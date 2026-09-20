import SwiftUI

/// 占位主窗口，由后续工单替换为服务器与订阅管理界面。
struct PlaceholderMainWindow: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("ShadowsocksX-NG 2.0")
                .font(.title2.bold())
            Text("这是工程骨架的占位主窗口，后续工单将逐个替换为真实的管理界面。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 420, height: 240)
    }
}
