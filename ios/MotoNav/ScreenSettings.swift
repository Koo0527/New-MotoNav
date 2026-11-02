import SwiftUI

/// 「圆屏」标签的分类设置入口：六组，每项设置只在一处编辑。
/// 显示与地图 / 按键与电源 / 开机设置 / 音乐控制 / G 仪表与校准 / 连接管理（连接管理入口由 ContentView 提供）。
enum ScreenSettingGroup: String, Identifiable, CaseIterable {
    case display, keysPower, boot, music, gauge, connection
    var id: String { rawValue }
    var title: String {
        switch self {
        case .display: return "显示与地图"
        case .keysPower: return "按键与电源"
        case .boot: return "开机设置"
        case .music: return "音乐控制"
        case .gauge: return "G 仪表与校准"
        case .connection: return "连接管理"
        }
    }
    var subtitle: String {
        switch self {
        case .display: return "方向 · 亮度 · 主题 · 地图"
        case .keysPower: return "实体按键 · 供电休眠 · 省电"
        case .boot: return "开机动画 · 提示音"
        case .music: return "授权 · 歌词"
        case .gauge: return "实时仪表 · 安装校准"
        case .connection: return "换屏 · 配对 · 时间"
        }
    }
    var icon: String {
        switch self {
        case .display: return "map"
        case .keysPower: return "button.top.right.press"
        case .boot: return "power"
        case .music: return "music.note"
        case .gauge: return "speedometer"
        case .connection: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// 与「我的」SettingsHubList 同款的分组入口列表
struct ScreenSettingsList<Destination: View>: View {
    @ViewBuilder var destination: (ScreenSettingGroup) -> Destination
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ScreenSettingGroup.allCases.enumerated()), id: \.element.id) { idx, group in
                NavigationLink(destination: destination(group)) {
                    HStack(spacing: 12) {
                        Image(systemName: group.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(AppTheme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                                .font(.body.weight(.semibold))
                                .foregroundColor(AppTheme.text)
                            Text(group.subtitle)
                                .font(.caption)
                                .foregroundColor(AppTheme.sub)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(AppTheme.sub.opacity(0.7))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if idx < ScreenSettingGroup.allCases.count - 1 {
                    Divider().padding(.leading, 56).opacity(0.35)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(AppTheme.card))
    }
}

// MARK: - 显示与地图（画面方向、亮度、昼夜配色、主题、小地图、建筑、路线效果、进度环、预判、隧道调暗）

struct ScreenDisplaySettings: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var ble = BleLink.shared
    @ObservedObject private var map = MapFeeder.shared
    @State private var showMapReport = false
    var body: some View {
        CardView {
            Text("画面方向").foregroundColor(AppTheme.text).bold()
            RotationDial(degrees: $settings.rotationDeg)      // 按住圆盘转动调角度
            Text("拖动圆盘调整方向，粉色指针代表画面上方。")
                .font(.caption2).foregroundColor(AppTheme.sub)
        }
        CardView {
            Text("亮度").foregroundColor(AppTheme.text).bold()
            Toggle("亮度跟着昼夜自动调", isOn: $settings.brightAuto).foregroundColor(AppTheme.text).tint(AppTheme.accent)
            if settings.brightAuto {
                HStack {
                    Text("白天").foregroundColor(AppTheme.text)
                    Slider(value: $settings.brightDay, in: 5...255, step: 5).tint(AppTheme.accent)
                    Text("\(Int(settings.brightDay))").font(.caption).foregroundColor(AppTheme.sub).frame(width: 34)
                }
                HStack {
                    Text("夜间").foregroundColor(AppTheme.text)
                    Slider(value: $settings.brightNight, in: 5...255, step: 5).tint(AppTheme.accent)
                    Text("\(Int(settings.brightNight))").font(.caption).foregroundColor(AppTheme.sub).frame(width: 34)
                }
                if !settings.brightDesc.isEmpty { Text(settings.brightDesc).font(.caption2).foregroundColor(AppTheme.sub) }
            } else {
                HStack {
                    Text("亮度").foregroundColor(AppTheme.text)
                    Slider(value: $settings.brightness, in: 5...255, step: 5).tint(AppTheme.accent)
                    Text("\(Int(settings.brightness))").font(.caption).foregroundColor(AppTheme.sub).frame(width: 34)
                }
            }
        }
        CardView {
            Text("昼夜配色").foregroundColor(AppTheme.text).bold()
            Picker("夜间配色", selection: $settings.nightMode) {
                Text("自动（日出日落）").tag(0); Text("白天").tag(1); Text("夜间").tag(2)
            }
            .pickerStyle(.segmented)
            if !settings.nightDesc.isEmpty { Text(settings.nightDesc).font(.caption2).foregroundColor(AppTheme.sub) }
            Text("圆屏小地图与界面随此设置切换昼夜。").font(.caption2).foregroundColor(AppTheme.sub)
        }
        CardView {
            Text("主题").foregroundColor(AppTheme.text).bold()
            Picker("风格", selection: $settings.theme) {
                ForEach(Settings.themeOrder, id: \.self) { t in Text(Settings.themeName(t)).tag(t) }
            }
            .tint(AppTheme.cyan)
            Text(Settings.themeDesc(settings.theme)).font(.caption2).foregroundColor(AppTheme.sub)
            Toggle("路程进度环", isOn: $settings.progressRing).foregroundColor(AppTheme.text).tint(AppTheme.accent)
            Picker("预判", selection: $settings.leadMs) {
                Text("关闭").tag(0); Text("0.3秒").tag(300); Text("0.6秒").tag(600)
            }.pickerStyle(.segmented)
            Text("预判让画面方向略微提前于车身转动。").font(.caption2).foregroundColor(AppTheme.sub)
        }
        CardView {
            Toggle("小地图", isOn: $settings.mapOn).foregroundColor(AppTheme.text).tint(AppTheme.accent)
            if settings.mapOn {
                if settings.mapSource == MapFeeder.SRC_AMAP && AmapCapturePolicy.supportsBuildings(settings.theme) {
                    Toggle("俯视建筑轮廓", isOn: $settings.buildings).foregroundColor(AppTheme.text).tint(AppTheme.accent)
                    if ble.isReady && !ble.buildingsSupported {
                        Text("当前圆屏暂不支持建筑轮廓，将显示普通地图。")
                            .font(.caption).foregroundColor(AppTheme.sub)
                    }
                }
                Text(Self.userMessage(map.offlineStatus)).font(.caption).foregroundColor(AppTheme.sub)
                Text("选定路线后，前台自动下载沿途地图；锁屏使用已保存地图包。请等下载完成再出发。")
                    .font(.caption2).foregroundColor(AppTheme.sub)
                Button("地图显示问题"){showMapReport=true}.foregroundColor(AppTheme.cyan)
            }
        }
        CardView {
            Text("路线效果").foregroundColor(AppTheme.text).bold()
            Picker("走过的路线", selection: $settings.trail) {
                Text("变灰").tag(1); Text("擦除").tag(2)
            }
            .pickerStyle(.segmented)
            Toggle("弯道急缓上色", isOn: $settings.curve).foregroundColor(AppTheme.text).tint(AppTheme.accent)
            Toggle("清爽模式", isOn: $settings.clean).foregroundColor(AppTheme.text).tint(AppTheme.accent)
            Text("仅保留地图和路线，隐藏其他提示").font(.caption2).foregroundColor(AppTheme.sub)
        }
        CardView {
            Toggle("隧道自动调暗", isOn: $settings.tunnelAuto).foregroundColor(AppTheme.text).tint(AppTheme.accent)
            Text("自动识别仅支持驾车导航；其他方式可使用导航中的临时隧道快捷操作。").font(.caption).foregroundColor(AppTheme.sub)
        }
        .sheet(isPresented:$showMapReport){MapSampleReportView()}
    }
    private static func userMessage(_ raw: String) -> String { ContentView.userMessage(raw) }
}

// MARK: - 按键与电源（实体按键说明、供电休眠、锁屏空闲省电）

struct ScreenKeysPowerSettings: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var ble = BleLink.shared
    private var connected: Bool { ble.isReady && ble.verified }
    private func duration(_ seconds: Int) -> String { seconds == 0 ? "永不" : "\(seconds) 秒" }
    var body: some View {
        CardView {
            Text("实体按键").foregroundColor(AppTheme.text).bold()
            if settings.deviceControlsSupported {
                Text(settings.deviceControlStatus).font(.caption).foregroundColor(AppTheme.sub)
                Text("BOOT 短按切换隧道模式，长按锁定触摸；休眠后首次按键只唤醒。断开手机也可使用。").font(.caption)
                Button("重新读取按键状态") { ble.sendOnce("#CTL"); ble.sendOnce("#PS") }.disabled(!connected)
                    .foregroundColor(AppTheme.cyan)
            } else {
                Text("连接支持的新版圆屏固件后，可设置实体按键状态与休眠。").font(.caption).foregroundColor(AppTheme.sub)
            }
        }
        CardView {
            Text("供电休眠").foregroundColor(AppTheme.text).bold()
            if settings.deviceControlsSupported {
                Picker("USB 供电休眠", selection: Binding(get: { settings.usbSleep }, set: { settings.setDevicePower(usb: $0, battery: settings.batterySleep) })) {
                    ForEach(Settings.usbSleepOptions, id: \.self) { Text(duration($0)).tag($0) }
                }.disabled(!connected || !settings.devicePowerRead)
                Picker("电池供电休眠", selection: Binding(get: { settings.batterySleep }, set: { settings.setDevicePower(usb: settings.usbSleep, battery: $0) })) {
                    ForEach(Settings.batterySleepOptions, id: \.self) { Text(duration($0)).tag($0) }
                }.disabled(!connected || !settings.devicePowerRead)
                Text(settings.devicePowerStatus).font(.caption).foregroundColor(AppTheme.sub)
                Text("休眠保留蓝牙；电池空闲累计 5 分钟关机。导航、巡航、配对和通话时不会休眠。").font(.caption)
            } else {
                Text("连接支持的新版圆屏固件后，可分别设置 USB 与电池供电的休眠时间。").font(.caption).foregroundColor(AppTheme.sub)
            }
        }
        CardView {
            Text("锁屏空闲省电").foregroundColor(AppTheme.text).bold()
            Toggle("锁屏空闲省电", isOn: $settings.idleLinkSave).foregroundColor(AppTheme.text).tint(AppTheme.accent)
            Text("锁屏且无导航、巡航、录制和音乐显示持续 3 分钟后断开圆屏，回到 App 自动重连；期间后台心跳也会放慢。关闭则只放慢心跳、不断开。")
                .font(.caption).foregroundColor(AppTheme.sub)
            if ble.status.contains("锁屏空闲省电") { Text(ble.status).font(.caption).foregroundColor(AppTheme.sub) }
            Text("巡航连续停车 10 分钟后自动结束。")
                .font(.caption).foregroundColor(AppTheme.sub)
        }
    }
}

// MARK: - 开机设置（开机动画、提示音与音量）

struct ScreenBootSettings: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var ble = BleLink.shared
    private var connected: Bool { ble.isReady && ble.verified }
    var body: some View {
        CardView {
            Text("开机动画").foregroundColor(AppTheme.text).bold()
            Picker("开机动画", selection: $settings.bootBrand) {
                ForEach(Settings.bootBrands.indices, id: \.self) { i in Text(Settings.bootBrands[i]).tag(i) }
            }.tint(AppTheme.cyan)
            Text(settings.bootStatus).font(.caption).foregroundColor(AppTheme.sub)
        }
        CardView {
            Text("提示音与音量").foregroundColor(AppTheme.text).bold()
            if settings.deviceAudioSupported {
                Toggle("播放开机提示音", isOn: Binding(get: { settings.bootSound }, set: { settings.setDeviceSound(enabled: $0, volume: settings.bootVolume) }))
                    .disabled(!connected || !settings.deviceAudioRead)
                Picker("音量", selection: Binding(get: { settings.bootVolume }, set: { settings.setDeviceSound(enabled: settings.bootSound, volume: $0) })) {
                    ForEach(Array(Set(stride(from: 0, through: 100, by: 10)).union([settings.bootVolume])).sorted(), id: \.self) { Text("\($0)%").tag($0) }
                }.disabled(!connected || !settings.deviceAudioRead)
                Text(settings.deviceAudioStatus).font(.caption).foregroundColor(AppTheme.sub)
                Button("重新读取提示音设置") { ble.sendOnce("#BS") }.disabled(!connected)
                    .foregroundColor(AppTheme.cyan)
            } else {
                Text("连接支持的新版圆屏固件后，可设置开机提示音和音量。").font(.caption).foregroundColor(AppTheme.sub)
            }
        }
    }
}

// MARK: - 音乐控制（控制授权、连接状态、歌词）

struct ScreenMusicSettings: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var ble = BleLink.shared
    var body: some View {
        CardView {
            Text("控制授权").foregroundColor(AppTheme.text).bold()
            Toggle("音乐控制", isOn: $settings.musicHID).foregroundColor(AppTheme.text).tint(AppTheme.accent)
            if !settings.musicHID {
                Button("授权 Apple Music 圆屏控制") { MusicBridge.shared.authorize() }
                    .foregroundColor(AppTheme.cyan)
            }
        }
        CardView {
            Text("连接状态").foregroundColor(AppTheme.text).bold()
            Text(ble.mediaHIDSupported
                 ? (ble.mediaHIDReady && ble.mediaHIDMode ? "媒体按键已就绪" : ble.mediaAMSControls > 0 && ble.mediaHIDMode ? "音乐控制已就绪" : "请在 iPhone 设置 → 蓝牙中配对 MotoNav；按圆屏配对码提示完成")
                 : "请连接圆屏并更新到支持音乐控制的固件")
                .font(.caption).foregroundColor(AppTheme.sub)
            if !ble.mediaSongInfo.isEmpty {
                Text(ble.mediaSongInfo).font(.caption).foregroundColor(AppTheme.cyan)
            }
        }
        CardView {
            Text("歌词").foregroundColor(AppTheme.text).bold()
            Toggle("显示逐句歌词", isOn: $settings.musicLyrics).foregroundColor(AppTheme.text).tint(AppTheme.accent)
            Text("开启后自动匹配歌词，未匹配到时显示歌名和歌手。")
                .font(.caption).foregroundColor(AppTheme.sub)
            if !settings.musicLyrics && ble.mediaLyricsActive { Text("正在关闭圆屏歌词…").font(.caption).foregroundColor(AppTheme.sub) }
            if settings.musicLyrics {
                Text(ble.mediaLyricsSupported ? "播放音乐后自动匹配歌词" : "请更新圆屏固件以显示歌词")
                    .font(.caption).foregroundColor(AppTheme.cyan)
            }
            Text("先在音乐 App 中播放，再用圆屏切歌或暂停。歌名和歌手由播放器提供。")
                .font(.caption).foregroundColor(AppTheme.sub)
        }
    }
}

// MARK: - G 仪表与校准（实时仪表、记录及安装校准；单一入口，不再重复）

struct ScreenGaugeSettings: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var ble = BleLink.shared
    @State private var reference = 1
    @State private var angle = 0
    private var connected: Bool { ble.isReady && ble.verified }
    var body: some View {
        CardView {
            Text("实时仪表与记录").foregroundColor(AppTheme.text).bold()
            NavigationLink(destination: GDashboardView()) {
                Label("G 仪表与记录", systemImage: "scope").foregroundColor(AppTheme.cyan)
            }
            Text("G 值是本地传感器估计；断开手机仍可使用。").font(.caption).foregroundColor(AppTheme.sub)
        }
        CardView {
            Text("安装校准").foregroundColor(AppTheme.text).bold()
            if settings.deviceIMUSupported {
                Text("保持实际安装倾角，进入 G 值页后停车静置约 3 秒会自动校准，无需水平放置。其他安装朝向可在下方手动调整。").font(.caption)
                Picker("车头参考方向", selection: $reference) {
                    Text("屏幕背面指向车头").tag(0)
                    Text("充电口朝后（默认）").tag(1)
                    Text("右侧边缘指向车头").tag(2)
                }
                HStack(spacing: 18) {
                    VStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9).stroke(AppTheme.sub, lineWidth: 2).frame(width: 48, height: 58)
                            Circle().stroke(AppTheme.sub, lineWidth: 1).frame(width: 32, height: 32)
                            Capsule().fill(AppTheme.sub).frame(width: 14, height: 4).offset(y: 29)
                            if reference == 0 { Image(systemName: "arrow.up.right").foregroundColor(AppTheme.accent) }
                            if reference == 1 { Rectangle().fill(AppTheme.accent).frame(width: 36, height: 4).offset(y: -29) }
                            if reference == 2 { Rectangle().fill(AppTheme.accent).frame(width: 4, height: 46).offset(x: 24) }
                        }
                        Text(reference == 0 ? "由屏幕指向背面" : reference == 1 ? "远离充电口为前" : "充电口朝后时的右侧").font(.caption2)
                    }
                    VStack {
                        Image(systemName: reference == 0 ? "arrow.down.backward" : reference == 1 ? "arrow.up" : "arrow.right")
                            .font(.largeTitle).rotationEffect(.degrees(Double(angle)))
                        Text("参考方向 → 车头").font(.caption2)
                    }
                    Text("\(angle)°").monospacedDigit()
                }.accessibilityLabel("安装参考：\(reference == 0 ? "屏幕背面" : reference == 1 ? "充电口朝后" : "充电口朝后时的右侧")，车头角度 \(angle) 度")
                RotationDial(degrees: $angle)
                Text("图中充电口在后方，远离充电口为前方，左右以面朝前方为准。默认角度 0°；其他安装方向按图示顺时针调节车头角度。保持静止 3 秒；参考方向接近竖直时请换一个方向。").font(.caption)
                Button("静止 3 秒并校准") { settings.calibrateDevice(reference: reference, angle: angle) }
                    .disabled(!connected || !settings.deviceCalibrationRead || settings.deviceCalibrating)
                Text(settings.deviceCalibrationStatus).font(.caption)
                Text("只有圆屏确认校准成功才会保存；失败后保留上次校准。").font(.caption)
                Button("重新读取校准状态") { ble.sendOnce("#GQ") }.disabled(!connected)
                    .foregroundColor(AppTheme.cyan)
            } else {
                Text("连接支持的新版圆屏固件后，可使用 G 值估计与安装校准。").font(.caption).foregroundColor(AppTheme.sub)
            }
        }
        .onAppear { reference = settings.mountReference; angle = settings.mountAngle }
        .onChange(of: settings.mountReference) { reference = $0 }
        .onChange(of: settings.mountAngle) { angle = $0 }
    }
}
