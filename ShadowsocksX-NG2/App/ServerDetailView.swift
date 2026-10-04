import SwiftUI

/// 服务器详情：标题反映已保存名称，字段持有独立草稿；订阅服务器只读。
/// 保存成功后重载提交值，失败保留草稿；分享经分区工具栏命令读取已保存
/// 配置（ServersView+Share.swift）。
struct ServerDetailView: View {
  @ObservedObject var workflow: CatalogWorkflow
  let serverID: NodeID
  /// 运行时事实（活动目标标记）：由父视图从既有接缝传入，详情面不持控制器。
  let isActiveTarget: Bool
  let errors: ErrorAlertPresenter

  /// 连接字段草稿由共享 module 持有（与新建表单同一 interface），经显式
  /// 编辑命令装载（凭据明文仅在编辑动作中出现）。
  @StateObject private var fields = ServerFormFields()
  @State private var isSubmitting = false
  @State private var loadedServerID: NodeID?
  @FocusState private var fieldFocus: ServerFormField?

  private var formState: ServerEditForm? {
    workflow.serverEditForm(for: serverID)
  }

  private var isEditable: Bool {
    formState?.isEditable ?? false
  }

  private var node: CatalogTreeNode? {
    workflow.tree.node(withID: serverID)
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          detailHeader
          formContent
        }
        .padding(.leading, 28)
        .padding(.trailing, 32)
        .disabled(isSubmitting)
        .padding(.top, 20)
        .padding(.bottom, 24)
      }
      if isEditable {
        detailFooter
      }
    }
    .onAppear(perform: loadForm)
    .onChange(of: serverID) { _, _ in loadForm() }
  }

  // MARK: - 详情头与表单

  private var detailHeader: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.12))
          Image(systemName: "server.rack")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.tint)
        }
        .frame(width: 38, height: 38)
        VStack(alignment: .leading, spacing: 2) {
          Text(workflow.displayName(for: serverID))
            .font(.title2.weight(.semibold))
            .lineLimit(1)
          Text(sourceDescription)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if let node, node.isInvalid {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("该服务器存在已知阻塞问题，激活会被点名拒绝")
        }
      }
      .padding(.bottom, 16)
      Divider()
    }
  }

  private var sourceDescription: String {
    guard let node else { return "" }
    if node.source == .subscription {
      return "订阅节点 · 远端管理"
    }
    return isActiveTarget ? "手动服务器 · 活动目标" : "手动服务器"
  }

  @ViewBuilder
  private var formContent: some View {
    if let node, node.isInvalid {
      invalidBanner(node)
    }
    if !isEditable {
      Label("订阅节点由远端管理：连接字段只读。", systemImage: "info.circle")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 16)
    }
    ServerFormFieldsGrid(
      fields: fields, plugin: formState?.plugin, isEditable: isEditable,
      fieldFocus: $fieldFocus
    )
    .padding(.top, 20)
  }

  private func invalidBanner(_ node: CatalogTreeNode) -> some View {
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
    .padding(.top, 16)
  }

  /// 底部操作区：重置恢复已保存值，保存提交草稿。
  private var detailFooter: some View {
    VStack(spacing: 0) {
      Divider()
      HStack {
        Spacer(minLength: 0)
        Button("重置") { loadForm() }
          .disabled(!fields.hasChanges || isSubmitting)
        Button("保存") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!fields.hasChanges || isSubmitting)
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 12)
    }
    .background(.bar)
  }

  // MARK: - 表单装载与提交

  private func loadForm() {
    guard let state = formState else { return }
    fields.load(from: state)
    loadedServerID = serverID
  }

  private func save() {
    guard !isSubmitting, fields.hasChanges else { return }
    guard fields.validateForSubmit(), let draft = fields.draft else {
      fieldFocus = fields.firstErrorField
      return
    }
    let id = serverID
    isSubmitting = true
    Task {
      defer { isSubmitting = false }
      do {
        try await workflow.updateServer(id, draft: draft)
        if loadedServerID == id { loadForm() }
      } catch {
        errors.present(error)
      }
    }
  }
}
