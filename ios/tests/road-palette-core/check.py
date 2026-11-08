from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
parser=argparse.ArgumentParser(description='Portable production Swift core checks; optionally require the local six-scene corpus.')
parser.add_argument('--real-corpus', nargs='?', const=ROOT/'output/map-edge-bridge', type=Path,
                    metavar='DIRECTORY', help='also require all six scenes (defaults to output/map-edge-bridge)')
args=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='motonav-road-palette-') as td:
    td=Path(td)
    exe=td/'test'
    subprocess.run(['swiftc','-O','-module-cache-path',str(td/'modules'),*[str(ROOT/'ios/MotoNav'/p) for p in ['MapGeo.swift','RasterProcessing.swift','RoadPalette.swift']],str(HERE/'main.swift'),'-o',str(exe)],check=True)
    command=[str(exe),str(HERE)]
    if args.real_corpus is not None:
        command.append(str(args.real_corpus.resolve()))
    raise SystemExit(subprocess.run(command).returncode)
