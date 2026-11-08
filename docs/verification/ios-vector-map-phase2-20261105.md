# iOS 锁屏巡航替代地图链路 · 阶段二：矢量图源接入现有调度（2026-11-05）

## 结论

阶段二（接现有调度，不做真实后台与圆屏验收）**完成**。普通风格 1-9 的地图数据源切换为 OpenFreeMap 矢量链路（`source==4`），且**前后台统一**：锁屏/后台状态下地图准备（下载 + CPU 栅格化）不再被"SDK 需要前台"的门控拦截。高德原版（风格 0）与卫星图（风格 10）保留旧链路及其后台限制。全部既有宿主回归通过（screenoff 96 项、building-offline、building-delivery、building-progress 等未动断言），新增 vector-feeder 15 项门控回归。

## 改动清单

| 文件 | 改动 |
| --- | --- |
| `ios/MotoNav/MapFeeder.swift` | ①`SRC_VECTOR=4`；②门控拆分：`canCapture`（SDK 渲染，需前台）vs `mayPrepareMaps`（准备地图，矢量源后台允许）；③15 处 `source==3` 条件逐一改判（见下）；④fetchChunk 矢量分支：底图经 `onRoadsReady` 先落缓存先上屏，建筑包随后经 deferredRoofs 在底图确认后升级；⑤`setRenderingAvailable(false)` 对矢量源不再取消在途取图/沿线预下载；⑥`vectorBuilder` 注入缝 + `ensureVectorTiles` TileJSON 一次性引导 |
| `ios/MotoNav/Settings.swift` | 图源跟随风格：`source(forTheme:)`（1-9→4，0/10/11→3），theme 变化与启动时同步；建筑能力广播 `#BC` 扩展到矢量源 |
| `ios/MotoNav/ScreenSettings.swift` | 建筑开关对矢量源可见；说明文字按图源区分（矢量："锁屏巡航继续补图"） |
| `ios/MotoNav/RouteOfflineMaps.swift` | 矢量沿线预下载分支（底图经回调落缓存，建筑包随结果落缓存）；后台门控对矢量源放开；完成判据按 source==4 特判（建筑包存在即完成，无 coverage 语义） |
| `ios/MotoNav/VectorTiles.swift` | 瓦片缓存 FIFO→LRU（命中移到队尾，48 MiB 上限不变，版本失效不变） |
| `ios/tests/vector-feeder/`（新） | 15 项门控回归（见下） |
| 三个既有 harness | 仅增量适配编译（screenoff run.py 增加两个矢量文件；building-offline/building-delivery 增加矢量符号 stub），断言未动 |

## 15 处 source==3 条件的逐项改判

| 位置（改前） | 判定 |
| --- | --- |
| paletteMode / buildingMode / onBuildingCapability | 语义包与建筑对矢量源同样成立（风格 1-3） |
| onLocation 后台取消在途取图 | 改 `mayPrepareMaps`：矢量后台不取消 |
| view-coverage 诊断门 | 扩展到 liveRaster（两源都产出 RASTER 块） |
| needsCoverage / prepareEarly / movement-cancel | 同上：覆盖/预取/取消语义对矢量同样适用 |
| retryBuildings / needsMap 的 paletteMode 项 / 取图总门 / 后台提示 | `canCapture`→`mayPrepareMaps` |
| useCachedMap 充分性判据 / fetchChunk 入口门 | 同上 |
| acceptChunk 空底图防护 | 两源都要求 hasMapContent（防白屏，矢量侧阶段一已断言道路像素下限） |
| outsideView 判定 | 两源一致 |

## vector-feeder 回归覆盖（15 项）

1. 后台 + `renderingAvailable=false`：矢量取图照常派发，SDK 图形零调用，底图上屏（TYPE_RASTER、compact 基图、包校验通过）；
2. 底图确认（ACK）后 deferredRoofs 建筑包升级为当前块；
3. 缓存命名空间：source 4 内可查、不泄漏进 source 3；
4. 切回高德源（mapSource=3）后台：仍零 SDK 调用、零矢量改道、保留"回前台补充"路径（旧行为不回归）；
5. 后台沿线离线预下载对矢量源继续（RouteOfflineMaps pump 不再被前台门挡）。

## 验证状态

- 宿主回归：vector-feeder 15 项 ✓、screenoff-maps 96 项 ✓、building-offline ✓、building-delivery（两套）✓、vector-map 阶段一 27 组包复跑 ✓
- iOS 全量编译：见报告发布时构建状态（后台进行中，结果在交付消息中如实注明）
- CI：release-ios.yml 新增 `Verify vector feeder background gating` 步骤（不联网：vectorBuilder 注入假结果）

## 边界与未验证范围

- **未做真实后台与圆屏连续换图验收**（阶段三/四）：本阶段只在宿主级验证门控语义，未在真机锁屏巡航下验证网络续传、蓝牙连续 ACK；
- 沿线离线预下载的矢量分支沿用现有 `RouteMapPreparationPolicy` 调度与 15 秒重试；瓦片磁盘缓存未做（内存 LRU 48 MiB，App 重启后沿线离线包仍走 RouteMapCache 持久层）；
- 高德原版/卫星图的行为与限制逐字节未动（screenoff 96 项断言即为其回归基线）；
- 矢量链路的圆屏显示效果依赖阶段三真机验收；`vectorBuilder` 注入缝仅供宿主测试，生产实现直连 VectorMapRaster。

## 复现

```
python3 ios/tests/vector-feeder/run.py    # 门控回归（离线）
python3 ios/tests/screenoff-maps/run.py   # 高德链路不回归
python3 ios/tests/vector-map/check.py     # 阶段一生成（联网）
```
