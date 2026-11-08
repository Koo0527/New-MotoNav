import Foundation

let start = Date()
let tables = DenseMapGeometry.Tables()
let tableMS = Date().timeIntervalSince(start) * 1000
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--selfcheck" {
    // Exhaust every binary halo, including rejected patterns absent from the candidate set.
    for key in 0..<65536 {
        let expected = DenseMapGeometry.fit((0..<16).map { (key >> $0) & 1 }, band: false).map { $0 + 1024 } ?? 0
        precondition(tables.binary[key] == expected, "binary LUT mismatch \(key)")
    }
    print("{\"exhaustiveBinaryHalos\":65536,\"binaryCandidates\":\(tables.binaryCandidates),\"binaryAccepted\":\(tables.binaryAccepted),\"bandCandidates\":\(tables.bandCandidates),\"bandAccepted\":\(tables.band.count),\"lookupElementCapacityBytes\":\(tables.allocatedElementCapacityBytes),\"lookupLogicalPayloadBytes\":\(tables.logicalPayloadBytes),\"tableBuildMS\":\(tableMS)}")
} else {
    precondition(CommandLine.arguments.count >= 5)
    let p = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    let w = Int(CommandLine.arguments[3])!, h = Int(CommandLine.arguments[4])!
    let direct = CommandLine.arguments.contains("--direct")
    var words: [UInt16] = [], times: [Double] = []
    for _ in 0..<3 {
        let begin = Date()
        words = DenseMapGeometry.encode(p, width: w, height: h, tables: tables, direct: direct)
        times.append(Date().timeIntervalSince(begin) * 1000)
    }
    var data = Data(capacity: words.count * 2)
    for word in words { data.append(UInt8(word & 255)); data.append(UInt8(word >> 8)) }
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("{\"encodeMS\":\(times),\"medianEncodeMS\":\(times.sorted()[1]),\"tableBuildMS\":\(tableMS),\"lookupElementCapacityBytes\":\(tables.allocatedElementCapacityBytes),\"lookupLogicalPayloadBytes\":\(tables.logicalPayloadBytes),\"bandAccepted\":\(tables.band.count)}")
}
