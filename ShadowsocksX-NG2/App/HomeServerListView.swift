import SwiftUI

/// 首页只浏览与激活；目录管理、运行控制仍由各自分区负责。
struct TargetTreeCard: View {
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var control: ProxyControlWorkflow
  @ObservedObject var serverList: HomeServerListState
  let onManageServers: () -> Void

  @FocusState private var listFocused: Bool
  @State private var activatingID: NodeID?
  @State private var activationError: String?
  @State private var activationRejected = false
  @State private var activationSkippedCount = 0

  private var activeID: NodeID? { control.snapshot.activeTarget?.id }
  private static let navigationKeys: Set<KeyEquivalent> = [
    .upArrow, .downArrow, .leftArrow, .rightArrow,
  ]

  var body: some View {
    HomeCard(
      title: "服务器列表", subtitle: nil,
      trailing: { EmptyView() },
      content: {
        ScrollViewReader { proxy in
          VStack(alignment: .leading, spacing: 12) {
            currentTarget {
              guard let activeID else { return }
              serverList.locate(activeID)
              listFocused = true
              // 展开后的行需要在下一轮布局中存在，才能滚动定位。
              Task { @MainActor in
                await Task.yield()
                proxy.scrollTo(activeID, anchor: .center)
              }
            }
            Divider()
            feedback
            if workflow.tree.isEmpty {
              emptyState
            } else {
              tree
                .onChange(of: serverList.selection) {
                  if let selection = serverList.selection,
                    serverList.visibleRows.contains(where: { $0.id == selection })
                  {
                    proxy.scrollTo(selection, anchor: .center)
                  }
                }
            }
          }
          .padding(.top, 12)
        }
      })
  }

  private func currentTarget(onLocate: @escaping () -> Void) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        if let activeID {
          Text("当前激活：\(workflow.tree.node(withID: activeID)?.name ?? "名称不可用")")
            .font(.callout.weight(.semibold))
          Text("路径：\(workflow.tree.pathSummary(for: activeID) ?? "路径不可用")")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        } else {
          Text("未激活")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let activeID {
        Button("定位", action: onLocate)
          .disabled(!workflow.tree.containsNode(activeID))
          .help("展开并定位当前激活项")
      }
    }
  }

  @ViewBuilder
  private var feedback: some View {
    if let failureMessage {
      Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
        .font(.callout)
        .foregroundStyle(.orange)
    } else if activationSkippedCount > 0 {
      Text("已跳过 \(activationSkippedCount) 个无效服务器")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var failureMessage: String? {
    if let activationError { return activationError }
    guard activationRejected else { return nil }
    return control.snapshot.activationFailure.map { AppPresentation.message(for: $0) }
      ?? "激活失败：目标已失效或没有可激活的服务器"
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("暂无服务器")
        .foregroundStyle(.secondary)
      Button("前往服务器管理", action: onManageServers)
    }
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
  }

  private var tree: some View {
    ScrollView {
      LazyVStack(spacing: 2) {
        ForEach(serverList.visibleRows) { row in
          HomeServerListRow(
            row: row,
            eligibility: workflow.activationEligibility(for: row.id),
            isSelected: serverList.selection == row.id,
            isActive: activeID == row.id,
            containsActive: activeID.map { serverList.ancestorIDs(for: $0).contains(row.id) }
              ?? false,
            isCollapsed: serverList.collapsedGroupIDs.contains(row.id),
            isActivationPending: activatingID == row.id,
            activationBlocked: activatingID != nil,
            onSelect: {
              serverList.select(row.id)
              listFocused = true
            },
            onToggle: { serverList.toggleGroup(row.id) },
            onActivate: { activate(row.id) }
          )
          .id(row.id)
        }
      }
      .padding(.vertical, 2)
    }
    .frame(height: 340)
    .focusable(interactions: .edit)
    .focused($listFocused)
    .accessibilityLabel("服务器列表")
    .onKeyPress(keys: Self.navigationKeys, phases: [.down, .repeat]) { press in
      switch press.key {
      case .upArrow: serverList.navigate(.upward)
      case .downArrow: serverList.navigate(.downward)
      case .leftArrow: serverList.navigate(.left)
      case .rightArrow: serverList.navigate(.right)
      default: return .ignored
      }
      return .handled
    }
    .onKeyPress(.return, phases: .down) { _ in
      if let selection = serverList.selection { activate(selection) }
      return .handled
    }
  }

  private func activate(_ id: NodeID) {
    guard activatingID == nil,
      serverList.activationTarget(
        activeTargetID: activeID, eligibility: workflow.activationEligibility(for: id)) == id
    else { return }
    activatingID = id
    activationError = nil
    activationRejected = false
    activationSkippedCount = 0
    Task { @MainActor in
      defer { activatingID = nil }
      do {
        switch try await workflow.activate(id) {
        case .activated(let skipped):
          activationSkippedCount = skipped
        case .rejectedActivation:
          activationRejected = true
        }
      } catch {
        activationError = AppPresentation.message(for: error)
      }
    }
  }
}

private struct HomeServerListRow: View {
  @Environment(\.controlActiveState) private var controlActiveState
  let row: HomeServerTreeRow
  let eligibility: ActivationEligibility?
  let isSelected: Bool
  let isActive: Bool
  let containsActive: Bool
  let isCollapsed: Bool
  let isActivationPending: Bool
  let activationBlocked: Bool
  let onSelect: () -> Void
  let onToggle: () -> Void
  let onActivate: () -> Void

  private var node: CatalogTreeNode { row.node }
  private var selectionTextColor: Color {
    Color(
      nsColor: controlActiveState == .inactive
        ? .unemphasizedSelectedTextColor : .alternateSelectedControlTextColor)
  }
  private var selectionBackgroundColor: Color {
    Color(
      nsColor: controlActiveState == .inactive
        ? .unemphasizedSelectedContentBackgroundColor : .selectedContentBackgroundColor)
  }
  private var textColor: Color {
    isSelected ? selectionTextColor : .primary
  }

  var body: some View {
    HStack(spacing: 8) {
      if node.isGroup {
        Button(action: onToggle) {
          Image(systemName: "chevron.right")
            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            .frame(width: 16, height: 24)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("\(isCollapsed ? "展开" : "收起") \(node.name)")
      } else {
        Color.clear.frame(width: 16, height: 24)
      }
      Button(action: onSelect) {
        HStack(spacing: 8) {
          Image(systemName: node.isGroup ? "folder" : "server.rack")
          VStack(alignment: .leading, spacing: 3) {
            Text(node.name)
              .font(.body.weight(isActive ? .semibold : .regular))
              .lineLimit(1)
              .help(node.name)
            if let eligibility, node.isGroup {
              Text(groupSummary(eligibility))
                .font(.caption)
            }
            if let reason = ineligibilityReason {
              Text(reason)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      if isActive || (containsActive && !isSelected) {
        Image(systemName: isActive ? "bolt.fill" : "bolt")
          .foregroundStyle(isSelected ? textColor : .orange)
          .frame(width: 16)
          .help(isActive ? "当前激活项" : "包含当前激活项")
          .accessibilityLabel(isActive ? "当前激活项" : "包含当前激活项")
      }
      // 保留当前选中行的操作区宽度。
      if !isActive && isSelected {
        Group {
          Button(isActivationPending ? "激活中…" : "激活", action: onActivate)
            .buttonStyle(SelectionActivationButtonStyle(foreground: selectionTextColor))
            .controlSize(.small)
            .disabled(activationBlocked || eligibility?.canActivate != true)
            .help(ineligibilityReason ?? "激活此项")
            .allowsHitTesting(isSelected)
        }
        .frame(width: 76, alignment: .trailing)
      }
    }
    .foregroundStyle(textColor)
    .padding(.leading, CGFloat(row.depth) * 18 + 8)
    .padding(.trailing, 8)
    .padding(.vertical, 6)
    .background(
      isSelected ? selectionBackgroundColor : .clear,
      in: RoundedRectangle(cornerRadius: 6))
  }

  private func groupSummary(_ eligibility: ActivationEligibility) -> String {
    let count = "\(eligibility.candidateCount) 个可激活服务器"
    return eligibility.skippedInvalidCount > 0
      ? "\(count) · 跳过 \(eligibility.skippedInvalidCount) 个" : count
  }

  private var ineligibilityReason: String? {
    if let reason = node.invalidReasons.first {
      return AppPresentation.message(
        for: ActivationFailure.invalidLeaf(node: node.id, reason: reason))
    }
    switch eligibility?.ineligibility {
    case .emptyGroup: return "空组，无法激活"
    case .noCandidates: return "没有可激活的有效服务器"
    case nil: return nil
    }
  }
}

/// 按钮与所在选中行共用语义前景色；不叠加系统按钮的着色背景。
private struct SelectionActivationButtonStyle: ButtonStyle {
  let foreground: Color

  func makeBody(configuration: Configuration) -> some View {
    SelectionActivationButtonContent(configuration: configuration, foreground: foreground)
  }
}

private struct SelectionActivationButtonContent: View {
  let configuration: ButtonStyle.Configuration
  let foreground: Color
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var isHovered = false

  private var backgroundOpacity: Double {
    guard isEnabled else { return 0 }
    if configuration.isPressed { return 0.20 }
    return isHovered ? 0.10 : 0
  }

  var body: some View {
    configuration.label
      .font(.callout.weight(.medium))
      .foregroundStyle(foreground.opacity(isEnabled ? 1 : 0.45))
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
      .background(foreground.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(
            foreground.opacity(isEnabled ? (contrast == .increased ? 0.8 : 0.45) : 0.20),
            lineWidth: contrast == .increased ? 2 : 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .onHover { isHovered = $0 }
  }
}
