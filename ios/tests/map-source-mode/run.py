"""Production feeder regression for cruise/navigation source selection and deferred fine ACK."""
from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[3]
tests = Path(__file__).resolve().parent
feeder_path = Path(os.environ.get('MOTONAV_FEEDER_OVERRIDE', root / 'ios/MotoNav/MapFeeder.swift'))
core = '\n'.join((root / 'ios' / 'MotoNav' / name).read_text() for name in (
    'MapGeo.swift', 'RasterProcessing.swift', 'RoadPalette.swift', 'SatelliteRaster.swift',
    'RouteMapPlan.swift', 'FineRoads.swift', 'MapSourceMode.swift', 'VectorTiles.swift', 'VectorMapRaster.swift', 'CruiseMapCache.swift',
    'BleBulkWriteQueue.swift'))
core = core.replace('static let shared = RouteMapCache()', 'static let shared = RouteMapCache(root: TestEnvironment.root)')
core = core.replace('static let shared = CruiseMapCache()', 'static let shared = CruiseMapCache(root: TestEnvironment.root)')
core = core.replace('var urls:[(URL,Bool)] = []', 'CacheReadProbe.record(frame.id)\n        var urls:[(URL,Bool)] = []')
queue = (root / 'ios/MotoNav/RouteOfflineMaps.swift').read_text().replace('import UIKit', '')
feeder = feeder_path.read_text().split('enum MapPipelineTrace {')[0].replace('import UIKit', '')
# Expose state for scenario assertions only; bodies unchanged.
feeder = feeder.replace('private(set) ', '').replace('private ', '')
stubs = (root / 'ios/tests/screenoff-maps/Stubs.swift').read_text()
stubs = stubs.replace('let bytes=testPacket(f,cx,cy)', 'let bytes=preparedBase ?? testPacket(f,cx,cy)')
link = (root / 'ios/MotoNav/BleLink.swift').read_text()
ack = link[link.index('        if parts.first == "K"'):link.index('        if parts.first == "N"')]
ack = ack.replace('MapFeeder.shared', 'target')
receipt_link = '''
struct TestReceiptLink {
    var mapReceipt = BleMapReceipt()
    var mapMeter = BleMapWireMeter()
    var bulkQ = BleBulkWriteQueue()
    mutating func notify(_ message: String, target: MapFeeder) {
        let parts = message.split(separator: ",")
''' + ack + '    }\n}\n'
source = ('import Foundation\nimport Combine\n' + stubs + core + queue + feeder + receipt_link
          + (tests / 'main.swift').read_text())
folder = Path(tempfile.mkdtemp(prefix='motonav-map-source-mode-'))
(folder / 'main.swift').write_text(source)
subprocess.run(['swiftc', '-module-cache-path', str(folder / 'modules'), '-swift-version', '5',
                str(folder / 'main.swift'), '-o', str(folder / 'test')], check=True)
subprocess.run([str(folder / 'test')], check=True, timeout=60)
print('map source mode and fine ACK host regression passed')
