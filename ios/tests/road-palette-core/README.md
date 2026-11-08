# Road palette core regression tests

Run from the repository root with Python 3 and `swiftc` installed. Both modes compile the production `MapGeo.swift`, `RasterProcessing.swift`, and `RoadPalette.swift`; the tests do not duplicate the classifier or codec.

## Portable suite (default / CI)

```sh
python3 ios/tests/road-palette-core/check.py
```

Requires no files under `output/`. Checks synthetic protocol packets, legacy/custom palette compatibility, capability conversions, invalid packets, roof carry/paint protection, white-road and flat warm-pavement controls. A bundled 676-byte native AMap crop checks the orange / observed casing / yellow classification as 8 / 10 / 9 at relative positions (7,6) / (6,6) / (5,6).

`fixtures/mingbo-native-road-13x13.argb32le` is a 13×13 crop of the previously frozen Mingbo 2 m sampled source, centered on its existing casing probe. It retains the original pixel colours and relative layout; it contains no geographic coordinates. Pixel storage is little-endian UInt32 ARGB (`BGRA` bytes). SHA-256: `adf822dbd7e7777516905bef99ad66915758ac2628a61f450bf77b524752d0f8`.

A portable PASS does not claim the six-scene regression ran. The output explicitly says the real corpus was not requested.

## Local six-scene corpus (explicit)

```sh
python3 ios/tests/road-palette-core/check.py --real-corpus
```

Runs the portable suite, then requires the gitignored corpus under `output/map-edge-bridge/`. All six `base-sampled-2m.argb32le` files must exist: `fresh-mingbo/06-mingbo` and `fresh-default-five/{01-dense,02-low-density,03-diagonal,04-interchange,05-waterfront}`. Mingbo also requires its four `building-{0,1,2,3}-sampled-2m.argb32le` files, `road-tones-prototype/06-mingbo/offline-palette-slots.idx`, and `source-casing-prototype/06-mingbo/local-mask.idx`.

This mode compares the frozen Mingbo classification pixel by pixel, checks its 8/10/9 probes and building-overwrite protection, and validates packet size/encoding for all six scenes. Only this mode prints `PASS real-corpus ... 6 / 6 scenes`. Missing, unreadable, or incorrectly sized fixtures fail with the required path; no scene is silently skipped.

An optional directory argument selects another corpus root. For example, the following must fail with `FAIL: required fixture missing or unreadable:` when the directory is empty:

```sh
python3 ios/tests/road-palette-core/check.py --real-corpus /tmp/empty-road-palette-corpus
```

These are host tests. They do not measure phone CPU, BLE ACK timing, or device rendering.

`fixtures/multitone-40.argb32le` and `multitone-40.expected.idx` are portable synthetic source and expected labels. The expected labels were generated offline from the baseline classifier and the preview's independent Pillow 3×3 min/max and two snapshot-vote passes; this input includes stable cores, propagation in both rounds, and unsupported fallback. The check excludes the three-pixel outer border. With `--real-corpus`, Mingbo and Shanghai warm pixels are also compared to the corresponding right-hand preview gold within that border; all six scenes are validated as packets.

The portable suite also classifies two offset windows from one synthetic image with ordinary background and three warm road tones. It compares every pixel in their common area after excluding each window's outer three pixels, and requires the common area to contain labels 8, 9 and 11.
