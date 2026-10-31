import SwiftUI
import ObjectiveC

struct NavigationReadout {
    var direction: String
    var turnMetres: Int
    var instruction: String
    var status: String
    var speed: Int
    var remaining: Int
    var remainingSeconds: Int
    var simulation: Bool
    var paused: Bool
    var simulationSpeed: Int
    var arrived: Bool

    var turn: (symbol: String, label: String) {
        switch direction {
        case "L": return ("arrow.turn.up.left", "左转")
        case "R": return ("arrow.turn.up.right", "右转")
        case "SL": return ("arrow.up.left", "左前方")
        case "SR": return ("arrow.up.right", "右前方")
        case "U": return ("arrow.uturn.down", "掉头")
        case "A": return ("mappin.and.ellipse", "前方目的地")
        default: return ("arrow.up", "直行")
        }
    }
}

struct NavigationPanelHeights: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}

private struct NavigationPanelHeightKey: PreferenceKey {
    static let defaultValue = NavigationPanelHeights()
    static func reduce(value: inout NavigationPanelHeights, nextValue: () -> NavigationPanelHeights) {
        let next = nextValue()
        value.top = max(value.top, next.top)
        value.bottom = max(value.bottom, next.bottom)
    }
}

/// Both navigation engines supply data and actions to the same phone interface.
struct NavigationOverlay<Extra: View>: View {
    @ObservedObject private var settings = Settings.shared
    let readout: NavigationReadout
    let muted: Bool
    let onOverview: () -> Void
    let onMute: () -> Void
    let onSettings: () -> Void
    let onEnd: () -> Void
    let onPause: () -> Void
    let onCycleSpeed: () -> Void
    let onLayout: (NavigationPanelHeights) -> Void
    @ViewBuilder var extra: Extra
    @State private var holding = false
    @State private var holdHint = false
    @State private var confirmEnd = false

    var body: some View {
        ZStack {
            if readout.arrived {
                VStack(spacing: 18) {
                    Image(systemName: "flag.checkered").font(.system(size: 40, weight: .bold)).foregroundColor(ContentView.pink)
                    Text("已到达目的地").font(.title.bold())
                    Button("返回首页", action: onEnd).frame(minHeight: 44)
                }
                .padding(30).background(RoundedRectangle(cornerRadius: 22).fill(ContentView.bg))
            } else {
                VStack(spacing: 12) {
                    HStack(spacing: 18) {
                        Image(systemName: readout.turn.symbol).font(.system(size: 48, weight: .bold))
                            .foregroundColor(ContentView.pink).frame(width: 58).accessibilityLabel(readout.turn.label)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(readout.turnMetres >= 0 ? NaviBridge.distText(readout.turnMetres) : "—")
                                .font(.system(size: 30, weight: .heavy))
                            Text(readout.instruction.isEmpty ? "沿路线前进" : readout.instruction).font(.headline).lineLimit(2)
                            Text(readout.status).font(.caption).foregroundColor(ContentView.sub)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(18).background(RoundedRectangle(cornerRadius: 22).fill(ContentView.bg.opacity(0.94)))
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: NavigationPanelHeightKey.self,
                                               value: NavigationPanelHeights(top: geometry.size.height))
                    })
                    Spacer(minLength: 12)
                    VStack(spacing: 12) {
                        HStack {
                            Text("\(max(0, readout.speed))").font(.system(size: 32, weight: .bold)) + Text(" km/h").font(.caption)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("剩余 \(NaviBridge.distText(max(0, readout.remaining)))").bold()
                                Text("约 \(NaviBridge.durText(max(0, readout.remainingSeconds)))").font(.caption)
                            }
                        }
                        extra
                        HStack {
                            Button("全览／跟随", action: onOverview).frame(minHeight: 44)
                            Spacer()
                            Button(muted ? "取消静音" : "静音", action: onMute).frame(minHeight: 44)
                            Spacer()
                            Button("返回设置", action: onSettings).frame(minHeight: 44)
                        }.font(.subheadline)
                        Button(settings.tunnelDimmed ? "隧道模式：开（点击关闭）" : "隧道模式：关（点击开启）") {
                            settings.toggleTunnelMode()
                        }
                        .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityValue(settings.tunnelDimmed ? "开启" : "关闭")
                        if readout.simulation {
                            HStack {
                                Button(readout.paused ? "继续" : "暂停", action: onPause).frame(minHeight: 44)
                                Spacer()
                                Button("\(readout.simulationSpeed) km/h", action: onCycleSpeed).frame(minHeight: 44)
                            }.font(.subheadline)
                        }
                        endButton
                    }
                    .padding(18).background(RoundedRectangle(cornerRadius: 22).fill(ContentView.bg.opacity(0.94)))
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: NavigationPanelHeightKey.self,
                                               value: NavigationPanelHeights(bottom: geometry.size.height))
                    })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(16)
        .foregroundColor(.white).tint(ContentView.pink)
        .onPreferenceChange(NavigationPanelHeightKey.self, perform: onLayout)
        .alert("结束导航？", isPresented: $confirmEnd) {
            Button("结束", role: .destructive, action: onEnd)
            Button("继续导航", role: .cancel) {}
        }
    }

    private var endButton: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color(red: 0.45, green: 0.14, blue: 0.32))
            GeometryReader { geometry in
                Capsule().fill(ContentView.pink).frame(width: holding ? geometry.size.width : 0)
                    .animation(holding ? .linear(duration: 0.6) : .easeOut(duration: 0.15), value: holding)
            }
            Text(holdHint ? "要长按才能结束" : (holding ? "松手取消" : "长按结束导航"))
                .font(.headline).frame(maxWidth: .infinity)
        }
        .frame(height: 48).clipShape(Capsule()).contentShape(Capsule())
        .onTapGesture {
            holdHint = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { holdHint = false }
        }
        .onLongPressGesture(minimumDuration: 0.6, pressing: { holding = $0 }) {
            holding = false
            onEnd()
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("结束导航")
        .accessibilityAddTraits(.isButton).accessibilityHint("双击后确认结束导航")
        .accessibilityAction { confirmEnd = true }
    }
}

/// 接住高德导航界面的按钮回调（和 NaviBridge 一样在运行时登记协议，见 CLAUDE.md 高德坑第 1 条）
final class DriveViewController: NSObject, ObservableObject {
    weak var view: AMapNaviDriveView?
    var edgePadding = UIEdgeInsets.zero
    var onClose: (() -> Void)?
    @Published var showMore = false

    var asDelegate: AMapNaviDriveViewDelegate? {
        class_addProtocol(DriveViewController.self, AMapNaviDriveViewDelegate.self)
        return (self as AnyObject) as? AMapNaviDriveViewDelegate
    }

    @objc(driveViewCloseButtonClicked:)
    func closeTapped(_ v: AMapNaviDriveView) { onClose?() }

    @objc(driveViewMoreButtonClicked:)
    func moreTapped(_ v: AMapNaviDriveView) { showMore = true }

    @objc(driveViewEdgePadding:)
    func mapPadding(_ v: AMapNaviDriveView) -> UIEdgeInsets { edgePadding }

    var isOverview: Bool { view?.showMode == .overview }
    func toggleOverview() {
        guard let v = view else { return }
        v.showMode = v.showMode == .overview ? .carPositionLocked : .overview
    }
    var trafficOn: Bool { view?.mapShowTraffic ?? true }
    func toggleTraffic() { view?.mapShowTraffic.toggle() }
}

struct AMapDriveViewRep: UIViewRepresentable {
    let controller: DriveViewController
    let night: Bool
    var showNativeUI = false
    var edgePadding = UIEdgeInsets.zero

    func makeUIView(context: Context) -> AMapNaviDriveView {
        let v = AMapNaviDriveView(frame: .zero)
        v.delegate = controller.asDelegate
        v.mapViewModeType = night ? .night : .day
        controller.view = v
        updateUIView(v, context: context)
        v.showTrafficLightView = true
        AMapNaviDriveManager.sharedInstance().addDataRepresentative(v)
        return v
    }

    func updateUIView(_ v: AMapNaviDriveView, context: Context) {
        let mode: AMapNaviViewMapModeType = night ? .night : .day
        if v.mapViewModeType != mode { v.mapViewModeType = mode }
        let padding = showNativeUI ? .zero : edgePadding
        let changed = v.showUIElements != showNativeUI || controller.edgePadding != padding
        if v.showUIElements != showNativeUI { v.showUIElements = showNativeUI }
        if v.showCrossImage != showNativeUI { v.showCrossImage = showNativeUI }
        controller.edgePadding = padding
        if !showNativeUI, v.bounds.height > 0 {
            let visible = max(0, v.bounds.height - padding.top - padding.bottom)
            let anchor = CGPoint(x: 0.5, y: min(0.85, max(0.15, (padding.top + visible * 0.6) / v.bounds.height)))
            if v.screenAnchor != anchor { v.screenAnchor = anchor }
        }
        if changed, v.showMode == .overview { v.updateRoutePolylineInTheVisualRangeWhenTheShowModeIsOverview() }
    }

    static func dismantleUIView(_ uiView: AMapNaviDriveView, coordinator: ()) {
        AMapNaviDriveManager.sharedInstance().removeDataRepresentative(uiView)
    }
}

struct NaviScreen: View {
    @ObservedObject var navi = NaviBridge.shared
    @ObservedObject var settings = Settings.shared
    @StateObject private var drive = DriveViewController()
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClose = false
    @State private var showNativeUI = false
    @State private var panelHeights = NavigationPanelHeights()

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                AMapDriveViewRep(controller: drive, night: settings.paletteNight, showNativeUI: showNativeUI,
                                 edgePadding: UIEdgeInsets(top: panelHeights.top + geometry.safeAreaInsets.top + 16,
                                                           left: 16, bottom: panelHeights.bottom + geometry.safeAreaInsets.bottom + 16, right: 16))
                    .ignoresSafeArea()
                if !showNativeUI || navi.showArrived {
                    NavigationOverlay(readout: readout, muted: settings.voiceMuted,
                                      onOverview: drive.toggleOverview, onMute: toggleMute,
                                      onSettings: { dismiss() }, onEnd: exitNavi,
                                      onPause: navi.toggleEmuPause, onCycleSpeed: navi.cycleEmuSpeed,
                                      onLayout: { panelHeights = $0 }) {
                        if navi.uiSuggestMin > 0 {
                            HStack {
                                Text("发现更快路线，能省约 \(navi.uiSuggestMin) 分钟").font(.caption)
                                Spacer()
                                Button("换这条") { navi.acceptSuggest() }.frame(minHeight: 44)
                                Button("不用") { navi.clearSuggest() }.frame(minHeight: 44)
                            }
                        }
                        Button { showNativeUI = true } label: {
                            Label("完整导航提示", systemImage: "map").font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                        }.accessibilityHint("显示高德完整导航界面，导航继续运行")
                    }
                } else {
                    Button { showNativeUI = false } label: {
                        Label("返回 App 风格", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.bold()).foregroundColor(ContentView.pink).padding(14)
                            .background(Capsule().fill(ContentView.bg.opacity(0.94)))
                    }.padding(16).padding(.bottom, 88)
                }
            }
        }
        .onAppear { drive.onClose = { confirmClose = true } }
        .alert("退出导航？", isPresented: $confirmClose) {
            Button("退出导航", role: .destructive) { exitNavi() }
            Button("继续导航", role: .cancel) {}
        }
        .onChange(of: navi.navigating) { now in
            if !now && !navi.showArrived { dismiss() }
        }
        .onChange(of: navi.showArrived) { now in
            if !now && !navi.navigating { dismiss() }
        }
        .confirmationDialog("导航选项", isPresented: $drive.showMore, titleVisibility: .hidden) {
            Button(drive.isOverview ? "回到车头跟随" : "看全程") { drive.toggleOverview() }
            Button(drive.trafficOn ? "关掉路况颜色" : "显示路况颜色") { drive.toggleTraffic() }
            Button("返回首页修改设置") { dismiss() }
            Button("退出导航", role: .destructive) { exitNavi() }
            Button("取消", role: .cancel) {}
        }
    }

    private var readout: NavigationReadout {
        NavigationReadout(direction: navi.uiDir, turnMetres: navi.uiDist, instruction: navi.uiRoad,
                          status: navi.info.hasPrefix("图标 ") ? (navi.emulating ? "模拟导航" : "导航中") : navi.info,
                          speed: navi.uiSpeed, remaining: navi.uiRemainM,
                          remainingSeconds: navi.uiRemainS, simulation: navi.emulating, paused: navi.emuPaused,
                          simulationSpeed: navi.emuSpeed, arrived: navi.showArrived)
    }
    private func toggleMute() {
        settings.voiceMuted.toggle()
        if settings.voiceMuted { Speech.shared.stopNow() }
    }
    private func exitNavi() {
        navi.stop()
        dismiss()
    }
}
