"""Execute production Swift session/tracker/policy on macOS with bounded fake I/O."""
from pathlib import Path
import os, sys, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
web = (root/'MotoNav/WebMotor.swift').read_text()
models = web[web.index('struct MotorPoint'):web.index('enum MotorRoutes')]
models += web[web.index('enum IndependentTakeoverPolicy'):web.index('/// Independent route following.')]
session = web[web.index('final class WebMotorSession'):web.index('final class MotorBrowser')]
# Expose only this entrypoint's visibility to test its post-stop guard; body is unchanged.
session = session.replace('private func replan(_ point:', 'func replan(_ point:')
core = '\n'.join((root/'MotoNav'/name).read_text() for name in [
    'RouteGeometry.swift', 'MotorRouteTracker.swift', 'NavigationSpeed.swift'] + (['MotorReroutePolicy.swift'] if (root/'MotoNav/MotorReroutePolicy.swift').exists() else []))
# Preserve the old production matcher as the output-parity/performance control.
old = (root/'tests/reroute-recovery/LegacyMotorRouteTracker.swift').read_text()
stubs = (root/'tests/reroute-recovery/Stubs.swift').read_text()
tests = (root/'tests/reroute-recovery/main.swift').read_text()
if '--baseline' in sys.argv:
    tests = tests[:tests.index('// Trigger times')] + '''
let session=WebMotorSession.shared,original=makeRoute()
MotorRoutes.mode = .empty;session.start(original,simulate:false)
session.replan(MotorPoint(lat:30.005,lng:104.001));spin(0.2)
check(!busy(session) && session.running && session.route?.id==original.id,"empty route must release reroute lease and retain original route")
print("PASS empty route recovery")
'''
folder = Path(tempfile.mkdtemp(prefix='motonav-reroute-', dir='/private/tmp'))
os.environ['CLANG_MODULE_CACHE_PATH'] = str(folder/'clang-cache')
os.environ['SWIFT_MODULECACHE_PATH'] = str(folder/'swift-cache')
source = folder/'main.swift'
source.write_text('import Foundation\nimport CoreLocation\nimport Combine\n'+models+core+old+stubs+session+tests)
subprocess.run(['swiftc', '-Onone' if '--baseline' in sys.argv else '-O', '-swift-version', '5', str(source), '-o', str(folder/'test')], check=True)
subprocess.run([str(folder/'test')], check=True, timeout=90)
