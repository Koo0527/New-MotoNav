"""Host checks for the isolated benchmark builder; no CLI, serial or device."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('edge_bench', ROOT / 'scripts/benchmark-map-edges.py')
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def fixture():
    base = bytearray(struct.pack('<HiiHHH', 1, 12345, 67890, 1200, 1200, 2000))
    left = 1200 * 1200
    while left:
        run = min(left, 271)
        base.extend((0xf0, run - 16) if run >= 16 else ((run - 1) << 4,))
        left -= run
    masks = bytearray(75 * 75 * 32)
    masks[0] = 1
    payload = masks + struct.pack('<H', (1 << 11) | 16)
    edge = struct.pack('<4sBBHHHIII', b'EDGE', 1, 0, 1200, 1200, 0, 5625, 1, bench.fnv(payload)) + payload
    return bytes(base), edge


class TestBuilder(unittest.TestCase):
    def test_validation_and_corruption(self):
        base, edge = fixture()
        info = bench.validate_scene(base, edge)
        self.assertEqual(info['metadata'], 5625 * 52 + 2)
        self.assertEqual(info['width'], 1200)
        for b, e in [(base[:-1], edge), (base, edge[:-1]), (base, edge + b'\0'), (base, edge[:20] + b'\0\0\0\0' + edge[24:])]:
            with self.assertRaises(ValueError):
                bench.validate_scene(b, e)
        self.assertEqual(bench.fnv(b'hello'), 0x4f9f2cab)
        # A complete, checksum-valid tail can fit transport while exceeding metadata.
        values = 116000
        masks = bytearray(5625 * 32)
        for bit in range(values):
            masks[bit // 8] |= 1 << (bit % 8)
        payload = masks + struct.pack('<H', (1 << 11) | 16) * values
        oversized = struct.pack('<4sBBHHHIII', b'EDGE', 1, 0, 1200, 1200, 0, 5625, values, bench.fnv(payload)) + payload
        with self.assertRaisesRegex(ValueError, '512 KiB'):
            bench.validate_scene(base, oversized)
        cropped = bytearray(base)
        struct.pack_into('<H', cropped, 10, 1199)
        with self.assertRaisesRegex(ValueError, 'complete original'):
            bench.validate_scene(cropped, edge)

    def test_canonical_sample_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            sample = Path(tmp)
            for name in ('base.bin', 'map.bin', 'prototype.edge', 'diagnostic-oversized.edge'):
                (sample / name).write_bytes(b'fixture')
            self.assertEqual(tuple(p.name for p in bench.sample_files(sample)), ('base.bin', 'prototype.edge'))
            (sample / 'base.bin').unlink()
            with self.assertRaises(ValueError):
                bench.sample_files(sample)

    def test_dict8_codec(self):
        base, plain = fixture()
        payload = plain[24:24 + 5625 * 32] + plain[-2:] + b'\0'
        def encode(data):
            zipped = zlib.compress(data, 9)
            return struct.pack('<4sBBHHHIII', b'EDGE', 1, 1, 1200, 1200, 1, 5625, 1, bench.fnv(zipped)) + zipped
        edge = encode(payload)
        info = bench.validate_scene(base, edge)
        self.assertEqual(info['codec'], 1)
        self.assertEqual(info['metadata'], 5625 * 36 + 3)
        for evil in (payload + b'\0', payload[:-1], payload[:-1] + b'\1', payload[:5625 * 32] + b'\0\0' + payload[-1:]):
            with self.assertRaises(ValueError):
                bench.validate_scene(base, encode(evil))
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / 'MotoNav'
            bench.generate(destination, base, edge, 2)
            runtime = (destination / 'EdgeBenchRuntime.h').read_text()
            self.assertIn('RASTER_EDGE_MAX_BYTES,edgeBenchInflate', runtime)
            self.assertLess(runtime.index('delay(8000);'), runtime.index('EDGE BENCH begin scene='))
            self.assertLess(runtime.index('EDGE BENCH begin scene='), runtime.index('if(!helperTask)'))

    def test_generate_and_isolate(self):
        base, edge = fixture()
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / 'MotoNav'
            bench.generate(destination, base, edge, 1)
            renderer = (destination / 'src/map/RasterRenderer.h').read_text()
            self.assertEqual(renderer.count('if(edges)'), 1)
            self.assertNotIn('rasterEdgeWord(edgeBenchView', renderer)
            self.assertIn('edgeDense[((vi&15)<<4)|(ui&15)]', renderer)
            self.assertIn('edgeBenchLUT.prepare(RM.pal', renderer)
            self.assertIn('MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT', renderer)
            entry = (destination / 'MotoNav.ino').read_text()
            self.assertLess(entry.index('helperInit();'), entry.index('runMapEdgeBenchmark();'))
            self.assertLess(entry.index('runMapEdgeBenchmark();'), entry.index('BLEDevice::init'))
            assets = (destination / 'EdgeBenchAssets.h').read_text()
            self.assertNotIn('12345', assets)
            self.assertIn('PROGMEM', assets)
            encoded = assets.split('edgeBenchCompressed[] PROGMEM = {', 1)[1].split('};', 1)[0]
            data = bytes(int(v.strip(), 16) for v in encoded.split(',') if v.strip())
            self.assertEqual(zlib.decompress(data), base + edge)
            runtime = (destination / 'EdgeBenchRuntime.h').read_text()
            self.assertIn('tinfl_decompressor *>(ps_malloc', runtime)
            self.assertIn('edgeBenchMemory("before-map")', runtime)
            self.assertIn('edgeBenchMemory("before-cache")', runtime)
            self.assertIn('edgeBenchMemory("after-cache")', runtime)
            self.assertIn('baseline=rendered', runtime)
            self.assertIn('parallelRows', (destination / 'EdgeBenchDeviceBenchmark.h').read_text())
            self.assertIn('while(true)', entry)


if __name__ == '__main__':
    unittest.main()
