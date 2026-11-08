"""Build an isolated processing probe with the existing app identity; never install."""
from pathlib import Path
import argparse, hashlib, json, plistlib, shutil, subprocess

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--mode', choices=['baseline', 'current'], required=True)
args = parser.parse_args()
out = ROOT/'output/road-multitone'/('probe-'+args.mode)
app = out/'MotoNav.app'
assert not app.exists(), 'Keep already-built evidence; choose a clean output explicitly'
out.mkdir(parents=True, exist_ok=True)
seed = ROOT/'output/road-multitone/DD-baseline/Build/Products/Release-iphoneos/MotoNav.app'
assert seed.is_dir()
shutil.copytree(seed, app)
source = ROOT/'.superpowers/sdd/road-multitone-20261104/baseline/ios/MotoNav' if args.mode == 'baseline' else ROOT/'ios/MotoNav'
names = ['MapGeo.swift', 'RasterProcessing.swift', 'RoadPalette.swift']
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-ios15.0', '-sdk', sdk,
                '-module-cache-path', str(out/'modules'), *[str(source/n) for n in names],
                str(Path(__file__).with_name('Probe.swift')), '-o', str(app/'MotoNav')], check=True)
info = plistlib.loads((app/'Info.plist').read_bytes())
info['MotoNavToneProbeMode'] = args.mode
info['UIApplicationSceneManifest'] = {
    'UIApplicationSupportsMultipleScenes': False,
    'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{'UISceneConfigurationName': 'ToneProbe'}]}
}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
fixtures = app/'ToneProbe'; fixtures.mkdir()
scenes = ['02-low-density', '03-diagonal', '04-interchange', '05-waterfront', '06-mingbo']
inputs = {'scenes': scenes, 'mode': args.mode, 'files': {}}
for scene in scenes:
    base = ROOT/'output/map-edge-bridge'/('fresh-mingbo' if scene.startswith('06') else 'fresh-default-five')/scene
    folder = fixtures/scene; folder.mkdir()
    files = [('base-sampled-2m.argb32le', 'base.argb', 1_440_000)] + [(f'building-{q}-sampled-2m.argb32le', f'patch-{q}.argb', 360_000) for q in range(4)]
    for src, dest, count in files:
        data = (base/src).read_bytes(); assert len(data) == count*4
        (folder/dest).write_bytes(data)
        inputs['files'][scene+'/'+dest] = hashlib.sha256(data).hexdigest()
(fixtures/'inputs.json').write_text(json.dumps(inputs, indent=2)+'\n')
entitlements = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(seed)], check=True, capture_output=True).stdout
assert plistlib.loads(entitlements)['application-identifier'].endswith('.'+info['CFBundleIdentifier'])
(out/'entitlements.plist').write_bytes(entitlements)
cert = out/'cert'
subprocess.run(['codesign', '-d', '--extract-certificates='+str(cert), str(seed)], check=True, capture_output=True)
identity = hashlib.sha1(Path(str(cert)+'0').read_bytes()).hexdigest().upper()
subprocess.run(['codesign', '--force', '--sign', identity, '--entitlements', str(out/'entitlements.plist'), '--timestamp=none', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
manifest = {'mode': args.mode, 'build': info['CFBundleVersion'], 'bundle': info['CFBundleIdentifier'],
            'sourceHashes': {n: hashlib.sha256((source/n).read_bytes()).hexdigest() for n in names},
            'probeSourceSHA256': hashlib.sha256(Path(__file__).with_name('Probe.swift').read_bytes()).hexdigest(),
            'sceneManifest': info['UIApplicationSceneManifest'],
            'executableSHA256': hashlib.sha256((app/'MotoNav').read_bytes()).hexdigest(), 'inputs': inputs,
            'normalAppRestore': str(seed), 'installed': False}
(out/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(app)
