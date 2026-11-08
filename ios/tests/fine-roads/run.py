from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
tests = Path(__file__).resolve().parent
sources = [
    root / "MotoNav/FineRoads.swift",
    root / "MotoNav/MapGeo.swift",
    root / "MotoNav/RasterProcessing.swift",
    root / "MotoNav/RoadPalette.swift",
]
with tempfile.TemporaryDirectory(prefix="motonav-fine-roads-") as scratch:
    subprocess.run(
        ["swiftc", "-O", "-module-cache-path", scratch + "/modules"]
        + [str(s) for s in sources] + [str(tests / "main.swift"), "-o", scratch + "/fine-roads"],
        check=True,
    )
    subprocess.run([scratch + "/fine-roads"], check=True)
print("fine-roads host regression passed")
