"""Generate and benchmark the five cached 1200x1200 semantic fixtures; no device or network access."""
from pathlib import Path
import json
import hashlib
import statistics
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parents[3]
folder = Path(sys.argv[1]) if len(sys.argv)>1 else root/"output/map-edge-bridge/cached-real"
reference = Path(sys.argv[2]) if len(sys.argv)>2 else None
with tempfile.TemporaryDirectory(prefix="motonav-edge-real-") as scratch:
    tests = Path(__file__).resolve().parent
    subprocess.run(["swiftc","-O","-module-cache-path",scratch+"/modules",str(root/"ios/MotoNav/MapEdgeGeometry.swift"),str(tests/"tool/main.swift"),"-o",scratch+"/generate"],check=True)
    subprocess.run(["c++","-std=c++11","-O1","-fsanitize=address,undefined",str(root/"firmware/tests/raster-edge/main.cpp"),"-lz","-o",scratch+"/read"],check=True)
    if reference:
        subprocess.run(["c++","-std=c++11","-O1","-fsanitize=address,undefined",str(tests/"compare.cpp"),"-lz","-o",scratch+"/compare"],check=True)
    reports=[]
    edges=[]
    for number in range(1,6):
        scene=folder/f"cached-{number:02d}"
        edge=scene/"prototype.edge"
        generated=Path(scratch)/f"cached-{number:02d}.edge"
        base=(scene/"base.bin").stat().st_size
        runs=[]
        for _ in range(3):
            result=subprocess.run([scratch+"/generate",str(scene/"pixels.idx"),"1200","1200",str(generated),str(base)],capture_output=True,text=True)
            report=json.loads(result.stdout)
            runs.append(report["hostGeometryMs"])
            if result.returncode:
                raise RuntimeError(f"{scene.name}: {report}")
        wire=generated.read_bytes()
        if edge.exists():
            assert edge.read_bytes()==wire, f"{scene.name}: existing wire would change; retained old edge"
        else:
            edge.write_bytes(wire)
        if reference:
            previous=reference/f"cached-{number:02d}.edge"
            assert previous.read_bytes()==wire, f"{scene.name}: reference SHA would change"
            subprocess.run([scratch+"/compare",str(previous),str(generated),"1200","1200"],check=True)
        report.update(sha256=hashlib.sha256(wire).hexdigest(),scene=scene.name,hostGeometryMs=statistics.median(runs),hostRunsMs=runs,baseBytes=base)
        assert base+edge.stat().st_size<=480000
        assert report["statistics"]["decodedBytes"]<=512*1024
        (scene/"prototype.json").write_text(json.dumps(report,indent=2)+"\n")
        print(json.dumps(report),flush=True)
        reports.append(report)
        edges.append(str(edge))
    decoded=subprocess.run([scratch+"/read",*edges],check=True,capture_output=True,text=True)
    print(decoded.stdout)
    (folder/"prototype-report.json").write_text(json.dumps({"scenes":reports,"realDecoder":decoded.stdout},indent=2)+"\n")
