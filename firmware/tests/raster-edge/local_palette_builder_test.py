import importlib.util
from pathlib import Path
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[3]
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod
common=load('edge_builder',ROOT/'scripts/benchmark-map-edges.py')
local=load('local_builder',Path(__file__).with_name('local_palette_builder.py'))
class TestLocalBuilder(unittest.TestCase):
 def test_exact_source_and_bounds(self):
  for scene in range(1,6):
   p=ROOT/'output/map-edge-bridge/cached-real'/f'cached-{scene:02d}'
   self.assertLessEqual(local.validate((p/'palette-probe-low.idx').read_bytes(),(p/'palette-probe-meta.bin').read_bytes()),524288)
  sample=ROOT/'output/map-edge-bridge/cached-real/cached-03'
  with tempfile.TemporaryDirectory() as tmp:
   target=Path(tmp)/'MotoNav';info=local.generate(common,target,sample,3)
   self.assertEqual(info['totalBytes'],375573)
   source=(common.SOURCE/'src/map/RasterRenderer.h').read_text()
   original=source[source.index('void __attribute__((optimize("O3"))) rasterRows('):source.index('static inline uint16_t vicePatchColor')]
   rendered=(target/'src/map/RasterRenderer.h').read_text()
   baseline=rendered[rendered.index('void __attribute__((noinline))'):rendered.index('void __attribute__((noinline))',rendered.index('void __attribute__((noinline))')+1)]
   self.assertEqual(original[original.index('{'):],baseline[baseline.index('{'):])
   self.assertNotIn('paletteEnabled',baseline)
   self.assertEqual(rendered.count('if(paletteEnabled &&'),1)
   self.assertIn('MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT',rendered)
   runtime=(target/'EdgeBenchRuntime.h').read_text()
   self.assertIn('base-exact=PASS',runtime)
   self.assertIn('paletteGridFNV',runtime)
   self.assertIn('delay(8000)',runtime)
 def test_profile_has_separate_timed_and_counted_functions(self):
  sample=ROOT/'output/map-edge-bridge/cached-real/cached-03'
  with tempfile.TemporaryDirectory() as tmp:
   target=Path(tmp)/'MotoNav';info=local.generate(common,target,sample,3,profile=True)
   self.assertLessEqual(info['cacheBudgetUpperBound'],524288)
   header=(target/'LocalPalette.h').read_text();self.assertIn('LOCAL_PALETTE_SLOTS=37',header);self.assertIn('tile%Slots',header)
   renderer=(target/'src/map/RasterRenderer.h').read_text()
   self.assertIn('cache.get<36>',renderer);self.assertIn('cache.get<37>',renderer)
   timed=renderer[renderer.index('void __attribute__((noinline))'):renderer.index('void __attribute__((noinline)) __attribute__((optimize("O3"))) rasterRowsCount36')]
   self.assertNotIn('counts.pixels',timed)
   self.assertNotIn('Serial.',timed)
   runtime=(target/'EdgeBenchRuntime.h').read_text()
   self.assertIn('status=PROFILE_ONLY',runtime);self.assertIn('exactNearest=',runtime)
   self.assertIn('themeIdx=1;nightOn=false',runtime)
if __name__=='__main__':unittest.main()
