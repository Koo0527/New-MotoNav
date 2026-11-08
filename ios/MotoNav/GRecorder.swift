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
struct GFlowStats: Equatable {
    var rx = 0, invalid = 0, idle = 0, tokenRejected = 0, sequenceRejected = 0, invalidFlags = 0
    var accepted = 0, recordAccepted = 0, gaps = 0
    var queuedRows = 0, queuedSamples = 0, writtenRows = 0, writtenSamples = 0
    var failedRows = 0, failedSamples = 0
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

struct GReplayWindow {
    var samples: [GSample] = []
    var missing: [GTimeRange] = []
    var peaks = GPeaks()
    var mergedGaps = false
}

/// Streaming replay accumulator: one pass keeps detailed buckets and a fixed
/// conservative summary in parallel, so memory stays O(limit) even for long records.
struct GReplayBuilder {
    private let lower: Double
    private let upper: Double
    private let budget: Int
    private let tailMissing: Bool
    private let detailBucketCount: Int
    private let detailWidth: Double
    private let summaryWidth: Double
    private let summaryCount: Int
    private var lastValid: Double?
    private var pendingStart: Double?
    private var pendingStartIsSample = false
    private var finished = false
    private var peaks = GPeaks()
    private var missing: [GTimeRange] = []
    private var missingOverflow = false
    private var detail: [GSample] = []
    private var detailBucket: [GSample] = []
    private var detailBucketID = Int.min
    private var summary: [[GSample]]
    private var summaryGapDelta: [Int]

    init(from: Double, to: Double, limit: Int, started: Date, tailMissing: Bool = false) {
        lower = max(0, from)
        upper = to
        budget = max(8, limit)
        self.tailMissing = tailMissing
        detailBucketCount = max(1, budget / 6)
        summaryCount = max(1, budget / 8)
        let span = max(0.001, upper - lower)
        detailWidth = max(0.001, span / Double(detailBucketCount))
        summaryWidth = span / Double(summaryCount)
        summary = Array(repeating: [], count: summaryCount)
        summaryGapDelta = Array(repeating: 0, count: summaryCount + 1)
    }

    var empty: Bool { !(upper > lower) }

    mutating func sample(_ sample: GSample) -> Bool {
        guard !finished, !empty, sample.valid, sample.elapsed.isFinite,
              sample.lateral.isFinite, sample.longitudinal.isFinite else { return !finished }
        if sample.elapsed > upper {
            if let start = pendingStart { addMissing(start: start, end: upper, startIsSample: pendingStartIsSample, endIsSample: false) }
            pendingStart = nil; pendingStartIsSample = false
            finished = true
            return false
        }
        if sample.elapsed < lower {
            lastValid = sample.elapsed
            pendingStart = nil; pendingStartIsSample = false
            return true
        }
        var entry = sample
        let hadPending = pendingStart != nil
        if let start = pendingStart {
            addMissing(start: start, end: sample.elapsed, startIsSample: pendingStartIsSample, endIsSample: true)
            pendingStart = nil; pendingStartIsSample = false
        }
        if sample.gap && !hadPending {
            let start = lastValid ?? lower
            addMissing(start: start, end: sample.elapsed, startIsSample: lastValid != nil && start >= lower, endIsSample: true)
        }
        if hadPending || sample.gap { entry.gap = true }
        lastValid = sample.elapsed
        peaks.include(entry)
        appendDetailed(entry)
        appendSummary(entry)
        return true
    }

    mutating func gap(at time: Double, date: Date? = nil) -> Bool {
        guard !finished, !empty else { return false }
        if pendingStart == nil {
            let start = lastValid ?? lower
            pendingStart = max(lower, start)
            pendingStartIsSample = lastValid != nil && start >= lower
        }
        return true
    }

    mutating func finish() -> GReplayWindow {
        if !finished {
            // Tail missing comes from a recorded gap row. A normal sampling
            // window must not invent a gap merely because no sample lands exactly on upper.
            if pendingStart != nil {
                addMissing(start: pendingStart!, end: upper, startIsSample: pendingStartIsSample, endIsSample: false)
            } else if tailMissing, lastValid == nil || lastValid! < upper {
                // A completed record with no sample at the requested tail: do not
                // let the cursor fall back to the last sample before the window end.
                if let last = lastValid, last >= lower {
                    addMissing(start: last, end: upper, startIsSample: true, endIsSample: false)
                } else {
                    addMissing(start: lower, end: upper, startIsSample: false, endIsSample: false)
                }
            }
            pendingStart = nil; pendingStartIsSample = false
            finished = true
        }
        if !missingOverflow { flushDetailed() }
        if missingOverflow || detail.count + 2 * missing.count > budget {
            return conservative()
        }
        return GReplayWindow(samples: detail, missing: missing, peaks: peaks, mergedGaps: false)
    }

    private mutating func addMissing(start: Double, end: Double, startIsSample: Bool, endIsSample: Bool) {
        let clippedStart = max(lower, start), clippedEnd = min(upper, end)
        guard clippedEnd > clippedStart else { return }
        markSummary(clippedStart, clippedEnd)
        guard !missingOverflow else { return }
        let startFlag = startIsSample && clippedStart == start
        let endFlag = endIsSample && clippedEnd == end
        if let last = missing.last, clippedStart < last.end ||
            (clippedStart == last.end && !(last.endIsSample && startFlag)) {
            let mergedEnd = max(last.end, clippedEnd)
            let mergedEndFlag = mergedEnd == last.end ? last.endIsSample : endFlag
            missing[missing.count - 1] = GTimeRange(start: last.start, end: mergedEnd, startIsSample: last.startIsSample, endIsSample: mergedEndFlag)
        } else {
            missing.append(GTimeRange(start: clippedStart, end: clippedEnd, startIsSample: startFlag, endIsSample: endFlag))
        }
        if !missingOverflow && detail.count + detailBucket.count + 2 * missing.count > budget {
            missingOverflow = true
            detail.removeAll(keepingCapacity: true)
            detailBucket.removeAll(keepingCapacity: true)
            missing.removeAll(keepingCapacity: true)
        }
    }

    private mutating func markSummary(_ start: Double, _ end: Double) {
        let width = summaryWidth
        let first = max(0, min(summaryCount - 1, Int((start - lower) / width)))
        let last = max(0, min(summaryCount - 1, Int((end - lower - 0.000000001) / width)))
        guard last >= first else { return }
        summaryGapDelta[first] += 1
        summaryGapDelta[last + 1] -= 1
    }

    private mutating func appendDetailed(_ sample: GSample) {
        guard !missingOverflow else { return }
        if sample.gap {
            flushDetailedBucket()
            detailBucketID = Int.min
        }
        let next = max(0, min(detailBucketCount - 1, Int((sample.elapsed - lower) / detailWidth)))
        if next != detailBucketID {
            flushDetailedBucket()
            detailBucketID = next
        }
        detailBucket.append(sample)
        if detailBucket.count > 6 { detailBucket = candidates(detailBucket) }
        if !missingOverflow && detail.count + detailBucket.count + 2 * missing.count > budget {
            missingOverflow = true
            detail.removeAll(keepingCapacity: true)
            detailBucket.removeAll(keepingCapacity: true)
            missing.removeAll(keepingCapacity: true)
        }
    }

    private mutating func flushDetailedBucket() {
        guard !detailBucket.isEmpty else { return }
        let picked = candidates(detailBucket)
        if detail.count + picked.count + 2 * missing.count > budget {
            missingOverflow = true
            detail.removeAll(keepingCapacity: true)
            detailBucket.removeAll(keepingCapacity: true)
            missing.removeAll(keepingCapacity: true)
            return
        }
        detail += picked
        detailBucket.removeAll(keepingCapacity: true)
        if detail.count + 2 * missing.count > budget {
            missingOverflow = true
            detail.removeAll(keepingCapacity: true)
            missing.removeAll(keepingCapacity: true)
        }
    }

    private mutating func flushDetailed() {
        guard !missingOverflow else { return }
        flushDetailedBucket()
    }

    private mutating func appendSummary(_ sample: GSample) {
        let index = max(0, min(summaryCount - 1, Int((sample.elapsed - lower) / summaryWidth)))
        summary[index].append(sample)
        if summary[index].count > 6 { summary[index] = candidates(summary[index]) }
    }

    private struct ValueKey: Hashable { let lateral: Double; let longitudinal: Double }
    private func candidates(_ values: [GSample]) -> [GSample] {
        guard let first = values.first, let last = values.last else { return [] }
        let pool = [first, last, values.min(by: { $0.lateral < $1.lateral })!, values.max(by: { $0.lateral < $1.lateral })!, values.min(by: { $0.longitudinal < $1.longitudinal })!, values.max(by: { $0.longitudinal < $1.longitudinal })!]
        var ids = Set<UInt64>(), keys = Set<ValueKey>()
        return pool.sorted { $0.elapsed < $1.elapsed }.filter { sample in
            guard ids.insert(sample.id).inserted else { return false }
            if sample.id == first.id || sample.id == last.id { return true }
            return keys.insert(ValueKey(lateral: sample.lateral, longitudinal: sample.longitudinal)).inserted
        }
    }

    private mutating func conservative() -> GReplayWindow {
        var gaps = Array(repeating: false, count: summaryCount), running = 0
        for i in 0..<summaryCount { running += summaryGapDelta[i]; gaps[i] = running > 0 }
        var output: [GSample] = [], ranges: [GTimeRange] = []
        var runStart: Int?
        var afterGap = false
        func closeRun(_ end: Int) {
            guard let start = runStart else { return }
            let startTime = lower + Double(start) * summaryWidth
            let endTime = min(upper, lower + Double(end) * summaryWidth)
            if endTime > startTime { ranges.append(GTimeRange(start: startTime, end: endTime, startIsSample: false, endIsSample: false)) }
            runStart = nil
        }
        for i in 0..<summaryCount {
            if gaps[i] {
                if runStart == nil { runStart = i }
                afterGap = true
                continue
            }
            closeRun(i)
            var values = summary[i]
            if afterGap, !values.isEmpty {
                values[0].gap = true
                afterGap = false
            }
            output.append(contentsOf: values)
        }
        closeRun(summaryCount)
        output.sort { $0.elapsed < $1.elapsed }
        return GReplayWindow(samples: output, missing: ranges, peaks: peaks, mergedGaps: true)
    }
}

final class GRecorder: ObservableObject {
    static let shared = GRecorder(livePublishInterval: 0.2)
    @Published private(set) var records: [GRecord] = []
    @Published private(set) var liveSamples: [GSample] = []
    @Published private(set) var liveAvailable = false
    @Published private(set) var recording = false
    @Published private(set) var ready = false
    @Published private(set) var status = "连接支持 G 记录的圆屏后使用"
    @Published private(set) var error = ""
    @Published private(set) var activeRecord: GRecord?
    @Published private(set) var owner = ""
    @Published private(set) var activePeaks = GPeaks()
    @Published private(set) var phoneEntryAvailable = false
    @Published private var phoneRetryDeadline: Double?
    var canStopManual: Bool { recording }
    var canRequestPhonePage: Bool { previewing && supported && phoneEntryAvailable && phoneRetryDeadline == nil }
    private let root: URL
    private let worker: DispatchQueue
    private let flowLogURL: URL?
    private var flowLogFailed = false // Accessed only on worker.
    private let send: (String) -> Void
    private var writer: FileHandle?
    private var writeID: UUID?
    private let storageLock = NSLock()
    private var storageFailed = false
    private var pendingRows = 0
    private let flowLock = NSLock()
    private var storedFlow = GFlowStats()
    var flow: GFlowStats {
        flowLock.lock(); defer { flowLock.unlock() }
        return storedFlow
    }
    private func flowBump(_ key: WritableKeyPath<GFlowStats, Int>, _ count: Int = 1) {
        guard count != 0 else { return }
        flowLock.lock(); storedFlow[keyPath: key] += count; flowLock.unlock()
    }
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
    private var phoneEntryActive = false, pageEntryPending = false
    private let sendPhoneEntry: (UInt32, Bool) -> Bool
    private let discardPhoneEntry: () -> Void
    private var ride: UUID?, suppressedRide: UUID?
    private var stream: GStreamClock?
    private var lastRenew = 0.0
    private var segmentDate: Date?
    private var segmentOffset = 0.0
    private var segmentTick = 0.0
    private var gap = false
    private var sampleID: UInt64 = 0
    private var loaded = false
    private let livePublishInterval: TimeInterval
    private var livePublishAt = -Double.infinity
    private var liveBuffer: [GSample] = []
    private var previewPeaks = GPeaks()
    private var recordingRecord: GRecord?
    private struct Row: Codable { var sample: GSample?; var gap: String?; var utc: Date?; var elapsed: Double? }
    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("GRecords", isDirectory: true), send: @escaping (String) -> Void = { BleLink.shared.sendOnce($0) }, phoneSend: @escaping (UInt32, Bool) -> Bool = { BleLink.shared.sendGPhoneEntry($0, $1) }, phoneDiscard: @escaping () -> Void = { BleLink.shared.discardGPhoneEntry() }, livePublishInterval: TimeInterval = 0, worker: DispatchQueue = DispatchQueue(label: "motonav.g-records", qos: .utility)) {
        root = directory; self.send = send; self.sendPhoneEntry = phoneSend; self.livePublishInterval = livePublishInterval; self.worker = worker
        discardPhoneEntry = phoneDiscard
        flowLogURL = ProcessInfo.processInfo.environment["MOTONAV_GFLOW_FILE"] == "1" ? directory.appendingPathComponent("GFLOW.log") : nil
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
    private func updateReady() {
        let value = loaded && supported && sensorReady && error.isEmpty && !hasStorageFailed && !stale
        if ready != value { ready = value }
    }
    private func shouldPublishLive(_ uptime: Double) -> Bool {
        livePublishInterval <= 0 || uptime - livePublishAt >= livePublishInterval
    }
    private func trimLiveBuffer() {
        if liveBuffer.count > 1200 { liveBuffer.removeFirst(liveBuffer.count - 1200) }
        if let last = liveBuffer.last, let cutoff = liveBuffer.firstIndex(where: { last.elapsed - $0.elapsed <= 60 }), cutoff > 0 {
            liveBuffer.removeFirst(cutoff)
        }
    }
    func setCapability() {
        supported = true; updateReady(); send("#GQ")
        if (recording || previewing) && stream == nil { beginSegment() }
        flushPhoneEntry()
    }
    /// CAP,GENT,1: the firmware understands a separate phone page-entry event.
    func setPhoneEntryCapability() {
        if !phoneEntryAvailable { phoneEntryAvailable = true }
        flushPhoneEntry()
    }
    /// A new BLE connection must renegotiate GENT and discard any entry intent.
    func resetPhoneEntry() {
        if phoneEntryAvailable { phoneEntryAvailable = false }
        if phoneRetryDeadline != nil { phoneRetryDeadline = nil }
        phoneEntryActive = false; pageEntryPending = false
    }
    /// Send 1 only on a real page entry. If this connection's capability or stream
    /// token has not arrived yet, keep a single pending intent for that same page
    /// opening; resetPhoneEntry clears it on reconnect so it is never replayed.
    func enterPhonePage() {
        guard previewing, phoneRetryDeadline == nil else { return }
        pageEntryPending = true
        flushPhoneEntry()
    }
    private func flushPhoneEntry() {
        guard pageEntryPending, phoneEntryAvailable, !phoneEntryActive, let token = stream?.token else { return }
        let sent = sendPhoneEntry(token, true)
        phoneEntryActive = sent
        pageEntryPending = !sent
    }
    func requestPhonePage(uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard canRequestPhonePage else { return }
        // A new stream makes this a distinct entry even when BLE coalesces queued commands.
        pageEntryPending = false
        if !gap { markGap("calibration retry") }
        beginSegment(uptime: uptime, phoneRetry: true)
        let deadline = uptime + 3
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.phoneRetryDeadline == deadline { self?.phoneRetryDeadline = nil }
        }
    }
    /// Send 0 while the stream is still alive; the firmware may reject a late event.
    func leavePhonePage() {
        pageEntryPending = false
        if phoneRetryDeadline != nil { phoneRetryDeadline = nil }
        guard phoneEntryActive else { return }
        phoneEntryActive = false
        if let token = stream?.token { _ = sendPhoneEntry(token, false) }
    }
    func setPreview(_ active: Bool) {
        if !active { leavePhonePage() }
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
        logFlow()
        if let deadline = phoneRetryDeadline, uptime >= deadline { phoneRetryDeadline = nil }
        guard recording || previewing, supported, !hasStorageFailed else { return }
        if stream == nil || uptime - lastFrameAt > 3 {
            stale = true; sensorReady = false; updateReady(); status = "样本中断，等待圆屏恢复"
            if !gap { markGap("stream silence") }
            liveSamples = []; liveBuffer = []; beginSegment(uptime: uptime)
        }
    }
    private func logFlow() {
        guard recording || previewing else { return }
        let f = flow
        let token = stream.map { String(format: "%08X", $0.token) } ?? "--------"
        let line = "GFLOW,token=\(token),rx=\(f.rx),invalid=\(f.invalid),idle=\(f.idle),tokenReject=\(f.tokenRejected),seqReject=\(f.sequenceRejected),flags=\(f.invalidFlags),accepted=\(f.accepted),record=\(f.recordAccepted),gaps=\(f.gaps),queued=\(f.queuedSamples),written=\(f.writtenSamples),failed=\(f.failedSamples)"
        print(line)
        // Explicit bench launch only. No diagnostic file I/O in ordinary launches.
        guard let url = flowLogURL else { return }
        worker.async {
            guard !self.flowLogFailed else { return }
            do {
                let data = Data((line + "\n").utf8)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try Data().write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
                }
                let handle = try FileHandle(forUpdating: url)
                defer { try? handle.close() }
                if try handle.seekToEnd() + UInt64(data.count) > 1_048_576 {
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                }
                try handle.write(contentsOf: data)
            } catch {
                self.flowLogFailed = true
                print("GFLOW diagnostic write failed: \(error.localizedDescription)")
            }
        }
    }
    func sensorState(_ state: Int) {
        sensorReady = state == 2
        if !sensorReady && liveAvailable {
            liveAvailable = false
            if !gap { markGap("sensor unavailable") }
        }
        updateReady()
    }
    func linkLost() {
        supported = false; sensorReady = false; stale = true; updateReady(); stream = nil
        if liveAvailable { liveAvailable = false }
        resetPhoneEntry()
        if recording { markGap("disconnect"); status = "连接中断，重连后继续同一记录" }
    }
    private func beginSegment(uptime: Double = ProcessInfo.processInfo.systemUptime, phoneRetry: Bool = false) {
        // A new token invalidates the phone entry; it is never resent by reconnect.
        discardPhoneEntry()
        phoneEntryActive = false
        if phoneRetry || phoneRetryDeadline != nil { phoneRetryDeadline = phoneRetry ? uptime + 3 : nil }
        if liveAvailable { liveAvailable = false }
        if !recording && !phoneRetry { liveSamples = []; liveBuffer = []; activePeaks = GPeaks(); previewPeaks = GPeaks(); livePublishAt = -Double.infinity }
        var token = UInt32.random(in: 1...UInt32.max)
        if token == stream?.token { token = token == UInt32.max ? 1 : token + 1 }
        stream = GStreamClock(token: token); segmentDate = nil
        lastRenew = uptime; lastFrameAt = uptime
        send(String(format: "#GS,%08X,20", token))
    }
    func receiveAck(_ text: String, uptime: Double = ProcessInfo.processInfo.systemUptime) {
        let parts = text.split(separator: ",")
        guard parts.count == 3, parts[0] == "GS", let token = UInt32(parts[1], radix: 16), token == stream?.token else { return }
        if parts[2] == "0", recording || previewing {
            beginSegment(uptime: uptime)
            if !gap { markGap("lease expired") }
        } else if parts[2] == "1", let deadline = phoneRetryDeadline {
            phoneRetryDeadline = nil
            if previewing && phoneEntryAvailable && uptime < deadline {
                phoneEntryActive = sendPhoneEntry(token, true)
            }
        }
    }
    func startManual() {
        guard ready, !recording, error.isEmpty else { return }
        manual = true; arm()
    }
    private func arm() {
        recording = true; owner = manual ? "手动记录" : "导航自动记录"; error = ""
        liveSamples = []; liveBuffer = []; previewPeaks = GPeaks(); activePeaks = GPeaks()
        activeRecord = nil; recordingRecord = nil; livePublishAt = -Double.infinity
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
        guard var record = recordingRecord, !record.rideIDs.contains(id) else { return }
        record.rideIDs.append(id); recordingRecord = record; activeRecord = record
        worker.async { do { try self.save(record) } catch { self.failed(error) } }
    }
    func stop(now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard canStopManual else { return }
        suppressedRide = ride; finish(now: now, uptime: uptime)
    }
    private func finish(now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        phoneEntryActive = false; pageEntryPending = false
        if let token = stream?.token { send(String(format: "#GS,%08X,0", token)) }
        stream = nil; recording = false; manual = false; owner = ""; status = "记录已停止"
        if previewing && supported { beginSegment() }
        guard var record = recordingRecord else { return }
        let ended = now
        record.duration = max(record.duration, ended.timeIntervalSince(record.started), recordBeganAt.map { uptime - $0 } ?? 0)
        record.ended = max(ended, record.started.addingTimeInterval(record.duration))
        record.gaps += 1
        append(Row(gap: "record ended", utc: record.ended, elapsed: record.duration), record: record)
        flushBatch(); activeRecord = nil; recordingRecord = nil; recordBeganAt = nil
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
        flowBump(\.gaps)
        guard var record = recordingRecord else { return }
        record.gaps += 1; recordingRecord = record; activeRecord = record
        append(Row(gap: reason, utc: Date(), elapsed: max(record.duration, recordBeganAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)), record: record)
    }
    func receive(_ bytes: Data, now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        flowBump(\.rx)
        guard recording || previewing else { flowBump(\.idle); return }
        guard let frame = GFrame(bytes) else { flowBump(\.invalid); return }
        guard frame.token == stream?.token else { flowBump(\.tokenRejected); return }
        guard let tick = stream?.accept(frame) else { flowBump(\.sequenceRejected); return }
        lastFrameAt = uptime; stale = false
        sensorReady = frame.valid
        if uptime - lastRenew >= 5 { lastRenew = uptime; send(String(format: "#GS,%08X,20", frame.token)) }
        if !frame.valid {
            flowBump(\.invalidFlags)
            if liveAvailable { liveAvailable = false }
            if !gap { markGap("invalid flags \(frame.flags)") }
            let waiting = "等待有效样本（校准／姿态／传感器状态）"
            if status != waiting { status = waiting }
            updateReady()
            return
        }
        if segmentDate == nil {
            segmentDate = now
            segmentTick = tick.seconds
            if !recording, let last = liveBuffer.last {
                segmentOffset = last.elapsed + max(0.05, now.timeIntervalSince(last.utc))
            } else {
                segmentOffset = max(0, now.timeIntervalSince(recordingRecord?.started ?? now), (recordingRecord?.duration ?? -0.05) + 0.05)
            }
        }
        let elapsedTick = tick.seconds - segmentTick
        let utc = segmentDate!.addingTimeInterval(elapsedTick)
        sampleID &+= 1
        let sample = GSample(id: sampleID, elapsed: segmentOffset + elapsedTick, utc: utc, lateral: Double(frame.lateralMG)/1000, longitudinal: Double(frame.longitudinalMG)/1000, gap: gap || tick.gap)
        flowBump(\.accepted)
        if !recording {
            gap = false
            previewPeaks.include(sample)
            liveBuffer.append(sample); trimLiveBuffer()
            if !liveAvailable || shouldPublishLive(uptime) {
                liveSamples = liveBuffer; activePeaks = previewPeaks
                status = "圆屏实时 G 值估计"; livePublishAt = uptime
                if !liveAvailable { liveAvailable = true }
            }
            updateReady()
            return
        }
        flowBump(\.recordAccepted)
        if recordingRecord == nil { recordingRecord = GRecord(started: utc, rideIDs: ride.map { [$0] } ?? []); recordBeganAt = ProcessInfo.processInfo.systemUptime }
        var record = recordingRecord!; record.sampleCount += 1; record.duration = sample.elapsed; record.peaks.include(sample)
        if tick.gap && !gap { record.gaps += 1; flowBump(\.gaps); append(Row(gap: "packet gap", utc: utc, elapsed: sample.elapsed), record: record) }
        gap = false; recordingRecord = record
        liveBuffer.append(sample); trimLiveBuffer()
        if !liveAvailable || shouldPublishLive(uptime) {
            liveSamples = liveBuffer; activeRecord = record; activePeaks = record.peaks
            status = "正在记录 · \(record.sampleCount) 个样本"; livePublishAt = uptime
            if !liveAvailable { liveAvailable = true }
        }
        updateReady()
        append(Row(sample: sample), record: record)
    }
    private func append(_ row: Row, record: GRecord) {
        flowBump(\.queuedRows)
        if row.sample != nil { flowBump(\.queuedSamples) }
        storageLock.lock()
        let overflow = pendingRows >= 2000
        if !overflow && !storageFailed { pendingRows += 1 }
        let failed = storageFailed
        storageLock.unlock()
        guard !failed else {
            flowBump(\.failedRows)
            if row.sample != nil { flowBump(\.failedSamples) }
            return
        }
        if overflow {
            flowBump(\.failedRows)
            if row.sample != nil { flowBump(\.failedSamples) }
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
        let sampleCount = rows.reduce(0) { $0 + ($1.sample == nil ? 0 : 1) }
        worker.async {
            defer { self.storageLock.lock(); self.pendingRows -= rows.count; self.storageLock.unlock() }
            guard !self.hasStorageFailed else {
                self.flowBump(\.failedRows, rows.count)
                self.flowBump(\.failedSamples, sampleCount)
                return
            }
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
                self.flowBump(\.writtenRows, rows.count)
                self.flowBump(\.writtenSamples, sampleCount)
            } catch {
                self.flowBump(\.failedRows, rows.count)
                self.flowBump(\.failedSamples, sampleCount)
                self.failed(error)
            }
        }
    }
    private func showFailure(_ failure: Error) {
        phoneEntryActive = false
        batchWork?.cancel(); batchWork = nil
        let discarded = buffered
        flowBump(\.failedRows, discarded.count)
        flowBump(\.failedSamples, discarded.reduce(0) { $0 + ($1.sample == nil ? 0 : 1) })
        storageLock.lock(); pendingRows -= buffered.count; storageLock.unlock()
        buffered = []; bufferedRecord = nil
        error = "G 记录保存／恢复失败：\(failure.localizedDescription)"; status = error
        if let token = stream?.token { send(String(format: "#GS,%08X,0", token)) }
        stream = nil; recording = false; activeRecord = nil; recordingRecord = nil; liveBuffer = []; manual = false; owner = ""; ready = false
        phoneEntryActive = false; pageEntryPending = false
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
        if var record = recordingRecord, record.rideIDs.contains(id) {
            record.rideIDs.removeAll { $0 == id }; recordingRecord = record; activeRecord = record
            let value = record
            worker.async { do { try self.save(value) } catch { self.failed(error) } }
        }
        for var record in records where record.rideIDs.contains(id) {
            record.rideIDs.removeAll { $0 == id }
            let value = record
            worker.async { do { try self.save(value); DispatchQueue.main.async { if let i = self.records.firstIndex(where: { $0.id == value.id }) { self.records[i] = value } } } catch { self.failed(error) } }
        }
    }
    /// One streaming pass returns plotting samples, clipped missing intervals,
    /// raw window peaks and whether dense gaps were merged for the budget.
    func loadReplayWindow(for record: GRecord, from: Double = 0, to: Double = .infinity, limit: Int = 2400, completion: @escaping (GReplayWindow) -> Void) {
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
                let lower = max(0, from), upper = min(to, record.duration)
                guard upper > lower else { DispatchQueue.main.async { completion(GReplayWindow()) }; return }
                var builder = GReplayBuilder(from: lower, to: upper, limit: limit, started: record.started, tailMissing: record.ended != nil)
                let start = self.indexes[record.id]?.last(where: { $0.time <= lower })?.offset ?? 0
                _ = try self.scan(record.id, from: start) { row, _ in
                    if let sample = row.sample { return builder.sample(sample) }
                    if row.gap != nil { _ = builder.gap(at: row.elapsed ?? 0, date: row.utc) }
                    return true
                }
                let window = builder.finish()
                DispatchQueue.main.async { completion(window) }
            } catch { self.failed(error); DispatchQueue.main.async { completion(GReplayWindow()) } }
        }
    }
    /// Sample-only compatibility wrapper.
    func loadSamples(for record: GRecord, from: Double = 0, to: Double = .infinity, limit: Int = 2400, completion: @escaping ([GSample]) -> Void) {
        loadReplayWindow(for: record, from: from, to: to, limit: limit) { completion($0.samples) }
    }
}
