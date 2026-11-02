# 1.75C controls, power, audio, G meter and game maps

Authorized implementation: 2026-11-01. Applies to firmware 175 and iOS only.

- BOOT: 30ms debounce; release short press toggles offline tunnel dimming;
  1.2s long press toggles full touch lock. Wake consumes the entire first press.
- Display sleep preserves BLE. USB defaults 600s (60/120/300/600/1800/never),
  battery defaults 120s (30/60/120/180/240). Keep battery idle hard-off at total
  300s, using the same start time. Navigation/cruise, pairing and calls inhibit.
- Authenticated capability-gated CTL/TM revision reconciliation; offline presses
  win stale phone state. Absolute tunnel setter, firmware brightness fade, legacy
  protocol fallback. PS readback and change-only NVS persistence.
- Boot sound: original ~350ms double tone, default enabled at 20%, app settings,
  ES8311 TX only with PA shutdown after playback; failure cannot stop navigation.
- Local six-axis G estimate, FIFO around 56Hz and display 10Hz. Dedicated page
  below navigation, preserving music/weather positions. Mount-reference plus
  angle and 3s stationary calibration, saved on device. Screen rotation separate.
  Gyro gravity propagation with gated correction, explicit invalid samples and
  estimate label. No raw telemetry, history or motion-based idle resets.
- Vice City classic-style palette and directional white teardrop; GTA5 neutral
  palette and arrow. Preserve theme IDs and other themes, roads and transport.
- Validate production state logic, BLE ordering and lengths, gestures, G traces,
  map marker transforms, iOS build and 175 firmware build. Real board acceptance
  required for sound, keys, shutdown/wake, calibration and power/performance.

## Work ledger

- Complete: firmware controls and power; native tests and firmware build passed.
- Complete: audio and G instrument; math/parser and gesture tests passed.
- Complete: iOS UI, reconciliation and tests; final unsigned Build16 succeeded.
- Complete: map palettes, marker geometry, integration and documentation; transform and package checks passed.
- Ruling: reuse the current feature checkout and preserve all existing dirty
  edits; do not create a replacement checkout, commit, flash or publish implicitly.

## Hardware references

- https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75C/Arduino
- https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75C/tree/main/examples/arduino/examples/07_ES8311
- https://files.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-1.75C/ESP32-S3-Touch-AMOLED-1.75C-schematic.pdf

Audio: MCLK16, BCLK9, WS45, TX8, PA46; microphone disabled. QMI8658 at
0x6b shares the existing I2C bus. Do not replace the working display pin mapping
with that of a different board revision. Retain existing flash partitions.

## Review closure

Cross-layer review closed strict PS/TM/BS/GC parsing, NVS confirmation failure,
physical acknowledgement coalescing, touch-release debounce and saved mounting
readback findings. No remaining protocol mismatch was found. Hardware acceptance
is deferred explicitly in ../verification/175c-build16.md; no physical claims
are inferred from successful builds or synthetic IMU traces.
