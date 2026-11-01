"""Unit and coordinate conversions used by the ride path (macOS, no device).

Compiles the production MapGeo (GPS <-> AMap coordinate conversion plus the metric
frame) and the production NaviBridge distance/duration formatters the ride bridge
reuses (distText / durText / distM), and checks them against reference values:
known WGS-84 -> GCJ-02 offsets in Beijing and Shanghai, round-trip accuracy of
gcjToWgs, metres between known coordinates, and the m/km and second/minute/hour
display conversions used on the phone UI and in route summaries.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
geo = (root / 'MotoNav/MapGeo.swift').read_text()
bridge = (root / 'MotoNav/NaviBridge.swift').read_text()


def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


tests = r'''
import Foundation
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}

// ---- GPS(WGS-84) ↔ 高德(GCJ-02) ----
// 已知参考点：北京（天安门一带）与上海（人民广场一带）的公开偏移参考值。
let beijingWgs = (39.90733345, 116.39122885)
let beijingGcj = MapGeo.wgsToGcj(beijingWgs.0, beijingWgs.1)
check(abs(beijingGcj.lat - 39.90733345) < 0.005, "Beijing GCJ latitude shifts within the documented range")
check(abs(beijingGcj.lat - 39.90873) < 0.0004, "Beijing GCJ latitude matches the reference offset")
check(beijingGcj.lat > beijingWgs.0, "Beijing GCJ latitude shifts north like the reference")
check(abs(beijingGcj.lng - 116.39747) < 0.0004, "Beijing GCJ longitude matches the reference offset")
check(beijingGcj.lng > beijingWgs.1, "Beijing GCJ longitude shifts east like the reference")
let shanghaiWgs = (31.223542, 121.465216)
let shanghaiGcj = MapGeo.wgsToGcj(shanghaiWgs.0, shanghaiWgs.1)
check(abs(shanghaiGcj.lat - 31.22162) < 0.0004, "Shanghai GCJ latitude matches the reference offset")
check(shanghaiGcj.lat < shanghaiWgs.0, "Shanghai GCJ latitude shifts south like the reference")
check(abs(shanghaiGcj.lng - 121.46977) < 0.0004, "Shanghai GCJ longitude matches the reference offset")
// 境外坐标不做偏移
let london = (51.5074, -0.1278)
check(MapGeo.wgsToGcj(london.0, london.1).lat == london.0 && MapGeo.wgsToGcj(london.0, london.1).lng == london.1,
      "coordinates outside China pass through unchanged")
// 逆变换两次迭代误差小于 1 米（约 1e-5 度）
for base in [beijingWgs, shanghaiWgs, (31.2304, 121.4737), (39.9042, 116.4074)] {
    let g = MapGeo.wgsToGcj(base.0, base.1)
    let back = MapGeo.gcjToWgs(g.lat, g.lng)
    check(abs(back.lat - base.0) < 1e-5 && abs(back.lng - base.1) < 1e-5,
          "gcjToWgs inverts wgsToGcj to sub-metre accuracy at \(base.0), \(base.1)")
}
// 偏移量在合理区间（GCJ 偏移通常 100–700 米）
for base in [beijingWgs, shanghaiWgs] {
    let g = MapGeo.wgsToGcj(base.0, base.1)
    let metres = NaviBridge.distM(base.0, base.1, g.lat, g.lng)
    check(metres > 100 && metres < 700, "GCJ offset magnitude stays in the plausible range at \(base.0)")
}

// ---- 距离换算：米 ↔ 公里显示 ----
check(NaviBridge.distText(0) == "0 米", "zero metres render without a unit shift")
check(NaviBridge.distText(999) == "999 米", "sub-kilometre distances stay in metres")
check(NaviBridge.distText(1000) == "1.0 公里", "exactly one kilometre renders as 1.0 公里")
check(NaviBridge.distText(1500) == "1.5 公里", "1.5 km keeps one decimal")
check(NaviBridge.distText(28_500) == "28.5 公里", "28.5 km keeps one decimal")

// ---- 时间换算：秒 → 分钟 / 小时显示 ----
check(NaviBridge.durText(30) == "1 分钟", "half a minute rounds up to one minute")
check(NaviBridge.durText(89) == "1 分钟", "89 s still rounds to one minute")
check(NaviBridge.durText(90) == "2 分钟", "90 s rounds to two minutes")
check(NaviBridge.durText(3599) == "1 小时 0 分", "just under an hour renders as 1 小时 0 分")
check(NaviBridge.durText(3600) == "1 小时 0 分", "exactly one hour renders as 1 小时 0 分")
check(NaviBridge.durText(5430) == "1 小时 31 分", "90.5 minutes round to 1 小时 31 分")

// ---- 两点距离（米）：行程统计与沿线地图用的平面近似（distM 用平均地球半径 6371 km） ----
check(NaviBridge.distM(31.2, 121.5, 31.2, 121.5) == 0, "identical points are zero metres apart")
// 赤道上经度差 1 度 = π/180 × 6371000 ≈ 111.195 km
let equator = NaviBridge.distM(0, 100, 0, 101)
check(abs(equator - 111_195) < 30, "one degree of longitude at the equator is 111.195 km for R=6371 km")
// 纬度 31 度上经度差 1 度 ≈ 111.195 × cos(31°) ≈ 95.314 km
let sh31 = NaviBridge.distM(31, 121, 31, 122)
check(abs(sh31 - 95_314) < 30, "one degree of longitude at 31°N is 95.314 km")
// 纬度差 1 度 ≈ 111.195 km（平均地球半径的平面近似）
let lat1 = NaviBridge.distM(31, 121, 32, 121)
check(abs(lat1 - 111_195) < 30, "one degree of latitude is 111.195 km")
// 上海纬度圈上的已知短距：0.01° 经度 ≈ 952.9 m（ride 路径上典型的匹配位置间距量级）
let short31 = NaviBridge.distM(31.22, 121.47, 31.22, 121.4701)
check(abs(short31 - 9.53) < 0.5, "0.0001° of longitude at 31.22°N is about 9.5 m")

// ---- 平面坐标框架（沿线地图 / 圆屏小地图用）：x = Δlng·cos(refLat)·111320，y = Δlat·110574 ----
let frame = MapGeo.Frame(refLat: 31, refLng: 121, id: 77)
// 0.01° lng × cos(31°) × 111320 ≈ 954.2 m
check(frame.x(121.01) > 950 && frame.x(121.01) < 960, "frame x converts 0.01° east to about 954 m at 31°N")
// 0.01° lat × 110574 ≈ 1105.7 m
check(frame.y(31.01) > 1104 && frame.y(31.01) < 1108, "frame y converts 0.01° north to about 1106 m")
check(frame.x(121) == 0 && frame.y(31) == 0, "the reference point maps to the origin")
check(abs(frame.lng(frame.x(121.03)) - 121.03) < 1e-9, "frame x/lng round-trips exactly")
check(abs(frame.lat(frame.y(31.03)) - 31.03) < 1e-9, "frame y/lat round-trips exactly")

print("PASS ride units: GPS/GCJ conversion, round trips, distance and duration formatting, metric frame")
'''

source = ('import Foundation\nimport CoreLocation\n' + geo + '\nenum NaviBridge {\n'
          + method(bridge, '    static func distText(') + '\n'
          + method(bridge, '    static func durText(') + '\n'
          + method(bridge, '    static func distM(')
          + '\n}\n' + tests)

with tempfile.TemporaryDirectory(prefix='motonav-ride-units-') as tmp:
    swift = Path(tmp) / 'main.swift'
    swift.write_text(source)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(Path(tmp) / 'cache'), SWIFT_MODULECACHE_PATH=str(Path(tmp) / 'cache'))
    subprocess.run(['swiftc', str(swift), '-o', str(Path(tmp) / 'check')], check=True, env=env)
    subprocess.run([str(Path(tmp) / 'check')], check=True, env=env)
