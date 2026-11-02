# G recording implementation — 2026-11-01

Approved scope: Waveshare 1.75C firmware + iOS. Preserve current dirty edits,
PWR/BOOT, tunnel dimming, navigation and existing ride files. No Android/185b.

## Required behavior

- Diagnose raw QMI identity/config/real rate/FIFO/errors before treating UI as done.
  Verify board axes physically; calibrate 3s continuous quiet within15s, preserve
  prior successful calibration on failure and mark incompatible mapping versions.
- ~56Hz acquisition/fusion, shared20Hz output,10Hz screen. Yellowpoint,white5s
  trail, four directional peaks,grayrings,0.5/1/2g. Invalid samples clearpoint and
  splittrail. Clear screenstats neverdeletes phone history.
- Auto realnavigation/cruise recording, no simulation; manual recording independent
  of navigation. Manual stop suppresses same-trip auto restart. No empty history.
  Link G record UUID to existing ride UUID; no GPS required for standalone G.
- Phone timecurves+XY replay share selectedtime. Bounded live60s, indexed history,
  peakpreserving drawing reduction. IncrementalJSONL+metadata with serialworker,
  1s batches, protected files, crash prefix recovery, explicit gaps/storageerrors.
- Background/lock delivery through existing CoreBluetooth modes+restoration;
  forcequit/interruption is marked, never invented as uninterrupted recording.
- Recordstream keeps sensor running during PWR sleep/pages. Active recordlease
  inhibits idlehardoff, not displayoff. Disconnect/leaseexpire releaseshold and
  resets idleclock; ordinary no-nav/no-record battery idle300s unchanged.

## Wire contract

Authenticated `CAP,GLOG,1`. `#GS,<8hex token>,20` start/idempotent renewal;
`#GS,<8hex token>,0` stop. `GS,<token>,<state>` state0stopped/1streaming.
Lease15s, renew5s from notification callbacks. Do not replay cachedGS orGC.

17byte littleendian sample: magicA7,version1,flagsU8,sequenceU16,
boardMillisecondsU32,tokenU32,lateralMilligI16,longitudinalMilligI16.
Flags bit0valid,bit1calibrating,bit2saturated,bit3waitingpose,bit4sensorerror.
Decode before UTF8, existing A6music unaffected. Handle modular counters,
reconnect/newtoken segments, device reboot, duplicates, stale packets, congestion.
Bounded queue; navigation/control/status acknowledgements take priority.

## External references

- Official 1.75C QMI example: hardware/rawdata baseline, not a replacement firmware.
  https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75C/tree/main/examples/arduino/examples/04_LVGL_QMI8658_ui
- Chrono-G MIT: acquisition independent of rendering and peakkeeping concepts.
  https://github.com/TioRuben/chrono-g
- CPS3 QMI fixed-axis tare is reference only, no copying unlicensed code.

## Ledger

- Firmware/sensor/roundUI: implemented, native tests and application-only flash passed.
- iOS BLE/storage/lifecycle: implemented, regressions and 72000-sample host stress passed.
- iOS UI/charts: implemented, geometry tests and signed Build17 installation passed.
- Hardware: calibration state2 and increasing valid samples confirmed; user reports
  records in the app. Physical axes, curve contents and full-duration checks remain
  open; see ../verification/g-recording-build17.md.
- Build18 follow-up: physical USB-rear axes measured; automatic stationary mount
  calibration on G-page entry and static tilt recovery implemented, regressions
  passed, firmware/app installed. User confirmed automatic tilted calibration and
  centered dot; USB diagnostics also show tilted near-zero samples. Road/endurance
  acceptance remains open; see
  ../verification/g-mount-build18.md.
- Ruling: reuse current feature checkout and preserve unrelated edits; no commits,
  pushes or new worktree. Existing flashing/install authorization remains in force
  for verified connected devices; retain partitions/NVS and application identity.

## Acceptance

Production tests for stream/parser/timestamps/calibration/status and session
ownership/recovery;14+ native regressions and related iOS suites. 1h/72000sample
host stress plus genuine rawdata/hardware checkpoints, axis tests/staticzero,
navigation+music+record traffic, locked phone/PWRsleep. Identify unperformed real
road/1h hardware checks honestly; successful synthetic tests do not prove IMU
orientation or riding accuracy.
