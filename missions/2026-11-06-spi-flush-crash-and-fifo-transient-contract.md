        # Implementation Contract

        **Date**: 2026-11-06

        ## Change Summary

        Fix the round-display LoadProhibited in spi_bus_lock_bg_exit by replacing the two-in-flight interrupt-queued fastPush transactions with one-in-flight DMA polling owned by flushTask; unify panel ownership; tolerate transient half-pair QMI8658 FIFO counts for at most two polls/100ms before invalidating.

        ## Non-Goals

        - No partition, NVS, pairing, installation-parameter or record-format changes; no iPhone UI/performance work; no pin-map or rotation algorithm changes; no version bump.

        ## Affected Files

        | File | Action | Description |
|------|--------|-------------|
| `firmware/boards/175/MotoNav/src/display/DisplayPipeline.h` | MODIFY | fastPush DMA polling, CS/bus ownership, flushDone on success/failure |
| `firmware/boards/175/MotoNav/src/power/DeviceControlRuntime.h` | MODIFY | wake/panel ownership barrier and 4s slow-flush wait |
| `firmware/boards/175/MotoNav/DeviceInstruments.h` | MODIFY | FIFO raw count/status capture, half-pair wait, bounded invalidation |
| `firmware/tests/flush-ownership/check.py` | MODIFY | bus acquisition failure, transaction timeout, wake busy ownership cases |
| `firmware/tests/GInstrumentRuntimeTest.cpp` | MODIFY | FIFO half-pair/transient count state machine |
| `firmware/tests/GInstrumentRecoveryTest.cpp` | MODIFY | FIFO timeout/overflow invalidation and trusted-stop recovery |
| `missions/2026-11-06-spi-flush-crash-and-fifo-transient.md` | MODIFY | mission status, contract and evidence |


        ## Risk Assessment

        - Concurrency HIGH: flushTask, main loop, SPI host and panel commands share ownership; one in-flight transaction and a single completion barrier required.
- Peripheral HIGH: QSPI display bus, DMA buffers, CS and bus release; no pin changes.
- Memory MEDIUM: two DMA buffers and task stack; no new allocation in ISR.
- Boot LOW: application-only; partition table, NVS, pairing and bootloader untouched.
- Compatibility LOW: A7, GENT, installation parameters and record formats unchanged.

        ## Test Plan

        - [ ] Host flush-ownership: bus acquire failure, polling_end failure/timeout, wake while flush busy, ownership never released early.
- [ ] Host G runtime/recovery: first/second FIFO read sees half-pair, transient count recovers, 100ms timeout, overflow and I2C failure invalidate; trusted stop restores runtime pose.
- [ ] Regression: touch-lock, page switching, G recording and BLE suites.
- [ ] Build: firmware build with artifact hashes/ELF recorded; existing iOS test App unchanged.
- [ ] Device: app-only 0x10000 flash with pre-flash image preserved; 30min G page, 30 page/off/wake cycles, 60min map/music/G parallel, zero reboot/crash, P95 flush and FIFO counters.

        ## Rollback Strategy

        Flash only app0 at 0x10000; preserve the pre-flash app image and matching ELF; revert source changes to the three firmware files/tests; no NVS/partition changes; fastf remains in NVS and can be disabled.

        ## Acceptance Criteria

        - [ ] All tests pass.
        - [ ] No new warnings.
        - [ ] PR prepared with evidence.

        ## Approval

        - [x] Contract reviewed
        - [x] Contract accepted — proceed with implementation (user, 2026-11-06)
