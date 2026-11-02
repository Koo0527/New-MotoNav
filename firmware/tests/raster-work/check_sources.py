from pathlib import Path

root=Path(__file__).resolve().parents[2]
fixture=Path(__file__).parent/'fixture'
production=root/'boards/175/MotoNav'
for name in ['RasterContinuity.h','RasterBuildingCarry.h','RasterSmoothing.h','RasterWork.h','src/map/RasterWorkQueue.h','src/protocol/BulkReceiver.h']:
    assert (fixture/name).read_bytes()==(production/name).read_bytes(),name
print('PASS incremental raster tests use exact public production headers')

ios_fixture=root.parent/'ios/tests/building-continuity/fixture'
for name in ['RasterContinuity.h','RasterBuildingCarry.h','RasterSmoothing.h','src/map/RasterDecoder.h']:
    assert (ios_fixture/name).read_bytes()==(production/name).read_bytes(),name
print('PASS iOS building-continuity decoder fixture byte parity')
