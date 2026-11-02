import SwiftUI

/// 圆屏 Tab：连接状态与电量卡（产品正视 PNG）。
/// 导航状态由四个标签上方的统一「回到导航」状态条展示，卡片不再重复。
struct DeviceConnectionCard: View {
    @ObservedObject var ble = BleLink.shared
    @ObservedObject var settings = Settings.shared
    @ObservedObject private var connectAnim = ConnectAnimationCoordinator.shared

    var body: some View {
        CardView {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("导航屏")
                        .font(.caption)
                        .foregroundColor(AppTheme.sub)
                    Text(ble.screenName.isEmpty ? "MotoNav" : ble.screenName)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(AppTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("圆屏导航")
                        .font(.caption)
                        .foregroundColor(AppTheme.sub)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ble.isReady ? AppTheme.green : AppTheme.amber)
                            .frame(width: 8, height: 8)
                        Text(ble.connectionSummary)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(ble.isReady ? AppTheme.green : AppTheme.sub)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("设备电量").font(.caption2).foregroundColor(AppTheme.sub)
                        Text(ble.screenBattery.map { "\($0)%" } ?? "—")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundColor(AppTheme.text)
                    }
                    .padding(.top, 4)
                    GlassChip(
                        title: ble.isReady ? "断开" : "连接",
                        icon: ble.isReady ? "bolt.slash" : "bolt.fill",
                        tint: ble.isReady ? nil : AppTheme.accent,
                        compact: true
                    ) {
                        if ble.isReady { ble.disconnect() }
                        else { connectAnim.connectManually() }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack(alignment: .bottom) {
                    Image("GroundShadow")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 150, height: 34)
                        .offset(y: 8)
                        .opacity(0.75)
                    // 3/4 角产品图（mockup C：银壳 + 导航屏，等比无椭圆压扁）
                    Image("DevicePuckHero")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 152, height: 170)
                }
                .frame(width: 156, height: 186)
            }

            Text(Settings.themeName(settings.theme)).font(.caption2).foregroundColor(AppTheme.sub)
        }
    }
}

