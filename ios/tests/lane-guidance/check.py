"""Run the production lane callback bodies; UIKit's image factory is the only stub."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[3]
bridge = (root / 'ios/MotoNav/NaviBridge.swift').read_text()

def body(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

stub = r'''
import Foundation
struct UIImage { let back: String; let select: String }
func CreateLaneInfoImageWithLaneInfo(_ back: String, _ select: String) -> UIImage? {
 UIImage(back: back, select: select)
}
struct AMapNaviDriveManager {}
final class BleLink {
 static let shared = BleLink(); var sent = [String]()
 func send(_ m: String) { sent.append(m) }
}
final class NaviBridge {
 var uiLaneImage: UIImage?, lastLaneMsg = "", laneRaw = ""
'''
source = stub.replace('var uiLaneImage: UIImage?', 'var uiCrossImage: UIImage?, uiLaneImage: UIImage?') + body(bridge, 'private func onLanes(') + '\n' + body(bridge, 'func mnLaneHide(') + '\n' + body(bridge, 'func mnCrossShow(') + '\n' + body(bridge, 'func mnCrossHide(') + r'''
 func show(_ back: String, _ select: String) { onLanes(back: back, select: select) }
}
let n = NaviBridge(), link = BleLink.shared
n.show("1|0|0|4", "255|0|0|0")
assert(n.uiLaneImage?.back == "1|0|0|4", "custom HUD must receive the SDK lanes")
assert(link.sent == ["#j,1f000040"])
n.show("1|0|0|4", "255|0|0|0")
assert(link.sent.count == 1, "unchanged lanes must not flood BLE")
n.mnLaneHide(AMapNaviDriveManager())
assert(n.uiLaneImage == nil && link.sent.last == "#j", "SDK hide clears phone and round display")
n.show("0|0", "0|255")
assert(n.uiLaneImage != nil && link.sent.last == "#j,000f")
n.show("", "")
assert(n.uiLaneImage == nil && link.sent.last == "#j", "empty lane callback clears guidance")
n.show("16|0", "16|0")
n.show("19|0", "19|0")
assert(n.uiLaneImage?.back == "19|0", "phone image must retain SDK codes beyond the legacy BLE encoding")
n.mnCrossShow(AMapNaviDriveManager(), image: UIImage(back: "junction", select: ""))
n.mnCrossShow(AMapNaviDriveManager(), image: nil)
assert(n.uiCrossImage?.back == "junction", "nil consumed by native UI must not erase the current junction")
n.mnCrossHide(AMapNaviDriveManager())
assert(n.uiCrossImage == nil, "explicit SDK hide clears the junction")
print("PASS production lane callbacks: phone image, BLE, deduplication and hide/show")
'''
with tempfile.TemporaryDirectory() as d:
    p = Path(d)
    (p / 'main.swift').write_text(source)
    subprocess.run(['swiftc', '-module-cache-path', str(p / 'cache'), str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

relay = (root / 'ios/MotoNav/NaviSessionCallbacks.swift').read_text()
screen = (root / 'ios/MotoNav/NaviScreen.swift').read_text()
assert 'driveManager:showCrossImage:' in relay and 'driveManagerHideCrossImage:' in relay
assert 'laneImage: navi.uiLaneImage' in screen and 'crossImage: navi.uiCrossImage' in screen
assert 'Image(uiImage: laneImage)' in screen and 'Image(uiImage: crossImage)' in screen
assert 'uiLaneImage = nil' in body(bridge, 'private func resetState(')
assert 'uiCrossImage = nil' in body(bridge, 'private func resetState(')
print('PASS guidance view, cross-image relay and trip-reset wiring')
