#!/bin/sh
set -eu
taskRoot=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# 编译产物放临时目录，不在仓库里留下二进制（原 .amap-only-tests 输出目录已移除）
taskOutput=$(mktemp -d "${TMPDIR:-/tmp}/motonav-amap-only.XXXXXX")
trap 'rm -rf "$taskOutput"' EXIT
swiftc "$taskRoot/MotoNav/MapGeo.swift" "$taskRoot/MotoNav/RasterProcessing.swift" "$taskRoot/MotoNav/SatelliteRaster.swift" "$taskRoot/MotoNav/MapDefaults.swift" "$taskRoot/tests/amap-only/main.swift" -o "$taskOutput/amap-only"
"$taskOutput/amap-only"
