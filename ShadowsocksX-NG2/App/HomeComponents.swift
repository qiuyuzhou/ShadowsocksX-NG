import SwiftUI

/// 首页卡片容器（地图 #52，票 #54）：标题 + 副题 + 头部尾随内容 + 正文；
/// 圆角描边卡片底，各分区票的分区卡片可复用。
struct HomeCard<Trailing: View, Content: View>: View {
  let title: String
  let subtitle: String?
  @ViewBuilder var trailing: () -> Trailing
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.title3.weight(.semibold))
          if let subtitle {
            Text(subtitle)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 16)
        trailing()
      }
      content()
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      .background.secondary,
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(.quaternary)
    )
  }
}

/// 当前模式徽标（票 #54）。
struct ModeBadge: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Color.accentColor.opacity(0.12), in: Capsule())
  }
}

/// 快速操作行按钮（票 #54）。
struct QuickActionButton: View {
  let icon: String
  let title: String
  var help: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: icon)
          .foregroundStyle(.tint)
        Text(title)
          .font(.callout.weight(.medium))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "arrow.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .help(help ?? title)
  }
}
