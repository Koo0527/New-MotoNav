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
    var laneImage: UIImage? = nil
    var crossImage: UIImage? = nil

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

    // 缺失数据显示"—"或真实状态，不填充虚构提示：负距离 / 非正耗时 = 还没有真实数据
    var turnDistanceText: String { turnMetres >= 0 ? NaviBridge.distText(turnMetres) : "—" }
    var remainingText: String { remaining >= 0 ? "剩余 \(NaviBridge.distText(remaining))" : "剩余 —" }
    var etaText: String { remainingSeconds > 0 ? "约 \(NaviBridge.durText(remainingSeconds)) 到" : "到达时间 —" }
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

// MARK: - 统一 HUD 布局（纯函数：按实测卡片高度设置地图可视区域）
//
// 三种导航（驾车 SDK / 官方骑行 SDK / 网页兼容）共用同一套 HUD 与这套内缩规则：
// 地图可视区域按 HUD 面板实测高度 + 安全区 + 呼吸间距内缩。HUD 高度由 PreferenceKey
// 实测（动态字号放大时卡片长高，内缩跟着长），安全区由 GeometryReader 实测（横屏 /
// 刘海屏取实际值），因此竖屏、横屏、安全区、动态字号都由同一公式覆盖。
enum NaviHudLayout {
    /// 地图可视区域边距：HUD 面板实测高度 + 安全区 + 固定呼吸间距（默认 16）
    static func mapEdgeInsets(panelTop: CGFloat, panelBottom: CGFloat,
                              safeTop: CGFloat, safeBottom: CGFloat,
                              margin: CGFloat = 16) -> UIEdgeInsets {
        UIEdgeInsets(top: panelTop + safeTop + margin, left: margin,
                     bottom: panelBottom + safeBottom + margin, right: margin)
    }

    /// 自车图标锚点：车标落在去掉 HUD 后可视区域约 60% 高度处（车标偏下，前方视野更大）。
    /// 结果限制在 [0.15, 0.85]，保证车标始终在地图内。
    static func carAnchor(boundsHeight: CGFloat, padding: UIEdgeInsets) -> CGPoint {
        guard boundsHeight > 0 else { return CGPoint(x: 0.5, y: 0.72) }
        let visible = max(0, boundsHeight - padding.top - padding.bottom)
        let y = (padding.top + visible * 0.6) / boundsHeight
        return CGPoint(x: 0.5, y: min(0.85, max(0.15, y)))
    }
}

/// Three navigation engines (drive SDK / official ride SDK / independent web route)
/// share this map-first HUD: one compact top card, short status strips and a glass
/// bottom control bar. Simulation controls, "return to settings" and the full SDK
/// interface entry live in the more menu; the long-press end action stays separate.
struct NavigationOverlay<Extra: View>: View {
    @ObservedObject private var settings = Settings.shared
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let readout: NavigationReadout
    let muted: Bool
    let onOverview: () -> Void
    let onMute: () -> Void
    let onSettings: () -> Void
    let onEnd: () -> Void
    let onPause: () -> Void
    let onCycleSpeed: () -> Void
    let onLayout: (NavigationPanelHeights) -> Void
    /// 完整 SDK 界面切换入口（官方驾车 / 骑行保留）；兼容导航传 nil = 菜单里隐藏，不伪造入口
    var onShowNativeUI: (() -> Void)? = nil
    @ViewBuilder var extra: Extra
    @State private var holding = false
    @State private var holdHint = false
    @State private var confirmEnd = false
    @State private var showMore = false

    var body: some View {
        ZStack {
            if readout.arrived {
                VStack(spacing: 18) {
                    Image(systemName: "flag.checkered").font(.system(size: 40, weight: .bold)).foregroundColor(ContentView.pink)
                    Text("已到达目的地").font(.title.bold())
                    Button("返回首页", action: onEnd).frame(minHeight: 44)
                }
                .padding(30).background(RoundedRectangle(cornerRadius: 22).fill(AppTheme.hudCard))
            } else {
                VStack(spacing: 12) {
                    topCard
                    Spacer(minLength: 12)
                    bottomBar
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(16)
        .foregroundColor(.white).tint(ContentView.pink)
        .onPreferenceChange(NavigationPanelHeightKey.self, perform: onLayout)
        .confirmationDialog("导航选项", isPresented: $showMore, titleVisibility: .hidden) {
            moreMenu
        }
        .alert("结束导航？", isPresented: $confirmEnd) {
            Button("结束", role: .destructive, action: onEnd)
            Button("继续导航", role: .cancel) {}
        }
    }

    /// 更多菜单：模拟控制、返回设置（不停止导航）与完整 SDK 界面入口
    @ViewBuilder private var moreMenu: some View {
        if readout.simulation {
            Button(readout.paused ? "继续模拟" : "暂停模拟", action: onPause)
            Button("模拟车速 \(readout.simulationSpeed) km/h", action: onCycleSpeed)
        }
        Button("返回设置（导航继续）", action: onSettings)
        if let onShowNativeUI {
            Button("完整导航提示", action: onShowNativeUI)
        }
        Button("取消", role: .cancel) {}
    }

    /// 顶部单张紧凑卡片：方向图标、下次动作与距离、道路名、剩余里程和 ETA
    private var topCard: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 8) {
                    HStack(spacing: 14) {
                        Image(systemName: readout.turn.symbol).font(.largeTitle.weight(.bold))
                            .foregroundColor(ContentView.pink).frame(minWidth: 44)
                            .accessibilityLabel(readout.turn.label)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(readout.turnDistanceText)
                                    .font(.title2.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.6)
                                Text(readout.turn.label).font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.hudSub)
                            }
                            Text(readout.instruction.isEmpty ? "沿路线前进" : readout.instruction)
                                .font(.subheadline).lineLimit(2)
                            HStack(spacing: 14) {
                                Label(readout.remainingText, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                                Label(readout.etaText, systemImage: "clock")
                            }
                            .font(.caption).foregroundColor(AppTheme.hudSub)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 20).fill(AppTheme.hudCard))
                    if verticalSizeClass != .compact { guidanceImages }
                }
                if verticalSizeClass == .compact,
                   readout.laneImage != nil || readout.crossImage != nil {
                    guidanceImages.frame(maxWidth: 150)
                }
            }
            // 简短状态条：弱定位、重算、模拟中等真实状态（只显示实际状态，不虚构提示）
            if !readout.status.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(ContentView.userMessage(readout.status)).lineLimit(2)
                }
                .font(.caption).foregroundColor(AppTheme.hudSub)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(AppTheme.hudCard))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("状态：\(ContentView.userMessage(readout.status))")
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: NavigationPanelHeightKey.self,
                                   value: NavigationPanelHeights(top: geometry.size.height))
        })
    }

    @ViewBuilder private var guidanceImages: some View {
        VStack(spacing: 8) {
            if let laneImage = readout.laneImage {
                Image(uiImage: laneImage).resizable().scaledToFit()
                    .frame(maxHeight: verticalSizeClass == .compact ? 28 : 52)
                    .padding(10).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 14).fill(AppTheme.hudCard))
                    .accessibilityLabel("前方车道，亮色箭头为推荐方向")
            }
            if let crossImage = readout.crossImage {
                Image(uiImage: crossImage).resizable().scaledToFit()
                    .frame(maxHeight: verticalSizeClass == .compact ? 64 : 130)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("前方路口放大图")
            }
        }
    }

    /// 底部轻量玻璃控制栏：附加状态条（更快路线、重算重试、兼容提示）、速度、全览／跟随、
    /// 静音、隧道快捷操作、更多；结束保持独立的长按操作。附加条与控制同底，不悬在地图上。
    private var bottomBar: some View {
        VStack(spacing: 10) {
            extra
            HStack(spacing: 2) {
                VStack(spacing: 0) {
                    Text("\(max(0, readout.speed))").font(.title3.weight(.bold).monospacedDigit()).lineLimit(1)
                    Text("km/h").font(.caption2).foregroundColor(AppTheme.hudSub)
                }
                .frame(minWidth: 48)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("当前时速 \(max(0, readout.speed)) 公里每小时")
                barButton("全览／跟随", systemImage: "map", action: onOverview)
                barButton(muted ? "取消静音" : "静音", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", action: onMute)
                barButton("隧道", systemImage: settings.tunnelDimmed ? "moon.fill" : "moon") {
                    settings.toggleTunnelMode()
                }
                .accessibilityValue(settings.tunnelDimmed ? "开启" : "关闭")
                .accessibilityHint("手动切换隧道模式")
                barButton("更多", systemImage: "ellipsis") { showMore = true }
            }
            endButton
        }
        .padding(14)
        .background(
            ZStack { RoundedRectangle(cornerRadius: 22).fill(AppTheme.hudCard) }
                .liquidGlass(RoundedRectangle(cornerRadius: 22), interactive: true)
        )
        .background(GeometryReader { geometry in
            Color.clear.preference(key: NavigationPanelHeightKey.self,
                                   value: NavigationPanelHeights(bottom: geometry.size.height))
        })
    }

    private func barButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.body)
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var endButton: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(AppTheme.secondaryFill.opacity(0.92))
                .liquidGlass(Capsule(), tint: nil, interactive: true)
            GeometryReader { geometry in
                Capsule().fill(AppTheme.red.opacity(0.55)).frame(width: holding ? geometry.size.width : 0)
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
        // 整合版：高德自带 UI（顶卡/底栏/logo/主页按钮/光柱）全部隐藏，改由 NaviScreen 自绘
        v.showUIElements = false
        v.screenAnchor = CGPoint(x: 0.5, y: 0.72)       // 仅 showUIElements=NO 时有效：车标偏下，前方视野更大
        controller.view = v
        updateUIView(v, context: context)
        v.showTrafficLightView = true
        NavigationCoordinator.shared.attachDriveMap(v)      // 只有驾车引擎是当前所有者时才绑定
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
            // 按实测卡片高度设置自车锚点（统一 HUD 布局纯函数，与地图边距同一套输入）
            let anchor = NaviHudLayout.carAnchor(boundsHeight: v.bounds.height, padding: padding)
            if v.screenAnchor != anchor { v.screenAnchor = anchor }
        }
        if changed, v.showMode == .overview { v.updateRoutePolylineInTheVisualRangeWhenTheShowModeIsOverview() }
    }

    static func dismantleUIView(_ uiView: AMapNaviDriveView, coordinator: ()) {
        // 地图销毁时引擎可能已被切换销毁：解绑不得重建旧单例
        NavigationCoordinator.shared.detachDriveMap(uiView)
    }
}

/// 接住高德骑行导航界面的按钮回调（与 DriveViewController 同一模式，运行时登记协议）
final class RideViewController: NSObject, ObservableObject {
    weak var view: AMapNaviRideView?
    var edgePadding = UIEdgeInsets.zero
    var onClose: (() -> Void)?
    @Published var showMore = false

    var asDelegate: AMapNaviRideViewDelegate? {
        class_addProtocol(RideViewController.self, AMapNaviRideViewDelegate.self)
        return (self as AnyObject) as? AMapNaviRideViewDelegate
    }

    @objc(rideViewCloseButtonClicked:)
    func closeTapped(_ v: AMapNaviRideView) { onClose?() }

    @objc(rideViewMoreButtonClicked:)
    func moreTapped(_ v: AMapNaviRideView) { showMore = true }

    @objc(rideViewEdgePadding:)
    func mapPadding(_ v: AMapNaviRideView) -> UIEdgeInsets { edgePadding }

    var isOverview: Bool { view?.showMode == .overview }
    func toggleOverview() {
        guard let v = view else { return }
        v.showMode = v.showMode == .overview ? .carPositionLocked : .overview
    }
}

/// 官方骑行的地图容器：AMapNaviRideView（SDK 10.1.600 自带，作为骑行引擎的数据代表）。
/// 与驾车容器同一套规则：默认隐藏 SDK 自带 UI 由统一 HUD 自绘，可切回完整 SDK 界面；
/// 可视区域按实测 HUD 高度内缩。注意 SDK 骑行视图只支持白天样式，夜间由 HUD 深色底保证可读。
struct AMapRideViewRep: UIViewRepresentable {
    let controller: RideViewController
    var showNativeUI = false
    var edgePadding = UIEdgeInsets.zero

    func makeUIView(context: Context) -> AMapNaviRideView {
        let v = AMapNaviRideView(frame: .zero)
        v.delegate = controller.asDelegate
        v.showUIElements = false
        v.screenAnchor = CGPoint(x: 0.5, y: 0.72)
        controller.view = v
        updateUIView(v, context: context)
        NavigationCoordinator.shared.attachRideMap(v)      // 只有骑行引擎是当前所有者时才绑定
        return v
    }

    func updateUIView(_ v: AMapNaviRideView, context: Context) {
        let padding = showNativeUI ? .zero : edgePadding
        let changed = v.showUIElements != showNativeUI || controller.edgePadding != padding
        if v.showUIElements != showNativeUI { v.showUIElements = showNativeUI }
        controller.edgePadding = padding
        if !showNativeUI, v.bounds.height > 0 {
            let anchor = NaviHudLayout.carAnchor(boundsHeight: v.bounds.height, padding: padding)
            if v.screenAnchor != anchor { v.screenAnchor = anchor }
        }
        if changed, v.showMode == .overview { v.updateRoutePolylineInTheVisualRangeWhenTheShowModeIsOverview() }
    }

    static func dismantleUIView(_ uiView: AMapNaviRideView, coordinator: ()) {
        // 地图销毁时引擎可能已被切换销毁：解绑不得重建旧单例
        NavigationCoordinator.shared.detachRideMap(uiView)
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
                                 edgePadding: NaviHudLayout.mapEdgeInsets(panelTop: panelHeights.top,
                                                                          panelBottom: panelHeights.bottom,
                                                                          safeTop: geometry.safeAreaInsets.top,
                                                                          safeBottom: geometry.safeAreaInsets.bottom))
                    .ignoresSafeArea()
                if !showNativeUI || navi.showArrived {
                    NavigationOverlay(readout: readout, muted: settings.voiceMuted,
                                      onOverview: drive.toggleOverview, onMute: toggleMute,
                                      onSettings: { dismiss() }, onEnd: exitNavi,
                                      onPause: navi.toggleEmuPause, onCycleSpeed: navi.cycleEmuSpeed,
                                      onLayout: { panelHeights = $0 },
                                      onShowNativeUI: { showNativeUI = true }) {
                        if navi.uiSuggestMin > 0 {
                            HStack {
                                Text("发现更快路线，能省约 \(navi.uiSuggestMin) 分钟").font(.caption)
                                Spacer()
                                Button("换这条") { navi.acceptSuggest() }.frame(minHeight: 44)
                                Button("不用") { navi.clearSuggest() }.frame(minHeight: 44)
                            }
                        }
                    }
                } else {
                    Button { showNativeUI = false } label: {
                        Label("返回 App 风格", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.bold()).foregroundColor(ContentView.pink).padding(14)
                            .background(Capsule().fill(AppTheme.hudCard))
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
                          simulationSpeed: navi.emuSpeed, arrived: navi.showArrived,
                          laneImage: navi.uiLaneImage, crossImage: navi.uiCrossImage)
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
