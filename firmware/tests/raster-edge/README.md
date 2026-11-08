# Raster edge prototype (not enabled by default)

This directory tests the isolated EDGE v1 reader and RGB565 edge sampler. It does
not enable decoding, rendering, transport, or firmware installation.

```sh
c++ -std=c++11 -O2 -Wall -Wextra -Werror firmware/tests/raster-edge/main.cpp -lz -o /tmp/motonav-raster-edge
/tmp/motonav-raster-edge
c++ -std=c++11 -Wall -Wextra -Werror -fsanitize=address,undefined firmware/tests/raster-edge/main.cpp -lz -o /tmp/motonav-raster-edge-sanitized
/tmp/motonav-raster-edge-sanitized
c++ -std=c++11 -Wall -Wextra -Werror -fsanitize=address,undefined firmware/tests/raster-edge/benchmark_driver_test.cpp -o /tmp/motonav-raster-edge-benchmark-driver
/tmp/motonav-raster-edge-benchmark-driver
```

## EDGE v1 tail

All multibyte values are little endian; no native packed C++ structs are read.

| Byte | Value |
|---|---|
| 0..3 | ASCII `EDGE` |
| 4 | version `1` |
| 5 | flags `0` raw words or `1` dict8 + zlib |
| 6..7 | width, matching raster |
| 8..9 | height, matching raster |
| 10..11 | flags0: reserved `0`; flags1: dictCount `1..256` |
| 12..15 | tile count = ceil(width/16) * ceil(height/16) |
| 16..19 | edge value count |
| 20..23 | FNV-1a32 of payload from byte 24 (initial 2166136261, multiply 16777619) |
| 24.. | flags0: raw payload; flags1: zlib-compressed payload |

Flags0 payload is tile-major masks (sixteen u16 rows per tile), then compact
u16 words. Flags1 decompressed payload is the same masks, `dictCount` u16
words, then `valueCount` byte dictionary indices in tile/row/x order. The FNV
always covers the actual wire payload: compressed bytes for flags1. Dictionary
indices must be below dictCount; dictionary words must have valid pairs.
Decompression must consume the complete stream and produce exactly
`tileCount*32 + dictCount*2 + valueCount` bytes, with no trailing data.

Bit x in a row mask marks local column x. No bits may address tile padding.
Each set bit consumes exactly one nonzero word. Pair indexes 1..28 enumerate
(a,b) in lexicographic order for a=0..6, b=a+1..7. Pairs 29..31 are invalid.
A word is `(pair << 11) | (normal << 5) | offset`, normal=0..63,
offset=0..31. Normal n=(cos(normal*2pi/64), sin(normal*2pi/64)), and
n dot (sourcePoint - (cellX+.5,cellY+.5)) - (offset-16)/16 is negative for a,
positive for b. Checksum mismatch rejects the whole optional tail. No mask bit means existing nearest sampling, including complex
junctions and missing source data. Material indexes are never interpolated.

`RasterEdgeView` owns one allocation and cannot be copied. Its destructor and
`rasterEdgeRelease` free it; `rasterEdgeSwap(a,b)` exchanges ownership without allocation (caller must wait for both row workers first). Header, budget and wire checksum are checked before allocation; decompressed contents are fully validated before publication. Failed replacement preserves the old view. Define `RASTER_EDGE_ALLOC` to `ps_malloc`
before including on ESP32 (allocation must be compatible with `free`). The
512 KiB prototype limit counts decoded edge data, both worker caches, the shared
base expansion LUT, and cache contexts. Flags0 retains its 52-byte tile/rank
representation: `52*tileCount + 2*valueCount`. Flags1 retains raw masks, dictionary
and byte indices plus one u32 value base per tile:
`36*tileCount + valueCount + 2*dictCount`. No row ranks are expanded for flags1.
The isolated slow `rasterEdgeWord` computes its row rank for offline checks.

Each worker owns a 64-slot cache of 16x16 dense u16 words, u32 tile tags/ages and
a byte tile-to-slot table: `64*(512+8)+tileCount` bytes. The device build allocates
these complete cache blocks with `MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT`; it never
falls back to PSRAM. A shared 256-entry u32 LUT expands each packed base byte to
two pair-zero material words, then sparse edge dictionary words overwrite the
marked cells. The renderer fetches a dense pointer on source-tile changes and
loads one u16 per pixel; it does not read the original base first. Pair-zero words
store the unchanged base material in bits 5..7. Shape words and all wire blobs
remain unchanged.

Cache preparation and map replacement require the existing two-worker barrier.
Each cache binds the view identity/epoch and caller-supplied source epoch; stale
views/source epochs reject lookups. Workers never share mutable cache state.
Unsupported footprints, stale bindings or failed cache allocation select the
baseline renderer. The diagnostic allocation-failure path explicitly paints the
baseline and reports failure; it does not produce a baseline-versus-baseline pass.
The builder conservatively reserves 256 bytes for the two cache contexts in its
host budget; firmware reports actual `sizeof` contexts. Reader packet
limit is 480000 bytes; integration must also enforce 480000 bytes on the complete
base raster plus optional tail. The owner must keep a published view unchanged
until both row workers finish, and discard pending views on cancellation.

Flags1 requires an explicit `RasterEdgeInflater` callback:
`bool(const uint8_t *input,size_t inputBytes,uint8_t *output,size_t exactOutputBytes)`.
Pass it as the seventh argument to `rasterEdgeDecode`, after the metadata limit.
The callback must honor output bounds and reject truncated or trailing streams and
non-exact output lengths. The header itself has no zlib dependency. Host tests
link system `-lz`; the generated device benchmark uses existing miniz with a
heap inflater. Synchronous decode here remains isolated from the production work
queue; a future queue integration must schedule inflate work separately.

`RasterEdgeLUT` occupies about 19 KiB; keep it off the ESP32 task stack. Call
`prepare(palette[8], 1/(screenScale*rasMpp), sourceRotationRadians)` before row
workers, then `color(word,UQ16,VQ16,nearest)`. Palette changes rebuild RGB565
blend tables; geometry changes update the integer distance gain and angle table.
Coverage uses the existing VCE square/half-plane integral with nine symmetric
angles. Unsupported footprints (outside 1/64..64 source cells/screen pixel) fall
back to nearest. Host dense square integration checks accept two RGB565 blue
levels for angle/distance quantization; this is not an exact analytic renderer.

The host test binary also accepts actual `.edge` files as arguments and prints
codec, decoded metadata bytes, nonzero cell count and FNV over row-major u16 LE
words (including zero cells). This enables independent Swift/C++ cross-checks
without emitting source coordinates.

## Device benchmark preparation

Include `DeviceBenchmark.h` after the production `RasterRenderer.h`, in a
diagnostic build only. Freeze map publication, palette and RM transform, ensure
the normal two-core row worker is running, then call
`rasterEdgeDeviceBenchmark(actualRuntimeEdgeGate, result)` from the main/display
producer context. The referenced gate must be the one read by actual
`rasterRows`; it must be synchronized through the existing row-worker handoff.
The helper calls `parallelRows(rasterRows, ...)` directly and waits for its normal
barrier. It temporarily allocates one full framebuffer in PSRAM, warms both
modes, alternates baseline/edge order for 31 samples each, reports medians and
same-pixel differences, restores the gate and repaints. It rejects pixelated,
satellite, VCE and theme 0 modes. Keep prebuilt LUTs outside the timed region,
as in a normal frame. No fixture, theme or scale may change between paired runs.

Run every real theme 1..3, day/night, straight/diagonal/rotated views, sparse and
dense maps and several zooms. Record complete map bytes and decoded metadata
bytes too. Require each scene's edge median <= baseline median * 1.10; retain
visual pixel diffs to inspect junction fallback and seams. A zero changed-pixel
count on a known slanted edge means the gate/metadata did not exercise the new
path, regardless of timing. The host driver test checks plumbing only. No device
benchmark, serial connection, flashing, or production-default change is performed
by these files.

## Isolated firmware builder

`scripts/benchmark-map-edges.py` copies the sketch into ignored
`output/map-edge-bridge/device-bench/MotoNav` and injects the prototype only there.
Each input directory should contain the canonical `base.bin` RLE packet and
`prototype.edge` tail; these take precedence over diagnostic files. A directory
with exactly one `.bin` and one `.edge` is also accepted. The builder requires the full 1200x1200 grid and checks base+tail
<=480000 bytes and complete decoded metadata <=512 KiB; it does not crop or
truncate a sample to make it fit.

```sh
python3 scripts/benchmark-map-edges.py --self-test
python3 scripts/benchmark-map-edges.py SCENE_A SCENE_B --scene 1 --dry-run
python3 scripts/benchmark-map-edges.py SCENE_A SCENE_B --scene 1 --config-file EXISTING_ARDUINO_CONFIG.yaml
```

Select one sample per build with `--scene 1..N` to stay inside the existing 3 MiB
application partition. Rebuild and retain each selected artifact before selecting
the next scene: the working sketch, manifest and artifacts use one fixed output
directory. Compilation uses the FQBN and flags from `firmware/build.py`, existing
Arduino CLI packages, and installed repository libraries. `--cli`, `--jobs` and
`--config-file` select existing tools; nothing is installed. No upload or serial
command exists in this builder. The unchanged production version string is not
an indication that this diagnostic image is a release image.

The generated firmware initializes the existing row helper, waits eight seconds
for log capture, prints `EDGE BENCH begin scene=...`, then runs 36 paired
cases: themes 1..3, day/night, theta 0/45/90 degrees, scales .38/.6. Both modes use
the actual production `rasterRows` and frozen palette/transform. It uses a heap
`tinfl_decompressor` to inflate zlib PROGMEM assets, checks exact input/output
lengths and whole-asset FNV, then uses the actual raster and edge readers. Logs
contain neutral scene numbers and byte/metadata/timing/diff/budget counts. Source
coordinates and input paths are not emitted in generated diagnostics. Startup
halts after the summary, before BLE initialization. Map publication and user
controls cannot change the source during paired measurements.

`--self-test` generates synthetic format-valid fixtures only for host checks;
such a fixture or compilation smoke check cannot establish a device frame
budget. Use real captured maps for device measurements and visual review.

The microcache diagnostic prints free internal/PSRAM bytes before map decode and
before/after cache allocation. `metadata` in device timing lines is the complete
view + two caches + shared LUT + cache-context total. These measurements run
before BLE for comparison with the previous diagnostic; they do not establish
that a BLE-connected/G-running production build has sufficient internal heap.

## Third diagnostic: exact local tile palettes

This remains an isolated prototype. The root's offline palette probe stores the
exact `(baseMaterial << 16) | shapeWord` keys, packed low indices, and two high
bits where needed. `LocalPalette.h` validates offsets, record sizes, sorted unique
keys, materials, shape pairs and every index before binding a borrowed immutable
view. The storage owner retains low+metadata until both workers stop.

The current bounded cache accepts K<=40 (the five probes have K<=38), rejects
larger palettes without trimming, and uses 36 direct-mapped slots per worker.
Each 232-byte entry contains 40 encoded palette values, 64 high-plane bytes and
tag/kind. Pure entries contain bit31 + current RGB565 color; mixed entries contain
the unchanged shape word. Both cache blocks use internal 8-bit RAM. Metadata,
both complete caches/contexts, the view handle and the shared 19 KiB color/coverage
LUT all count toward 512 KiB. All five host totals are below the cap; cached04
has the smallest remaining margin.

The diagnostic side is zlib(low+metadata), paired with the compact legal RLE
transport base. Combined wire accounting includes 24 bytes of diagnostic header
allowance and remains <=480000. This does not define or enable a production wire
codec. At startup the side inflates directly into the existing back-raster
allocation plus metadata tail, and exact original base material, including roofs,
is restored to the front raster from palette keys. Its full-grid FNV is checked
against the original pixels before any timing. The compact road raster never
serves as the comparison baseline.

The generated `rasterRowsBaseline` body is byte-identical to production
`rasterRows` and git d2f49a7 (SHA recorded in manifest and boot log); only its name
and `noinline` signature differ. `rasterRows` dispatches once to separate noinline
baseline/local-palette functions. There is no runtime gate branch inside either
pixel loop. `drawRasterMap` still prepares the production theme/day/night palette.

```sh
python3 firmware/tests/raster-edge/local_palette_builder_test.py
c++ -std=c++11 -Wall -Wextra -Werror -fsanitize=address,undefined firmware/tests/raster-edge/LocalPaletteTest.cpp -lz -o /tmp/motonav-local-palette
/tmp/motonav-local-palette output/map-edge-bridge/cached-real/cached-0{1,2,3,4,5}
python3 scripts/benchmark-map-edges.py output/map-edge-bridge/cached-real/cached-0{1,2,3,4,5} --scene 3 --local-palette --config-file EXISTING_ARDUINO_CONFIG.yaml
```

Output is isolated in `output/map-edge-bridge/device-bench-palette`; previous
codec/microcache artifacts and timing logs remain untouched. The same 8-second
capture window, 36 paired scenes, 31 samples, full pixel comparisons and memory
logs remain. No firmware is uploaded by the builder. Device timing and later
BLE-connected/G-running memory checks remain necessary; K<=40/36 slots is not a
production format decision.

## Bounded cache/AA stage profile (same local-palette records)

`--local-palette --profile-stages` writes only to
`output/map-edge-bridge/device-bench-palette-profile`. One pair of 37-slot cache
allocations is reused by constant-template 36-slot and 37-slot shaders. It keeps
base-material bits in mixed cached keys so nearest stages can reproduce the full
original base exactly. The wire side, keys and source images remain unchanged.

For theme 1/day at six theta/scale geometries, it runs paired original baseline
versus `nearest36`, `nearest37`, then `fullAA37`. Both nearest stages must have
zero pixel differences. Separate untimed shaders report one steady frame's
cache hits/misses, sampled/high-plane/AA-eligible pixel counts. Timed shaders have
no profiling counters or per-pixel mode branch. The final summary is
`PROFILE_ONLY`: nearest stages and diagnostic timing do not approve an AA path.
All new caches, contexts, color/coverage LUT and diagnostic counters stay within
512 KiB; the builder conservatively includes the counters in its budget.

The decision is bounded: if the corrected nearest representation already exceeds
1.10 times baseline, this representation has no demonstrated AA budget. If
nearest is close enough but AA alone dominates, measure that delta before any
arithmetic optimization. Exact per-word 2D phase color tables exceed the remaining
metadata budget; coarser phase tables require new quality evidence and are not an
approved shortcut.
