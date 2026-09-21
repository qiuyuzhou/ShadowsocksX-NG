import SwiftUI

/// First-launch and explicit re-import surface for issue #36. The sheet never
/// exposes passwords, plugin options, or remote URL values; it presents counts,
/// named skipped records, identity regeneration, and migration warnings.
struct LegacyImportSheet: View {
  @ObservedObject var viewModel: CatalogViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var isImporting = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(viewModel.legacyImportCompleted ? "再次导入 Legacy 配置" : "发现 Legacy 配置")
        .font(.title2.weight(.semibold))
      Text(
        viewModel.legacyImportCompleted
          ? "再次导入会创建新的独立手动分组，不会合并或修改原 Legacy 数据。"
          : "可以把旧版服务器和支持的偏好复制到 2.0。导入是一次快照提交；代理保持关闭，也不会写入系统代理。"
      )
      .foregroundStyle(.secondary)

      if let report = viewModel.legacyImportReport {
        reportView(report)
      } else {
        Text("插件程序引用会原样保留，但不会复制 Legacy 插件二进制；本版本未提供的插件需要你之后处理。")
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
        Button(viewModel.legacyImportCompleted ? "再次导入" : "导入") {
          importLegacy()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isImporting || !viewModel.legacyImportAvailable)
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
        Text("导入完成后代理保持关闭，系统代理未被写入。")
          .font(.callout)
          .foregroundStyle(.secondary)

        if report.regeneratedIdentityCount > 0 {
          Text("有 \(report.regeneratedIdentityCount) 台服务器因 UUID 缺失、无效、重复或冲突而生成了新身份。")
        }

        switch report.activeTarget {
        case .imported:
          Text("Legacy 活动服务器已唯一映射为 2.0 活动目标。")
        case .cleared(let reason):
          Text("Legacy 活动目标未保留：\(reason)。")
        }

        if !report.skippedRecords.isEmpty {
          Text("未导入记录")
            .font(.headline)
          ForEach(report.skippedRecords, id: \.index) { record in
            Text("第 \(record.index + 1) 条（\(record.description)）：\(record.reason)")
              .font(.callout)
          }
        }

        if !report.migratedPreferences.isEmpty {
          Text("已迁移偏好：" + report.migratedPreferences.joined(separator: "、"))
            .font(.callout)
        }
        if !report.warnings.isEmpty {
          Text("注意")
            .font(.headline)
          ForEach(report.warnings, id: \.self) { warning in
            Text("• " + warning)
              .font(.callout)
              .foregroundStyle(.orange)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func importLegacy() {
    isImporting = true
    errorMessage = nil
    let reimport = viewModel.legacyImportCompleted
    Task { @MainActor in
      do {
        _ = try await viewModel.importLegacy(reimport: reimport)
      } catch let error as LegacyImportError {
        errorMessage = error.presentedReason
      } catch {
        errorMessage = String(describing: error)
      }
      isImporting = false
    }
  }
}
