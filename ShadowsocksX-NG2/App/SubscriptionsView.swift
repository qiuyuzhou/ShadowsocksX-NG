import SwiftUI

/// 订阅分区（spec #21 D11，issue #35）：每订阅一卡片（名称、URL host、状态、
/// 上次刷新、服务器数）+ 单个/全部更新 + 编辑 URL + 删除确认；新建即粘贴 URL。
struct SubscriptionsView: View {
  @ObservedObject var viewModel: CatalogViewModel

  @State private var showAddSheet = false
  @State private var editTarget: SubscriptionRecord?
  @State private var deleteTarget: SubscriptionRecord?
  @State private var isRefreshingAll = false

  var body: some View {
    List {
      ForEach(viewModel.subscriptions) { record in
        SubscriptionCard(
          info: viewModel.subscriptionCard(for: record),
          isRefreshing: viewModel.inFlightRefreshIDs.contains(record.id),
          onRefresh: { Task { await viewModel.refreshSubscription(record.id) } },
          onEdit: { editTarget = record },
          onDelete: { deleteTarget = record })
      }
    }
    .listStyle(.inset)
    .overlay {
      if viewModel.subscriptions.isEmpty {
        ContentUnavailableView(
          "暂无订阅", systemImage: "arrow.triangle.2.circlepath",
          description: Text("用「添加订阅…」粘贴 HTTPS 订阅地址（SIP-008 JSON）")
        )
        .allowsHitTesting(false)
      }
    }
    .safeAreaInset(edge: .bottom) { bottomBar }
    .sheet(isPresented: $showAddSheet) {
      AddSubscriptionSheet(viewModel: viewModel)
    }
    .sheet(item: $editTarget) { record in
      EditSubscriptionURLSheet(viewModel: viewModel, record: record)
    }
    .confirmationDialog(
      "删除订阅「\(deleteTarget.map { viewModel.displayName(for: $0.groupID) } ?? "")」及其整棵子树？",
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } }),
      titleVisibility: .visible
    ) {
      Button("删除订阅", role: .destructive) { commitDelete() }
      Button("取消", role: .cancel) { deleteTarget = nil }
    } message: {
      Text(
        "将移除订阅源、固定分组、全部远端成员与本地启用状态；若代理正走此订阅，代理会停止。此操作不可撤销。"
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
      .disabled(viewModel.subscriptions.isEmpty || isRefreshingAll)
    }
    .padding(12)
    .background(.bar)
  }

  private func refreshAll() {
    isRefreshingAll = true
    Task {
      await viewModel.refreshAllSubscriptions()
      isRefreshingAll = false
    }
  }

  private func commitDelete() {
    guard let target = deleteTarget else { return }
    deleteTarget = nil
    Task {
      do {
        try await viewModel.removeSubscription(target.id)
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }
}

/// 单张订阅卡片。
private struct SubscriptionCard: View {
  let info: SubscriptionCardInfo
  let isRefreshing: Bool
  let onRefresh: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "arrow.triangle.2.circlepath")
          .foregroundStyle(info.isFailed ? Color.red : Color.secondary)
        Text(info.name)
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
      Text(info.host)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help("订阅主机（完整地址不入诊断与日志）")
      HStack(spacing: 12) {
        Label("\(info.serverCount) 台服务器", systemImage: "server.rack")
        Label(info.lastRefreshText, systemImage: "clock")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if let detail = info.statusDetail {
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
    if info.isFailed {
      Text(info.statusText)
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.red.opacity(0.15)))
        .foregroundStyle(.red)
    } else {
      Text(info.statusText)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

/// 「添加订阅」表单：粘贴 HTTPS 订阅地址；创建后立即首次刷新。
private struct AddSubscriptionSheet: View {
  @ObservedObject var viewModel: CatalogViewModel
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
        try await viewModel.createSubscription(urlString: urlString)
        dismiss()
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }
}

/// 「编辑订阅 URL」表单（保留订阅与固定分组身份）；保存后立即刷新。
private struct EditSubscriptionURLSheet: View {
  @ObservedObject var viewModel: CatalogViewModel
  let record: SubscriptionRecord
  @Environment(\.dismiss) private var dismiss

  @State private var urlString = ""
  @State private var loaded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("编辑订阅地址。订阅身份、固定分组与本地启用状态全部保留；新地址刷新成功前保留最后一次成功内容。")
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
      let stored = (try? viewModel.credentials.secret(for: record.urlRef)) ?? nil
      urlString = stored ?? ""
    }
  }

  private func save() {
    Task {
      do {
        try await viewModel.editSubscriptionURL(record.id, urlString: urlString)
        dismiss()
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }
}
