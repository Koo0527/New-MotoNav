import SwiftUI
import CoreLocation
import AVFoundation
import UIKit

/// 版本：跟随 App 版本（见 Config.swift）
///
/// 主界面：圆屏连接状态、搜索目的地 / 导入高德分享路线、选路线、开始导航、巡航、圆屏设置、Key 设置
/// 0.16.0 UI alignment: four tabs, semantic colours, device card and grouped settings.
struct ContentView: View {
    @ObservedObject var ble = BleLink.shared
    @ObservedObject var navi = NaviBridge.shared
    @ObservedObject var ride = RideBridge.shared
    @ObservedObject var independent = WebMotorSession.shared
    @ObservedObject var search = SearchService.shared
    @ObservedObject var settings = Settings.shared
    @ObservedObject var weather = Weather.shared
    @ObservedObject var history = History.shared
    @ObservedObject var favorites = Favorites.shared
    @ObservedObject private var rides=RideRecorder.shared
    @ObservedObject private var connectAnim=ConnectAnimationCoordinator.shared
    @AppStorage("ui_appearance") private var appearance=0
    @AppStorage("ui_tab_placement") private var tabPlacement=0
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var uiStarted=false
    @AppStorage("ui_selected_tab") private var page = 0
    @State private var showWebMotor = false
    @StateObject private var planner = RoutePlanner()
    @State private var showRides = false
    @State private var showScreens=false
    @State private var showDestManage=false
    @State private var confirmForgetPhones=false
    @State private var clockRequested=false
    @AppStorage("voice_rate") private var voiceRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("voice_pitch") private var voicePitch = 1.0
    @AppStorage("voice_id") private var voiceID = ""

    @State private var query = ""
    @State private var showKeys = false                 // iOS v0.7 填写地图 Key 页面
    private static var keyPrompted = false              // 这次打开 App 已经提醒过填 key 了
    @State private var shareBusy = false
    @State private var shareStatus = ""
    @State private var pendingShare=""
    @State private var shareImportID=UUID()
    @State private var showShareVerification=false
    @State private var cruiseNote = ""

    static let bg=AppTheme.bg,card=AppTheme.card,stroke=AppTheme.stroke
    static let pink=AppTheme.accent,cyan=AppTheme.accent,sub=AppTheme.sub

    var body:some View {
        GeometryReader { geo in
            let wide=TabLayout.isWide(size:geo.size,hSizeClass:hSizeClass)
            let rail=TabLayout.useSideRail(size:geo.size,hSizeClass:hSizeClass,placement:tabPlacement)
            NavigationView {
                ZStack(alignment:.bottom) {
                    if rail {
                        HStack(spacing:0) {
                            VStack(spacing:0){activeNavigationBanner;pages(wide:wide)}
                            rightRail(systemEdge:0)
                        }
                    } else {
                        VStack(spacing:0){activeNavigationBanner;pages(wide:wide)}
                        bottomBar
                    }
                }.background(Self.bg.ignoresSafeArea()).navigationBarHidden(true)
            }.navigationViewStyle(.stack)
        }
        .fullScreenCover(isPresented: $showWebMotor) { WebMotorView(model:planner) }
        .sheet(isPresented: $showRides) { NavigationView { RideHistoryView() } }
        .sheet(isPresented:$showScreens) { screenPicker }
        .sheet(isPresented:$showDestManage) { destinationManageSheet }
        .confirmationDialog("让圆屏忘掉其他手机？",isPresented:$confirmForgetPhones,titleVisibility:.visible) {
            Button("忘掉其他手机",role:.destructive){ble.forgetOtherPhones()}
            Button("取消",role:.cancel){}
        } message: {Text("当前手机保留配对，其他手机以后需要重新配对。")}
        .sheet(isPresented: $showKeys) { KeySetupView() }
        .sheet(isPresented:$showShareVerification){
            ShareVerificationView(page:AmapShare.findUrl(pendingShare).flatMap{URL(string:$0)}){
                let text=pendingShare
                DispatchQueue.main.asyncAfter(deadline:.now()+0.35){importShare(text)}
            }
        }

        .overlay { if connectAnim.isPresented {ConnectSheetView().transition(.opacity).zIndex(50)} }
        .animation(.easeOut(duration:0.35),value:connectAnim.isPresented)
        .onAppear {
            softenSegmentedChrome()
            if !uiStarted {
                uiStarted=true
                if !settings.keysMissing && !ble.isReady && ble.bluetoothAvailable {connectAnim.connectAutomatically()}
            }                                    // iOS v0.7 打开 App 时，高德或高德 key 没填就提醒一次
            if !ContentView.keyPrompted && settings.keysMissing {
                ContentView.keyPrompted = true
                showKeys = true
            }
        }
        .onOpenURL { url in                            // iOS v0.4 高德里“分享到 MotoNav”：motonav://share?t=分享的文字
            guard url.scheme == "motonav",
                  let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value
            else { return }
            importShare(t)
        }
    }

    private var activeNavigationBanner: some View {
        Group {
            // 统一的“正在导航”判断：驾车、官方骑行或独立导航（防止导航被其他入口抢占）
            if NavigationCoordinator.shared.navigationActive {
                HStack {
                    VStack(alignment:.leading,spacing:3) {
                        Text("导航继续运行中").bold()
                        Text(independent.running ? independent.instruction
                             : ride.navigating ? "\(ride.uiDir) · \(ride.uiDist) 米"
                             : "\(navi.uiDir) · \(navi.uiDist) 米")
                            .font(.caption).lineLimit(1)
                    }
                    Spacer()
                    Button("回到导航") {
                        showWebMotor=true
                    }.foregroundColor(Self.pink)
                }.padding(12).background(Self.card).foregroundColor(AppTheme.text)
            }
        }
    }

    private var screenPicker:some View {
        NavigationView {
            List {
                Section {
                    Text("选择圆屏，编号可在圆屏首页查看。").font(.subheadline).foregroundColor(Self.sub)
                    if ble.availableScreens.isEmpty {Text("正在搜索附近圆屏…")}
                    ForEach(ble.availableScreens){screen in
                        Button(screen.name){ble.selectScreen(screen.id);showScreens=false;connectAnim.connectAutomatically()}
                    }
                }
            }.navigationTitle("选择圆屏").toolbar {
                ToolbarItem(placement:.cancellationAction){Button("取消"){showScreens=false}}
                ToolbarItem(placement:.confirmationAction){Button("重新搜索"){ble.beginScreenSelection()}}
            }
        }.onAppear{ble.beginScreenSelection()}.onDisappear{ble.endScreenSelection()}
    }

    private var statusCard: some View {
        CardView {
            HStack {
                Circle().fill(ble.isReady ? Color.green : Color.orange).frame(width: 10, height: 10)
                Text("圆屏").foregroundColor(AppTheme.text).bold()
                Spacer()
                Button(ble.isReady ? "断开" : "连接") { if ble.isReady {ble.disconnect()}else{connectAnim.connectManually()} }
                    .foregroundColor(ContentView.cyan)
            }
            Text(ble.connectionSummary).font(.footnote).foregroundColor(ContentView.sub)
            Button("换一块圆屏"){showScreens=true}.foregroundColor(Self.cyan)
            Button("忘掉其他手机",role:.destructive){confirmForgetPhones=true}.disabled(!ble.isReady || !ble.verified)
        }
    }

    private func pages(wide: Bool) -> some View {
        ScrollView {
            Group {
                if page == 0 && wide {
                    // Duo / 宽屏：左主（搜索、收藏与最近、路线与分享、巡航）右辅（连接摘要 + 轨迹快切）
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 16) {
                            header
                            destCard
                            favoritesRecentCard
                            routeEntries
                            cruiseCard
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            statusCard
                            GlassChip(title: "导航轨迹", icon: "location.north.line", tint: Self.cyan) { page = 1 }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        if page == 0 {
                            header
                            destCard
                            favoritesRecentCard
                            routeEntries
                            cruiseCard
                        } else if page == 1 {
                            ridesTabContent
                        } else if page == 2 {
                            deviceTabContent
                        } else {
                            settingsTabContent
                        }
                    }
                }
            // 内容滚过悬浮玻璃条后方，留白 ≈ 条高 + 安全区
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 128)
        }
        .frame(maxWidth: wide ? 1080 : .infinity)
        .frame(maxWidth: .infinity)
    }

    private var ridesTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("轨迹")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundColor(AppTheme.text)
                    Text(monthRideSummary)
                        .font(.caption)
                        .foregroundColor(AppTheme.sub)
                }
                Spacer()
                GlassChip(title: "全部", icon: "list.bullet", tint: Self.cyan, compact: true) { showRides = true }
            }
            .padding(.top, 8)

            if let active = rides.active {
                CardView {
                    Text("记录中 · \(active.mode) · \(Int(active.meters)) 米")
                        .foregroundColor(AppTheme.accent).bold()
                    Text("真实导航或巡航中自动写入轨迹点")
                        .font(.caption).foregroundColor(AppTheme.sub)
                }
            }

            if let latest = rides.rides.first {
                NavigationLink(destination: RideDetailView(ride: latest)) {
                    RideFeatureCard(ride: latest)
                }
                .buttonStyle(.plain)
            } else if rides.active == nil {
                CardView {
                    Text("还没有导航记录")
                        .foregroundColor(AppTheme.text).bold()
                    Text("真实导航或巡航开始时自动记录；模拟导航不记录。")
                        .font(.caption).foregroundColor(AppTheme.sub)
                }
            }

            if rides.rides.count > 1 {
                Text("更早的导航")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.sub)
                    .padding(.top, 4)
                let earlier = Array(rides.rides.dropFirst().prefix(12))
                VStack(spacing: 0) {
                    ForEach(Array(earlier.enumerated()), id: \.element.id) { idx, ride in
                        NavigationLink(destination: RideDetailView(ride: ride)) {
                            RideListRow(ride: ride)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if idx < earlier.count - 1 {
                            Divider().padding(.leading, 88).opacity(0.35)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 18).fill(AppTheme.card))
            }
        }
    }

    private var monthRideSummary: String {
        let cal = Calendar.current
        let monthRides = rides.rides.filter { cal.isDate($0.started, equalTo: Date(), toGranularity: .month) }
        let meters = monthRides.reduce(0.0) { $0 + $1.meters }
        let km = meters / 1000.0
        return String(format: "本月 %.1f km · %d 次导航", km, monthRides.count)
    }

    private var deviceTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("圆屏", subtitle: "连接状态 · 分类设置")
            DeviceConnectionCard()
            ScreenSettingsList { group in
                secondaryPage(title: group.title) { screenGroupPage(group) }
            }
        }
    }

    /// 六组圆屏设置的二级页：每项设置只在一处编辑（连接管理含弹窗状态，留在本文件）
    @ViewBuilder private func screenGroupPage(_ group: ScreenSettingGroup) -> some View {
        switch group {
        case .display: ScreenDisplaySettings()
        case .keysPower: ScreenKeysPowerSettings()
        case .boot: ScreenBootSettings()
        case .music: ScreenMusicSettings()
        case .gauge: ScreenGaugeSettings()
        case .connection: connectionManagementCard
        }
    }

    private var settingsTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("我的", subtitle: "通用 · 导航语音 · 关于")
            SettingsHubList { item in
                secondaryPage(title: item.title) {
                    switch item {
                    case .general:
                        appearanceCard
                        layoutCard
                        keyCard
                    case .voice:
                        voiceCard

                    case .about:
                        CardView {
                            Text("关于").foregroundColor(AppTheme.text).bold()
                            Text("\(APP_VERSION) · Build \(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "2")").font(.footnote).foregroundColor(AppTheme.sub)
                            Text("AI 辅助开发 · 仅供非商业使用")
                                .font(.caption).foregroundColor(AppTheme.sub)
                        }
                        Link("项目与使用说明",destination:URL(string:"https://github.com/zyn950929/MotoNav")!).font(.subheadline)
                    }
                }
            }
        }
    }

    private func secondaryPage<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 128)
        }
        .background(AppTheme.bg.ignoresSafeArea())
        .navigationBarHidden(false)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .background(InteractivePopEnabler())
    }

    private func softenSegmentedChrome() {
        let app = UISegmentedControl.appearance()
        app.selectedSegmentTintColor = UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.039, green: 0.518, blue: 1.000, alpha: 0.28)
                : UIColor(red: 0.000, green: 0.478, blue: 1.000, alpha: 0.16)
        }
        app.backgroundColor = UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.173, green: 0.173, blue: 0.180, alpha: 1)
                : UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)
        }
        app.setDividerImage(UIImage(), forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default)
        app.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .normal)
        app.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .selected)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundColor(AppTheme.text)
            Text(subtitle).font(.caption).foregroundColor(ContentView.sub)
        }
        .padding(.top, 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MotoNav")
                .font(.system(size: 34, weight: .heavy, design: .default))
                .foregroundColor(AppTheme.text)
            Text("圆屏导航 · \(APP_VERSION)").font(.caption).foregroundColor(ContentView.sub)
        }
        .padding(.top, 8)
    }

    private var appearanceCard: some View {
        CardView {
            Text("外观").foregroundColor(AppTheme.text).bold()
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag(0); Text("浅色").tag(1); Text("深色").tag(2)
            }
            .pickerStyle(.segmented)
            Text("跟随系统时，界面随手机的深色模式自动切换浅色 / 深色；也可以一直用浅色或深色。圆屏小地图的昼夜由「圆屏 → 夜间配色」控制。")
                .font(.caption2).foregroundColor(AppTheme.sub)
        }
    }

    private var connectionManagementCard:some View {
        CardView {
            Text("连接管理").font(.headline).foregroundColor(AppTheme.text)
            Text(ble.connectionSummary).font(.subheadline).foregroundColor(Self.sub)
            HStack {
                GlassChip(title:"换一块圆屏",icon:"arrow.triangle.2.circlepath",tint:Self.cyan){showScreens=true}
                Spacer()
                GlassChip(title:"忘掉其他手机",foreground:AppTheme.red,enabled:ble.isReady && ble.verified,compact:true){confirmForgetPhones=true}
            }
            Text("更换圆屏时按设备名称选择，并按圆屏提示完成配对。").font(.caption).foregroundColor(Self.sub)
            Button("校准圆屏时间") {ble.syncPhoneClock(force:true);clockRequested=true}
                .disabled(!ble.isReady || !ble.verified)
            if clockRequested {Text("已发送手机时间，圆屏收到后会更新。") .font(.caption).foregroundColor(Self.sub)}
        }
    }
    private var layoutCard:some View {
        CardView {
            Text("导航栏").font(.headline).foregroundColor(AppTheme.text)
            Picker("导航栏位置",selection:$tabPlacement) {
                Text("自动").tag(0);Text("底部").tag(1);Text("右侧").tag(2)
            }.pickerStyle(.segmented)
            Text("自动模式在宽屏横向布局中使用侧栏。").font(.caption).foregroundColor(Self.sub)
        }
    }

    // MARK: 去哪儿
    /// 搜索目的地：搜索与结果；收藏、最近目的地和分享导入同样进入统一规划页
    private var destCard: some View {
        CardView {
            Text("去哪儿").foregroundColor(AppTheme.text).bold()
            HStack(spacing: 10) {
                // 只在按键盘上的“搜索”或右边按钮时才查高德（边打字边查太费额度）
                TextField("搜索地点、地址", text: $query)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(ContentView.bg))
                    .foregroundColor(AppTheme.text)
                    .submitLabel(.search)
                    .onSubmit { if !needAmapKey() { search.search(query) } }
                    .onChange(of: query) { if $0.isEmpty { search.clear() } }
                Button("搜索") { hideKeyboard(); if !needAmapKey() { search.search(query) } }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(ContentView.pink))
            }
            if !search.status.isEmpty { Text(search.status).font(.footnote).foregroundColor(ContentView.sub) }
            ForEach(search.results.prefix(8)) { p in
                Button { choose(p) } label: {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).foregroundColor(AppTheme.text)
                            Text(p.address).font(.caption).foregroundColor(ContentView.sub).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let d = distanceTo(p) { Text(d).font(.caption).foregroundColor(ContentView.cyan) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
                Divider().background(ContentView.stroke)
            }
        }
    }

    /// 收藏与最近目的地：首页最近最多 5 条，通过「全部」查看和管理
    private var favoritesRecentCard: some View {
        CardView {
            HStack(alignment: .center) {
                Text("收藏与最近目的地").foregroundColor(AppTheme.text).bold()
                Spacer()
                GlassChip(title: "全部", icon: "list.bullet", tint: Self.cyan, compact: true) { showDestManage = true }
            }
            if favorites.places.isEmpty && history.places.isEmpty {
                Text("选择目的地后点收藏；搜索并选择的目的地会自动进入最近记录")
                    .foregroundColor(Self.sub)
            }
            ForEach(favorites.places) { place in
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        page = 0
                        choose(place.searchPlace)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(place.name, systemImage: "star.fill").foregroundColor(Self.cyan)
                                .font(.subheadline)
                            if !place.address.isEmpty { Text(place.address).font(.caption).foregroundColor(ContentView.sub).lineLimit(1) }
                        }
                    }
                    Spacer(minLength: 4)
                    if let d = distanceTo(place.searchPlace) { Text(d).font(.caption).foregroundColor(ContentView.cyan) }
                    Button("移除") { favorites.remove(place) }.foregroundColor(Self.sub)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.vertical, 2)
                Divider().background(ContentView.stroke)
            }
            if !history.places.isEmpty {
                Text("最近去过").font(.caption).foregroundColor(ContentView.sub).padding(.top, 2)
                ForEach(history.places.prefix(5)) { p in
                    Button { page = 0; choose(p) } label: {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundColor(AppTheme.text)
                                if !p.address.isEmpty { Text(p.address).font(.caption).foregroundColor(ContentView.sub).lineLimit(1) }
                            }
                            Spacer(minLength: 4)
                            if let d = distanceTo(p) { Text(d).font(.caption).foregroundColor(ContentView.cyan) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    Divider().background(ContentView.stroke)
                }
            }
        }
    }

    /// 「全部」管理页：完整收藏（可移除）与最近目的地（可清除）
    private var destinationManageSheet: some View {
        NavigationView {
            List {
                Section("常用目的地") {
                    if favorites.places.isEmpty { Text("选择目的地后点收藏").foregroundColor(Self.sub) }
                    ForEach(favorites.places) { place in
                        Button {
                            showDestManage = false
                            page = 0
                            choose(place.searchPlace)
                        } label: {
                            HStack {
                                Label(place.name, systemImage: "star.fill").foregroundColor(Self.cyan)
                                Spacer()
                            }
                        }
                        .foregroundColor(AppTheme.text)
                    }
                    .onDelete { indexSet in
                        for index in indexSet.sorted(by: >) { favorites.remove(favorites.places[index]) }
                    }
                }
                Section("最近去过") {
                    if history.places.isEmpty { Text("搜索并选择目的地后会出现在这里").foregroundColor(Self.sub) }
                    ForEach(history.places) { p in
                        Button {
                            showDestManage = false
                            page = 0
                            choose(p)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).foregroundColor(AppTheme.text)
                                    if !p.address.isEmpty { Text(p.address).font(.caption).foregroundColor(ContentView.sub) }
                                }
                                Spacer()
                            }
                        }
                    }
                    if !history.places.isEmpty {
                        Button("清除最近记录", role: .destructive) { history.clear() }
                    }
                }
            }.navigationTitle("目的地")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showDestManage = false } } }
        }
    }

    /// 路线规划与分享导入：与搜索、收藏、最近目的地进入同一个规划流程
    private var routeEntries: some View {
        CardView {
            Text("路线与分享").foregroundColor(AppTheme.text).bold()
            Button { showWebMotor=true } label: {
                Label("路线规划 · 驾车 / 摩托车 / 自行车",systemImage:"map")
                    .frame(minHeight: 44, alignment: .leading)
            }.foregroundColor(Self.cyan)
            // iOS v0.3 导入高德 App 分享的路线（比如高德里规划好的摩托车路线）
            Button { pasteShare() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                    Text(shareBusy ? "正在读取分享的路线…" : "粘贴高德分享的路线")
                }
                .font(.subheadline).foregroundColor(Color.orange)
                .frame(minHeight: 44, alignment: .leading)
            }
            .disabled(shareBusy)
            Text("在高德里规划好路线 → 分享 → 选 MotoNav；或者复制链接后点上面这行").font(.caption2).foregroundColor(ContentView.sub)
            if !shareStatus.isEmpty { Text(Self.userMessage(shareStatus)).font(.footnote).foregroundColor(ContentView.sub) }
            if !pendingShare.isEmpty && !shareBusy {Button("网页验证后重试"){showShareVerification=true}.foregroundColor(Self.cyan)}
        }
    }

    /// 离现在位置的直线距离（搜索结果、最近去过右边显示）
    private func distanceTo(_ p: SearchService.Place) -> String? {
        guard let me = navi.myPosition() else { return nil }
        let d = Int(NaviBridge.distM(me.lat, me.lng, p.lat, p.lng))
        return d >= 1000 ? String(format: "%.1f 公里", Double(d) / 1000) : "\(d) 米"
    }

    /// 剩余秒数 → 到达时间“18:52”
    static func etaText(_ remainS: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date().addingTimeInterval(TimeInterval(remainS)))
    }

    /// 搜索、历史和收藏均进入同一个规划页
    private func choose(_ p: SearchService.Place) {
        guard !NavigationCoordinator.shared.navigationActive else {shareStatus="导航仍在运行；如需更换目的地，请先结束导航";return}
        if navi.cruising {navi.stopCruise()}
        search.clear()
        hideKeyboard()
        shareImportID=UUID();shareBusy=false;pendingShare=""
        independent.arrived=false
        query = p.name
        shareStatus = ""
        History.shared.add(p)
        planner.setDestination(MotorPoint(lat:p.lat,lng:p.lng,name:p.name))
        showWebMotor = true
    }

    /// 读剪贴板里的高德分享链接，还原路线后按它规划
    private func pasteShare() {
        guard let t = UIPasteboard.general.string, AmapShare.findUrl(t) != nil else {
            shareStatus = "剪贴板里没有高德的分享链接：先在高德里打开路线 → 分享 → 复制链接"
            return
        }
        importShare(t)
    }

    /// 导入高德分享的路线（剪贴板粘贴，或者从高德“分享到 MotoNav”过来）
    private func importShare(_ t: String) {
        guard AmapShare.findUrl(t) != nil else { shareStatus = "分享的内容里没有高德链接"; return }
        if NavigationCoordinator.shared.navigationActive { shareStatus = "正在导航：先退出导航，再导入分享的路线"; return }
        if navi.cruising {navi.stopCruise()}
        hideKeyboard()
        let sequence=UUID();shareImportID=sequence
        shareBusy=true;pendingShare=t
        shareStatus="正在读取高德分享的路线…"
        Task { @MainActor in
            defer { if shareImportID==sequence {shareBusy=false} }
            do {
                let route=try await AmapWebSession.loadShare(t)
                guard shareImportID==sequence else{return}
                // 统一导航活动判断（覆盖官方骑行）：加载期间任何导航已开始，迟到的分享结果不写入规划器
                guard !NavigationCoordinator.shared.navigationActive else{shareStatus="导航已开始，请结束后重新导入";return}
                shareStatus="已读取：\(route.kind)路线" + (route.restored ? "":"（高德未确认原样还原，请核对地图）")
                pendingShare=""
                let name=route.endName.isEmpty ? "分享的目的地":route.endName
                History.shared.add(SearchService.Place(name:name,address:"",lat:route.endLat,lng:route.endLng))
                query=name;search.clear()
                if navi.cruising {navi.stopCruise()}
                independent.arrived=false
                planner.importShare(route)
                showWebMotor=true
            } catch {
                guard shareImportID==sequence else{return}
                shareStatus="读取失败：\(error.localizedDescription)；可完成网页验证后重试"
            }
        }
    }

    // MARK: 巡航
    private var cruiseCard: some View {
        CardView {
            HStack {
                Text("巡航模式").foregroundColor(AppTheme.text).bold()
                Spacer()
                if navi.cruising { Text("进行中 · \(navi.uiSpeed) km/h").font(.caption).foregroundColor(ContentView.cyan) }
            }
            Text("不设目的地，也能查看地图和道路提醒")
                .font(.caption).foregroundColor(ContentView.sub)
            PillButton(title: navi.cruising ? "结束巡航" : "开始巡航", color: navi.cruising ? Color.gray : ContentView.cyan.opacity(0.8),
                       enabled: !NavigationCoordinator.shared.navigationActive) {
                cruiseNote = ""
                if navi.cruising { navi.stopCruise() }
                else if !needAmapKey(), let err = navi.startCruise() { cruiseNote = err }
            }
            if !cruiseNote.isEmpty { Text(cruiseNote).font(.caption).foregroundColor(Color.orange) }
            // 官方骑行规划被巡航抢占：与独立导航（WebMotorSession.ridePlanNotice）同机制的短暂提示
            if !navi.ridePlanNotice.isEmpty { Text(navi.ridePlanNotice).font(.caption2).foregroundColor(.orange) }
        }
    }

    // MARK: 圆屏设置（六组入口见 ScreenSettings.swift；连接管理卡留在本文件）
    private var voiceCard: some View {
        CardView {
            Text("导航语音").foregroundColor(AppTheme.text).bold()
            Toggle("导航静音", isOn: $settings.voiceMuted)
            Toggle("播报时压低音乐", isOn: $settings.duck)
            Picker("系统音色", selection: $voiceID) {
                Text("自动优选中文").tag("")
                ForEach(Self.zhSpeechVoices, id: \.identifier) { voice in
                    Text(voice.name).tag(voice.identifier)
                }
            }
            Text("语速"); Slider(value: $voiceRate, in: 0.3...0.6)
            Text("音调"); Slider(value: $voicePitch, in: 0.7...1.4)
            Button("试听播报") { Speech.shared.test() }
        }.foregroundColor(AppTheme.text).tint(Self.pink)
    }

    private static let zhSpeechVoices=AVSpeechSynthesisVoice.speechVoices().filter{$0.language.hasPrefix("zh")}

    // MARK: Key 设置
    private var keyCard: some View {
        CardView {
            Text("Key 设置").foregroundColor(AppTheme.text).bold()
            Text("高德 Key：\(Settings.mask(settings.amapKeyInUse))（搜索、导航、巡航用）")
                .font(.footnote).foregroundColor(settings.amapKeyInUse.isEmpty ? Color.orange : ContentView.sub)
            Text("和风天气：\(weather.host.isEmpty || weather.key.isEmpty ? "未配置（可选）" : "已配置")")
                .font(.footnote).foregroundColor(ContentView.sub)
            Button(settings.keysMissing ? "去填写" : "修改") { showKeys = true }
                .foregroundColor(ContentView.cyan)
        }
    }

    /// 没填高德 key：弹出填写页，返回 true（调用的地方就不往下做了）
    private func needAmapKey() -> Bool {
        if settings.amapKeyInUse.isEmpty { hideKeyboard(); showKeys = true; return true }
        return false
    }

    /// Product-facing recovery hints; raw SDK, URL and transport details stay out of the interface.
    static func userMessage(_ raw:String)->String {
        let value=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        if value.range(of:#"https?://|NSURLError|Error Domain=|AMapError|HTTP|\bSDK\b|\bGCJ|\bWGS|数据包|毫秒|字节|0x[0-9a-fA-F]+"#,options:.regularExpression) != nil {
            if value.contains("登录") || value.contains("验证") { return "请完成高德登录或验证后重试" }
            if value.contains("地图") { return "地图暂未准备完成，请保持 App 在前台后重试" }
            return "暂时未能完成，请检查网络和服务配置后重试"
        }
        return value.replacingOccurrences(of:#"（-?\d+）"#,with:"",options:.regularExpression)
    }

    // MARK: 底部导航条（对齐 Apple Music：悬浮液态玻璃胶囊，内容从后方穿过时实时透色）
    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach(0..<TabSpec.count, id: \.self) { i in tabButton(i) }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .tabBarLiquidGlass(Capsule())
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func tabButton(_ i: Int) -> some View {
        let selected = page == i
        let accent = AppTheme.tabAccents[i]
        return Button {
            hideKeyboard()
            page = i
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    // Apple Music：选中态是图标后的软色圆晕，不是整格白胶囊（白胶囊会盖死玻璃折射）
                    if selected {
                        Circle()
                            .fill(accent.opacity(0.18))
                            .frame(width: 44, height: 32)
                    }
                    Image(systemName: selected ? TabSpec.fillIcons[i] : TabSpec.icons[i])
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(selected ? accent : AppTheme.sub.opacity(0.72))
                        .frame(width: 44, height: 28)
                }
                Text(TabSpec.titles[i])
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? accent : AppTheme.sub.opacity(0.72))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 右侧竖栏（Duo 外屏：同系液态玻璃竖条）
    private func rightRail(systemEdge: CGFloat) -> some View {
        VStack(spacing: 6) {
            Spacer(minLength: systemEdge > 0 ? 170 : 12)
            ForEach(0..<TabSpec.count, id: \.self) { i in railButton(i) }
            Spacer(minLength: 12)
        }
        .padding(.vertical, 10)
        .frame(width: max(66, systemEdge))
        .tabBarLiquidGlass(Capsule())
        .padding(.vertical, 8).padding(.trailing, 6)
    }

    private func railButton(_ i: Int) -> some View {
        let selected = page == i
        let accent = AppTheme.tabAccents[i]
        return Button {
            hideKeyboard()
            page = i
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    if selected {
                        Circle()
                            .fill(accent.opacity(0.18))
                            .frame(width: 46, height: 34)
                    }
                    Image(systemName: selected ? TabSpec.fillIcons[i] : TabSpec.icons[i])
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(selected ? accent : AppTheme.sub.opacity(0.72))
                        .frame(width: 46, height: 30)
                }
                Text(TabSpec.titles[i])
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? accent : AppTheme.sub.opacity(0.72))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(width: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 小组件

struct CardView<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(ContentView.card))

    }
}

/// 一条路线的对比卡片：标签、时间、距离 · 红绿灯 · 收费
struct RouteCard: View {
    let option: NaviBridge.RouteOption
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(option.label).font(.caption).foregroundColor(selected ? ContentView.pink : ContentView.sub).lineLimit(1)
            Text(NaviBridge.durText(option.timeS)).font(.headline).foregroundColor(AppTheme.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(NaviBridge.distText(option.length) + (option.lights > 0 ? " · \(option.lights)灯" : "") + (option.toll > 0 ? " · ¥\(option.toll)" : ""))
                .font(.caption2).foregroundColor(ContentView.sub).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ContentView.bg))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? ContentView.pink : ContentView.stroke, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

struct PillButton: View {
    let title: String
    let color: Color
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Capsule().fill(enabled ? color : Color.gray.opacity(0.4)))
        }
        .disabled(!enabled)
    }
}

/// 收起键盘
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

enum TabSpec {
    static let count=4
    static let titles=["导航","轨迹","圆屏","我的"]
    static let icons=["location.north","map","circle.circle","person"]
    static let fillIcons=["location.north.fill","map.fill","circle.circle.fill","person.fill"]
}
enum TabLayout {
    static func isWide(size:CGSize,hSizeClass:UserInterfaceSizeClass?)->Bool {size.width>=700}
    static func useSideRail(size:CGSize,hSizeClass:UserInterfaceSizeClass?,placement:Int)->Bool {
        if placement==1{return false};if placement==2{return true}
        return size.width>=700 && size.width>size.height
    }
}
