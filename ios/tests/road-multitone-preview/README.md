# B: source pavement tone preservation (offline)

Run from the repository with `python3 ios/tests/road-multitone-preview/run.py`. Requires existing Pillow, Swift and C++; no new dependency. Outputs: `output/map-edge-bridge/road-multitone-preview/`. No production files, caches, wire packets or devices are written. The `.idx` candidate is an experimental array, not a supported production packet.

The experiment reads the actual 1200×1200, 2 m/pixel ARGB32 source for Mingbo and Shanghai 04-interchange. It reuses production `building.idx`: only existing warm-road indices 8/9 are eligible; ordinary roads 1, protected native casing 10, roofs, water, parks and ground remain exactly unchanged. Source hashes must match the QA manifest, and freshly compiled production Swift classification must equal every pixel of `roads.idx` before the experiment can complete. This verifies existing geometry without changing production.

## Method and scope

There are three separated warm pavement color populations in the source: orange, yellow and pale yellow. A core pixel requires a 3×3 entirely eligible neighborhood and max-minus-min ≤12 for every RGB channel. This tolerance keeps the existing 247/255 red, 231/235 green etc. RGB565 sampling variants together. Stable luminance (`0.30R + 0.59G + 0.11B`) is assigned using boundaries 214 and 226. Only measured core labels propagate to at least three agreeing neighbors, for at most two 2 m sampled pixels, inside the existing warm-road mask. Pixels without this support retain production 8/9. No geometry is grown, and no bridge outline is invented.

Ordinary roads plus these three warm populations give **four source color categories**, not four levels of road elevation. A fifth category would split small color/quantization variations inside an existing family in this corpus; there is no demonstrated fifth stable pavement population. Shanghai lacks a stable orange core; it therefore has fewer useful categories than Mingbo. The CSV lists every retained core color and frequency so this can be inspected directly.

These populations might represent road classes or SDK styling of a bridge/shadow. A single rendered frame has no layer identity, road ID or elevation labels, so this experiment cannot distinguish those meanings, infer a height, or prove topology. The extra pale family is a real broad pavement region in the input, not a line reconstructed from assumed height. Small edge/noise colors do not create additional families. Stability here means spatial coherence within one frame, not temporal stability across camera movements.

The candidate uses source luminance order *inside warm roads*: dark orange-family output, middle yellow-family output, lighter pale-family output. Each game theme gets three quantized theme-colored values; existing ordinary road color stays fixed. This is a proposed palette, and warm tone order differs from production's two-hue mapping. Thus visual differences include both the additional family and that deliberate palette choice. Color ordering is not necessarily monotonic between warm roads and ordinary white roads, since the latter retain their existing material theme.

Source and both themed panels are displayed after the same RGB565 packing/expansion. The middle panel uses production semantic indices and the actual `GameMapStyle` palette compiled from its header. It is a flat semantic raster replay: no device framebuffer, route overlay, circular clipping, rotation, firmware shading, or claim of actual display output. Crops are identical across all three columns, enlarged with nearest-neighbor sampling; overview is the same central 424×424 source-pixel window used by prior experiments.

## Results

Mingbo stable cores contain orange luminance 199.49–206.56 (22,125 pixels), yellow 219.20–222.59 (13,830), pale yellow 229.91–233.30 (4,249). Candidate full-mask coverage: ordinary 138,960; orange 30,249; yellow 19,753; pale 6,199 pixels. 4,517 eligible warm pixels lack stable nearby support and retain production classification. This limitation can leave local fallback seams and needs temporal evidence before a production design.

The existing 4-bit RLE model, including the existing 48-byte header/palette, gives Mingbo 148,124 → 148,762 bytes (+638, +0.43%); Shanghai 208,435 → 211,337 (+2,902, +1.39%). The estimator must reproduce the exact current `building.bin` size before reporting a candidate estimate. **No new packet is encoded**. Slot 11 is unused by current supported content but production Swift currently rejects indices above 10; firmware/wire behavior for new slots has not been validated. Keeping 4-bit width alone does not establish compatibility.

`swift-host-timing.json` records four optimized full production classifications per scene on the host. `report.json` records one Python/Pillow additional-tone-stage time per scene (about 1.4 seconds for 1.44 million pixels). The former includes the production classifier and smoothing, while the latter starts from the already computed masks. These are different languages and different work scopes: **no direct speed ratio, iPhone estimate, or ESP32 timing follows from them**. A native implementation and device measurements would be required to assess practical latency.

Assertions check source/mask sizes, production hashes and exact Swift replay, untouched non-warm semantics/casing, supported experimental index bounds, stable support for every new slot-11 pixel, four distinct RGB565 display colors in all six palettes, exact baseline RLE size, RLE boundary cases and unchanged ordinary-junction negative crops. Production source hashes are rechecked at the end. Existing working-tree changes belong to other work and are not edited here.

## Review images

For each scene, `t{1,2,3}-n{0,1}-{overview,core,...}-comparison.png` has source / production / candidate columns. Theme 1 is VC, 2 GTA5, 3 Cyber. `source-rgb565.png`, full production and candidate PNGs, experimental indices, stable color CSVs and JSON reports are retained alongside these images.

Start with Mingbo `t2-n0-core-comparison.png` and `t2-n0-overview-comparison.png`. Inspect `t2-n0-ordinary-junction-comparison.png` and Shanghai `t2-n0-ordinary-negative-comparison.png` for unchanged ordinary-road negatives. All three themes and day/night variants are generated by the same run.

The GTA5 day control `t2-n0-core-control-comparison.png` shows production / same candidate indices with unchanged production colors 8 and 9 plus new 11=#9AA4A4 / full source-luminance remap. This separates the extra category from changing warm brightness order. `changedPixels` counts index changes only; `displayChangedPixels` counts every actual per-theme RGB565 display-color change, and is larger when existing categories are recolored. The control still uses the same proposed indices, including small 8↔9 revisions from coherent cores.
