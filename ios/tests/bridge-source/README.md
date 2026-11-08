# Bridge source replay (offline)

Run from the repository root with the already installed Python/Pillow and Swift CLI:

```sh
python3 ios/tests/bridge-source/replay.py \
  output/map-edge-bridge/fresh-default/01-dense \
  output/map-edge-bridge/bridge-replay/01-dense \
  --rois ios/tests/bridge-source/01-dense-rois.json
```

Use a new output directory on every invocation. No Xcode build, SDK call, device,
firmware, production edit or additional package is needed. Temporary compilation
reads the current `ios/MotoNav/MapGeo.swift` and changes only the access modifier
of `recoverGrayRoads`; its complete source SHA-256 is in `report.json`. The driver
asserts the stage result equals `classifyAmapBase(style: 1)` byte for byte. This is
not the cleanup/dilation pipeline used outside game styles.

`base.png` is sampled with the exact archived `base.json` integer `columns/rows`.
The BGRA bytes must equal `base-sampled-2m.argb32le` exactly before analysis.
`--tile building-0-off` (or another available OFF tile) instead uses the paired
ON projection, requires the camera's `onProjection == offProjection`, and samples
OFF PNG independently. Paired building ARGB can include ON/masking logic and is
not used as OFF truth. Base and OFF images at different zoom are separate
experiments, never a classification-loss comparison. Camera and source file
hashes are included in the report.

ROI files are JSON arrays. Each entry has a unique `name`, a `rect` in sampled
coordinates `[left, top, rightExclusive, bottomExclusive]`, an optional profile
`["y", row, startX, endExclusiveX]` (or `"x"` for a column), and an interpretation.
A probe has three `samplePoints` and optionally three `sourcePoints`; omitted
source points use the precise production sampling coordinates. The triplet is
manually selected pavement, candidate boundary, pavement. Points must be chosen
from inspected source imagery; this program detects neither bridges nor layers.

The five probe labels describe only this selected RGB/material distinction:

- `source-absent`: candidate source RGB is not distinct from both flank RGBs.
- `resampling-loss`: source distinction exists, selected sampled distinction does not.
- `classification-loss`: sampled distinction exists, classified or recovered triplet loses it.
- `smoothing-loss`: classified and recovered distinction exists, smoothed loses it.
- `retained`: the distinction survives all three stages.

Exact RGB inequality is not evidence of a continuous road separator. Anti-alias,
quantization, background texture and coloured transit lines can produce distinct
RGB too. Always read each probe's interpretation and inspect the crop/profile;
these labels do not imply bridge detection, topology loss or an entire ROI's
classification. An outside outline can lose its colour distinction while a
road-to-ground boundary remains intact. A bridge claim requires continuous source
boundary evidence at that same camera/zoom, not a colour difference alone.

Per ROI: native-resolution `source.png`, sampled RGB, each material image,
nearest-neighbour enlarged stage panel, exact source/sample coordinates and
RGB/material profile CSV, ROI stage material counts and changed-pixel counts.
Global `.idx` files are row-major 0=block, 1=road, 2=park, 3=water. Reports never
invent layer identities. Source crop bounds cover the sampled ROI from its first
to last selected source coordinate. Native source detail between these points is
preserved in the crop.

The script runs five category assertions; the Swift driver checks production
stage equivalence for every supplied image. A successful source replay is not a
device visual acceptance test. Official-style comparison must use separately
recorded real style captures at the same projection/camera before drawing any
conclusion about the candidate asset.

Paired real style captures can be compared without SDK/device access:

```sh
python3 ios/tests/bridge-source/compare.py DEFAULT_SCENE STYLE_SCENE NEW_REPORT.json
```

This records all paired PNG file hashes, decoded RGB changed-pixel counts,
paired camera JSON equality and style request metadata. Asset request metadata
and missing error callbacks do not prove the style became visually active.
`candidate.py REPLAY_DIRECTORY` exports only the manually inspected 04 OFF3
median gray segment; inspect any new source before reusing its trace.
