import SwiftUI

private func gValue(_ value: Double) -> String { String(format: "%.2f", value) }
private func gPoints(_ samples: [GSample]) -> [GPlotPoint] {
    samples.map { GPlotPoint(time: $0.elapsed, lateral: $0.lateral, longitudinal: $0.longitudinal, valid: $0.valid, gap: $0.gap) }
}
private func gWindowPeaks(_ points: [GPlotPoint]) -> GPeaks {
    let valid = points.filter(\.valid)
    return GPeaks(acceleration: max(0, valid.map(\.longitudinal).max() ?? 0),
                  braking: max(0, -(valid.map(\.longitudinal).min() ?? 0)),
                  left: max(0, -(valid.map(\.lateral).min() ?? 0)),
                  right: max(0, valid.map(\.lateral).max() ?? 0))
}

struct GDashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @ObservedObject private var recorder = GRecorder.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var ble = BleLink.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardView {
                    Text("圆屏实时 G 估计").font(.headline)
                    Text(recorder.status).font(.subheadline).foregroundColor(recorder.ready ? AppTheme.green : AppTheme.sub)
                    Text(ble.isReady && ble.verified ? "已连接圆屏 · 数据来自车辆传感器" : "圆屏未连接，等待设备数据")
                        .font(.caption).foregroundColor(AppTheme.sub)
                    Text(settings.deviceCalibrationStatus).font(.caption).foregroundColor(AppTheme.sub)
                    Text("按实际装车倾角固定圆屏，充电口默认朝后。进入本页或圆屏 G 值页后，停车静置约 3 秒自动校准；无需水平安装。充电口朝下接近竖直时，以屏幕背面为前。转动或抖动会重新计时。请只在停车后校准。可靠定位显示行驶时会暂停校准；定位不可信、后台或断连时采用保守策略，可能需要停车后重新进入 G 页或手动校准。")
                        .font(.caption).foregroundColor(AppTheme.sub)
                    HStack {
                        if recorder.recording {
                            Label("记录中 · \(recorder.owner)", systemImage: "record.circle").foregroundColor(AppTheme.red)
                            Spacer()
                            if recorder.canStopManual { Button("停止并保存") { recorder.stop() } }
                        } else {
                            Button { recorder.startManual() } label: { Label("开始手动记录", systemImage: "record.circle") }
                                .disabled(!recorder.ready)
                        }
                    }.font(.subheadline.weight(.semibold))
                    if recorder.recording && !recorder.canStopManual {
                        Text("随真实导航自动记录，导航结束后自动保存。").font(.caption).foregroundColor(AppTheme.sub)
                    }
                    Text("手动记录无需 GPS；真实导航会自动记录并关联导航详情。断连、校准和传感器异常会标为数据间断。")
                        .font(.caption).foregroundColor(AppTheme.sub)
                    if !recorder.error.isEmpty { Text(recorder.error).font(.caption).foregroundColor(AppTheme.red) }
                }
                GReplayCharts(points: gPoints(recorder.liveSamples), duration: 60, live: true,
                              available: recorder.ready, sessionPeaks: recorder.recording && (recorder.activeRecord?.sampleCount ?? 0) > 0 ? recorder.activePeaks : nil)
                NavigationLink(destination: GHistoryView()) {
                    Label("G 记录历史（\(recorder.records.count)）", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(RoundedRectangle(cornerRadius: 18).fill(AppTheme.card))
                }
                Text("白线为最近 5 秒轨迹，黄色点为所选时刻。G 值为圆屏本地估计，手机不使用自身运动传感器替代。")
                    .font(.caption).foregroundColor(AppTheme.sub)
            }.padding(16)
        }
        .background(AppTheme.bg.ignoresSafeArea())
        .navigationTitle("G 仪表与记录").navigationBarTitleDisplayMode(.inline).navigationBarHidden(false)
        .onAppear { visible = true; recorder.setPreview(scenePhase == .active); if ble.isReady && ble.verified { ble.sendOnce("#GQ") } }
        .onDisappear { visible = false; recorder.setPreview(false) }
        .onChange(of: scenePhase) { recorder.setPreview(visible && $0 == .active) }
    }
}

struct GHistoryView: View {
    @ObservedObject private var recorder = GRecorder.shared
    var rideID: UUID? = nil
    private var records: [GRecord] { recorder.records.filter { record in rideID.map { record.rideIDs.contains($0) } ?? true } }
    var body: some View {
        List {
            if records.isEmpty { Text("暂无 G 记录").foregroundColor(AppTheme.sub) }
            ForEach(records) { record in
                NavigationLink(destination: GRecordDetailView(record: record)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.started, style: .date).font(.headline)
                        Text("\(record.rideIDs.isEmpty ? "手动记录" : "导航关联记录") · \(Int(record.duration)) 秒 · \(record.sampleCount) 个采样")
                            .font(.caption).foregroundColor(AppTheme.sub)
                        if record.interrupted { Text("记录曾中断，缺失区间不连线").font(.caption).foregroundColor(AppTheme.amber) }
                    }.padding(.vertical, 4)
                }
            }.onDelete { offsets in offsets.map { records[$0] }.forEach { recorder.delete($0) } }
        }
        .navigationTitle(rideID == nil ? "G 记录历史" : "本次导航 G 记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GRecordDetailView: View {
    let record: GRecord
    @ObservedObject private var recorder = GRecorder.shared
    @State private var points: [GPlotPoint] = []
    @State private var loading = true
    @State private var loadGeneration = UUID()
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(record.started, style: .date).font(.headline)
                Text("\(record.sampleCount) 个采样 · \(Int(record.duration)) 秒\(record.interrupted ? " · 曾中断" : "")")
                    .font(.caption).foregroundColor(AppTheme.sub)
                if loading { ProgressView("读取时间窗口…") }
                GReplayCharts(points: points, duration: max(1, record.duration), live: false, available: true,
                              requestWindow: { from, to in load(from: from, to: to) })
                if !recorder.error.isEmpty { Text(recorder.error).foregroundColor(AppTheme.red).font(.caption) }
                Button("删除这条 G 记录", role: .destructive) { confirmDelete = true }
            }.padding(16)
        }
        .background(AppTheme.bg.ignoresSafeArea())
        .navigationTitle("G 记录回放").navigationBarTitleDisplayMode(.inline)
        .alert("删除这条 G 记录？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { recorder.delete(record); dismiss() }
            Button("取消", role: .cancel) {}
        }
    }
    private func load(from: Double, to: Double) {
        let generation = UUID(); loadGeneration = generation; loading = true
        recorder.loadSamples(for: record, from: from, to: to, limit: 2400) { samples in
            guard loadGeneration == generation else { return }
            points = gPoints(samples); loading = false
        }
    }
}

/// Both plots share one time window and cursor. No chart interpolates invalid data.
struct GReplayCharts: View {
    let points: [GPlotPoint]
    let duration: Double
    let live: Bool
    let available: Bool
    var sessionPeaks: GPeaks? = nil
    var requestWindow: ((Double, Double) -> Void)? = nil
    @State private var range = 1.0
    @State private var width = 30.0
    @State private var end: Double? = nil
    @State private var cursor: Double? = nil
    @State private var pinchWidth: Double? = nil
    @State private var fetchTask: DispatchWorkItem? = nil
    private var bounds: ClosedRange<Double> {
        if live { let last = points.last?.time ?? 60; return max(0, last - 60)...max(0.001, last) }
        return 0...max(1, duration)
    }
    private var window: ClosedRange<Double> { GChartGeometry.window(end: end ?? bounds.upperBound, duration: width, bounds: bounds) }
    private var shown: [GPlotPoint] { points.filter { window.contains($0.time) } }
    private var plotRange: Double { max(range, shown.filter(\.valid).map { max(abs($0.lateral), abs($0.longitudinal)) }.max() ?? range) }
    private var selectedTime: Double { cursor ?? window.upperBound }
    private var selected: GPlotPoint? { available ? GChartGeometry.selected(shown, at: selectedTime, maxDistance: live ? 0.3 : .infinity) : nil }
    private var peaks: GPeaks { sessionPeaks ?? gWindowPeaks(shown) }
    var body: some View {
        VStack(spacing: 14) {
            CardView {
                HStack { Text("横向 / 纵向 G").font(.headline); Spacer(); Text(sessionPeaks == nil ? "窗口峰值" : "本次记录峰值").font(.caption).foregroundColor(AppTheme.sub) }
                Picker("仪表量程", selection: $range) {
                    Text("0.5 g").tag(0.5); Text("1 g").tag(1.0); Text("2 g").tag(2.0)
                }.pickerStyle(.segmented)
                dial.aspectRatio(1, contentMode: .fit)
                Text(selected.map { "横向 \(gValue($0.lateral)) g  ·  纵向 \(gValue($0.longitudinal)) g" } ?? "等待有效圆屏数据 / 当前时刻数据间断")
                    .font(.subheadline.monospacedDigit()).foregroundColor(AppTheme.text)
                    .frame(maxWidth: .infinity)
            }
            CardView {
                HStack { Text("时间曲线").font(.headline); Spacer(); Text("±\(gValue(plotRange)) g").font(.caption).foregroundColor(AppTheme.sub) }
                HStack(spacing: 16) { Label("横向", systemImage: "minus").foregroundColor(AppTheme.accent); Label("纵向", systemImage: "minus").foregroundColor(AppTheme.amber); Spacer(); Text("g").foregroundColor(AppTheme.sub) }.font(.caption)
                timePlot.frame(height: 170)
                HStack { Text(String(format: "%.1f 秒", window.lowerBound)); Spacer(); Text(String(format: "所选 %.1f 秒", selectedTime)); Spacer(); Text(String(format: "%.1f 秒", window.upperBound)) }.font(.caption2.monospacedDigit()).foregroundColor(AppTheme.sub)
                Picker("时间窗口", selection: $width) {
                    Text("10 秒").tag(10.0); Text("30 秒").tag(30.0); Text("60 秒").tag(60.0)
                    if !live && ![10.0, 30.0, 60.0].contains(max(1, duration)) { Text("全部").tag(max(1, duration)) }
                }.pickerStyle(.segmented)
                if bounds.upperBound - bounds.lowerBound > min(width, bounds.upperBound - bounds.lowerBound) + 0.01 {
                    Slider(value: Binding(get: { window.upperBound }, set: { end = $0; cursor = nil }),
                           in: min(bounds.upperBound, bounds.lowerBound + width)...bounds.upperBound)
                        .accessibilityLabel("移动回放时间窗口")
                }
                HStack {
                    Button(live ? "回到实时" : "回到末尾") { end = nil; cursor = nil }
                    Spacer()
                    Button("上一采样") { step(-0.1) }; Button("下一采样") { step(0.1) }
                }.font(.caption)
                Text("拖动曲线选择时刻，双指缩放时间窗口；滑块移动窗口。间断区间保留空白。")
                    .font(.caption).foregroundColor(AppTheme.sub)
            }
        }
        .onAppear { fetch() }
        .onChange(of: width) { _ in cursor = nil; fetch() }
        .onChange(of: end) { _ in fetch() }
        .onDisappear { fetchTask?.cancel() }
    }
    private func fetch() {
        fetchTask?.cancel()
        guard let requestWindow else { return }
        let interval = window
        let task = DispatchWorkItem { requestWindow(interval.lowerBound, interval.upperBound) }
        fetchTask = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
    }
    private func step(_ delta: Double) { cursor = min(window.upperBound, max(window.lowerBound, selectedTime + delta)) }
    private var dial: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * 0.34
            ZStack {
                Canvas { context, _ in
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius * 1.1, y: center.y - radius * 1.1, width: radius * 2.2, height: radius * 2.2)), with: .color(.black))
                    for fraction in [0.25, 0.5, 0.75, 1.0] {
                        let r = radius * fraction
                        context.stroke(Path(ellipseIn: CGRect(x: center.x-r, y: center.y-r, width: r*2, height: r*2)), with: .color(.gray.opacity(0.5)), lineWidth: 1)
                    }
                    var axes = Path(); axes.move(to: CGPoint(x: center.x-radius,y: center.y)); axes.addLine(to: CGPoint(x:center.x+radius,y:center.y)); axes.move(to:CGPoint(x:center.x,y:center.y-radius)); axes.addLine(to:CGPoint(x:center.x,y:center.y+radius)); context.stroke(axes, with:.color(.gray.opacity(0.5)))
                    func position(_ point: GPlotPoint) -> CGPoint {
                        let normalized = GChartGeometry.clipped(lateral: point.lateral, longitudinal: point.longitudinal, range: range)
                        return CGPoint(x: center.x + normalized.0 * radius, y: center.y + normalized.1 * radius)
                    }
                    for segment in GChartGeometry.segments(shown, maxGap: live ? 0.35 : .infinity) {
                        let reduced = GChartGeometry.decimate(segment, pixels: 300)
                        var path = Path()
                        for (index, point) in reduced.enumerated() { if index == 0 { path.move(to:position(point)) } else { path.addLine(to:position(point)) } }
                        context.stroke(path, with:.color(.gray.opacity(0.35)), lineWidth: 1)
                    }
                    let trail = shown.filter { $0.time <= selectedTime && $0.time >= selectedTime - 5 }
                    for segment in GChartGeometry.segments(trail, maxGap: live ? 0.35 : .infinity) {
                        var path = Path()
                        for (index, point) in segment.enumerated() { if index == 0 { path.move(to:position(point)) } else { path.addLine(to:position(point)) } }
                        context.stroke(path, with:.color(.white.opacity(0.85)), style:StrokeStyle(lineWidth:1.5,lineCap:.round,lineJoin:.round))
                    }
                    if let selected = selected {
                        let p = position(selected)
                        context.fill(Path(ellipseIn:CGRect(x:p.x-6,y:p.y-6,width:12,height:12)),with:.color(.yellow))
                    }
                }
                peakLabel("加速", peaks.acceleration).position(x:center.x,y:15)
                peakLabel("制动", peaks.braking).position(x:center.x,y:size.height-15)
                peakLabel("左向", peaks.left).position(x:28,y:center.y)
                peakLabel("右向", peaks.right).position(x:size.width-28,y:center.y)
                Text("\(gValue(range)) g").font(.caption2).foregroundColor(.gray).position(x:center.x,y:center.y+radius*0.8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("G 仪表，\(selected.map { "横向 \(gValue($0.lateral)) g，纵向 \(gValue($0.longitudinal)) g" } ?? "数据不可用")，加速峰值 \(gValue(peaks.acceleration)) g，制动 \(gValue(peaks.braking)) g，左向 \(gValue(peaks.left)) g，右向 \(gValue(peaks.right)) g")
    }
    private func peakLabel(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 2) { Text(title).font(.caption2); Text(sessionPeaks != nil || shown.contains(where: \.valid) ? "\(gValue(value)) g" : "— g").font(.caption.monospacedDigit().weight(.semibold)) }
            .foregroundColor(AppTheme.text)
    }
    private var timePlot: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let span = max(1, window.upperBound-window.lowerBound)
                func x(_ t: Double) -> CGFloat { (t-window.lowerBound)/span * size.width }
                func y(_ value: Double) -> CGFloat { size.height/2 - CGFloat(value/plotRange)*size.height*0.45 }
                var zero = Path(); zero.move(to:CGPoint(x:0,y:size.height/2)); zero.addLine(to:CGPoint(x:size.width,y:size.height/2)); context.stroke(zero,with:.color(AppTheme.stroke))
                for segment in GChartGeometry.segments(shown, maxGap: live ? 0.35 : .infinity) {
                    let reduced = GChartGeometry.decimate(segment,pixels:max(1,Int(size.width)))
                    for axis in 0..<2 {
                        var path = Path()
                        for (index, point) in reduced.enumerated() {
                            let p=CGPoint(x:x(point.time),y:y(axis==0 ? point.lateral : point.longitudinal))
                            if index==0 { path.move(to:p) } else { path.addLine(to:p) }
                        }
                        context.stroke(path,with:.color(axis==0 ? AppTheme.accent : AppTheme.amber),lineWidth:1.5)
                    }
                }
                var selection=Path();selection.move(to:CGPoint(x:x(selectedTime),y:0));selection.addLine(to:CGPoint(x:x(selectedTime),y:size.height));context.stroke(selection,with:.color(AppTheme.text.opacity(0.6)),style:StrokeStyle(lineWidth:1,dash:[4,3]))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged { value in
                let time=window.lowerBound+Double(min(geometry.size.width,max(0,value.location.x))/max(1,geometry.size.width))*(window.upperBound-window.lowerBound)
                cursor=GChartGeometry.selected(shown, at:time, maxDistance: live ? 0.3 : .infinity)?.time ?? time
            })
            .simultaneousGesture(MagnificationGesture().onChanged { value in
                if pinchWidth == nil { pinchWidth = width }
                width=min(bounds.upperBound-bounds.lowerBound,max(1,(pinchWidth ?? width)/Double(value)))
            }.onEnded { _ in pinchWidth=nil })
        }
        .accessibilityElement(children:.ignore).accessibilityLabel("横向与纵向 G 时间曲线，所选 \(String(format:"%.1f",selectedTime)) 秒")
        .accessibilityAdjustableAction { direction in step(direction == .increment ? 0.1 : -0.1) }
    }
}
