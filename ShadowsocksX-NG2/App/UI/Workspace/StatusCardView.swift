import SwiftUI

/// 侧栏底部代理状态卡（issue #60）：只做 tone→语义色映射与排版，行结构、
/// 回退文案与色调政策全部来自 StatusCardModel（与状态菜单同用一份文本映射，
/// issue #47 的整体 snapshot 口径）。
struct StatusCardView: View {
  @ObservedObject var control: ProxyControlWorkflow

  var body: some View {
    let card = StatusCardModel.card(from: control.snapshot)
    return VStack(alignment: .leading, spacing: 7) {
      row(card.runtimeRow)
      if let detail = card.runtimeDetail {
        detailLine(detail)
      }
      row(card.systemProxyRow)
      if let detail = card.systemProxyDetail {
        detailLine(detail)
      }

      Text(card.target.text)
        .font(.footnote.weight(.medium))
        .lineLimit(1)
        .truncationMode(.middle)
        .help(card.target.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("活动目标：\(card.target.text)")

      HStack(spacing: 0) {
        Text("模式：")
          .foregroundStyle(.secondary)
        Text(card.modeText)
      }
      .font(.caption)
      .accessibilityElement(children: .combine)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(.quaternary)
    )
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, 12)
  }

  private func row(_ row: StatusCardModel.Row) -> some View {
    HStack(spacing: 4) {
      Text("\(row.label)：")
        .foregroundStyle(.secondary)
      Text(row.text)
        .fontWeight(.semibold)
        .foregroundStyle(color(row.tone))
    }
    .font(.footnote)
    .lineLimit(1)
    .accessibilityElement(children: .combine)
  }

  private func detailLine(_ detail: StatusCardModel.DetailLine) -> some View {
    Text(detail.text)
      .font(.caption)
      .foregroundStyle(color(detail.tone))
      .lineLimit(2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(detail.text)
  }

  private func color(_ tone: StatusCardModel.Tone) -> Color {
    switch tone {
    case .positive: .green
    case .attention: .orange
    case .failure: .red
    case .neutral: .secondary
    }
  }
}
