from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[3]
tests = Path(__file__).resolve().parent
sources = [
    root / "ios/MotoNav/FineRoads.swift",
    root / "ios/MotoNav/MapGeo.swift",
    root / "ios/MotoNav/RasterProcessing.swift",
    root / "ios/MotoNav/RoadPalette.swift",
    root / "ios/MotoNav/RouteMapPlan.swift",
]
with tempfile.TemporaryDirectory(prefix="motonav-fine-cache-") as scratch:
    subprocess.run(
        ["swiftc", "-O", "-module-cache-path", scratch + "/modules"]
        + [str(s) for s in sources] + [str(tests / "main.swift"), "-o", scratch + "/cache"],
        check=True,
    )
    subprocess.run([scratch + "/cache"], check=True)
print("fine-road cache host regression passed")
