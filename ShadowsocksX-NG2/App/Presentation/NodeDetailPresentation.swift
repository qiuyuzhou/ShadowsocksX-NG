import Foundation

/// 详情会话的展示值；包含参数明文，不进入目录工作流的非秘密投影或持久快照。
@MainActor
struct NodeDetailPresentation {
  struct Property: Equatable {
    let label: String
    let value: String
  }

  struct Properties: Equatable {
    let title: String
    let items: [Property]
  }

  let title: String
  var subtitle: String
  var properties: [Properties]

  init(
    node: CatalogTreeNode, server: ServerDetailPresentation?,
    eligibility: ActivationEligibility?, isActiveTarget: Bool
  ) {
    title = node.name
    var descriptions = [
      node.isGroup
        ? (node.isManual
          ? String(localized: "本地", table: "ServerDetails")
          : String(localized: "订阅", table: "ServerDetails"))
        : (node.isManual
          ? String(localized: "本地配置", table: "ServerDetails")
          : String(localized: "订阅配置", table: "ServerDetails"))
    ]
    if isActiveTarget { descriptions.append(String(localized: "活动目标", table: "ServerDetails")) }
    if node.isGroup {
      if let reason = eligibility?.ineligibility {
        switch reason {
        case .emptyGroup:
          descriptions.append(String(localized: "空分组，暂无子节点，不能激活。", table: "ServerDetails"))
        case .noCandidates:
          descriptions.append(String(localized: "分组中没有可激活的有效服务器。", table: "ServerDetails"))
        }
      }
      if let count = eligibility?.skippedInvalidCount, count > 0, eligibility?.canActivate == true {
        descriptions.append(
          String(localized: "激活时将跳过 \(count) 个存在已知阻塞问题的服务器。", table: "ServerDetails"))
      }
    } else {
      descriptions += node.invalidReasons.map { reason in
        if case .pluginNotProvided(let program) = reason,
          let warning = server?.plugin.availabilityWarning(for: program)
        {
          return warning
        }
        return AppPresentation.message(
          for: ActivationFailure.invalidLeaf(node: node.id, reason: reason))
      }
    }
    subtitle = descriptions.joined(separator: " · ")
    properties = [Self.information(for: node, eligibility: eligibility)]
    if let server { properties.append(Self.connection(for: server)) }
  }

  private static func connection(for server: ServerDetailPresentation) -> Properties {
    let program: String
    switch server.plugin.selection {
    case .none: program = String(localized: "无", table: "ServerDetails")
    case .named(let name), .unknown(let name): program = name
    }
    return Properties(
      title: String(localized: "连接信息", table: "ServerDetails"),
      items: [
        Property(label: String(localized: "地址", table: "ServerDetails"), value: server.address),
        Property(
          label: String(localized: "端口", table: "ServerDetails"), value: String(server.port)),
        Property(
          label: String(localized: "加密方式", table: "ServerDetails"), value: server.encryptionMethod),
        Property(label: String(localized: "插件", table: "ServerDetails"), value: program),
      ])
  }

  private static func information(
    for node: CatalogTreeNode, eligibility: ActivationEligibility?
  ) -> Properties {
    var information = [Property(label: "ID", value: node.id.rawValue)]
    if node.isGroup {
      information += [
        Property(
          label: String(localized: "有效服务器", table: "ServerDetails"),
          value: String(eligibility?.candidateCount ?? 0)),
        Property(
          label: String(localized: "无效服务器", table: "ServerDetails"),
          value: String(eligibility?.skippedInvalidCount ?? 0)),
      ]
    }
    information += [
      Property(
        label: String(localized: "创建时间", table: "ServerDetails"),
        value: Self.timestamp(node.createdAt)),
      Property(
        label: String(localized: "修改时间", table: "ServerDetails"),
        value: Self.timestamp(node.updatedAt)),
    ]
    return Properties(title: String(localized: "信息", table: "ServerDetails"), items: information)
  }

  mutating func appendPluginParameters(_ raw: String) {
    guard !raw.isEmpty else { return }
    let items: [Property]
    if let parsed = PluginOptionsDraft.parse(raw) {
      items = parsed.items.map { item in
        Property(
          label: item.key,
          value: item.hasValue
            ? (item.value.isEmpty ? String(localized: "空值", table: "ServerDetails") : item.value)
            : String(localized: "开关", table: "ServerDetails"))
      }
    } else {
      items = [Property(label: String(localized: "原始文本", table: "ServerDetails"), value: raw)]
    }
    properties.append(
      Properties(title: String(localized: "插件参数", table: "ServerDetails"), items: items))
  }

  mutating func appendPluginParameterFailure() {
    properties.append(
      Properties(
        title: String(localized: "插件参数", table: "ServerDetails"),
        items: [
          Property(
            label: String(localized: "插件参数", table: "ServerDetails"),
            value: String(localized: "无法读取插件参数", table: "ServerDetails"))
        ]))
  }

  private static func timestamp(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(date: .numeric, time: .shortened)
  }
}
