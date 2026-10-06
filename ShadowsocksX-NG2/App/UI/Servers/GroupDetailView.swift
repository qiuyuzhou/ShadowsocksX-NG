import SwiftUI

/// 分组详情（issue #32/#41）：直接子节点数与激活入口；名称只读展示，
/// 重命名经侧栏右键菜单。数据来自目录工作流 module 的树 projection 与
/// 激活资格查询；订阅固定分组名称由远端管理，只读。
struct GroupDetailView: View {
  /// 观察目录 projection：侧栏发起的变更（如右键重命名）需同步本详情面。
  @ObservedObject var workflow: CatalogWorkflow
  let groupID: NodeID
  /// 激活反馈共享状态：命令经它发出；pending 与最近反馈呈现在本详情面。
  @ObservedObject var activation: ActivationFeedbackState
  let errors: ErrorAlertPresenter

  private var node: CatalogTreeNode? { workflow.tree.node(withID: groupID) }
  private var isManual: Bool { node?.isManual ?? false }

  private var eligibility: ActivationEligibility? {
    workflow.activationEligibility(for: groupID)
  }

  var body: some View {
    VStack(spacing: 0) {
      // 详情头（票 #55）：与服务器详情同款图标 + 名称 + 来源说明。
      HStack(alignment: .center, spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.12))
          Image(systemName: "folder")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.tint)
        }
        .frame(width: 38, height: 38)
        VStack(alignment: .leading, spacing: 2) {
          Text(workflow.displayName(for: groupID))
            .font(.title2.weight(.semibold))
            .lineLimit(1)
          Text(isManual ? "手动分组" : "订阅分组")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(.leading, 28)
      .padding(.trailing, 32)
      .padding(.top, 20)
      .padding(.bottom, 16)
      Divider()
      Form {
        Section {
          LabeledContent("直接子节点", value: "\(directChildCount)")
          if let eligibility, eligibility.skippedInvalidCount > 0 {
            LabeledContent("已知无效服务器", value: "\(eligibility.skippedInvalidCount)")
          }
          LabeledContent("来源", value: isManual ? "手动" : "订阅")
          Button {
            Task { @MainActor in
              do {
                _ = try await activation.activate(groupID, via: workflow)
              } catch {
                errors.present(error)
              }
            }
          } label: {
            Label(
              activation.pendingTargetID == groupID ? "激活中…" : "激活此分组",
              systemImage: "bolt.fill")
          }
          .disabled(!(eligibility?.canActivate ?? false) || activation.isPending)
          activationFeedback
          if directChildCount == 0 {
            Text("空分组，暂无子节点，不能激活。")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else if eligibility?.canActivate == false {
            Text("分组中没有可激活的有效服务器。")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else if let eligibility, eligibility.skippedInvalidCount > 0 {
            Text("激活时将跳过 \(eligibility.skippedInvalidCount) 个存在已知阻塞问题的服务器。")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .padding(.leading, 20)
      .padding(.trailing, 24)
    }
  }

  private var directChildCount: Int { node?.childCount ?? 0 }

  /// 命令后内联反馈（拒绝原因/跳过数/意外错误）；会话级反馈，直至下一次
  /// 激活命令前保留。成功且无跳过不呈现。
  @ViewBuilder
  private var activationFeedback: some View {
    if let feedback = activation.feedback {
      switch feedback {
      case .rejected(let failure):
        Text(AppPresentation.message(for: failure))
          .font(.footnote)
          .foregroundStyle(.orange)
      case .failed(let message):
        Text(message)
          .font(.footnote)
          .foregroundStyle(.orange)
      case .activated(let skipped) where skipped > 0:
        Text("已跳过 \(skipped) 个存在已知阻塞问题的服务器。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      case .activated:
        EmptyView()
      }
    }
  }
}
