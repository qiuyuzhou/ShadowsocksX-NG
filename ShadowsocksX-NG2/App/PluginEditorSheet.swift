import SwiftUI
import UniformTypeIdentifiers

struct PluginEditorSheet: View {
  @ObservedObject var model: PluginManagementModel
  let session: PluginEditorSession
  @Environment(\.dismiss) private var dismiss
  /// Each presentation intentionally seeds a fresh, independent draft.
  @State private var name: String
  @State private var path: String
  @State private var failure: String?
  @State private var showFilePicker = false

  init(model: PluginManagementModel, session: PluginEditorSession) {
    self.model = model
    self.session = session
    _name = State(initialValue: session.program ?? "")
    _path = State(initialValue: session.initialPath)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.title2)
      VStack(alignment: .leading, spacing: 5) {
        Text("插件名称")
        if session.program != nil {
          Text(name).textSelection(.enabled)
        } else {
          TextField("插件名称", text: $name).textFieldStyle(.roundedBorder)
        }
        if let issue = model.nameIssue(name, session: session) {
          fieldError(issue)
        }
      }
      VStack(alignment: .leading, spacing: 5) {
        Text("可执行文件路径")
        HStack {
          TextField("可执行文件路径", text: $path).textFieldStyle(.roundedBorder)
          Button("选择文件…") { showFilePicker = true }
        }
        if let issue = model.pathIssue(path) { fieldError(issue) }
      }
      if !session.isEditing
        && ManagedPluginCatalog.info(
          forProgram: name.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
      {
        Text("保存后将覆盖同名内置插件。")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let failure {
        Label(failure, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("保存") {
          do {
            try model.save(session, name: name, path: path)
            dismiss()
          } catch {
            failure = PluginManagementCopy.error(error)
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          model.snapshot.mappingsUnreadable || model.nameIssue(name, session: session) != nil
            || model.pathIssue(path) != nil)
      }
    }
    .padding(24)
    .frame(width: 560)
    .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
      switch result {
      case .success(let url): path = url.path
      case .failure: failure = String(localized: "无法选择文件，请重试。")
      }
    }
  }

  private var title: String {
    if session.isEditing { return String(localized: "编辑插件") }
    return session.program == nil
      ? String(localized: "新增插件") : String(localized: "覆盖内置插件")
  }

  private func fieldError(_ error: PluginMappingError) -> some View {
    Text(PluginManagementCopy.error(error)).font(.caption).foregroundStyle(.red)
  }
}
