"""Offline prototype only: raw row-major 2 m semantic bytes -> EDGE + production LUT PNG pair."""
from pathlib import Path
import argparse
import json
import struct
import subprocess
import tempfile
import zlib


def png_from_ppm(source, destination):
    with source.open("rb") as stream:
        assert stream.readline() == b"P6\n"
        width, height = map(int, stream.readline().split())
        assert stream.readline() == b"255\n"
        rgb = stream.read()
    assert len(rgb) == width * height * 3
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    rows = b"".join(b"\0" + rgb[y*width*3:(y+1)*width*3] for y in range(height))
    destination.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pixels", type=Path)
    parser.add_argument("width", type=int)
    parser.add_argument("height", type=int)
    parser.add_argument("output", type=Path, help="Output prefix")
    parser.add_argument("--theme", type=int, choices=(1,2,3), default=1)
    parser.add_argument("--night", action="store_true")
    parser.add_argument("--scale", type=float, default=4)
    parser.add_argument("--rotation", type=float, default=0, help="Degrees in source coordinates")
    parser.add_argument("--base", type=Path, help="Base packet for the complete 480000-byte budget")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    edge = Path(str(args.output)+".edge")
    with tempfile.TemporaryDirectory(prefix="motonav-edge-preview-") as temp:
        scratch = Path(temp)
        subprocess.run(["swiftc","-O","-module-cache-path",temp+"/modules",str(root/"ios/MotoNav/MapEdgeGeometry.swift"),str(Path(__file__).with_name("tool")/"main.swift"),"-o",temp+"/generate"],check=True)
        generation = subprocess.run([temp+"/generate",str(args.pixels),str(args.width),str(args.height),str(edge),str(args.base.stat().st_size if args.base else 0)],check=True,capture_output=True,text=True)
        generation_report = json.loads(generation.stdout)
        geometry_ms = generation_report["hostGeometryMs"]
        print(f"Host geometry only: {geometry_ms:.3f} ms")
        subprocess.run(["c++","-std=c++11","-O2","-Wall","-Wextra","-Werror",str(Path(__file__).with_name("render.cpp")),"-lz","-o",temp+"/render"],check=True)
        result = subprocess.run([temp+"/render",str(args.pixels),str(edge),str(args.width),str(args.height),str(args.theme),str(int(args.night)),str(args.scale),str(args.rotation),temp+"/nearest.ppm",temp+"/edge.ppm"],check=True,capture_output=True,text=True)
        print(result.stdout.strip())
        for name in ("nearest", "edge"):
            png_from_ppm(scratch/(name+".ppm"),Path(str(args.output)+"-"+name+".png"))
    report = {"width":args.width,"height":args.height,"theme":args.theme,"night":args.night,"scale":args.scale,"rotation":args.rotation,"edgeBytes":edge.stat().st_size,"hostGeometryMs":geometry_ms,"statistics":generation_report["statistics"],"decoderStats":result.stdout.strip()}
    Path(str(args.output)+".json").write_text(json.dumps(report,indent=2)+"\n")


if __name__ == "__main__":
    main()
