"""Frozen fixture validation only; never generates or accesses a device."""
from pathlib import Path
import json
import zlib
from dense_builder import validate_dense

root=Path(__file__).resolve().parents[3]
directory=root/'output/map-edge-bridge/dense-feasibility'
hashes=json.loads((directory/'C-raw-sha256.json').read_text())
assert len(hashes)==7
for name,sha in hashes.items():
    raw=(directory/name).read_bytes()
    packed=(directory/name).with_suffix('.rle.zlib').read_bytes()
    validate_dense(b'',raw,packed,sha)
    bad=[(b'',raw[:-1],packed,sha),(b'',raw,packed,'0'*64),
         (b'',raw,packed+b'X',sha),(b'',raw,packed[:-1],sha),
         (b'',raw,zlib.compress(b'\0'*4),sha),
         (b'',raw,zlib.compress(b'\x01\0\xff\xff'),sha),
         (b'',raw,zlib.compress(b'X'),sha),(b'X'*480000,raw,packed,sha)]
    for args in bad:
        try:
            validate_dense(*args)
        except (ValueError,zlib.error):
            continue
        raise AssertionError('bad input accepted')
print('DENSE BUILDER: 7 frozen scenes + 56 corruption/budget rejections PASS')
