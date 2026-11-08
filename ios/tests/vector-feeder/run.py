"""Run the production feeder with the vector (OpenFreeMap) source under locked/ background boundaries."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[2]
folder=Path(tempfile.mkdtemp(prefix='motonav-vector-feeder-'))
core='\n'.join((root/'MotoNav'/name).read_text() for name in ('MapGeo.swift','RasterProcessing.swift','RoadPalette.swift','SatelliteRaster.swift','RouteMapPlan.swift', 'FineRoads.swift','MapSourceMode.swift','VectorTiles.swift','VectorMapRaster.swift','CruiseMapCache.swift'))
# Select a temporary disk boundary; cache validation/read/write bodies are unchanged.
core=core.replace('static let shared = RouteMapCache()', 'static let shared = RouteMapCache(root: TestEnvironment.root)')
core=core.replace('static let shared = CruiseMapCache()', 'static let shared = CruiseMapCache(root: TestEnvironment.root)')
queue=(root/'MotoNav/RouteOfflineMaps.swift').read_text().replace('import UIKit','')
feeder=(root/'MotoNav/MapFeeder.swift').read_text().split('enum MapPipelineTrace {')[0].replace('import UIKit','')
# Expose state for scenario assertions only; no body changes.
feeder=feeder.replace('private(set) ', '').replace('private ', '')
stubs=(root/'tests/vector-feeder/Stubs.swift').read_text()
source='import Foundation\nimport Combine\n'+stubs+core+queue+feeder+(root/'tests/vector-feeder/main.swift').read_text()
(folder/'main.swift').write_text(source)
subprocess.run(['swiftc','-module-cache-path',str(folder/'modules'),'-swift-version','5',str(folder/'main.swift'),'-o',str(folder/'test')],check=True)
subprocess.run([str(folder/'test')],check=True,timeout=60)
print("vector feeder host regression passed")
