# Road palette firmware verification

Production target: `firmware/boards/175/MotoNav`, existing 175c.9 version retained.
This work changes no device state and performs no flash, release packaging or commit.
The resumed checkout includes unrelated hygiene commits through `d0ff07d`; host
fixtures were updated to its production AckFifo and PSRAM allocation diagnostic.

## Wire and runtime contract

- Reserved family: custom palette slot 14 = `0x4D4E`, slot 15 high byte = `0x52`.
  Only `0x5201` and `0x5211` are accepted, with 1200×1200 dimensions and 2000 mm.
  Body indices are 0…10; 11…15, invalid/truncated/overflow RLE, trailing semantic
  payload and a roof marker inconsistent with actual 4…7 pixels are rejected.
- `RasterHeader.semantic` survives current-header reconstruction, sliced work,
  front/back publication and roof clearing. The wire palette flag remains intact;
  semantic pixels use theme materials, while generic custom palettes keep the
  original photo colors and night dimming path.
- Carry accepts semantic and ordinary material maps, rejects photo palettes, and
  retains only source 4…7 onto destination 0/2. Destination 8/9/10 remains protected.
  Clearing removes 4…7 from both available maps and preserves semantic identity
  and 8/9/10. Publication clears late semantic roofs while buildings are disabled;
  explicitly disabled ordinary buildings are similarly cleared in that session.
- Non-photo frame palettes populate 8/9/10 even during a semantic-to-ordinary
  handoff, so back-buffer semantic roads retain their colors at the coverage edge.
  The existing packed-nibble sample and coordinate transform are unchanged.
- Actual theme 1 uses black/main and #444448/secondary; theme 2 uses #C6CACA and
  #707A7A; theme 3 uses #388281 and #214648. Existing 45%/75% night dimming applies.
  Other actual themes use ordinary road color. Protected index 10 uses ground.
  Paper-at-night does not accidentally acquire actual theme 3's semantic palette.
- Authenticated capability retries and the existing building capability response
  emit exactly 10 bytes `CAP,MPAL,1`. Authentication/disconnection guards remain.

No EDGE/DENSE/AA metadata, render-buffer allocation, per-pixel semantic branch,
new phone command, or change to G/BOOT/PWR/tunnel/HID behavior was introduced.

## Host evidence

All executed with clang++ C++17, `-O1 -g -fsanitize=address,undefined`:

| Test | Result |
| --- | --- |
| `firmware/tests/raster-road-palette/main.cpp` | PASS actual production validator, decoder, queue, renderer and palette; reserved versions, dimensions, mm, 11…15, roof-bit mismatch, truncated/tail rejection, atomic publication, toggle cancellation, late packets, front/back clearing, semantic/ordinary/photo transitions, real packed pixel samples, six game palettes, paper-night and generic photo night behavior |
| `firmware/tests/raster-road-palette/notifications.cpp` | PASS actual notification function: authenticated 3 retries, capability-response resend, exact payload length and auth/disconnection gates |
| `firmware/tests/raster-smoothing/main.cpp` | PASS existing disabled-prototype RGB/tile/seam, sliced carry, atomic queue and allocation/VCE compatibility checks; smoothing remains disabled in production |
| `firmware/tests/raster-work/main.cpp` | PASS 7,455,483 checks comparing production carry/decode byte-for-byte with historical scalar reference, including odd shifts and padding |
| `firmware/tests/raster-work/receiver.cpp` | PASS 131 receiver checks, now using real AckFifo |
| `firmware/tests/RasterContinuityTest.cpp` | PASS ordinary RLE and retired experimental flag rejection |
| `firmware/tests/GameMapStyleTest.cpp` | PASS |
| `firmware/tests/GameMapPlacementTest.cpp` | PASS |
| `firmware/tests/GameRingPaletteTest.cpp` | PASS |
| `ios/tests/building-continuity/main.cpp` | PASS production decoder fixture, old blink reproduction, six detail/base handoffs, full-size 600m scrolling, clearing and isolation |
| `python3 firmware/tests/raster-work/check_sources.py` | PASS exact production byte parity for relevant firmware and iOS decoder fixture headers |

Compile the new host tests, for example:

```
clang++ -std=c++17 -O1 -g -fsanitize=address,undefined -Wno-unknown-attributes firmware/tests/raster-road-palette/main.cpp -o /tmp/raster-road-palette
/tmp/raster-road-palette
clang++ -std=c++17 -O1 -g -fsanitize=address,undefined firmware/tests/raster-road-palette/notifications.cpp -o /tmp/road-palette-notifications
/tmp/road-palette-notifications
```

`git -c core.whitespace=cr-at-eol diff --check -- firmware ios/tests/building-continuity`
passes. The existing decoder and its byte-exact fixture retain CRLF line endings.

## ESP32 compile-only

Arduino CLI with existing `/private/tmp/motonav-esp32-toolchain/config.yaml`, core
3.3.10, repository libraries, original app3M/16MB/OPI-PSRAM/CDC board settings,
and `-Wl,--wrap=xTaskCreatePinnedToCore`: PASS.

- Build and output: `/private/tmp/motonav-road-palette-compile/`.
- Build log: `/private/tmp/motonav-road-palette-compile.log`.
- Compiler program usage: 1,348,007 bytes / 3,145,728 (42%).
- Static RAM: 118,060 / 327,680 bytes; 209,620 bytes remaining.
- Application image: 1,348,256 bytes, SHA256
  `f5f223b968af4482e3391a82bed47a339117480f1de61ff23cf6e6c86949eca8`.
- Existing SensorLib deprecation pragma remains; no compilation error.

This compile artifact is not a release image. No device timing, heap watermark,
BLE ACK/size/CPU/memory measurement, physical display acceptance or G sampling is
claimed here. Root owns shared real-scene replay, independent review, device
benchmarking, final version selection and delivery.
