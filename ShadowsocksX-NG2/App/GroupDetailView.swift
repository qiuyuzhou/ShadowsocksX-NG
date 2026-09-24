import SwiftUI

/// 分组详情（issue #32/#41）：名称编辑（手动组）、直接子节点数与激活入口。
/// 数据来自目录工作流 module 的树 projection 与激活资格查询；订阅固定分组
/// 名称由远端管理，只读。空组保留可编辑（可先搭结构再填内容）。
struct GroupDetailView: View {
  let workflow: CatalogWorkflow
  let groupID: NodeID
  let errors: ErrorAlertPresenter

  @State private var name = ""

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
        Section("分组") {
          TextField("名称", text: $name)
            .disabled(!isManual)
          if isManual {
            Button("保存名称") { saveName() }
          }
        }
        Section {
          LabeledContent("直接子节点", value: "\(directChildCount)")
          if let eligibility, eligibility.skippedInvalidCount > 0 {
            LabeledContent("已知无效服务器", value: "\(eligibility.skippedInvalidCount)")
          }
          LabeledContent("来源", value: isManual ? "手动" : "订阅")
          Button {
            Task {
              do {
                _ = try await workflow.activate(groupID)
              } catch {
                errors.present(error)
              }
            }
          } label: {
            Label("激活此分组", systemImage: "bolt.fill")
          }
          .disabled(!(eligibility?.canActivate ?? false))
          if directChildCount == 0 {
            Text("空分组保留可编辑，但不能激活。")
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
    .onAppear(perform: loadName)
    .onChange(of: groupID) { _, _ in loadName() }
  }

  private var directChildCount: Int { node?.childCount ?? 0 }

  private func loadName() {
    name = workflow.displayName(for: groupID)
  }

  private func saveName() {
    Task {
      do {
        try await workflow.renameGroup(groupID, to: name)
      } catch {
        errors.present(error)
      }
    }
  }
}
