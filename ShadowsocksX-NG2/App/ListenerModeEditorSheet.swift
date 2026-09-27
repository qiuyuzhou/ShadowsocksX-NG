import SwiftUI

struct ListenerModeEditorSession: Identifiable {
  let id = UUID()
  let initialMode: ListenerMode
}

struct ListenerModeEditorSheet: View {
  @ObservedObject var workflow: SettingsWorkflow
  @Environment(\.dismiss) private var dismiss
  @State private var selectedMode: ListenerMode
  @State private var saveError: String?
  @State private var savedWithUnknownOccupancy: [SettingsPortID]?

  init(workflow: SettingsWorkflow, initialMode: ListenerMode) {
    self.workflow = workflow
    _selectedMode = State(initialValue: initialMode)
  }

  private var didSave: Bool { savedWithUnknownOccupancy != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("监听方式")
        .font(.title2)
      Text("SOCKS 与 HTTP 代理共用此监听方式。")
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 10) {
        ForEach(ListenerMode.allCases, id: \.self) { mode in
          modeChoice(mode)
        }
      }

      if selectedMode.exposesNetworkInterfaces {
        Label(
          "此方式会在所选网络接口开放无鉴权的代理端口；其他设备能否连接仍受防火墙与网络限制。",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }

      if let savedWithUnknownOccupancy, !savedWithUnknownOccupancy.isEmpty {
        Text("无法确认 \(portNames(savedWithUnknownOccupancy)) 是否空闲，监听方式仍已保存。")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      if let saveError {
        Text(saveError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button(didSave ? "完成" : "取消", role: didSave ? nil : .cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(workflow.isCommitting)

        if !didSave {
          Button(workflow.isCommitting ? "保存中…" : "保存") {
            Task { await save() }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(workflow.isCommitting)
        }
      }
    }
    .padding(24)
    .frame(width: 440)
    .interactiveDismissDisabled(workflow.isCommitting)
  }

  private func modeChoice(_ mode: ListenerMode) -> some View {
    Button {
      selectedMode = mode
      saveError = nil
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: selectedMode == mode ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selectedMode == mode ? Color.accentColor : Color.secondary)
        VStack(alignment: .leading, spacing: 3) {
          Text(mode.displayName)
            .foregroundStyle(.primary)
          Text(mode.bindingHint)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(workflow.isCommitting || didSave)
    .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
  }

  private func save() async {
    saveError = nil
    switch await workflow.saveListenerMode(selectedMode) {
    case .saved(let unknownOccupancy):
      if unknownOccupancy.isEmpty {
        dismiss()
      } else {
        savedWithUnknownOccupancy = unknownOccupancy
      }
    case .rejected(.occupied(let ports)):
      saveError = "\(portNames(ports))已被占用；请先在「端口设置」中选择空闲端口。"
    case .rejected(.inProgress):
      saveError = "设置正在保存，请稍后重试。"
    case .rejected:
      saveError = "无法保存此监听方式。"
    case .persistenceFailed:
      saveError = workflow.lastFailure?.presentableMessage ?? "监听方式保存失败。"
    }
  }

  private func portNames(_ ports: [SettingsPortID]) -> String {
    ports.map { $0 == .socks ? "SOCKS5 端口" : "HTTP 端口" }.joined(separator: "、")
  }
}
