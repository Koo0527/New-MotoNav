"""Structural checks for the unified map-first navigation UI (drive / ride / compat).

The pure layout math, map-representative wiring and turn readout behaviour are
compiled and executed in tests/ios-fixes and tests/nav-coordinator; this suite
pins the SwiftUI structure of the three navigation screens to the unified-HUD
contract: one compact top card, short status strips, a glass bottom control bar
with the tunnel quick action, a more menu (simulation controls, return to
settings, full-SDK entry hidden for the independent backend), the long-press
end action, map-first layouts per backend and the 4-second arrival hand-off.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
navi_screen = (root / "MotoNav/NaviScreen.swift").read_text()
planner = (root / "MotoNav/IndependentRouteView.swift").read_text()
ride_bridge = (root / "MotoNav/RideBridge.swift").read_text()
coordinator = (root / "MotoNav/NavigationCoordinator.swift").read_text()
web_motor = (root / "MotoNav/WebMotor.swift").read_text()

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
        print(f"FAIL: {message}")


def body(source, opening):
    """Return the brace-balanced block starting at `opening` (struct/class/enum)."""
    start = source.index(opening)
    cursor = source.index("{", start)
    depth, end = 1, cursor + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


overlay = body(navi_screen, "struct NavigationOverlay")
top_card = body(overlay, "private var topCard")
bottom_bar = body(overlay, "private var bottomBar")
more_menu = body(overlay, "private var moreMenu")
drive_screen = body(navi_screen, "struct NaviScreen")
ride_rep = body(navi_screen, "struct AMapRideViewRep")
ride_ctl = body(navi_screen, "final class RideViewController")
ride_screen = body(planner, "struct RideNaviScreen")
independent = body(planner, "struct IndependentNavigationView")

# 1. 顶部单张紧凑卡片：方向图标、下次动作与距离、道路名、剩余和 ETA；状态用简短状态条
check("readout.turn.symbol" in top_card, "top card shows the turn direction icon")
check("accessibilityLabel(readout.turn.label)" in top_card, "turn icon keeps its VoiceOver label")
check("turnDistanceText" in top_card and "readout.instruction" in top_card,
      "top card shows the next-action distance and the road/instruction line")
check("remainingText" in top_card and "etaText" in top_card, "top card shows remaining distance and ETA")
check("status" in top_card and "Capsule()" in top_card, "non-empty status renders as a short strip")
check(body(navi_screen, "struct NavigationReadout").count('"—"') >= 2,
      'missing guidance data renders as "—" instead of invented values')

# 2. 底部轻量控制栏：速度、全览/跟随、静音、隧道快捷操作、更多；独立的长按结束
for button in ['"全览／跟随"', '"取消静音" : "静音"', '"隧道"', '"更多"']:
    check(button in bottom_bar, f"bottom control bar keeps the {button} action")
check("readout.speed" in bottom_bar, "bottom control bar shows the speed")
check("settings.toggleTunnelMode()" in bottom_bar, "tunnel quick action toggles manual tunnel mode for every backend")
check("onShowNativeUI" not in bottom_bar, "the full-SDK entry lives in the more menu, not the bar")
end_button = body(overlay, "private var endButton")
check("onLongPressGesture" in end_button, "ending navigation keeps the long-press guard")

# 3. 更多菜单：模拟控制、返回设置（不停止导航）、完整 SDK 提示（可选，隐藏不伪造）
check("readout.simulation" in more_menu and "onCycleSpeed" in more_menu, "simulation controls live in the more menu")
check("返回设置（导航继续）" in more_menu and "onSettings" in more_menu, "return-to-settings stays in the more menu and keeps navigating")
check("if let onShowNativeUI" in more_menu and "完整导航提示" in more_menu,
      "full-SDK entry appears in the more menu only when the backend provides it")

# 4. 驾车：Drive 地图容器 + 统一 HUD + 完整 SDK 界面切换入口
check("AMapDriveViewRep(" in drive_screen, "drive navigation keeps the Drive map container")
check("NaviHudLayout.mapEdgeInsets(" in drive_screen, "drive map insets follow the measured HUD layout")
check("onShowNativeUI: { showNativeUI = true }" in drive_screen, "drive keeps the full-SDK interface entry")
check("showNativeUI" in drive_screen and "返回 App 风格" in drive_screen, "drive can return from the SDK interface to the unified HUD")

# 5. 官方骑行：Ride 地图容器（AMapNaviRideView）+ 真实全览/跟随 + 到达 4 秒收尾
check("AMapRideViewRep(" in ride_screen, "official ride navigation renders the SDK ride map first")
check("NaviHudLayout.mapEdgeInsets(" in ride_screen, "ride map insets follow the measured HUD layout")
check("onOverview: rideCtl.toggleOverview" in ride_screen, "the ride overview button is wired to the real map mode")
check("onOverview: {}" not in ride_screen, "no stubbed overview closure remains")
check("onShowNativeUI: { showNativeUI = true }" in ride_screen, "ride keeps the full-SDK interface entry")
check("onChange(of: ride.showArrived)" in ride_screen and "onChange(of: ride.navigating)" in ride_screen,
      "ride arrival shows for the bridge-held 4 seconds and then the screen dismisses itself")
check("NavigationCoordinator.shared.attachRideMap(v)" in ride_rep, "the ride map attaches through the coordinator owner gate")
check("NavigationCoordinator.shared.detachRideMap(uiView)" in ride_rep, "ride map teardown goes through the coordinator owner gate")
check("v.showUIElements = false" in ride_rep, "the ride map hides SDK UI elements for the unified HUD by default")
check("rideViewEdgePadding:" in ride_ctl and "rideViewCloseButtonClicked:" in ride_ctl,
      "the ride view controller registers the SDK delegate callbacks at runtime")

# 6. 兼容导航：现有地图 + 统一 HUD；SDK 专属功能隐藏（不伪造），通知条保留
check("MotorMap(route:" in independent, "independent navigation keeps the existing map container")
check("NaviHudLayout.mapEdgeInsets(" in independent, "independent map insets follow the measured HUD layout")
check("onShowNativeUI:" not in independent, "independent navigation hides the SDK-only full-UI entry instead of faking it")
check("ridePlanNotice" in independent and "metadata.status" in independent, "independent keeps its real status notices")
check("4_000_000_000" in independent, "independent arrival display still holds for 4 seconds")

# 7. 移交 minor：显示侧转向距离取整（线上 BLE 格式不变）
on_navi_info = body(ride_bridge, "fileprivate func onNaviInfo")
check("uiDist = roundDist(n.segmentRemainDistance)" in on_navi_info,
      "ride display turn distance rounds to hundreds past 1 km (wire format untouched)")

# 8. 隧道：快捷操作全模式手动；自动调光仍只在驾车 SDK 路径
check("updateTunnel" not in ride_bridge and "updateTunnel" not in web_motor,
      "automatic tunnel dimming still never runs on the ride or independent paths")
check("tunnelAuto" not in overlay, "the quick action toggles manual state and does not touch auto settings")

# 9. 协调器：骑行地图与驾车地图同一套属主门禁
coord_ride_attach = body(coordinator, "func attachRideMap")
coord_ride_detach = body(coordinator, "func detachRideMap")
check("rideManagerIfActive()" in coord_ride_attach and "addDataRepresentative" in coord_ride_attach,
      "ride map attach is gated on ride engine ownership")
check("rideManagerIfActive()" in coord_ride_detach and "removeDataRepresentative" in coord_ride_detach,
      "ride map detach is gated on ride engine ownership")

if failures:
    raise SystemExit(1)

# 10. 分享异步回归：加载完成后必须用统一的导航活动判断重新检查（覆盖官方骑行），
#     已有导航开始后迟到的分享结果不得写入规划器；不得退回拆分的旧判断。
content = (root / "MotoNav/ContentView.swift").read_text()
import_share = body(content, "private func importShare")
check("NavigationCoordinator.shared.navigationActive" in import_share,
      "share import re-checks the unified navigation activity after loading (covers official ride)")
check("!navi.navigating,!independent.running" not in import_share,
      "share import must not fall back to the split navigation check that misses official ride")
check("planner.importShare(route)" in import_share,
      "an accepted share result is the only path that writes into the planner")

if failures:
    raise SystemExit(1)
print("PASS unified navigation UI: shared card/bar/more-menu, three map containers, "
      "hidden SDK entries for compat, ride arrival hand-off, manual tunnel quick action "
      "and unified late-share rejection")
