import SwiftUI

/// 已保存服务器资料；详情只装载插件参数，不读取密码或编辑草稿。
struct ServerDetailView: View {
  @ObservedObject var workflow: CatalogWorkflow
  let serverID: NodeID
  let isActiveTarget: Bool
  @StateObject private var parameters = ServerDetailParameters()

  private var node: CatalogTreeNode? { workflow.tree.node(withID: serverID) }

  var body: some View {
    ScrollView {
      if let facts = workflow.serverDetailPresentation(for: serverID) {
        VStack(alignment: .leading, spacing: 24) {
          header(facts)
          if let node, node.isInvalid {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(Array(node.invalidReasons.enumerated()), id: \.offset) { _, reason in
                Label(
                  AppPresentation.message(
                    for: ActivationFailure.invalidLeaf(node: node.id, reason: reason)),
                  systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
              }
            }
          }
          VStack(alignment: .leading, spacing: 12) {
            Text("连接信息").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
              informationRow("地址", value: facts.address)
              informationRow("端口", value: String(facts.port))
              informationRow("加密方式", value: facts.encryptionMethod)
            }
          }
          Divider()
          pluginSection(facts.plugin)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
      }
    }
    .onAppear { parameters.showServer(serverID, load: workflow.serverDetailPluginOptions) }
    .onReceive(workflow.serverDetailChanges) { affected in
      parameters.didRefresh(affectedServers: affected, load: workflow.serverDetailPluginOptions)
    }
  }

  private func header(_ facts: ServerDetailPresentation) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "server.rack")
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 40, height: 40)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 4) {
        Text(facts.name)
          .font(.title2.weight(.semibold))
          .textSelection(.enabled)
        HStack(spacing: 8) {
          Text(node?.source == .subscription ? "订阅节点 · 远端管理" : "手动服务器")
          if isActiveTarget {
            Label("活动目标", systemImage: "bolt.fill")
          }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func informationRow(_ label: String, value: String) -> some View {
    GridRow(alignment: .top) {
      Text(label).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }
  }

  private func pluginSection(_ plugin: PluginSectionState) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("插件").font(.headline)
      switch plugin.selection {
      case .none:
        Text("无").foregroundStyle(.secondary)
      case .named(let program), .unknown(let program):
        Text(program).textSelection(.enabled)
        if let notice = plugin.availabilityWarning(for: program) {
          Label(notice, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
        } else if plugin.unresolvedProgram(for: plugin.selection) != nil {
          Label("未找到插件“\(program)”。", systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
        }
        Text("插件参数")
          .font(.callout.weight(.medium))
          .foregroundStyle(.secondary)
        if parameters.failure != nil {
          VStack(alignment: .leading, spacing: 8) {
            Label("无法读取插件参数", systemImage: "exclamationmark.triangle")
            Button("重新加载") { parameters.reload(load: workflow.serverDetailPluginOptions) }
          }
        } else if plugin.optionsPresent {
          PluginOptionsReadOnlyEditor(draft: parameters.options)
        } else {
          Text("无").foregroundStyle(.secondary)
        }
      }
    }
  }

}
