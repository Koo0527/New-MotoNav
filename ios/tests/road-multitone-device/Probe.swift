import UIKit
import Foundation
import Darwin

private func cpuSeconds() -> Double {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private func peakResidentBytes() -> Int64 {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Int64(usage.ru_maxrss)
}

private func pixels(_ folder: URL, _ name: String, count: Int) throws -> [UInt32] {
    let data = try Data(contentsOf: folder.appendingPathComponent(name))
    precondition(data.count == count * 4)
    return data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
}

private func runProbe() throws -> [String: Any] {
    let bundle = Bundle.main
    let folder = bundle.bundleURL.appendingPathComponent("ToneProbe", isDirectory: true)
    let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("inputs.json"))) as! [String: Any]
    let scenes = spec["scenes"] as! [String]
    precondition(scenes.count == 5)
    var records = [[String: Any]]()
    let initialThermal = ProcessInfo.processInfo.thermalState.rawValue
    for scene in scenes {
        var runs = [[String: Any]]()
        for iteration in 0..<7 {
            let row: [String: Any] = try autoreleasepool {
                let dir = folder.appendingPathComponent(scene, isDirectory: true)
                let startCPU = cpuSeconds(), start = DispatchTime.now().uptimeNanoseconds
                let raw = try pixels(dir, "base.argb", count: 1_440_000)
                let ids = RoadPalette.classify(raw, w: 1200, h: 1200)
                let roadsDoneCPU = cpuSeconds()
                let base = RoadPalette.encode(frameId: 60000, x0: -1200, y0: 1200, w: 1200, h: 1200, indices: ids)
                precondition(RasterPacket.valid(base))
                var patches = [Int: Data]()
                for q in 0..<4 {
                    patches[q] = try FastBuildings.simplify(pixels(dir, "patch-\(q).argb", count: 360_000))
                }
                let built = FastBuildings.packet(base: base, patches: patches)
                precondition(RasterPacket.valid(built) && built.count <= 480_000)
                precondition(ids.count == 1_440_000)
                let bytes = [UInt8](base)
                return ["iteration": iteration, "warmup": iteration == 0,
                        "roadCPUSeconds": roadsDoneCPU - startCPU,
                        "blockCPUSeconds": cpuSeconds() - startCPU,
                        "wallSeconds": Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9,
                        "baseBytes": base.count, "fullBytes": built.count,
                        "formatMarker": Int(bytes[46]) | Int(bytes[47]) << 8,
                        "peakResidentBytes": peakResidentBytes(),
                        "thermal": ProcessInfo.processInfo.thermalState.rawValue]
            }
            runs.append(row)
        }
        records.append(["scene": scene, "runs": runs])
    }
    return ["kind": "offline-native-map-pipeline", "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "",
            "inputManifest": spec, "initialThermal": initialThermal,
            "finalThermal": ProcessInfo.processInfo.thermalState.rawValue,
            "peakResidentBytes": peakResidentBytes(), "records": records,
            "scope": "Same raw sampled scenes: read, classify, encode, simplify four roof patches, compose and validate. Excludes SDK screenshots, live BLE, UI navigation and G."]
}

@main
final class ToneProbeApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "ToneProbe", sessionRole: session.role)
        configuration.delegateClass = ToneProbeScene.self
        return configuration
    }
}

final class ToneProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        let label = UILabel(frame: UIScreen.main.bounds.insetBy(dx: 24, dy: 90))
        label.numberOfLines = 0; label.textColor = .white
        label.text = "MotoNav 地图处理测试\n正在测量五个区域，请保持亮屏。\n测试完成后恢复正常 App。"
        controller.view.addSubview(label)
        window.rootViewController = controller; window.makeKeyAndVisible(); self.window = window
        UIApplication.shared.isIdleTimerDisabled = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let report = try runProbe()
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MotoNav-Diagnostics", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let mode = Bundle.main.object(forInfoDictionaryKey: "MotoNavToneProbeMode") as! String
                let url = root.appendingPathComponent("tone-probe-\(mode).json")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                DispatchQueue.main.async { label.text = "地图处理测试完成\n结果已保存，请保持连接。" }
            } catch {
                DispatchQueue.main.async { label.text = "地图处理测试失败\n\(error.localizedDescription)" }
            }
        }
    }
}
