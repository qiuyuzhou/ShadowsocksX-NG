import SwiftUI

/// First-launch and explicit re-import surface for issue #36. The sheet never
/// exposes passwords, plugin options, or remote URL values; it presents counts,
/// named skipped records, and identity regeneration.
struct LegacyImportSheet: View {
  @ObservedObject var workflow: CatalogWorkflow
  @Environment(\.dismiss) private var dismiss

  @State private var isImporting = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(workflow.legacyImportState.completed ? "再次导入 Legacy 配置" : "发现 Legacy 配置")
        .font(.title2.weight(.semibold))
      Text(
        workflow.legacyImportState.completed
          ? "再次导入会创建新的独立手动分组，不会合并或修改原 Legacy 数据。"
          : "只复制旧版服务器记录，不迁移偏好或活动目标。导入是一次快照提交；代理保持关闭，也不会写入系统代理。"
      )
      .foregroundStyle(.secondary)

      if let report = workflow.legacyImportReport {
        reportView(report)
      } else {
        Text("密码和插件参数会进入 2.0 的凭据引用边界；插件程序引用会原样保留，但不会复制 Legacy 插件二进制。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(.red)
      }

      HStack {
        Button("暂不导入") { dismiss() }
        Spacer()
        Button(workflow.legacyImportState.completed ? "再次导入" : "导入") {
          importLegacy()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isImporting || !workflow.legacyImportState.snapshotFound)
      }
    }
    .padding(24)
    .frame(width: 560, height: 560)
  }

  @ViewBuilder
  private func reportView(_ report: LegacyImportReport) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Label(
          "已导入 \(report.importedServerCount) 台服务器到“\(report.groupName)”",
          systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
        Text(
          "统计：导入 \(report.importedServerCount) 台，跳过 "
            + "\(report.skippedRecords.count) 条，身份重生成 "
            + "\(report.regeneratedIdentityCount) 个。"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Text("导入完成后代理保持关闭，系统代理未被写入。")
          .font(.callout)
          .foregroundStyle(.secondary)

        if report.regeneratedIdentityCount > 0 {
          Text("有 \(report.regeneratedIdentityCount) 台服务器因 UUID 缺失、无效、重复或冲突而生成了新身份。")
        }
        Text("Legacy 偏好和活动目标未导入；请在 2.0 中显式选择激活目标。")
          .font(.callout)
          .foregroundStyle(.secondary)

        if !report.skippedRecords.isEmpty {
          Text("未导入记录")
            .font(.headline)
          ForEach(report.skippedRecords, id: \.index) { record in
            Text(
              "第 \(record.index + 1) 条（\(record.description)）：\(AppPresentation.message(for: record.reason))"
            )
            .font(.callout)
          }
        }

      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func importLegacy() {
    isImporting = true
    errorMessage = nil
    let reimport = workflow.legacyImportState.completed
    Task { @MainActor in
      do {
        _ = try await workflow.importLegacy(reimport: reimport)
      } catch let error as LegacyImportError {
        errorMessage = error.presentableMessage
      } catch {
        errorMessage = error.presentableMessage
      }
      isImporting = false
    }
  }
}
