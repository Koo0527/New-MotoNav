"""Collect the reproducible fine-road verification numbers into one JSON report.

Reads the Swift sample harness output and records the host measurements taken in
this session. It does not invent device/BLE numbers; those stay in notVerified.
"""
from pathlib import Path
import json

root = Path(__file__).resolve().parents[3]
out = root / 'output' / 'map-edge-bridge' / 'fine-roads-20261106'
sample = json.loads((root / 'output' / 'map-edge-bridge' / 'fine-roads-sample' / 'result' / 'summary.json').read_text())
out.mkdir(parents=True, exist_ok=True)

report = {
    'date': '2026-11-06',
    'scope': 'circle-screen base-map fine roads; iOS raster generation and delivery only',
    'deviceBaseline': {
        'installedBuild': 'Build28 / firmware 175c.16 (unchanged by this work)',
        'sourceTree': 'current source: ordinary themes 1-9 use OpenFreeMap vector source; Build28 ordinary themes still use the AMap capture path',
    },
    'delivery': {
        'wideBase': 'sent once through onBaseReady before the near capture',
        'fineEnhancement': 'sent once as a same-block replacement when added > 0',
        'duplicateGuard': 'MapFeeder.deliveredBase skips the second acceptChunk when the returned packet is the already-sent wide base',
        'notMeasured': ['BLE send count', 'ACK', 'road-first arrival', 'enhanced-packet latency'],
    },
    'acceptedSample': {
        'location': 'Mingbo interchange, Kunming; same 1200x1200 2 m grid',
        'roi': [740, 830, 930, 1000],
        'acceptedPrototype': {'addedRoadCells': 3120, 'baseBytes': 58597, 'enhancedBytes': 60113,
                              'deltaBytes': 1516},
        'productionRuleReplay': sample,
        'retention': round(sample['added'] / 3120, 4),
    },
    'fineRoadsRule': {
        'version': 1,
        'quadrant': 'current view quadrant; south-east when no view (matches accepted sample)',
        'windowMetres': 384,
        'joinDistanceCells': 2,
        'minimumComponentCells': 16,
        'minimumLuminance': 230,
        'maximumSaturationPercent': 14,
        'protected': ['existing roads 1/8/9/11', 'water 3', 'roofs 4-7', 'building completion bitmap'],
    },
    'hostPerformanceMac': {
        'source': 'swiftc -O on the archived Mingbo sample; encode baseline 9 runs median',
        'baselineEncodeMs': 2.15,
        'enhancedMs': 8.60,
        'incrementMs': 6.45,
        'classifyFineRoadsMs': 2.95,
        'mergeMs': 3.59,
        'encodeMs': 2.15,
        'peakRSSBaseMB': 7.1,
        'peakRSSEnhancedMB': 9.7,
        'peakRSSIncrementMB': 2.6,
        'cpuTargetNote': '6.45 ms is 14.7% of the Build28 Mingbo 43.86 ms phone median, but scopes differ; the 10% target is not proven and needs phone measurement',
        'memoryTargetNote': '2.6 MB increment is about 5.0% of the Build28 52.36 MB phone peak, but this is a host-process increment, not an App peak measurement',
    },
    'vectorAudit': {
        'source': 'OpenFreeMap z14, 49 tiles around Mingbo (x 12861-12867, y 7013-7019)',
        'classes': {'path': 1243, 'primary': 1241, 'secondary': 1021, 'tertiary': 784,
                    'service': 677, 'minor': 620, 'motorway': 338, 'trunk': 317, 'track': 68},
        'mingboBuild': {'tiles': 4, 'baseBytes': 93148, 'roadPixels': 180368, 'style': 2},
        'centuryParkBuild': {'wgs': [31.2185, 121.5480], 'tiles': 4, 'baseBytes': 114646,
                             'roadPixels': 193377, 'style': 2},
        'conclusion': 'the tile data already contains service/minor/path/track; VectorMapRaster draws them on the existing path, so no category filter or width change was made',
        'regression': 'vector-map 27/27 packages valid',
    },
    'minimalFix': {
        'input': '120-cell long, one-cell wide white road on 238 ground',
        'before': {'horizontal': 0, 'vertical': 0, 'diagonal': 0},
        'after': {'horizontal': 120, 'vertical': 120, 'diagonal': 120, 'shortBranch': 239},
        'negative': {'3x3speck': 0, 'isolatedDots': 0, 'gapLine': 119},
    },
    'regressions': {
        'fine-roads': 'PASS merge/rejection/water/roof/bounds/encode/quadrant',
        'fine-roads-cache': 'PASS fine version preferred, original base retained',
        'four-styles': 'PASS existing palette/style isolation plus minimal fine lines',
        'vector-feeder': 'PASS 15 checks',
        'screenoff-maps': 'PASS 96 checks',
        'road-palette-core': 'PASS portable fixture',
        'vector-map': 'PASS 27/27 online packages',
        'map-smoothing': 'pre-existing failure: test expects FastBuildings.qualityVersion==3, working tree uses 4; not changed by this work',
    },
    'build': {
        'typecheck': 'swiftc -typecheck FineRoads/MapGeo/RasterProcessing/RoadPalette/RouteMapPlan: PASS',
        'xcodebuild': 'SwiftCompile succeeded for FineRoads.swift, AmapSdkRaster.swift, MapFeeder.swift, MapGeo.swift, RouteMapPlan.swift, AmapCaptureHost.swift; full app build blocked by Xcode 27.2 SwiftUIMacros.StateMacro plugin malformed response in RideMapViews.swift/ScreenSettings.swift',
        'artifact': 'no new IPA produced',
    },
    'notVerified': [
        'device install / screen observation',
        'BLE send count, ACK, road-first arrival time and enhanced-packet latency',
        'phone CPU and peak memory',
        'cross-block and adjacent-block continuity on the circle screen',
        'fine roads with buildings enabled (not implemented in this round)',
        'minimal style on a real AMap minimal screenshot',
        'vector source on device',
    ],
}
(out / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
print(out / 'report.json')
