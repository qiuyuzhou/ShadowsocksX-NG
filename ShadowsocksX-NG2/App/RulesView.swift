import SwiftUI

/// Read-only first delivery. Every interaction goes through the workflow; no
/// filesystem, runtime control, or placeholder mutation actions live here.
struct RulesView: View {
  @ObservedObject var workflow: RulesWorkflow

  var body: some View {
    VStack(spacing: 0) {
      if workflow.snapshot.isLoading {
        ProgressView(RulesCopy.text("加载规则…")).padding()
      }
      if !workflow.snapshot.issues.isEmpty {
        VStack(alignment: .leading) {
          Label(RulesCopy.text("集合不完整"), systemImage: "exclamationmark.triangle")
          Text(RulesCopy.text("集合不完整时，覆盖解释仅基于已加载来源。")).font(.caption)
          ForEach(workflow.snapshot.issues, id: \.self) { issue in
            Text(verbatim: issueDescription(issue))
              .font(.caption).textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
      }
      HSplitView {
        sourceList.frame(minWidth: 160, idealWidth: 180, maxWidth: 240)
        VStack(spacing: 0) {
          filters.padding()
          if let source = workflow.snapshot.sources.first(where: {
            $0.id == workflow.snapshot.query.source
          }) {
            RulesSourceDetailsView(source: source).padding(.horizontal)
          }
          ruleTable
          if workflow.snapshot.rows.isEmpty && !workflow.snapshot.isLoading {
            ContentUnavailableView(
              RulesCopy.text("没有符合条件的规则"), systemImage: "line.3.horizontal.decrease.circle")
          }
          if let row = workflow.snapshot.rows.first(where: {
            workflow.snapshot.selection.contains($0.id)
          }) {
            Divider()
            RulesDetailsView(row: row, sources: workflow.snapshot.sources)
              .frame(minHeight: 110, idealHeight: 180, maxHeight: 260)
          }
        }.frame(minWidth: 500)
      }
    }
    .task {
      if workflow.snapshot.version.isEmpty { await workflow.refresh() }
    }
  }

  private var sourceList: some View {
    List(selection: sourceBinding) {
      Text(RulesCopy.text("全部规则")).tag(RulesSourceChoice.all)
      ForEach(RulesSource.allCases) { source in
        HStack {
          Text(source.label)
          Spacer()
          if let metadata = workflow.snapshot.sources.first(where: { $0.id == source }) {
            Text(metadata.count, format: .number).foregroundStyle(.secondary)
          } else if !workflow.snapshot.isLoading && !workflow.snapshot.version.isEmpty {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
          }
        }.tag(RulesSourceChoice.source(source))
      }
    }
  }

  private var filters: some View {
    HStack {
      TextField(
        RulesCopy.text("搜索规则"),
        text: Binding(
          get: { workflow.snapshot.query.search },
          set: { value in updateQuery { $0.search = value } })
      )
      .textFieldStyle(.roundedBorder)
      Picker(
        RulesCopy.text("行动"),
        selection: Binding(
          get: { workflow.snapshot.query.action },
          set: { value in updateQuery { $0.action = value } })
      ) {
        Text(RulesCopy.text("全部行动")).tag(Optional<RuleAction>.none)
        Text(RulesCopy.text("直连")).tag(Optional(RuleAction.direct))
        Text(RulesCopy.text("代理")).tag(Optional(RuleAction.proxy))
      }.labelsHidden().fixedSize()
      Picker(
        RulesCopy.text("匹配内容"),
        selection: Binding(
          get: { workflow.snapshot.query.sort },
          set: { value in updateQuery { $0.sort = value } })
      ) {
        Text("A → Z").tag(RulesQuery.Sort.ascending)
        Text("Z → A").tag(RulesQuery.Sort.descending)
      }.labelsHidden().fixedSize()
    }
  }

  private var ruleTable: some View {
    Table(
      workflow.snapshot.rows,
      selection: Binding(
        get: { workflow.snapshot.selection }, set: { workflow.select($0) })
    ) {
      TableColumn(RulesCopy.text("匹配内容")) { row in Text(verbatim: row.displayContent) }
        .width(min: 170, ideal: 260)
      TableColumn(RulesCopy.text("类型")) { row in Text(verbatim: row.matchType) }
      TableColumn(RulesCopy.text("行动")) { row in Text(row.actionLabel) }
      TableColumn(RulesCopy.text("来源")) { row in Text(row.sourceLabels) }
      TableColumn(RulesCopy.text("状态")) { row in Text(row.statusLabel) }
    }
  }

  private var sourceBinding: Binding<RulesSourceChoice?> {
    Binding(
      get: {
        workflow.snapshot.query.source.map(RulesSourceChoice.source) ?? .all
      },
      set: { choice in
        updateQuery {
          if case .source(let source) = choice { $0.source = source } else { $0.source = nil }
        }
      })
  }

  private func updateQuery(_ update: (inout RulesQuery) -> Void) {
    var query = workflow.snapshot.query
    update(&query)
    workflow.query(query)
  }

  private func issueDescription(_ issue: RulesPageSnapshot.Issue) -> String {
    switch issue {
    case .userDocument(let detail): "\(RulesCopy.text("自定义规则")): \(detail)"
    case .builtin(let source, let detail): "\(source.label): \(detail)"
    }
  }
}

private struct RulesDetailsView: View {
  let row: RulesRow
  let sources: [RulesSourceSnapshot]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: row.displayContent).font(.headline)
        Text(row.sourceLabels)
        Text(row.statusLabel)
        ForEach(row.relationships, id: \.kind) { relationship in
          VStack(alignment: .leading) {
            Text(relationship.browsingLabel)
            ForEach(relationship.covering, id: \.self) { identity in
              Text(
                verbatim: identity.match.browsingContent + " · "
                  + RulesCopy.text(identity.action == .direct ? "直连" : "代理"))
            }
          }
        }
        if let coverage = row.fixedCoverage {
          Text(RulesCopy.text("固定本地策略"))
          ForEach(coverage.matches, id: \.self) { match in
            Text(verbatim: match.browsingContent)
          }
          if coverage.includesSimpleHostname { Text(RulesCopy.text("简单主机名")) }
          Text(RulesCopy.text("固定策略优先，以下范围始终直连。"))
        }
        if row.isFixed {
          Text(RulesCopy.text("固定策略优先，以下范围始终直连。"))
        } else {
          Text(RulesCopy.text("覆盖分析仅描述当前规则集合，不表示运行时已生效。"))
        }
        ForEach(sources.filter { row.sources.contains($0.id) }) { source in
          RulesSourceDetailsView(source: source)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled)
    }
  }
}

enum RulesCopy {
  static func text(_ key: String) -> String {
    NSLocalizedString(key, tableName: "Rules", bundle: .main, value: key, comment: "")
  }
}

extension RulesSource {
  var label: String {
    switch self {
    case .custom: RulesCopy.text("自定义规则")
    case .fixed: RulesCopy.text("固定本地策略")
    case .geolocationCN: "geolocation-cn"
    case .chinaIPv4: "china-ipv4"
    case .gfwlist: "GFWList"
    }
  }
}

extension RulesRow {
  var displayContent: String { identity == nil ? RulesCopy.text("简单主机名") : content }
  var sourceLabels: String {
    RulesSource.allCases.filter { sources.contains($0) }.map(\.label).joined(separator: ", ")
  }
  var actionLabel: String { RulesCopy.text(action == .direct ? "直连" : "代理") }
  var matchType: String {
    switch identity?.match {
    case .domainExact: RulesCopy.text("精确域名")
    case .domainSuffix: RulesCopy.text("域名后缀")
    case .ipv4CIDR: "IPv4 CIDR"
    case .ipv6CIDR: "IPv6 CIDR"
    case nil: RulesCopy.text("简单主机名")
    }
  }
  var statusLabel: String {
    if isFixed { return RulesCopy.text("固定本地策略") }
    var labels = relationships.map(\.browsingLabel)
    if let fixedCoverage {
      let label =
        RulesCopy.text(action == .direct ? "被同行动规则覆盖" : "被相反行动规则遮蔽")
        + " · " + RulesCopy.text("固定本地策略")
      labels.append(
        fixedCoverage.extent == .partial ? label + " · " + RulesCopy.text("部分重叠") : label)
    }
    return labels.isEmpty ? RulesCopy.text("独立候选") : labels.joined(separator: "; ")
  }
}

private enum RulesSourceChoice: Hashable {
  case all
  case source(RulesSource)
}

extension RuleRelationship {
  var browsingLabel: String {
    let label = RulesCopy.text(kind == .absorption ? "被同行动规则覆盖" : "被相反行动规则遮蔽")
    return extent == .partial ? label + " · " + RulesCopy.text("部分重叠") : label
  }
}
