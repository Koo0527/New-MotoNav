# Isolated Swift EDGE geometry prototype

No production caller, cache, transport, Xcode target or device gate is changed.

```sh
python3 ios/tests/edge-geometry/check.py
python3 ios/tests/edge-geometry/real.py output/map-edge-bridge/cached-real
python3 ios/tests/edge-geometry/preview.py /tmp/semantic.raw 1200 1200 /tmp/map-edge --base /tmp/base.bin --theme 1 --scale 1 --rotation 13
```

Input is row-major material bytes (0...7), one byte per 2 m cell. Preview writes
`.edge`, `-nearest.png`, `-edge.png` and a JSON report. Themes 1...3, `--night`,
scale 1...16 and rotation use actual `GameMapStyle::palette` and
`RasterEdgeLUT`, compiled directly from firmware headers. PNG encoding uses
Python standard library. Swift uses system `zlib`; C++ host tools link `-lz`.
No networking, location metadata, device connection or installation is involved.

## Geometry and priority

`MapEdgeGeometry.build(pixels:width:height:basePacketBytes:) -> Data?` emits an
EDGE v1 optional tail; `buildReport` also returns candidate/retained counts,
unique words, interior/rare discarded counts, decoded bytes, complete packet
bytes and a fallback reason. Supply actual base packet size to enforce the
480000-byte complete packet budget. Metadata must fit 512 KiB. Invalid input,
compression failure or either exceeded limit returns `nil`, retaining nearest.

A straight line is fitted to material-transition midpoints in a 3x3 stencil.
The 64-direction normal and 1/16-cell offset must classify all stencil centers
correctly, with <=0.28-cell midpoint residual. Hard corners, nonseparable lines,
three-material junctions, narrow strips and missing border stencils fall back.
Uniform neighborhoods use direct indexing. Other stencils use nine stack bytes,
a material bitmask, building normalization and a 9-bit pattern lookup. The sole
geometric fitter runs once to build 512 immutable entries; no per-edge array,
PCA or trigonometry remains. All 28 ordered material pairs x 512 binary patterns
match the pre-lookup words exactly. Five real maps match the previous encoded
output byte for byte.

Building 4/5 and 6/7 roof/outline pairs form one region at the outer silhouette.
Only background/outline words are emitted there, never on roof centers. Internal
roof/outline edges fit separately. Outer-building stencils containing road (1)
or water (3) fall back on both sides, preserving road/water colors. Mixed
underlying building classes at outer boundaries also fall back. Ground/park
silhouettes and road/water edges away from buildings still receive AA.

## Codec and quality budget

Small maps retain flags=0: masks + compact LE u16 words, reserved header u16=0.
Larger maps (>32768 candidates or uncompressed budget pressure) use flags=1:
header byte 10 is dictionary count (1...256); the entire payload is zlib stream
`masks[tileCount*32] + dictionary[dictCount*LEu16] + indices[valueCount*u8]`.
Header FNV-1a covers compressed wire bytes. Firmware tile metadata is 52 bytes;
flags0 decoded bytes = 52*T+2*N, flags1 = 52*T+N+2*K. Empty compressed maps use
one unused valid dictionary word. Normal/offset/pair encoding remains unchanged.

If compressed metadata needs space, least-frequent exact internal building
words (pairs 4/5 or 6/7) are removed first, preserving nearest roof/outline
materials and all exterior words. Dictionary overflow then removes the least
frequent exact words only if their combined count <=1% of original candidates;
otherwise the whole optional tail falls back. No retained word is approximated.
Ties sort by word, making output deterministic. Complete packet overflow also
falls back. All losses are reported, rather than hidden by changing a limit.

## Verification and current limits

`check.py` compiles optimized Swift preconditions and the real C++ reader with
ASan/UBSan. It checks pre-lookup golden SHA256 values for 14336 decoded pattern
words and the 512 original 0/1 packets. It covers 0/30/45/90 degrees, <=1 m synthetic displacement, hard
corners, courtyard, one-cell neck, multi-material junction, building fill/outline,
tile seams/padding, invalid input, flags0 and flags1, dictionary pruning/refusal,
interior-AA pruning and complete packet budgets. Road/water contact fixtures
check actual production LUT colors for three subpixel positions, themes 1...3,
day/night, footprints 0.5/1/2 and rotations 0/0.37 rad.

`real.py` generates all five cached 1200-square inputs, records three build-only
host timings and their median, enforces base+tail <=480000, then invokes actual
firmware decoder/lookup under ASan/UBSan. Reports live beside fixtures as
`prototype.json`, with a combined `prototype-report.json`. Existing `.edge` files
are retained and must match newly generated temporary output exactly. An optional
second argument names a reference directory containing `cached-01.edge` through
`cached-05.edge`: the real C++ decoder then compares all 7.2 million source-cell
words individually under ASan/UBSan, as well as checking complete packet equality
and recording SHA256. Current five tails:
91307 / 180495 / 178730 / 180996 / 173592 bytes; complete packets:
201618 / 387383 / 408741 / 415217 / 366705 bytes. Internal-AA losses:
0 / 17903 / 60637 / 55403 / 10294; rare-word losses: all zero. Host build medians
after lookup optimization are 18.54 / 24.07 / 25.42 / 25.23 / 23.42 ms in one
three-run check, versus 74.65 / 129.78 / 137.65 / 142.70 / 119.19 ms using the
saved pre-lookup source. Times exclude compiler, I/O and rendering. This does not establish <=10% whole-pipeline CPU overhead or phone
performance. The original pre-sampling geometry cannot be recovered from these
semantic rasters; original 2 m building/4 m base integration remains separate.
