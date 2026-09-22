import SwiftUI

/// 订阅分区（spec #21 D11，issue #35/#41）：每订阅一卡片（名称、URL host、
/// 状态、上次刷新、服务器数）+ 单个/全部更新 + 编辑 URL + 删除确认；新建即
/// 粘贴 URL。卡片数据来自订阅 projection（非敏感）；结构化刷新状态在呈现层
/// 本地化（story 42）。
struct SubscriptionsView: View {
  @ObservedObject var workflow: CatalogWorkflow
  let errors: ErrorAlertPresenter
  /// 删除完成后回调（被删身份集合；主窗口据此清除失效选择）。
  let onNodesRemoved: (Set<NodeID>) -> Void

  @State private var showAddSheet = false
  @State private var editTarget: SubscriptionSummary?
  @State private var deleteTarget: SubscriptionSummary?
  @State private var isRefreshingAll = false

  var body: some View {
    List {
      ForEach(workflow.subscriptions) { summary in
        SubscriptionCard(
          summary: summary,
          isRefreshing: workflow.refreshingSubscriptionIDs.contains(summary.id),
          onRefresh: { Task { await workflow.refreshSubscription(summary.id) } },
          onEdit: { editTarget = summary },
          onDelete: { deleteTarget = summary })
      }
    }
    .listStyle(.inset)
    .overlay {
      if workflow.subscriptions.isEmpty {
        ContentUnavailableView(
          "暂无订阅", systemImage: "arrow.triangle.2.circlepath",
          description: Text("用「添加订阅…」粘贴 HTTPS 订阅地址（SIP-008 JSON）")
        )
        .allowsHitTesting(false)
      }
    }
    .safeAreaInset(edge: .bottom) { bottomBar }
    .sheet(isPresented: $showAddSheet) {
      AddSubscriptionSheet(workflow: workflow, errors: errors)
    }
    .sheet(item: $editTarget) { summary in
      EditSubscriptionURLSheet(workflow: workflow, errors: errors, summary: summary)
    }
    .confirmationDialog(
      "删除订阅「\(deleteTarget?.name ?? "")」及其整棵子树？",
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } }),
      titleVisibility: .visible
    ) {
      Button("删除订阅", role: .destructive) { commitDelete() }
      Button("取消", role: .cancel) { deleteTarget = nil }
    } message: {
      Text(
        "将移除订阅源、固定分组与全部远端成员；若代理正走此订阅，代理会停止。此操作不可撤销。"
      )
    }
  }

  private var bottomBar: some View {
    HStack {
      Button {
        showAddSheet = true
      } label: {
        Label("添加订阅…", systemImage: "plus")
      }
      Spacer()
      Button {
        refreshAll()
      } label: {
        if isRefreshingAll {
          ProgressView().controlSize(.small)
        } else {
          Label("立即更新全部", systemImage: "arrow.triangle.2.circlepath")
        }
      }
      .disabled(workflow.subscriptions.isEmpty || isRefreshingAll)
    }
    .padding(12)
    .background(.bar)
  }

  private func refreshAll() {
    isRefreshingAll = true
    Task {
      await workflow.refreshAllSubscriptions()
      isRefreshingAll = false
    }
  }

  private func commitDelete() {
    guard let target = deleteTarget else { return }
    deleteTarget = nil
    Task {
      do {
        let outcome = try await workflow.removeSubscription(target.id)
        onNodesRemoved(outcome.removedNodeIDs)
      } catch {
        errors.present(error)
      }
    }
  }
}

/// 刷新状态 → 呈现文案（story 42：本地化在 UI 呈现层，不在 module 内）。
extension SubscriptionRefreshStatus {
  var badgeText: String {
    switch self {
    case .never: "尚未刷新"
    case .succeeded: "正常"
    case .failed: "刷新失败"
    }
  }

  var lastRefreshText: String {
    switch self {
    case .never: "尚未刷新"
    case .succeeded(let date), .failed(let date, _):
      date.formatted(date: .abbreviated, time: .shortened)
    }
  }

  var failureDetail: String? {
    if case .failed(_, let reason) = self { return reason }
    return nil
  }

  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}

/// 单张订阅卡片。
private struct SubscriptionCard: View {
  let summary: SubscriptionSummary
  let isRefreshing: Bool
  let onRefresh: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "arrow.triangle.2.circlepath")
          .foregroundStyle(summary.status.isFailed ? Color.red : Color.secondary)
        Text(summary.name)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        statusBadge
        if isRefreshing {
          ProgressView().controlSize(.small)
        } else {
          Button {
            onRefresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("立即更新此订阅")
        }
      }
      Text(summary.host)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help("订阅主机（完整地址不入诊断与日志）")
      HStack(spacing: 12) {
        Label("\(summary.serverCount) 台服务器", systemImage: "server.rack")
        Label(summary.status.lastRefreshText, systemImage: "clock")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if let detail = summary.status.failureDetail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
      }
      HStack {
        Spacer()
        Button("编辑 URL…", action: onEdit)
          .controlSize(.small)
        Button("删除…", role: .destructive, action: onDelete)
          .controlSize(.small)
      }
      .buttonStyle(.borderless)
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var statusBadge: some View {
    if summary.status.isFailed {
      Text(summary.status.badgeText)
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.red.opacity(0.15)))
        .foregroundStyle(.red)
    } else {
      Text(summary.status.badgeText)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

/// 「添加订阅」表单：粘贴 HTTPS 订阅地址；创建后立即首次刷新。
private struct AddSubscriptionSheet: View {
  let workflow: CatalogWorkflow
  let errors: ErrorAlertPresenter
  @Environment(\.dismiss) private var dismiss

  @State private var urlString = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("粘贴订阅地址（必须 HTTPS，返回 SIP-008 JSON；Content-Type 需为 application/json; charset=utf-8）。")
        .font(.callout)
        .foregroundStyle(.secondary)
      TextField("https://example.com/subscription.json", text: $urlString)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("添加并刷新") { create() }
          .keyboardShortcut(.defaultAction)
          .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 480)
  }

  private func create() {
    Task {
      do {
        _ = try await workflow.createSubscription(urlString: urlString)
        dismiss()
      } catch {
        errors.present(error)
      }
    }
  }
}

/// 「编辑订阅 URL」表单（保留订阅与固定分组身份）；保存后立即刷新。
/// URL 明文经显式命令读取（story 11）。
private struct EditSubscriptionURLSheet: View {
  let workflow: CatalogWorkflow
  let errors: ErrorAlertPresenter
  let summary: SubscriptionSummary
  @Environment(\.dismiss) private var dismiss

  @State private var urlString = ""
  @State private var loaded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("编辑订阅地址。订阅身份与固定分组全部保留；新地址刷新成功前保留最后一次成功内容。")
        .font(.callout)
        .foregroundStyle(.secondary)
      TextField("https://example.com/subscription.json", text: $urlString)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("保存并刷新") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 480)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      urlString = (try? workflow.subscriptionURL(for: summary.id)) ?? ""
    }
  }

  private func save() {
    Task {
      do {
        try await workflow.editSubscriptionURL(summary.id, urlString: urlString)
        dismiss()
      } catch {
        errors.present(error)
      }
    }
  }
}
