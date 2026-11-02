"""Run the production feeder/cache/route queue with bounded graphics and BLE fakes."""
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[2]
folder=Path(tempfile.mkdtemp(prefix='motonav-screenoff-'))
core='\n'.join((root/'MotoNav'/name).read_text() for name in ('MapGeo.swift','RasterProcessing.swift','SatelliteRaster.swift','RouteMapPlan.swift'))
# Select a temporary disk boundary; cache validation/read/write bodies are unchanged.
core=core.replace('static let shared = RouteMapCache()', 'static let shared = RouteMapCache(root: TestEnvironment.root)')
queue=(root/'MotoNav/RouteOfflineMaps.swift').read_text().replace('import UIKit','')
feeder=(root/'MotoNav/MapFeeder.swift').read_text().split('enum MapPipelineTrace {')[0].replace('import UIKit','')
# Expose state only to seed an in-flight capture and recent failure. No body changes.
feeder=feeder.replace('private(set) ', '').replace('private ', '')
source='import Foundation\nimport Combine\n'+(root/'tests/screenoff-maps/Stubs.swift').read_text()+core+queue+feeder+(root/'tests/screenoff-maps/main.swift').read_text()
(folder/'main.swift').write_text(source)
subprocess.run(['swiftc','-swift-version','5',str(folder/'main.swift'),'-o',str(folder/'test')],check=True)
subprocess.run([str(folder/'test')],check=True,timeout=45)
# Preserve the other production geometry/classifier/transfer regressions as well.
for suite in ('map-delivery',):
    (folder/'main.swift').write_text(core+'\n'+(root/'tests'/suite/'main.swift').read_text())
    # This suite does not use shared cache I/O, but its static initializer must resolve.
    with (folder/'main.swift').open('a') as f:
        f.write('\nenum TestEnvironment {static let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}\n')
    subprocess.run(['swiftc','-O',str(folder/'main.swift'),'-o',str(folder/'regression')],check=True)
    subprocess.run([str(folder/'regression')],check=True,timeout=60)
