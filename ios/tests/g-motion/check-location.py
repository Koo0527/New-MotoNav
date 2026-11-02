"""Exercise the production raw-location adapter with controlled platform permission/source boundaries."""
from pathlib import Path
import os, subprocess, tempfile
root=Path(__file__).resolve().parents[2]
source=(root/'MotoNav/SearchService.swift').read_text()
start=source.index('    var gMotionFix: GMotionFix? {')
end=source.index('\n    override init()',start)
adapter=source[start:end]
code=r'''
import Foundation
// The platform permission state is the only mutable boundary; the adapter and reporter are production code.
enum Authorization { case notDetermined, restricted, denied, authorizedWhenInUse, authorizedAlways }
final class CLLocationManager {
    static var enabled=true
    static func locationServicesEnabled()->Bool { enabled }
    var authorizationStatus=Authorization.authorizedWhenInUse
}
struct SourceInformation { let isSimulatedBySoftware:Bool }
struct Location {
    var timestamp=Date(timeIntervalSince1970:100)
    var horizontalAccuracy=1.0, speed=0.0, speedAccuracy=0.1
    var sourceInformation:SourceInformation?
}
final class LocationService {
    let lm=CLLocationManager()
    var location:Location?=Location()
''' + adapter + r'''
}
func check(_ condition: @autoclosure () -> Bool,_ message:String) {
    precondition(condition(),message)
}
let location=LocationService()
let reporter=GMotionReporter(active:true,sample:{location.gMotionFix},now:{100},send:{_ in})
reporter.setCapability()
check(reporter.message == "#GM,0", "authorized genuine location supports stopped")
for denied in [Authorization.denied,.restricted,.notDetermined] {
    location.lm.authorizationStatus=denied
    check(reporter.message == "#GM,2", "permission revoked invalidates even a fresh cached fix")
}
location.lm.authorizationStatus = .authorizedAlways
check(reporter.message == "#GM,0", "existing Always permission accepted without requesting more")
CLLocationManager.enabled=false
check(reporter.message == "#GM,2", "system location switch invalidates fresh cached fix")
CLLocationManager.enabled=true
location.location?.sourceInformation=SourceInformation(isSimulatedBySoftware:true)
check(reporter.message == "#GM,2", "OS software simulation cannot prove a stop")
location.location?.sourceInformation=SourceInformation(isSimulatedBySoftware:false)
check(reporter.message == "#GM,0", "genuine source resumes raw motion")
location.location=nil
check(reporter.message == "#GM,2", "missing fix remains unknown")
reporter.reset()
print("PASS raw motion adapter: live permission, system switch, simulated source and missing fix")
'''
with tempfile.TemporaryDirectory(prefix='motonav-motion-location-') as folder:
    p=Path(folder);(p/'main.swift').write_text(code)
    env=dict(os.environ,SWIFT_MODULECACHE_PATH=str(p/'swift'),CLANG_MODULE_CACHE_PATH=str(p/'clang'))
    subprocess.run(['swiftc',str(root/'MotoNav/GMotionReporter.swift'),str(p/'main.swift'),'-o',str(p/'test')],check=True,env=env)
    subprocess.run([str(p/'test')],check=True,env=env)
