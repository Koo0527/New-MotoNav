# Mission: 175c.16 SPI flush crash and FIFO transient

## Goal

Remove the observed round-display `LoadProhibited` in `spi_bus_lock_bg_exit` and bound the transient QMI8658 FIFO-count interrupts that leave G output in `WAITING`. Preserve the existing fast flush, double DMA buffering, rotation algorithm, wire formats and record formats.

## Board / Target

- **Chip**: ESP32-S3
- **Board**: Waveshare ESP32-S3-Touch-AMOLED-1.75
- **Framework**: Arduino ESP32 core 3.3.10 (ESP-IDF 5.5.x), 16 MB flash
- **Partition**: `app3M_fat9M_16MB`; application at `0x10000`

## Constraints

- Preserve all existing uncommitted work in the shared tree.
- Flash only application `app0` at `0x10000`; never write the partition table, NVS, pairing data or bootloader. Preserve a pre-flash image for rollback.
- Do not change A7 frames, `GENT`/`#GE`, installation parameters (`gmount2`), record format or calibration policy.
- No version bump unless separately requested.
- Keep the existing iOS test app; no iOS source changes in this mission.
- SPI and FIFO changes are independently verifiable batches.

## Files in Scope

| File | Action | Notes |
|------|--------|-------|
| `firmware/boards/175/MotoNav/src/display/DisplayPipeline.h` | MODIFY | Single-in-flight DMA polling in `fastPush`; CS/bus/`flushDone` ownership; failure handling |
| `firmware/boards/175/MotoNav/src/power/DeviceControlRuntime.h` | MODIFY | Wake/panel ownership barrier; 4 s slow-flush limit; no panel command without ownership |
| `firmware/boards/175/MotoNav/DeviceInstruments.h` | MODIFY | FIFO raw count/status capture; bounded half-pair wait; invalidation on real loss |
| `firmware/tests/flush-ownership/check.py` | MODIFY | Bus-acquire failure, transaction failure/timeout, wake-while-busy ownership |
| `firmware/tests/GInstrumentRuntimeTest.cpp` | MODIFY | FIFO half-pair/transient-count state machine |
| `firmware/tests/GInstrumentRecoveryTest.cpp` | MODIFY | FIFO timeout/overflow invalidation; trusted-stop runtime-pose recovery |
| `missions/2026-11-06-spi-flush-crash-and-fifo-transient.md` | MODIFY | Mission status and evidence |
| `missions/2026-11-06-spi-flush-crash-and-fifo-transient-contract.md` | MODIFY | Accepted contract and approval |

## Design Notes

- **SPI**: `fastPush` must hold bus/CS and own `flushDone` for the whole frame. At most one DMA transaction may be in flight. Use the ESP-IDF polling transaction API; prepare the alternate buffer while the current transaction is in flight, but start the next only after `spi_device_polling_end` succeeds. Check `spi_device_acquire_bus`, panel setup, `spi_device_polling_start/end` and release results. On an ambiguous completion, record stage/error, disable fast flush and restart rather than touching the panel or reusing DMA buffers.
- **Panel ownership**: `controlWake` uses the same flush-completion barrier as the flush path. Remove the branch that calls `displayOn`/`setBrightness` after a 100 ms timeout. Slow flush total wait is at most 4 s, leaving margin under the 5 s task watchdog. Sleep, brightness and off paths only issue panel commands after taking `flushDone` and must return the token.
- **FIFO**: record raw FIFO count and status before any reset. A capacity-range count with no full/overflow flag and a non-integral XYZ pair is a transient half-pair: wait at most two normal polls and 100 ms from the first anomaly, without reading or integrating a partial frame. Only a complete paired batch passing the existing continuity check may continue integration. Timeout, I2C failure, overflow, saturation or confirmed loss still invalidates the runtime pose. A trusted stop with about 3 s stability restores only the runtime pose; Unknown motion keeps the original-page retry path.

## Acceptance Criteria

- [ ] Host `flush-ownership` covers bus acquisition failure, polling failure/timeout and wake while flush is busy; no next transaction or early ownership release occurs.
- [ ] Host G runtime/recovery covers first/second read half-pair, transient-count recovery, 100 ms timeout, I2C failure and overflow.
- [ ] Existing touch-lock, page switching, G recording and BLE suites pass.
- [ ] Firmware builds with the expected application size and `verifiedApplicationOffset: 0x10000`.
- [ ] Real device: 30 min G page, 30 page/off/wake cycles and 60 min map/music/G parallel run with zero unexpected reboot and zero new crash dumps; record P95 flush time, FIFO fault counts and effective sample rate.
- [ ] Unknown-motion original-page retry and trusted-stop auto recovery are separately reported.
- [ ] No partition/NVS/pairing/installation/record-format changes.

## Test Plan

- Host: extend `firmware/tests/flush-ownership/check.py`; run with the existing firmware test build.
- Host G: extend `GInstrumentRuntimeTest.cpp` and `GInstrumentRecoveryTest.cpp`; run ASAN/UBSAN.
- Regression: touch-lock, page navigation, G recording and BLE suites.
- Build: firmware build with artifact hash/ELF; existing iOS app unchanged.
- Device: pre-flash app image; flash only `0x10000`; 30/30/60-minute gates above; preserve raw logs.

## Known Risks

| Risk | Severity | Mitigation |
|------|----------|-----------|
| SPI bus/panel concurrency; early `flushDone` or CS release | HIGH | One in-flight transaction; single completion barrier; no panel operations without ownership |
| DMA buffer reuse before polling completion | HIGH | Only start next after successful `polling_end`; restart on ambiguous result |
| FIFO half-pair misclassified as loss | MEDIUM | Raw count/status capture; 2-poll/100 ms bounded wait; no partial integration |
| Persistent NVS / installation data corruption | HIGH | Application-only write; preserve pre-flash image; no NVS/partition changes |
| False confidence from host tests | HIGH | Separate host, build and real-device evidence; no software substitute for soak tests |

## Current Status

- **State**: PAUSED — device flashed, long soak deferred by user
- **Last updated**: 2026-11-06
- **Completed items**: contract accepted; SPI fastPush polling; panel ownership; FIFO half-pair wait; host regression; firmware build; pre-flash app0 backup; app-only `0x10000` flash; boot `#GD` shows `lastfifo`/`stage`
- **Blocking issues**: user has no 60-minute window for the 30/60 soak; P95 histogram not instrumented; new-firmware device short tests not rerun

## Next Step

When the user has time: rerun the four short tests on the new firmware, then 30 min G page, 30 page/off/wake cycles and 60 min map/music/G parallel; capture zero reboots/new crash dumps, FIFO fault counts and effective sample rate. P95 must be instrumented or explicitly marked not measured.

## History

| Date | Action | Notes |
|------|--------|-------|
| 2026-11-06 | Created | SPI/FIFO mission from user-provided implementation and acceptance plan |
| 2026-11-06 | Contract drafted | `missions/2026-11-06-spi-flush-crash-and-fifo-transient-contract.md` |
| 2026-11-06 | Contract ACCEPTED | User selected “接受契约并开始实施” |
| 2026-11-06 | Implementation + host/build | SPI/panel/FIFO changes; all host suites pass; firmware app 2c2678… |
| 2026-11-06 | Device flash | pre-flash app0 6c1444…; only app0 0x10000; `Hash of data verified`; boot #GD has new fields |
| 2026-11-06 | Long soak PAUSED | User has no 60-minute window; no 30/60 result, P95 not measured |
