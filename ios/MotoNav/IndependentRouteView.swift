import SwiftUI
import CoreLocation

enum TravelMode: String, CaseIterable, Identifiable {
    case driving="驾车", motorcycle="摩托车", bicycle="自行车"
    var id: String { rawValue }
    /// 模拟档位按「自行车 / 机动车」分族：驾车与摩托车共用档位，两者之间切换不重置
    var usesBicycleGears: Bool { self == .bicycle }
}

/// 本次规划实际执行的后端。出行方式与实际引擎分别记录：
/// 例如“摩托车分享使用驾车SDK”、“自行车分享走独立导航”，都按这里判断，不用出行方式猜测引擎。
enum PlanBackend: String {
    case driveSDK, rideSDK, independent
}

final class RoutePlanner: ObservableObject {
    @Published var mode: TravelMode = .driving {
        didSet {
            // 自行车与机动车之间切换恢复对应默认档；驾车与摩托车之间切换保留所选档位
            if oldValue.usesBicycleGears != mode.usesBicycleGears {
                simulationSpeed = NavigationSpeed.defaultSpeed(bicycle: mode.usesBicycleGears)
            }
            inputsChanged()
        }
    }
    /// 模拟导航档位：按出行方式显示，开始模拟时交给对应引擎（与途中循环调速同一策略）
    @Published var simulationSpeed = NavigationSpeed.motorDefault
    @Published var start: MotorPoint? { didSet { inputsChanged() } }
    @Published var end: MotorPoint? { didSet { inputsChanged() } }
    @Published var vias: [MotorPoint]=[] { didSet { inputsChanged() } }
    /// 普通自行车路线默认官方骑行引擎（产品规则）；失败时明确提示，可显式改回兼容（网页）引擎，不静默切换。
    @Published var officialRide = UserDefaults.standard.object(forKey: "ride_engine_official") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(officialRide, forKey: "ride_engine_official")
            inputsChanged()
        }
    }
    /// 自行车分享默认保留原轨迹走独立导航；用户显式点“用官方引擎重新规划”后才置位。
    @Published var shareRideOfficial = false
    @Published var routes: [MotorRoute]=[]
    @Published var selected=0
    @Published var busy=false
    @Published var message=""
    @Published private(set) var drivingPlanned=false
    @Published private(set) var ridePlanned=false
    @Published private(set) var share: AmapShare.Route?
    private var generation=UUID()
    private var task: Task<Void,Never>?
    var usesDriving: Bool { mode == .driving || (mode == .motorcycle && share != nil) }
    /// 官方骑行引擎（SDK）：普通自行车按开关（默认开）；自行车分享默认保留原线，
    /// 只有显式“用官方引擎重新规划”（shareRideOfficial）后才走官方引擎。
    var usesOfficialRide: Bool {
        guard mode == .bicycle else { return false }
        return share != nil ? shareRideOfficial : officialRide
    }
    /// 实际后端标识：driveSDK / rideSDK / independent
    var backend: PlanBackend {
        if usesDriving { return .driveSDK }
        if usesOfficialRide { return .rideSDK }
        return .independent
    }
    func inputsChanged() {
        let imported = share != nil
        share=nil
        shareRideOfficial=false
        invalidate()
        message=imported ? "输入或出行方式已更改，请重新规划；不再沿用分享路线" : "请规划当前路线"
    }
    func invalidate() {
        generation=UUID();task?.cancel();task=nil;routes=[];selected=0;busy=false
        drivingPlanned=false;ridePlanned=false
        if !NavigationCoordinator.shared.navigationActive && !NaviBridge.shared.cruising {
            NaviBridge.shared.clearPlan()
            RideBridge.shared.clearPlan()
        }
    }
    func setDestination(_ point: MotorPoint) { start=nil;vias=[];end=point }
    func importShare(_ route: AmapShare.Route) {
        mode=route.kind == "自行车" ? .bicycle : route.kind == "摩托车" ? .motorcycle : .driving
        start=MotorPoint(lat:route.startLat,lng:route.startLng,name:route.startName)
        end=MotorPoint(lat:route.endLat,lng:route.endLng,name:route.endName)
        vias=[];share=route;shareRideOfficial=false
        if mode == .bicycle {
            routes=[MotorRoutes.fromShare(route)];selected=0;message="已载入分享的自行车路线"
        } else { plan() }
    }
    /// 放弃官方重划，回到分享的原轨迹（独立导航预览）
    func restoreShareLine() {
        guard let route = share else { return }
        shareRideOfficial=false
        ridePlanned=false
        if !NavigationCoordinator.shared.navigationActive && !NaviBridge.shared.cruising { RideBridge.shared.clearPlan() }
        routes=[MotorRoutes.fromShare(route)];selected=0
        message="已回到分享的原轨迹"
    }
    func load(_ entry:SavedMotorPlan) {
        guard entry.valid else{return}
        // History stores independent planning inputs, never an old route geometry.
        mode=entry.request.bicycle ? .bicycle:.motorcycle
        start=entry.request.start;end=entry.request.end;vias=entry.request.vias
        message="已恢复起终点和途经点，点击规划获取最新路线"
    }
    func plan() {
        guard !NavigationCoordinator.shared.navigationActive else { message="请先结束当前导航或巡航";return }
        if NaviBridge.shared.cruising {NaviBridge.shared.stopCruise()}
        invalidate()
        guard !Settings.shared.keysMissing else { message="请先在地图 Key 页面填写自己的高德 iOS Key";return }
        guard let end=end else { message="请选择目的地";return }
        guard mode != .bicycle || vias.isEmpty else { message="自行车规划暂不支持途经点，请移除途经点后重试，或切换出行方式";return }
        guard vias.count<=3 else { message="最多支持 3 个途经点";return }
        // 按实际后端分流（出行方式与引擎分别记录，见 backend）
        switch backend {
        case .driveSDK:
            NaviBridge.shared.plan(toLat:end.lat,lng:end.lng,share:share,origin:share == nil ? start : nil,
                                   viaPoints:vias.map{NaviBridge.Via(name:$0.name,lat:$0.lat,lng:$0.lng)})
            drivingPlanned=true;message="";return
        case .rideSDK:
            // 官方骑行：SDK 独立算路；起点没手选时由 SDK 用当前位置（分享重划与驾车分享一样不手传起点）。
            // 分享的官方重划不进历史（沿用分享导入不记历史）。
            RideBridge.shared.plan(toLat:end.lat,lng:end.lng,origin:share == nil ? start : nil,
                                   endName:end.name,historyEligible:share == nil)
            ridePlanned=true;message="";return
        case .independent:
            break
        }
        let origin: MotorPoint
        if let start=start { origin=start }
        else {
            guard let fix=LocationService.shared.location,fix.horizontalAccuracy>=0,fix.horizontalAccuracy<=100,abs(fix.timestamp.timeIntervalSinceNow)<15 else { message="当前位置尚未就绪，请等待定位或手动选择起点";LocationService.shared.start();return }
            let g=MapGeo.wgsToGcj(fix.coordinate.latitude,fix.coordinate.longitude)
            origin=MotorPoint(lat:g.lat,lng:g.lng,name:"我的位置")
        }
        let token=generation
        let request=MotorRequest(start:origin,end:end,vias:vias,bicycle:mode == .bicycle)
        busy=true;message="正在规划\(mode.rawValue)路线…"
        task=Task { @MainActor [weak self] in
            do{
                let result=try await MotorRoutes.load(request)
                guard let self=self,self.generation==token,!Task.isCancelled else{return}
                self.routes=result;self.selected=0;self.busy=false
                self.message="已找到 \(result.count) 条路线，请选择方案"
                if let first=result.first{MotorPlanHistory.shared.save(first)}
            }catch{
                guard let self=self,self.generation==token,!Task.isCancelled else{return}
                self.busy=false;self.message=error.localizedDescription
            }
        }
    }
}

struct MotorLoginView:View {
    @StateObject private var browser=MotorBrowser()
    let page:URL?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationView{
            VStack{
                Text("仅在登录或验证时打开网页。登录保存在本机，正常规划可直接在 App 完成。").font(.caption).padding()
                MotorBrowserView(browser:browser)
                Text(ContentView.userMessage(browser.status)).font(.caption)
            }.navigationTitle("高德登录／验证").toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){dismiss()}}}
        }.onAppear{if let page=page{browser.web.load(URLRequest(url:page))}}
    }
}

struct RoutePlannerView: View {
    @ObservedObject var model: RoutePlanner
    @ObservedObject var navi=NaviBridge.shared
    @ObservedObject var guide=WebMotorSession.shared
    @ObservedObject var ride=RideBridge.shared
    @ObservedObject var settings=Settings.shared
    @State private var pick: Int? // 0 origin, 1 destination
    @State private var login=false
    @State private var waypoints=false
    @State private var showHistory=false
    @State private var showSimulationSettings=false
    @State private var showRouteOptions=false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Picker("出行方式",selection:$model.mode){ForEach(TravelMode.allCases){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
                    CardView {
                        Button{pick=0}label:{Label(model.start?.name.isEmpty == false ? model.start!.name : "我的位置（点此更改起点）",systemImage:"location")}
                        if model.start != nil {Button("使用当前位置"){model.start=nil}.font(.caption)}
                        Divider()
                        Button{pick=1}label:{Label(model.end?.name.isEmpty == false ? model.end!.name : "输入目的地",systemImage:"mappin.and.ellipse")}
                        if let end=model.end { Button("收藏目的地"){Favorites.shared.add(SearchService.Place(name:end.name,address:"",lat:end.lat,lng:end.lng))}.font(.caption) }
                        if model.mode != .bicycle || !model.vias.isEmpty {
                            Button {waypoints=true} label: {
                                Label(model.vias.isEmpty ? "添加途经点（最多三个）":"途经："+model.vias.map{$0.name}.joined(separator:" → "),systemImage:"point.topleft.down.curvedto.point.bottomright.up")
                            }
                        }
                        if model.mode == .bicycle && !model.vias.isEmpty {Text("自行车暂不支持途经点，请移除后规划，或切换方式。").font(.caption).foregroundColor(.orange)}
                        routeOptions
                        PillButton(title:model.busy || navi.calculating || ride.calculating ? "正在规划…" : "规划\(model.mode.rawValue)路线",color:ContentView.pink,enabled:!model.busy && !navi.calculating && !ride.calculating && model.end != nil){model.plan()}
                    }
                    if model.mode != .driving {Button("路线历史"){showHistory=true}.foregroundColor(ContentView.cyan)}
                    if !model.message.isEmpty {Text(ContentView.userMessage(model.message)).font(.footnote).foregroundColor(ContentView.sub)}
                    if model.share != nil {Text("已载入高德分享路线；更改输入或方式将重新规划。").font(.caption).foregroundColor(.orange)}
                    if model.mode == .motorcycle && !model.usesDriving {Button("高德登录／验证"){login=true}.font(.footnote).foregroundColor(ContentView.cyan)}
                    routeResults
                    PillButton(title:"开始导航",color:ContentView.pink,enabled:ready){begin(false)}
                    simulationSettings
                    Text(footerHint)
                        .font(.caption).foregroundColor(ContentView.sub)
                    if settings.tunnelAuto {
                        Text(model.usesDriving ? "本方式支持隧道自动调暗。" : "本方式可在导航页手动开启隧道模式，暂不自动识别隧道。")
                            .font(.caption).foregroundColor(ContentView.sub)
                    }
                }.padding(16)
            }.background(ContentView.bg).navigationTitle("路线规划")
                .toolbar{ToolbarItem(placement:.cancellationAction){Button("返回首页"){dismiss()}}}
        }.foregroundColor(AppTheme.text).tint(ContentView.pink)
        .sheet(isPresented:Binding(get:{pick != nil},set:{if !$0{pick=nil}})){
            RoutePointPicker(title:pick==0 ? "选择起点" : "选择目的地",near:model.start){point in
                if pick==0{model.start=point}else{model.end=point}
                pick=nil
            }
        }
        .sheet(isPresented:$waypoints){RouteWaypointEditor(points:model.vias,near:model.start){points in model.vias=points}}
        .sheet(isPresented:$showHistory){MotorHistoryView(bicycle:model.mode == .bicycle){entry in model.load(entry)}}
        .sheet(isPresented:$login){MotorLoginView(page:nil)}
        .onAppear {LocationService.shared.start()}

    }
    private var selectedRoute: MotorRoute? {model.routes.indices.contains(model.selected) ? model.routes[model.selected] : nil}
    /// 路线选项：驾车策略与骑行引擎选择集中在此；失败时明确提示，不自动更换引擎
    private var routeOptions: some View {
        DisclosureGroup(isExpanded:$showRouteOptions) {
            VStack(alignment:.leading,spacing:10) {
                if model.usesDriving {
                Toggle("不走高速",isOn:$settings.avoidHighway).onChange(of:settings.avoidHighway){_ in model.inputsChanged()}
                }
                if model.mode == .bicycle && model.share == nil {
                    // 普通自行车路线默认官方骑行引擎；关闭后走网页兼容路线（显式选择，不静默切换）
                    Toggle("官方骑行引擎（SDK）",isOn:$model.officialRide)
                }
            }.padding(.top,4)
        } label: {
            Text("路线选项").font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.text)
                .frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())
        }.tint(ContentView.pink)
    }
    /// 模拟设置为次操作：档位按出行方式显示（自行车 10/20/30，机动车 60/100/120），
    /// 与开始模拟、途中循环调速共用 NavigationSpeed 同一策略。
    private var simulationSettings: some View {
        DisclosureGroup(isExpanded:$showSimulationSettings) {
            VStack(alignment:.leading,spacing:10) {
                Text("速度档位（\(model.mode.rawValue)）").font(.caption).foregroundColor(ContentView.sub)
                Picker("模拟速度",selection:$model.simulationSpeed){
                    ForEach(NavigationSpeed.values(bicycle:model.mode.usesBicycleGears),id:\.self){Text("\($0) km/h").tag($0)}
                }.pickerStyle(.segmented)
                PillButton(title:"模拟导航",color:AppTheme.accent,enabled:ready){begin(true)}
            }.padding(.top,4)
        } label: {
            Text("模拟设置").font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.text)
                .frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())
        }.tint(ContentView.pink)
    }
    /// 规划结果区：驾车 SDK / 官方骑行 SDK（Task 1）/ 网页路线 三选一展示
    @ViewBuilder private var routeResults: some View {
        if model.usesDriving && model.drivingPlanned {
            Text(ContentView.userMessage(navi.info)).font(.footnote).foregroundColor(ContentView.sub)
            if !navi.shareMatch.isEmpty {Text(navi.shareMatch).font(.caption).foregroundColor(ContentView.sub)}
            if !navi.routeOptions.isEmpty {
                let ghost: [CLLocationCoordinate2D] = navi.shareRoute?.pts.map{CLLocationCoordinate2D(latitude:$0.lat,longitude:$0.lng)} ?? []
                let viaPins: [CLLocationCoordinate2D] = navi.vias.map{CLLocationCoordinate2D(latitude:$0.lat,longitude:$0.lng)}
                RouteMapView(routes:navi.routeOptions,selected:navi.selectedRouteID,
                             ghost:ghost,dest:navi.destCoord,vias:viaPins,night:settings.paletteNight)
                    .frame(height:260).clipShape(RoundedRectangle(cornerRadius:18))
                HStack{ForEach(navi.routeOptions){o in RouteCard(option:o,selected:o.id == navi.selectedRouteID).onTapGesture{navi.select(routeID:o.id)}}}
            }
        } else if model.usesOfficialRide && model.ridePlanned {
            // 官方骑行 SDK 的算路 / 选路（复用驾车卡片与预览地图）。
            // 分享重划时原轨迹以橙色细线同时展示：先看原线与新方案，再开始。
            Text(ContentView.userMessage(ride.info)).font(.footnote).foregroundColor(ContentView.sub)
            if model.share != nil {Text("橙色细线是分享的原轨迹，新方案为官方骑行路线；对比后再开始。").font(.caption).foregroundColor(.orange)}
            if let failure=ride.failure {
                Text("\(failure.title)：\(failure.detail)").font(.footnote).foregroundColor(.orange)
            }
            if ride.planFailed {
                // 失败时明确提示 + 显式选择：重试官方引擎，或改用兼容引擎（不静默切换）
                HStack {
                    PillButton(title:"重新规划",color:ContentView.pink){model.plan()}
                    if model.share != nil {
                        PillButton(title:"回到分享原轨迹",color:AppTheme.accent){model.restoreShareLine()}
                    } else {
                        PillButton(title:"改用兼容引擎",color:AppTheme.accent){model.officialRide=false;model.plan()}
                    }
                }
                Text("改用兼容引擎将从网页路线规划，保持当前选择。").font(.caption).foregroundColor(ContentView.sub)
            }
            if !ride.routeOptions.isEmpty {
                let dest: CLLocationCoordinate2D? = model.end.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
                let ghost: [CLLocationCoordinate2D] = model.share.map { $0.pts.map { CLLocationCoordinate2D(latitude:$0.lat,longitude:$0.lng) } } ?? []
                RouteMapView(routes:ride.routeOptions,selected:ride.selectedRouteID,
                             ghost:ghost,dest:dest,night:settings.paletteNight)
                    .frame(height:260).clipShape(RoundedRectangle(cornerRadius:18))
                HStack{ForEach(ride.routeOptions){o in RouteCard(option:o,selected:o.id == ride.selectedRouteID).onTapGesture{ride.select(routeID:o.id)}}}
                if model.share != nil {
                    Button("沿用分享原轨迹（独立导航）"){model.restoreShareLine()}.font(.footnote).foregroundColor(ContentView.cyan)
                }
            }
        } else if let route=selectedRoute {
            if model.mode == .bicycle && model.share != nil {
                // 自行车分享默认保留原轨迹走独立导航；显式改用官方引擎重划（展示原线与新方案后再开始）
                Button("用官方引擎重新规划"){model.shareRideOfficial=true;model.plan()}.font(.footnote).foregroundColor(ContentView.cyan)
            }
            MotorMap(route:route,position:nil,overview:true).frame(height:260).clipShape(RoundedRectangle(cornerRadius:18))
            if !route.detailedGuidance {Text("已取得路线轨迹，暂无分段转向指引，请按地图路线行进。").font(.footnote).foregroundColor(ContentView.sub)}
            ForEach(Array(model.routes.enumerated()),id:\.offset){i,r in
                Button{model.selected=i}label:{
                    HStack{
                        Image(systemName:model.selected==i ? "checkmark.circle.fill" : "circle")
                        VStack(alignment:.leading,spacing:4){Text("方案 \(i+1) · \(NaviBridge.durText(r.seconds))").bold();Text(NaviBridge.distText(r.totalMeters)).font(.subheadline)}
                        Spacer()
                    }.padding(14).background(RoundedRectangle(cornerRadius:14).fill(ContentView.card))
                }
            }
        }
    }
    private var ready: Bool {
        !model.busy && !guide.running && !navi.navigating && !ride.navigating &&
            (model.usesDriving ? model.drivingPlanned && navi.routeReady
             : model.usesOfficialRide ? model.ridePlanned && ride.routeReady
             : selectedRoute != nil)
    }
    private var footerHint: String {
        if model.usesDriving { return model.share == nil ? "驾车路线支持路况、车道和完整导航提示。" : "参考高德分享的路线，沿用驾车策略导航。" }
        if model.usesOfficialRide { return model.share == nil ? "官方骑行引擎：SDK 骑行路线与导航，暂不支持途经点。" : "官方重划从当前位置到分享的终点；原轨迹以橙色细线保留对比。" }
        return model.mode == .motorcycle ? "按摩托车方案规划，需要时可完成高德登录或验证。" : "按自行车路线规划，暂不支持途经点；分享的自行车路线默认按原轨迹独立导航。"
    }
    private func begin(_ simulate:Bool){
        guard ready else{model.message="请先结束当前导航或规划当前路线";return}
        if let end=model.end {History.shared.add(SearchService.Place(name:end.name,address:"",lat:end.lat,lng:end.lng))}
        if navi.cruising {navi.stopCruise()}
        if model.usesDriving {navi.preferredSimulationSpeed=NavigationSpeed.normalized(model.simulationSpeed, bicycle: false);navi.start(emulate:simulate)}
        else if model.usesOfficialRide {ride.preferredSimulationSpeed=NavigationSpeed.normalized(model.simulationSpeed, bicycle: true);ride.start(emulate:simulate)}
        else if let route=selectedRoute {MotorPlanHistory.shared.save(route);guide.start(route,simulate:simulate,simulationSpeed:model.simulationSpeed)}
    }
}

/// 骑行导航画面：地图优先 —— AMapNaviRideView 作为骑行引擎的数据代表画路线和车标，
/// 浮层用与驾车/兼容导航同一套统一 HUD（顶部紧凑卡 + 底部控制栏 + 更多菜单）。
/// 真实 / 模拟共用；到达展示保留 4 秒（RideBridge 收尾），随后自动回规划页。
struct RideNaviScreen: View {
    @ObservedObject var ride = RideBridge.shared
    @ObservedObject var settings = Settings.shared
    @StateObject private var rideCtl = RideViewController()
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClose = false
    @State private var showNativeUI = false
    @State private var panelHeights = NavigationPanelHeights()

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                AMapRideViewRep(controller: rideCtl, showNativeUI: showNativeUI,
                                edgePadding: NaviHudLayout.mapEdgeInsets(panelTop: panelHeights.top,
                                                                         panelBottom: panelHeights.bottom,
                                                                         safeTop: geometry.safeAreaInsets.top,
                                                                         safeBottom: geometry.safeAreaInsets.bottom))
                    .ignoresSafeArea()
                if !showNativeUI || ride.showArrived {
                    NavigationOverlay(readout: readout, muted: settings.voiceMuted,
                                      onOverview: rideCtl.toggleOverview, onMute: toggleMute,
                                      onSettings: { dismiss() }, onEnd: exitNavi,
                                      onPause: { ride.toggleEmuPause() },
                                      onCycleSpeed: { ride.cycleEmuSpeed() },
                                      onLayout: { panelHeights = $0 },
                                      onShowNativeUI: { showNativeUI = true }) {
                        if ride.rerouteFailed {
                            VStack(spacing: 6) {
                                HStack {
                                    Text("重新规划失败，已保留当前路线").font(.caption)
                                    Spacer()
                                    Button("重试") { ride.retryRecalculate() }.frame(minHeight: 44)
                                }
                                Text("多次失败可退出导航，从当前位置改用兼容引擎重新规划并预览。")
                                    .font(.caption2).foregroundColor(AppTheme.hudSub)
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
        .onAppear { rideCtl.onClose = { confirmClose = true } }
        .alert("退出导航？", isPresented: $confirmClose) {
            Button("退出导航", role: .destructive) { exitNavi() }
            Button("继续导航", role: .cancel) {}
        }
        .onChange(of: ride.navigating) { now in
            if !now && !ride.showArrived { dismiss() }
        }
        .onChange(of: ride.showArrived) { now in
            // 到达展示保留 4 秒：RideBridge 到达 4 秒后才清 showArrived，这里随之自动退出
            if !now && !ride.navigating { dismiss() }
        }
        .confirmationDialog("导航选项", isPresented: $rideCtl.showMore, titleVisibility: .hidden) {
            Button(rideCtl.isOverview ? "回到车头跟随" : "看全程") { rideCtl.toggleOverview() }
            Button("返回首页修改设置") { dismiss() }
            Button("退出导航", role: .destructive) { exitNavi() }
            Button("取消", role: .cancel) {}
        }
    }

    private var readout: NavigationReadout {
        NavigationReadout(direction: ride.uiDir, turnMetres: ride.uiDist, instruction: ride.uiRoad,
                          status: ride.info, speed: ride.uiSpeed, remaining: ride.uiRemainM,
                          remainingSeconds: ride.uiRemainS, simulation: ride.emulating, paused: ride.emuPaused,
                          simulationSpeed: ride.emuSpeed, arrived: ride.showArrived)
    }
    private func toggleMute() {
        settings.voiceMuted.toggle()
        if settings.voiceMuted { Speech.shared.stopNow() }
    }
    private func exitNavi() {
        ride.stop()
        dismiss()
    }
}

struct IndependentNavigationView: View {
    @ObservedObject var guide = WebMotorSession.shared
    @ObservedObject var settings = Settings.shared
    @ObservedObject var metadata = WebRouteMetadata.shared
    @Environment(\.dismiss) private var dismiss
    @State private var panelHeights = NavigationPanelHeights()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let route = guide.route {
                    MotorMap(route: route, position: guide.position, overview: guide.overview,
                             edgePadding: NaviHudLayout.mapEdgeInsets(panelTop: panelHeights.top,
                                                                      panelBottom: panelHeights.bottom,
                                                                      safeTop: geometry.safeAreaInsets.top,
                                                                      safeBottom: geometry.safeAreaInsets.bottom))
                        .ignoresSafeArea()
                }
                // 兼容导航：不传 onShowNativeUI——SDK 专属功能（完整导航界面）在菜单里隐藏，不伪造入口
                NavigationOverlay(readout: readout, muted: settings.voiceMuted,
                                  onOverview: { guide.overview.toggle() }, onMute: toggleMute,
                                  onSettings: { dismiss() }, onEnd: exitNavi,
                                  onPause: { guide.paused.toggle() },
                                  onCycleSpeed: { guide.speed = NavigationSpeed.next(guide.speed, bicycle: guide.route?.request.bicycle ?? false) },
                                  onLayout: { panelHeights = $0 }) {
                    if !guide.ridePlanNotice.isEmpty {
                        Text(guide.ridePlanNotice).font(.caption2).foregroundColor(.orange)
                    }
                    if !metadata.status.isEmpty {
                        Text(ContentView.userMessage(metadata.status)).font(.caption2).foregroundColor(ContentView.sub)
                    }
                }
            }
        }
        .task(id:guide.arrived) {
            guard guide.arrived else{return}
            try? await Task.sleep(nanoseconds:4_000_000_000)
            guard !Task.isCancelled,guide.arrived,!guide.running else{return}
            guide.arrived=false;dismiss()
        }
    }

    private var readout: NavigationReadout {
        NavigationReadout(direction: guide.turnDirection, turnMetres: guide.turnMetres, instruction: guide.instruction,
                          status: navigationNotice, speed: guide.speed, remaining: guide.remaining,
                          remainingSeconds: guide.remainingSeconds, simulation: guide.simulation, paused: guide.paused,
                          simulationSpeed: guide.speed, arrived: guide.arrived)
    }
    private var navigationNotice:String {
        if guide.status.contains("重算失败") {return "重新规划暂未完成，将保留当前路线"}
        if guide.status.contains("正在重新规划") {return "偏离路线，正在重新规划…"}
        if guide.status.contains("已偏离路线") {return "已偏离路线"}
        if guide.status.contains("GPS") {return "定位信号较弱"}
        if guide.route?.detailedGuidance == false {return "按路线行进 · 暂无分段转向指引"}
        return guide.simulation ? "模拟导航":"导航中"
    }
    private func toggleMute() {
        settings.voiceMuted.toggle()
        if settings.voiceMuted { Speech.shared.stopNow() }
    }
    private func exitNavi() {
        guide.stop()
        guide.arrived = false
        dismiss()
    }
}
