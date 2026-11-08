import Foundation
let args = CommandLine.arguments
let pixels = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))
let width = Int(args[2])!, height = Int(args[3])!, baseBytes = Int(args[5])!
let started = ProcessInfo.processInfo.systemUptime
let result = MapEdgeGeometry.buildReport(pixels: pixels, width: width, height: height, basePacketBytes: baseBytes)
let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
struct Report: Encodable { let hostGeometryMs: Double; let statistics: MapEdgeGeometry.Statistics }
print(String(data: try JSONEncoder().encode(Report(hostGeometryMs: milliseconds, statistics: result.statistics)), encoding: .utf8)!)
if let data = result.data { try data.write(to: URL(fileURLWithPath: args[4])) } else { exit(2) }
