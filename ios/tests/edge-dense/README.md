# Host-only dense-cell feasibility

Run `python3 ios/tests/edge-dense/check.py` from the repository root.

Reads five cached semantic IDX scenes and fresh02/fresh03 candidate.raw; preserves original base.bin/candidate.bin full-RLE prefixes for whole-wire-budget accounting. Writes only output/map-edge-bridge/dense-feasibility. probe.cpp builds A/B/C conservative4m/uint16 variants, including C fixed morphological building bands, and checks exact original2m centers. Python independently decodes, checks full legacy RLE equality, roundtrips RLE+zlib, reports material-set refusal categories, geometry/outer-silhouette coverage and bytes.

See generated report.json and README.md for results and limits. No production format, renderer, board activity, or CPU claim.
