from pathlib import Path
import json, subprocess, tempfile

root = Path(__file__).resolve().parents[3]
tests = Path(__file__).resolve().parent
out = root / "output" / "vector-map"
out.mkdir(parents=True, exist_ok=True)

sources = [
    root / "ios/MotoNav/VectorTiles.swift",
    root / "ios/MotoNav/VectorMapRaster.swift",
    root / "ios/MotoNav/MapGeo.swift",
    root / "ios/MotoNav/RoadPalette.swift",
    root / "ios/MotoNav/RasterProcessing.swift",
]
with tempfile.TemporaryDirectory(prefix="motonav-vector-map-") as scratch:
    subprocess.run(
        ["swiftc", "-O", "-module-cache-path", scratch + "/modules"]
        + [str(s) for s in sources] + [str(tests / "main.swift"), "-o", scratch + "/vector-map"],
        check=True,
    )
    subprocess.run([scratch + "/vector-map", str(out)], check=True)

summary = json.loads((out / "summary.json").read_text())
rows = summary["rows"]
assert len(rows) == 27, f"应 3 城市 × 9 风格 = 27 行，实际 {len(rows)}"
assert not summary["hardFailures"], summary["hardFailures"]

assert "{z}" in summary["tileTemplate"] and "{y}" in summary["tileTemplate"], summary["tileTemplate"]
ok = [r for r in rows if "error" not in r]
assert len(ok) == 27
for r in ok:
    assert r["baseValid"] and r["baseMatches"] and r["hasContent"]
    assert r["baseBytes"] <= 480000
    assert r["roadPixels"] >= summary["roadPixelFloor"]
# 风格 1-3 城市中心应有建筑包（允许个别缺失留空，但 9 组中至少 7 组要有）
bld = [r for r in ok if r["style"] in (1, 2, 3) and r.get("buildingBytes") is not None]
assert len(bld) >= 7, f"建筑包过少: {len(bld)}/9"
for r in bld:
    assert r["bldValid"] and r["bldMatches"] and r["bldIsBuilding"]
# 风格 4-9 不应产生建筑包
assert all(r.get("buildingBytes") is None for r in ok if r["style"] >= 4)
# PNG 对照图落盘（base 27 张 + 建筑 ≤9 张），供人工目视检查
pngs = list(out.glob("*-base.png"))
assert len(pngs) == 27, f"base PNG 应 27 张，实际 {len(pngs)}"
print(f"27 组包有效；TileJSON 版本 {summary['tileVersion']}；对照图 {len(pngs)}+{len(list(out.glob('*-bld.png')))} 张在 {out}")
