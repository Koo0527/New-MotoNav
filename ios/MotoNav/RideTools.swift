import SwiftUI
import CoreLocation

final class Favorites: ObservableObject {
    static let shared = Favorites()
    struct Place: Codable, Identifiable {
        var id = UUID(); var name: String; var address: String; var lat: Double; var lng: Double
        var searchPlace: SearchService.Place { .init(name: name, address: address, lat: lat, lng: lng) }
    }
    @Published private(set) var places: [Place] = []
    private init() {
        if let data = UserDefaults.standard.data(forKey: "favorite_places") { places = (try? JSONDecoder().decode([Place].self, from: data)) ?? [] }
    }
    func add(_ p: SearchService.Place) {
        guard !places.contains(where: { NaviBridge.distM($0.lat, $0.lng, p.lat, p.lng) < 50 }) else { return }
        places.insert(Place(name: p.name, address: p.address, lat: p.lat, lng: p.lng), at: 0); save()
    }
    func remove(_ p: Place) { places.removeAll { $0.id == p.id }; save() }
    private func save() { if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: "favorite_places") } }
}

/// WGS84 fixes only. A serial worker appends fixes; completed rides retain the legacy JSON format.
final class RideRecorder: ObservableObject {
    static let shared = RideRecorder()
    struct Fix: Codable { let lat: Double; let lng: Double; let time: Date; let speed: Double }
    struct Ride: Codable, Identifiable {
        var id = UUID(); let started: Date; var ended: Date?; var mode: String; var fixes: [Fix] = []; var meters = 0.0
    }
    @Published private(set) var rides: [Ride] = []
    @Published private(set) var active: Ride?
    @Published var error = ""
    private let root: URL
    private let worker = DispatchQueue(label: "motonav.rides", qos: .utility)
    private var journalWriter: FileHandle? // Worker-confined; lifecycle and fixes share its FIFO.
    private struct JournalPoint: Codable { let fix: Fix; let meters: Double }
    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Rides", isDirectory: true)) {
        root = directory
        worker.async {
            var stored: [Ride] = []
            do {
                try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
                for file in try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                    guard var ride = try? JSONDecoder().decode(Ride.self, from: Data(contentsOf: file)) else { continue }
                    if ride.ended == nil {
                        let journal = self.journalURL(ride.id)
                        if FileManager.default.fileExists(atPath: journal.path) {
                            let data = try Data(contentsOf: journal)
                            for line in data.split(separator: 10) {
                                // A killed process can leave a partial final line; retain the complete prefix.
                                guard let point = try? JSONDecoder().decode(JournalPoint.self, from: Data(line)),
                                      ride.fixes.last.map({ point.fix.time > $0.time }) ?? true else { break }
                                ride.fixes.append(point.fix); ride.meters = point.meters
                            }
                        }
                        ride.ended = ride.fixes.last?.time ?? ride.started
                        try self.write(ride)
                    }
                    // A completed atomic snapshot supersedes its journal, including after a crash.
                    try? FileManager.default.removeItem(at: self.journalURL(ride.id))
                    stored.append(ride)
                }
            } catch { self.storageError(error) }
            let sorted = stored.sorted { $0.started > $1.started }
            DispatchQueue.main.async { self.rides = sorted }
        }
    }
    private func journalURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".jsonl") }
    private func storageError(_ error: Error) {
        let message = "轨迹保存／恢复失败：\(error.localizedDescription)"
        DispatchQueue.main.async { self.error = message }
    }
    private func closeJournal() throws {
        let writer = journalWriter; journalWriter = nil
        try writer?.close()
    }
    private func write(_ ride: Ride) throws {
        try JSONEncoder().encode(ride).write(to: root.appendingPathComponent(ride.id.uuidString + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func start(_ mode: String) {
        finish()
        let ride = Ride(started: Date(), mode: mode)
        active = ride; error = ""
        GRecorder.shared.rideStarted(ride.id)
        worker.async {
            do {
                try self.write(ride)
                let journal = self.journalURL(ride.id)
                try Data().write(to: journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                self.journalWriter = try FileHandle(forWritingTo: journal)
            } catch { self.storageError(error) }
        }
    }
    func fix(_ l: CLLocation) {
        guard active != nil, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 60,
              abs(l.timestamp.timeIntervalSinceNow) < 15 else { return }
        if let last = active?.fixes.last {
            guard l.timestamp > last.time else { return }
            let distance = CLLocation(latitude: last.lat, longitude: last.lng).distance(from: l)
            guard distance / l.timestamp.timeIntervalSince(last.time) < 90 else { return }
            guard distance >= 3 || l.timestamp.timeIntervalSince(last.time) >= 10 else { return }
            active?.meters += distance
        }
        let fix = Fix(lat: l.coordinate.latitude, lng: l.coordinate.longitude, time: l.timestamp, speed: max(0, l.speed))
        active?.fixes.append(fix)
        let point = JournalPoint(fix: fix, meters: active!.meters)
        worker.async {
            do {
                var bytes = try JSONEncoder().encode(point); bytes.append(10)
                try self.journalWriter?.write(contentsOf: bytes)
            } catch {
                try? self.closeJournal()
                self.storageError(error)
            }
        }
    }
    func finish() {
        guard var ride = active else { return }; ride.ended = Date(); active = nil
        GRecorder.shared.rideFinished(ride.id)
        let completed = ride
        worker.async {
            do {
                try self.closeJournal()
                try self.write(completed)
                try? FileManager.default.removeItem(at: self.journalURL(completed.id))
                DispatchQueue.main.async { self.rides.insert(completed, at: 0) }
            } catch { self.storageError(error) }
        }
    }
    func remove(_ ride: Ride) {
        worker.async {
            do {
                try FileManager.default.removeItem(at: self.root.appendingPathComponent(ride.id.uuidString + ".json"))
                DispatchQueue.main.async { self.rides.removeAll { $0.id == ride.id }; GRecorder.shared.unlinkRide(ride.id) }
            } catch { self.storageError(error) }
        }
    }
    func export(_ ride: Ride) throws -> URL {
        let formatter = ISO8601DateFormatter()
        let points = ride.fixes.map { "<trkpt lat=\"\($0.lat)\" lon=\"\($0.lng)\"><time>\(formatter.string(from: $0.time))</time></trkpt>" }.joined()
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"MotoNav\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>MotoNav</name><trkseg>\(points)</trkseg></trk></gpx>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MotoNav-\(ride.id).gpx")
        try Data(xml.utf8).write(to: url, options: .atomic); return url
    }
}

struct RideHistoryView:View {
    @ObservedObject var recorder=RideRecorder.shared
    var body:some View {
        List {
            if let active=recorder.active {Text("记录中 · \(active.mode) · \(Int(active.meters)) 米")}
            if !recorder.error.isEmpty {Text(ContentView.userMessage(recorder.error)).foregroundColor(AppTheme.red)}
            ForEach(recorder.rides){ride in
                NavigationLink(destination:RideDetailView(ride:ride)){RideListRow(ride:ride)}
            }
            if recorder.rides.isEmpty && recorder.active == nil {Text("真实导航或巡航开始时自动记录；模拟导航不记录。")}
        }.navigationTitle("导航轨迹")
    }
}
struct ExportSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
