import SwiftUI
import CoreLocation

enum TravelMode: String, CaseIterable, Identifiable {
    case driving="驾车", motorcycle="摩托车", bicycle="自行车"
    var id: String { rawValue }
}

final class RoutePlanner: ObservableObject {
    @Published var mode: TravelMode = .driving { didSet { inputsChanged() } }
    @Published var start: MotorPoint? { didSet { inputsChanged() } }
    @Published var end: MotorPoint? { didSet { inputsChanged() } }
    @Published var vias: [MotorPoint]=[] { didSet { inputsChanged() } }
    @Published var routes: [MotorRoute]=[]
    @Published var selected=0
    @Published var busy=false
    @Published var message=""
    @Published private(set) var drivingPlanned=false
    @Published private(set) var share: AmapShare.Route?
    private var generation=UUID()
    private var task: Task<Void,Never>?
    var usesDriving: Bool { mode == .driving || (mode == .motorcycle && share != nil) }
    func inputsChanged() {
        let imported = share != nil
        share=nil
        invalidate()
        message=imported ? "输入或出行方式已更改，请重新规划；不再沿用分享路线" : "请规划当前路线"
    }
    func invalidate() {
        generation=UUID();task?.cancel();task=nil;routes=[];selected=0;busy=false;drivingPlanned=false
        if !NaviBridge.shared.navigating && !NaviBridge.shared.cruising && !WebMotorSession.shared.running { NaviBridge.shared.clearPlan() }
    }
    func setDestination(_ point: MotorPoint) { start=nil;vias=[];end=point }
    func importShare(_ route: AmapShare.Route) {
        mode=route.kind == "自行车" ? .bicycle : route.kind == "摩托车" ? .motorcycle : .driving
        start=MotorPoint(lat:route.startLat,lng:route.startLng,name:route.startName)
        end=MotorPoint(lat:route.endLat,lng:route.endLng,name:route.endName)
        vias=[];share=route
        if mode == .bicycle {
            routes=[MotorRoutes.fromShare(route)];selected=0;message="已载入分享的自行车路线"
        } else { plan() }
    }
    func plan() {
        guard !WebMotorSession.shared.running,!NaviBridge.shared.navigating else { message="请先结束当前导航或巡航";return }
        if NaviBridge.shared.cruising {NaviBridge.shared.stopCruise()}
        invalidate()
        guard !Settings.shared.keysMissing else { message="请先在地图 Key 页面填写自己的高德 iOS Key";return }
        guard let end=end else { message="请选择目的地";return }
        guard mode != .bicycle || vias.isEmpty else { message="自行车规划暂不支持途经点，请移除途经点后重试，或切换出行方式";return }
        guard vias.count<=3 else { message="最多支持 3 个途经点";return }
        if usesDriving {
            NaviBridge.shared.plan(toLat:end.lat,lng:end.lng,share:share,origin:share == nil ? start : nil,
                                   viaPoints:vias.map{NaviBridge.Via(name:$0.name,lat:$0.lat,lng:$0.lng)})
            drivingPlanned=true;message="";return
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
            do {
                let result=try await MotorRoutes.load(request)
                guard let self=self,self.generation==token,!Task.isCancelled else { return }
                self.routes=result;self.selected=0;self.busy=false
                self.message="已找到 \(result.count) 条路线，请选择方案"
            } catch {
                guard let self=self,self.generation==token,!Task.isCancelled else { return }
                self.busy=false;self.message=error.localizedDescription
            }
        }
    }
}

struct PlacePickerView: View {
    let title: String
    let choose: (MotorPoint)->Void
    @StateObject private var search=SearchService()
    @State private var query=""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            List {
                HStack {
                    TextField("搜索地点或地址",text:$query).submitLabel(.search).onSubmit{search.search(query)}
                    Button("搜索"){search.search(query)}
                }
                if !search.status.isEmpty { Text(search.status).font(.caption) }
                ForEach(search.results) { p in
                    Button {
                        choose(MotorPoint(lat:p.lat,lng:p.lng,name:p.name));dismiss()
                    } label: {
                        VStack(alignment:.leading,spacing:4){Text(p.name);Text(p.address).font(.caption).foregroundColor(.secondary)}
                    }
                }
                if search.results.isEmpty && query.isEmpty {
                    ForEach(History.shared.places) { p in
                        Button(p.name){choose(MotorPoint(lat:p.lat,lng:p.lng,name:p.name));dismiss()}
                    }
                }
            }.navigationTitle(title).toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}}}
        }.preferredColorScheme(.dark)
    }
}

struct MotorLoginView: View {
    @StateObject private var browser=MotorBrowser()
    let page: URL?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            VStack {
                Text("仅在登录或验证时打开网页。登录保存在本机，正常规划可直接在 App 完成。").font(.caption).padding()
                MotorBrowserView(browser:browser)
                Text(browser.status).font(.caption)
            }.navigationTitle("高德登录／验证").toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){dismiss()}}}
        }.onAppear{if let page=page {browser.web.load(URLRequest(url:page))}}
    }
}

struct RoutePlannerView: View {
    @ObservedObject var model: RoutePlanner
    @ObservedObject var navi=NaviBridge.shared
    @ObservedObject var guide=WebMotorSession.shared
    @ObservedObject var settings=Settings.shared
    @State private var pick: Int? // 0 origin, 1 destination, 2 via
    @State private var login=false
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
                        ForEach(model.vias.indices,id:\.self){i in HStack{Text("途经 \(i+1)：\(model.vias[i].name)");Spacer();Button("移除"){model.vias.remove(at:i)}}}
                        if model.vias.count<3 {Button("添加途经点"){pick=2}}
                        if model.mode == .bicycle && !model.vias.isEmpty {Text("自行车暂不支持途经点，请移除后规划，或切换方式。").font(.caption).foregroundColor(.orange)}
                        if model.usesDriving {
                            Toggle("不走高速",isOn:$settings.avoidHighway).onChange(of:settings.avoidHighway){_ in model.inputsChanged()}
                        }
                        PillButton(title:model.busy || navi.calculating ? "正在规划…" : "规划\(model.mode.rawValue)路线",color:ContentView.pink,enabled:!model.busy && !navi.calculating && model.end != nil){model.plan()}
                    }
                    if !model.message.isEmpty {Text(model.message).font(.footnote).foregroundColor(ContentView.sub)}
                    if model.share != nil {Text("已载入高德分享路线；更改输入或方式将重新规划。").font(.caption).foregroundColor(.orange)}
                    if model.mode == .motorcycle && !model.usesDriving {Button("高德登录／验证"){login=true}.font(.footnote).foregroundColor(ContentView.cyan)}
                    if model.usesDriving && model.drivingPlanned {
                        Text(navi.info).font(.footnote).foregroundColor(ContentView.sub)
                        if !navi.shareMatch.isEmpty {Text(navi.shareMatch).font(.caption).foregroundColor(ContentView.sub)}
                        if !navi.routeOptions.isEmpty {
                            RouteMapView(routes:navi.routeOptions,selected:navi.selectedRouteID,
                                         ghost:navi.shareRoute?.pts.map{CLLocationCoordinate2D(latitude:$0.lat,longitude:$0.lng)} ?? [],
                                         dest:navi.destCoord,vias:navi.vias.map{CLLocationCoordinate2D(latitude:$0.lat,longitude:$0.lng)},night:settings.paletteNight)
                                .frame(height:260).clipShape(RoundedRectangle(cornerRadius:18))
                            HStack{ForEach(navi.routeOptions){o in RouteCard(option:o,selected:o.id == navi.selectedRouteID).onTapGesture{navi.select(routeID:o.id)}}}
                        }
                    } else if let route=selectedRoute {
                        MotorMap(route:route,position:nil,overview:true).frame(height:260).clipShape(RoundedRectangle(cornerRadius:18))
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
                    HStack {
                        PillButton(title:"开始导航",color:ContentView.pink,enabled:ready){begin(false)}
                        PillButton(title:"模拟导航",color:.purple,enabled:ready){begin(true)}
                    }
                    Text(model.usesDriving ? (model.share == nil ? "驾车路线支持路况、车道和完整导航提示。" : "参考高德分享的路线，沿用驾车策略导航。") : model.mode == .motorcycle ? "按摩托车方案规划，需要时可完成高德登录或验证。" : "按自行车路线规划，暂不支持途经点。")
                        .font(.caption).foregroundColor(ContentView.sub)
                    if settings.tunnelAuto {
                        Text(model.usesDriving ? "本方式支持隧道自动调暗。" : "本方式可在导航页手动开启隧道模式，暂不自动识别隧道。")
                            .font(.caption).foregroundColor(ContentView.sub)
                    }
                }.padding(16)
            }.background(ContentView.bg).navigationTitle("路线规划")
                .toolbar{ToolbarItem(placement:.cancellationAction){Button("返回首页"){dismiss()}}}
        }.foregroundColor(.white).tint(ContentView.pink)
        .sheet(isPresented:Binding(get:{pick != nil},set:{if !$0{pick=nil}})){
            PlacePickerView(title:pick==0 ? "选择起点" : pick==2 ? "选择途经点" : "选择目的地"){point in
                if pick==0{model.start=point}else if pick==2{if model.vias.count<3{model.vias.append(point)}}else{model.end=point}
                pick=nil
            }
        }
        .sheet(isPresented:$login){MotorLoginView(page:nil)}

    }
    private var selectedRoute: MotorRoute? {model.routes.indices.contains(model.selected) ? model.routes[model.selected] : nil}
    private var ready: Bool { !model.busy && !guide.running && !navi.navigating && (model.usesDriving ? model.drivingPlanned && navi.routeReady : selectedRoute != nil) }
    private func begin(_ simulate:Bool){
        guard ready else{model.message="请先结束当前导航或规划当前路线";return}
        if let end=model.end {History.shared.add(SearchService.Place(name:end.name,address:"",lat:end.lat,lng:end.lng))}
        if navi.cruising {navi.stopCruise()}
        if model.usesDriving {navi.start(emulate:simulate)} else if let route=selectedRoute {guide.start(route,simulate:simulate)}
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
                             edgePadding: UIEdgeInsets(top: panelHeights.top + geometry.safeAreaInsets.top + 16,
                                                       left: 16, bottom: panelHeights.bottom + geometry.safeAreaInsets.bottom + 16, right: 16))
                        .ignoresSafeArea()
                }
                NavigationOverlay(readout: readout, muted: settings.voiceMuted,
                                  onOverview: { guide.overview.toggle() }, onMute: toggleMute,
                                  onSettings: { dismiss() }, onEnd: exitNavi,
                                  onPause: { guide.paused.toggle() },
                                  onCycleSpeed: { guide.speed = guide.speed == 60 ? 120 : guide.speed == 120 ? 180 : 60 },
                                  onLayout: { panelHeights = $0 }) {
                    if !metadata.status.isEmpty {
                        Text(metadata.status).font(.caption2).foregroundColor(ContentView.sub)
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
                          status: guide.status, speed: guide.speed, remaining: guide.remaining,
                          remainingSeconds: guide.remainingSeconds, simulation: guide.simulation, paused: guide.paused,
                          simulationSpeed: guide.speed, arrived: guide.arrived)
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
