import Foundation
import Combine

struct GSample: Codable, Identifiable {
    let id: UInt64
    let elapsed: Double
    let utc: Date
    let lateral: Double
    let longitudinal: Double
    var valid = true
    var gap = false
}
struct GPeaks: Codable {
    var acceleration = 0.0, braking = 0.0, left = 0.0, right = 0.0
    mutating func include(_ sample: GSample) {
        acceleration = max(acceleration, sample.longitudinal); braking = max(braking, -sample.longitudinal)
        left = max(left, -sample.lateral); right = max(right, sample.lateral)
    }
}
struct GRecord: Codable, Identifiable {
    var id = UUID()
    let started: Date
    var ended: Date?
    var rideIDs: [UUID] = []
    var sampleCount = 0
    var interrupted = false
    var duration = 0.0
    var gaps = 0
    var peaks = GPeaks()
}
struct GFrame {
    let flags: UInt8, sequence: UInt16, milliseconds: UInt32, token: UInt32
    let lateralMG: Int16, longitudinalMG: Int16
    init?(_ data: Data) {
        guard data.count == 17 else { return nil }
        let b = [UInt8](data)
        guard b[0] == 0xa7, b[1] == 1, b[2] & 0xe0 == 0 else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i+1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i+2)) << 16 }
        flags = b[2]; sequence = u16(3); milliseconds = u32(5); token = u32(9)
        lateralMG = Int16(bitPattern: u16(13)); longitudinalMG = Int16(bitPattern: u16(15))
    }
    var valid: Bool { flags == 1 }
}

/// Each connection gets a fresh lease token; ordering is measured on the board clock, never BLE arrival time.
struct GStreamClock {
    var token: UInt32
    private var sequence: UInt16?
    private var board: UInt32?
    private var ticks: UInt64 = 0
    mutating func accept(_ frame: GFrame) -> (seconds: Double, gap: Bool)? {
        guard frame.token == token else { return nil }
        if let sequence, let board {
            let delta = frame.sequence &- sequence, ms = frame.milliseconds &- board
            guard delta > 0, delta < 32768, ms > 0, ms < 0x80000000 else { return nil }
            ticks += UInt64(ms)
            self.sequence = frame.sequence; self.board = frame.milliseconds
            return (Double(ticks)/1000, delta > 1 || ms > 150)
        }
        sequence = frame.sequence; board = frame.milliseconds
        return (0, false)
    }
}

final class GRecorder: ObservableObject {
    static let shared = GRecorder()
    @Published private(set) var records: [GRecord] = []
    @Published private(set) var liveSamples: [GSample] = []
    @Published private(set) var recording = false
    @Published private(set) var ready = false
    @Published private(set) var status = "连接支持 G 记录的圆屏后使用"
    @Published private(set) var error = ""
    @Published private(set) var activeRecord: GRecord?
    @Published private(set) var owner = ""
    @Published private(set) var activePeaks = GPeaks()
    var canStopManual: Bool { recording }
    private let root: URL
    private let worker: DispatchQueue
    private let send: (String) -> Void
    private var writer: FileHandle?
    private var writeID: UUID?
    private let storageLock = NSLock()
    private var storageFailed = false
    private var pendingRows = 0
    private var buffered: [Row] = []
    private var bufferedRecord: GRecord?
    private var batchWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var lastFrameAt = 0.0
    private var stale = false
    private var recordBeganAt: Double?
    var pendingSampleCount: Int { storageLock.lock(); defer { storageLock.unlock() }; return pendingRows }
    private var hasStorageFailed: Bool { storageLock.lock(); defer { storageLock.unlock() }; return storageFailed }
    private var indexes: [UUID: [(time: Double, offset: UInt64)]] = [:]
    private var indexCount = 0
    private var supported = false, sensorReady = false, manual = false, previewing = false
    private var ride: UUID?, suppressedRide: UUID?
    private var stream: GStreamClock?
    private var lastRenew = 0.0
    private var segmentDate: Date?
    private var segmentOffset = 0.0
    private var segmentTick = 0.0
    private var gap = false
    private var sampleID: UInt64 = 0
    private var loaded = false
    private struct Row: Codable { var sample: GSample?; var gap: String?; var utc: Date?; var elapsed: Double? }
    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("GRecords", isDirectory: true), send: @escaping (String) -> Void = { BleLink.shared.sendOnce($0) }, worker: DispatchQueue = DispatchQueue(label: "motonav.g-records", qos: .utility)) {
        root = directory; self.send = send; self.worker = worker
        worker.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var found: [GRecord] = []
                for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                    guard var record = try? JSONDecoder().decode(GRecord.self, from: Data(contentsOf: url)) else { continue }
                    try self.recover(&record)
                    if record.sampleCount > 0 { found.append(record) }
                }
                let sorted = found.sorted { $0.started > $1.started }
                DispatchQueue.main.async { self.records = sorted; self.loaded = true; self.updateReady() }
            } catch { self.failed(error) }
        }
    }
    private func journal(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".jsonl") }
    private func metadata(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    private func save(_ record: GRecord) throws {
        try JSONEncoder().encode(record).write(to: metadata(record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    // Bounded line scanning also accepts the complete prefix of a torn final write.
    private func scan(_ id: UUID, from offset: UInt64 = 0, visit: (Row, UInt64) -> Bool) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: journal(id)); defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var pending = Data(), position = offset
        while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
            pending.append(bytes)
            while let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                guard let row = try? JSONDecoder().decode(Row.self, from: line) else { return position }
                let next = position + UInt64(line.count + 1)
                if !visit(row, position) { return position }
                pending.removeSubrange(...end); position = next
            }
            if pending.count > 65536 { return position }
        }
        return position
    }
    private func recover(_ record: inout GRecord) throws {
        let interrupted = record.ended == nil
        guard interrupted else { return }
        var count = 0, last: GSample?, gapEnd: Double = 0, gapDate: Date?, peaks = GPeaks(), index: [(Double, UInt64)] = [], gaps = 0
        let end = try scan(record.id) { row, offset in
            if let sample = row.sample {
                guard sample.valid, sample.elapsed.isFinite, sample.lateral.isFinite, sample.longitudinal.isFinite,
                      last.map({ sample.elapsed > $0.elapsed }) ?? true else { return false }
                if count % 200 == 0 { index.append((sample.elapsed, offset)) }
                count += 1; last = sample; peaks.include(sample)
            }
            if row.gap != nil { gaps += 1; gapEnd = max(gapEnd, row.elapsed ?? 0); gapDate = row.utc ?? gapDate }
            return true
        }
        indexes[record.id] = index
        if interrupted {
            let file = try FileHandle(forWritingTo: journal(record.id)); try file.truncate(atOffset: end); try file.close()
            record.sampleCount = count; record.duration = max(last?.elapsed ?? 0, gapEnd); record.peaks = peaks; record.gaps = gaps
            record.ended = max(last?.utc ?? record.started, gapDate ?? record.started); record.interrupted = true
            try save(record)
        }
    }
    private func updateReady() { ready = loaded && supported && sensorReady && error.isEmpty && !hasStorageFailed && !stale }
    func setCapability() {
        supported = true; updateReady(); send("#GQ")
        if (recording || previewing) && stream == nil { beginSegment() }
    }
    func setPreview(_ active: Bool) {
        previewing = active
        if active { foreground() }
        if active, supported, stream == nil { beginSegment() }
        if !active, !recording, let token = stream?.token { send(String(format: "#GS,%08X,0", token)); stream = nil }
    }
    /// Foreground recovery cannot depend on a frame arriving after the board's 15 second lease expired.
    func foreground(uptime: Double = ProcessInfo.processInfo.systemUptime) {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkSilence() }
        checkSilence(uptime: uptime)
    }
    func background() { watchdog?.invalidate(); watchdog = nil; setPreview(false); flush() }
    func checkSilence(uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard recording || previewing, supported, !hasStorageFailed else { return }
        if stream == nil || uptime - lastFrameAt > 3 {
            stale = true; sensorReady = false; updateReady(); status = "样本中断，等待圆屏恢复"
            if !gap { markGap("stream silence") }
            liveSamples = []; beginSegment(uptime: uptime)
        }
    }
    func sensorState(_ state: Int) { sensorReady = state == 2; updateReady() }
    func linkLost() {
        supported = false; sensorReady = false; stale = true; updateReady(); stream = nil
        if recording { markGap("disconnect"); status = "连接中断，重连后继续同一记录" }
    }
    private func beginSegment(uptime: Double = ProcessInfo.processInfo.systemUptime) {
        if !recording { liveSamples = []; activePeaks = GPeaks() }
        let token = UInt32.random(in: 1...UInt32.max)
        stream = GStreamClock(token: token); segmentDate = nil
        lastRenew = uptime; lastFrameAt = uptime
        send(String(format: "#GS,%08X,20", token))
    }
    func receiveAck(_ text: String) {
        let parts = text.split(separator: ",")
        guard parts.count == 3, parts[0] == "GS", let token = UInt32(parts[1], radix: 16), token == stream?.token else { return }
        if parts[2] == "0", recording || previewing { beginSegment(); markGap("lease expired") }
    }
    func startManual() {
        guard ready, !recording, error.isEmpty else { return }
        manual = true; arm()
    }
    private func arm() {
        recording = true; owner = manual ? "手动记录" : "导航自动记录"; error = ""; liveSamples = []; activePeaks = GPeaks()
        status = "等待首个有效 G 样本"; gap = false
        if supported { beginSegment() }
    }
    func rideStarted(_ id: UUID) {
        ride = id
        if recording { associate(id); return }
        guard suppressedRide != id, error.isEmpty else { return }
        manual = false; arm()
    }
    func rideFinished(_ id: UUID) {
        guard ride == id else { return }
        ride = nil
        if !manual { finish() }
    }
    private func associate(_ id: UUID) {
        guard var record = activeRecord, !record.rideIDs.contains(id) else { return }
        record.rideIDs.append(id); activeRecord = record
        worker.async { do { try self.save(record) } catch { self.failed(error) } }
    }
    func stop(now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard canStopManual else { return }
        suppressedRide = ride; finish(now: now, uptime: uptime)
    }
    private func finish(now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        if let token = stream?.token { send(String(format: "#GS,%08X,0", token)) }
        stream = nil; recording = false; manual = false; owner = ""; status = "记录已停止"
        if previewing && supported { beginSegment() }
        guard var record = activeRecord else { return }
        let ended = now
        record.duration = max(record.duration, ended.timeIntervalSince(record.started), recordBeganAt.map { uptime - $0 } ?? 0)
        record.ended = max(ended, record.started.addingTimeInterval(record.duration))
        record.gaps += 1
        append(Row(gap: "record ended", utc: record.ended, elapsed: record.duration), record: record)
        flushBatch(); activeRecord = nil; recordBeganAt = nil
        worker.async {
            guard !self.hasStorageFailed else { return }
            do {
                try self.writer?.synchronize(); try self.writer?.close(); self.writer = nil; self.writeID = nil
                try self.save(record)
                DispatchQueue.main.async { self.records.insert(record, at: 0) }
            } catch { self.failed(error) }
        }
    }
    private func markGap(_ reason: String) {
        gap = true
        guard var record = activeRecord else { return }
        record.gaps += 1; activeRecord = record
        append(Row(gap: reason, utc: Date(), elapsed: max(record.duration, recordBeganAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)), record: record)
    }
    func receive(_ bytes: Data, now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard recording || previewing, let frame = GFrame(bytes), frame.token == stream?.token else { return }
        guard let tick = stream?.accept(frame) else { return }
        lastFrameAt = uptime; stale = false
        sensorReady = frame.valid; updateReady()
        if uptime - lastRenew >= 5 { lastRenew = uptime; send(String(format: "#GS,%08X,20", frame.token)) }
        if !frame.valid { if !gap { markGap("invalid flags \(frame.flags)") }; status = "等待有效样本（校准／姿态／传感器状态）"; return }
        if segmentDate == nil { segmentDate = now; segmentTick = tick.seconds; segmentOffset = max(0, now.timeIntervalSince(activeRecord?.started ?? now), (activeRecord?.duration ?? -0.05) + 0.05) }
        let elapsedTick = tick.seconds - segmentTick
        let utc = segmentDate!.addingTimeInterval(elapsedTick)
        sampleID &+= 1
        let sample = GSample(id: sampleID, elapsed: segmentOffset + elapsedTick, utc: utc, lateral: Double(frame.lateralMG)/1000, longitudinal: Double(frame.longitudinalMG)/1000, gap: gap || tick.gap)
        if !recording {
            gap = false; activePeaks.include(sample)
            liveSamples.append(sample)
            if liveSamples.count > 1200 { liveSamples.removeFirst(liveSamples.count - 1200) }
            status = "圆屏实时 G 值估计"; return
        }
        if activeRecord == nil { activeRecord = GRecord(started: utc, rideIDs: ride.map { [$0] } ?? []); recordBeganAt = ProcessInfo.processInfo.systemUptime }
        var record = activeRecord!; record.sampleCount += 1; record.duration = sample.elapsed; record.peaks.include(sample)
        if tick.gap && !gap { record.gaps += 1; append(Row(gap: "packet gap", utc: utc, elapsed: sample.elapsed), record: record) }
        gap = false; activeRecord = record; activePeaks = record.peaks
        liveSamples.append(sample)
        if liveSamples.count > 1200 { liveSamples.removeFirst(liveSamples.count - 1200) }
        if let cutoff = liveSamples.firstIndex(where: { sample.elapsed - $0.elapsed <= 60 }), cutoff > 0 { liveSamples.removeFirst(cutoff) }
        append(Row(sample: sample), record: record); status = "正在记录 · \(record.sampleCount) 个样本"
    }
    private func append(_ row: Row, record: GRecord) {
        storageLock.lock()
        let overflow = pendingRows >= 2000
        if !overflow && !storageFailed { pendingRows += 1 }
        let failed = storageFailed
        storageLock.unlock()
        guard !failed else { return }
        if overflow {
            storageLock.lock(); storageFailed = true; storageLock.unlock()
            showFailure(NSError(domain: "GRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "磁盘写入积压达到 2000 条，已停止以保护记录"]))
            worker.async { try? self.writer?.close(); self.writer = nil }
            return
        }
        if bufferedRecord?.id != record.id { flushBatch() }
        bufferedRecord = record; buffered.append(row)
        if buffered.count >= 20 { flushBatch() }
        else if batchWork == nil {
            let task = DispatchWorkItem { [weak self] in self?.flushBatch() }
            batchWork = task; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
        }
    }
    private func flushBatch() {
        batchWork?.cancel(); batchWork = nil
        guard !buffered.isEmpty, let record = bufferedRecord else { return }
        let rows = buffered; buffered = []; bufferedRecord = nil
        worker.async {
            defer { self.storageLock.lock(); self.pendingRows -= rows.count; self.storageLock.unlock() }
            guard !self.hasStorageFailed else { return }
            do {
                if self.writeID != record.id {
                    try self.writer?.close()
                    try Data().write(to: self.journal(record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    self.writer = try FileHandle(forWritingTo: self.journal(record.id)); self.writeID = record.id; self.indexCount = 0
                }
                var bytes = Data()
                let offset = try self.writer!.offset()
                for row in rows {
                    if let sample = row.sample {
                        if self.indexCount % 200 == 0 { self.indexes[record.id, default: []].append((sample.elapsed, offset + UInt64(bytes.count))) }
                        self.indexCount += 1
                    }
                    bytes.append(try JSONEncoder().encode(row)); bytes.append(10)
                }
                try self.writer!.write(contentsOf: bytes); try self.writer?.synchronize(); try self.save(record)
            } catch { self.failed(error) }
        }
    }
    private func showFailure(_ failure: Error) {
        batchWork?.cancel(); batchWork = nil
        storageLock.lock(); pendingRows -= buffered.count; storageLock.unlock()
        buffered = []; bufferedRecord = nil
        error = "G 记录保存／恢复失败：\(failure.localizedDescription)"; status = error
        if let token = stream?.token { send(String(format: "#GS,%08X,0", token)) }
        stream = nil; recording = false; activeRecord = nil; manual = false; owner = ""; ready = false
    }
    private func failed(_ failure: Error) {
        storageLock.lock(); storageFailed = true; storageLock.unlock()
        try? writer?.close(); writer = nil
        DispatchQueue.main.async { self.showFailure(failure) }
    }
    func flush() {
        flushBatch()
        worker.async { do { try self.writer?.synchronize() } catch { self.failed(error) } }
    }
    func delete(_ record: GRecord) {
        worker.async {
            do {
                try FileManager.default.removeItem(at: self.metadata(record.id)); try FileManager.default.removeItem(at: self.journal(record.id)); self.indexes.removeValue(forKey: record.id)
                DispatchQueue.main.async { self.records.removeAll { $0.id == record.id } }
            } catch { self.failed(error) }
        }
    }
    func unlinkRide(_ id: UUID) {
        if var record = activeRecord, record.rideIDs.contains(id) {
            record.rideIDs.removeAll { $0 == id }; activeRecord = record
            let value = record
            worker.async { do { try self.save(value) } catch { self.failed(error) } }
        }
        for var record in records where record.rideIDs.contains(id) {
            record.rideIDs.removeAll { $0 == id }
            let value = record
            worker.async { do { try self.save(value); DispatchQueue.main.async { if let i = self.records.firstIndex(where: { $0.id == value.id }) { self.records[i] = value } } } catch { self.failed(error) } }
        }
    }
    /// Read only the requested indexed interval; retain both channels' extrema in each time bucket.
    func loadSamples(for record: GRecord, from: Double = 0, to: Double = .infinity, limit: Int = 2400, completion: @escaping ([GSample]) -> Void) {
        worker.async {
            do {
                if self.indexes[record.id] == nil {
                    var index: [(Double, UInt64)] = [], count = 0
                    _ = try self.scan(record.id) { row, offset in
                        if let sample = row.sample { if count % 200 == 0 { index.append((sample.elapsed, offset)) }; count += 1 }
                        return true
                    }
                    self.indexes[record.id] = index
                }
                let start = self.indexes[record.id]?.last(where: { $0.time <= from })?.offset ?? 0
                let upper = min(to, record.duration), width = max(0.001, (upper - from) / Double(max(1, limit / 6)))
                var output: [GSample] = [], bucket: [GSample] = [], bucketID = -1, bucketGap = false
                func emit() {
                    guard !bucket.isEmpty else { return }
                    let candidates = [bucket.first!, bucket.last!, bucket.min(by: { $0.lateral < $1.lateral })!, bucket.max(by: { $0.lateral < $1.lateral })!, bucket.min(by: { $0.longitudinal < $1.longitudinal })!, bucket.max(by: { $0.longitudinal < $1.longitudinal })!]
                    var ids = Set<UInt64>()
                    output += candidates.sorted { $0.elapsed < $1.elapsed }.filter { ids.insert($0.id).inserted }.map { value in var sample = value; sample.gap = sample.gap || bucketGap; return sample }
                    bucket.removeAll(keepingCapacity: true); bucketGap = false
                }
                _ = try self.scan(record.id, from: start) { row, _ in
                    guard let sample = row.sample else { return true }
                    if sample.elapsed > upper { return false }
                    guard sample.elapsed >= from else { return true }
                    let next = Int((sample.elapsed - from) / width)
                    if next != bucketID { emit(); bucketID = next }
                    bucketGap = bucketGap || sample.gap
                    bucket.append(sample)
                    if bucket.count > 6 {
                        let candidates = [bucket.first!, bucket.last!, bucket.min(by: { $0.lateral < $1.lateral })!, bucket.max(by: { $0.lateral < $1.lateral })!, bucket.min(by: { $0.longitudinal < $1.longitudinal })!, bucket.max(by: { $0.longitudinal < $1.longitudinal })!]
                        var ids = Set<UInt64>(); bucket = candidates.sorted { $0.elapsed < $1.elapsed }.filter { ids.insert($0.id).inserted }
                    }
                    return true
                }
                emit(); DispatchQueue.main.async { completion(output) }
            } catch { self.failed(error); DispatchQueue.main.async { completion([]) } }
        }
    }
}
