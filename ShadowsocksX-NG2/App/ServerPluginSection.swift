import SwiftUI

/// 服务器详情的插件区（issue #38/D10，地图 #52 票 #55）：受管选择器——
/// 「无」+ 受管列表；集外引用（Legacy 导入/订阅带入）追加显式「本版本未
/// 提供」项使当前状态可见并原样保留。选中受管项才显示供应链事实（来源
/// 项目、许可证、固定版本、重签）与参数输入。
struct ServerPluginSection: View {
  @Binding var selection: PluginSelection
  @Binding var optionsText: String
  let plugin: PluginSectionState?
  let isEditable: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      picker
      detail
    }
  }

  @ViewBuilder
  private var picker: some View {
    if let plugin {
      Picker("受管理插件", selection: $selection) {
        Text("无").tag(PluginSelection.none)
        ForEach(plugin.managed, id: \.program) { info in
          Text(info.program).tag(PluginSelection.managed(program: info.program))
        }
        if case .unknown(let program) = plugin.selection {
          Text("\(program)（本版本未提供）").tag(PluginSelection.unknown(program: program))
        }
      }
      .disabled(!isEditable)
    } else {
      Text("不可用").foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let plugin {
      switch selection {
      case .none:
        Text("不使用插件：生成的配置不含 plugin 字段。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      case .managed(let program):
        managedDetails(program: program, plugin: plugin)
      case .unknown(let program):
        unknownNotice(program: program, plugin: plugin)
      }
    }
  }

  /// 选中受管项：供应链事实与参数输入。
  @ViewBuilder
  private func managedDetails(program: String, plugin: PluginSectionState) -> some View {
    if let info = plugin.managed.first(where: { $0.program == program }) {
      VStack(alignment: .leading, spacing: 8) {
        Text("来源项目 \(info.project) · 许可证 \(info.license) · 固定版本 \(info.release)")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Text("随 app 打包，构建期经 Developer ID 重签：\(info.signIdentifier)")
          .font(.footnote)
          .foregroundStyle(.secondary)
        if !plugin.provided {
          Label(
            "受管插件可执行文件缺失：激活会被点名拒绝；请重新安装本 app。",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.footnote)
          .foregroundStyle(.orange)
        }
        TextField(
          "插件参数",
          text: $optionsText,
          prompt: Text("选择插件后填写参数（如 mode=websocket;host=…）")
        )
        .textFieldStyle(.roundedBorder)
        .disabled(!isEditable)
      }
    }
  }

  /// 集外引用：原样保留并明确指出当前 app 无法提供该插件。
  @ViewBuilder
  private func unknownNotice(program: String, plugin: PluginSectionState) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        "本版本未提供「\(program)」：引用原样保留，激活包含该服务器会被点名拒绝；可改选「无」或受管插件。",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.footnote)
      .foregroundStyle(.orange)
      if plugin.optionsPresent {
        Text("插件参数已配置（存于钥匙串，原样保留）。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }
}
