#!/bin/bash
set -euo pipefail
taskRoot="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$taskRoot"
test "$(uname -s)" = Darwin || { echo '请在安装 Xcode 的 Mac 上运行'; exit 1; }
command -v pod >/dev/null || { echo '请先安装 CocoaPods 1.16.2'; exit 1; }
(cd ios && pod _1.16.2_ install --deployment)
export SWIFT_MODULECACHE_PATH="$taskRoot/output/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$taskRoot/output/clang-module-cache"
mkdir -p "$SWIFT_MODULECACHE_PATH" "$CLANG_MODULE_CACHE_PATH"
python3 ios/tests/ios-fixes/check.py
python3 ios/tests/unified-planner/check.py
python3 ios/tests/tunnel-settings/check.py
python3 ios/tests/tunnel-sdk/check.py
swiftc ios/MotoNav/TunnelDimming.swift ios/tests/tunnel-dimming/main.swift -o /tmp/motonav-tunnel
/tmp/motonav-tunnel
swiftc ios/MotoNav/PhoneClockSync.swift ios/tests/phone-clock/main.swift -o /tmp/motonav-clock
/tmp/motonav-clock
python3 ios/tests/webmotor/check.py
swiftc ios/MotoNav/ArrivalPolicy.swift ios/tests/arrival/main.swift -o /tmp/motonav-arrival
/tmp/motonav-arrival
swiftc ios/MotoNav/ArrivalPolicy.swift ios/MotoNav/NaviSessionCallbacks.swift ios/tests/arrival-relay/SDKStubs.swift ios/tests/arrival-relay/main.swift -o /tmp/motonav-relay
/tmp/motonav-relay
swiftc -O ios/MotoNav/MapGeo.swift ios/MotoNav/RasterProcessing.swift ios/MotoNav/RouteMapPlan.swift ios/tests/maps/main.swift -o /tmp/motonav-maps
/tmp/motonav-maps
swiftc ios/MotoNav/BleBulkWriteQueue.swift ios/MotoNav/BleWritePacer.swift ios/tests/ble-bulk/main.swift -o /tmp/motonav-bulk
/tmp/motonav-bulk
swiftc ios/MotoNav/BleWritePacer.swift ios/tests/ble-pacing/main.swift -o /tmp/motonav-pacing
/tmp/motonav-pacing
bash scripts/build-ios-ipa.sh
