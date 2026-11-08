from pathlib import Path
import subprocess, tempfile, hashlib
root = Path(__file__).resolve().parents[3]
tests = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="motonav-edge-") as scratch:
    subprocess.run(["swiftc", "-O", "-module-cache-path", scratch+"/modules", str(root/"ios/MotoNav/MapEdgeGeometry.swift"), str(tests/"main.swift"), "-o", scratch+"/generate"],check=True)
    subprocess.run([scratch+"/generate", scratch],check=True)
    subprocess.run(["c++","-std=c++11","-O1","-fsanitize=address,undefined","-Wall","-Wextra","-Werror",str(tests/"roundtrip.cpp"),"-lz","-o",scratch+"/roundtrip"],check=True)
    subprocess.run([scratch+"/roundtrip",scratch],check=True)
    assert hashlib.sha256(Path(scratch,"pattern-words.u16").read_bytes()).hexdigest() == "1c42bac416479868fe0c1459d6a7b462c839bef64c7c707eb8f3fbdf329bfbf6"
    assert hashlib.sha256(Path(scratch,"pattern-packets.bin").read_bytes()).hexdigest() == "ab816032fd1b9062ccef303a653c5de80724f103aa24ae1a1ce3b5e959d52a15"
    print("28 pairs x 512 patterns: pre-lookup words and packet SHA256 unchanged")
