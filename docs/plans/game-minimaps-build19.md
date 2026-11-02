# Game minimaps Build19 / 175c.4

User-approved plan, 2026-11-02. Scope: iOS map preparation/settings and Waveshare
1.75C firmware. Preserve current dirty work including G recording, controls,
power and tunnel settings. Existing feature checkout; no commits/push/reset.

## Approved behavior

- IDs1/2/3 remain VC/GTA5/Cyberpunk. Rename 赛博霓虹 to 赛博朋克, retaining saved IDs.
- Shared building support1/2/3, existing switch/packet/BC protocol/cache formats.
  Roads/base first, optional roofs later; retain overlapping roofs, clear on off,
  never replace roads/water, reject blank maps for all three. Existing VC AA stays VC.
- Day base/road/roof/outline: VC E6E5E2/101012/CECECA/929490;
  GTA5 252628/A6A8A8/36383A/505255; CP0D101A/285F60/111522/686574.
  Water/park VC lightblue/green; GTA mutedbluegray/graygreen; CP deepblue/deepteal.
  VC route pinkpurple; GTA A45CFF; CP F4F6B0 dotted. Visited routes muted,
  honor existing gray/erase switch. Night base materials scaled45% VC,75% GTA/CP;
  routes/markers remain legible; hardware brightness managed separately.
- VC white black-outlined drop, GTA white black-outlined arrow, CP green hollow
  chevron. Theme destinations VC pinksquare, GTA purplefour-waycross, CP yellowhexagon,
  dark outer/light inner border; offscreen colored direction triangle avoiding N/HUD.
- VC pinkpurple base ring, bright completed/dark remaining trip arc and white dot.
  GTA simple ring; CP thin cyan ring. Alerts > turn countdown > trip > base.
  No fake progress when absent/disabled. Fast cache key includes theme/night/colors;
  fast/fallback render parity. Black-backed white N. Other9styles unchanged, including
  paper-night old style3 alias: new CP branches use selected theme ID, not alias.
- CP dots every14worldmeters, radius~2screenpx, anchored to route distance.
  Honor progress/erase, traffic/curve tint dots without solid-line overlay. Keep
  viewport culling and avoid per-frame allocation/full long-route scans.

## Work ledger

- iOS buildings/settings: complete; settings/style/cache/delivery regressions passed.
- Firmware palettes/markers/rings: complete; user icon corrections included and tests passed.
- CP route rendering: complete; visible clipping, stable phase, force colors and huge-distance bounded tests passed.
- Integration/review/production previews/build19+175c.4: complete; no remaining blocking review findings.
- Device deployment: complete, Build19 installed/launched and final175c.4 app-only flash/hash/boot confirmed.
- Performance/visual acceptance: VC same-route simulation sampled 9old/12new reports,
  median frame66->67ms (+1.5%), FPS12.6->12.2; within10% for this observation,
  not a fixed-viewport paired benchmark. GTA5 user visualnormal + median12.8FPS/63ms;
  CP user visualnormal + repeat median13.5FPS/60ms. Initial CP0.5FPS window retained
  in evidence; not repeated in extended sample. Night/alerts/endurance remain open.
- Separate finding: simulated-navigation G estimate can drift until pose reset;
  recorded for follow-up, not changed as part of game-map implementation.

## Verification/delivery

User correction: GTA5 waypoint is a tapered four-way purple cross with transparent
center and black-only border, replacing the earlier diamond/white trim. Its hole
must preserve actual map pixels rather than paint a guessed background color.
Grade-separated road shading deferred per
user preference: current screenshot/material pipeline has no reliable all-road
elevation/layer field; route-only link types cannot classify surrounding roads.

Test palettes/daynight, marker rotation/edge/obstacles, cache invalidation and ring
priority/parity; building support/onoff/legacy/cache/handoffs; anchored dots through
turns/zoom/Uturn/reroute and traffic. Run existing iOS/map/firmware regressions.
Produce same-scene three-theme day/night previews using production data/rendering.
Signed Build19 and firmware175c.4. Install/flash authorized connected devices,
application-only firmware preserves partitions/NVS. Measure real device timing/memory
if available; target <=10% overhead under same conditions. Report unperformed
hardware tests honestly and distinguish host/synthetic previews from real-map shots.
