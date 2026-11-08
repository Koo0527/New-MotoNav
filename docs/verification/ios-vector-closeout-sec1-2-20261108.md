# iOS 锁屏巡航矢量链路 · 闭环计划第一、二、三节落地（2026-11-08）

对应《巡航地图锁屏持续补图闭环计划》第一节（诊断扩展）、第二节（矢量链路可靠性
与道路优先）、第三节（巡航滚动缓存）。真机锁屏短测与第四节分级验收**尚未开始**，
本报告只声明：编译通过 + 宿主替身回归通过。

## 第三节：巡航滚动缓存（新增）

| 文件 | 改动 |
| --- | --- |
| `ios/MotoNav/CruiseMapCache.swift`（新） | 巡航成品磁盘块级 LRU：64 MiB 预算、地图块为淘汰单位（base+bld 同块同进同出）；缓存键 = 图源/数据代次/坐标参考(frame 引用点)/块中心/兼容主题组(1-3 语义、4/6-9 普通、5 极简)/质量版本；读取校验魔数+身份+长度（内存索引先判 miss，连续定位零磁盘）；正在显示/待交接块 setPins 固定不淘汰；无可淘汰空间或磁盘可用 <32MB 跳过写入并出 `cruise-cache-skip` 事件（reason=budget-pinned\|disk\|write\|corrupt），绝不抛错阻断道路交付；原子写+排除备份+completeFileProtectionUntilFirstUnlock；读会推新 LRU 位；独立目录（Application Support/cruise-maps），不动导航离线 512MB 层 |
| `ios/MotoNav/VectorTiles.swift` | 新增 `VectorTileDiskStore`：原始瓦片压缩响应磁盘层，48 MiB LRU（键=数据代次/z/x/y，代次隔离天然失效）；`VectorTileClient` 增加 `tileDiskDirectory` 注入，内存 miss → 磁盘命中（解压+回填内存+`origin=disk` 事件，零网络）→ 网络；网络成功后原始响应落盘；损坏文件（魔数/长度不符）即删走网络；索引重启重建（文件名 `_`↔`/` 恢复键） |
| `ios/MotoNav/MapFeeder.swift` | ①`vectorTiles` 初始化闭包增加 tiles 磁盘目录；②矢量缓存读改双层：`cruiseOrLegacyPacket`（巡航缓存优先→旧 512MB 层回退，旧层命中且有效即异步按需导入巡航缓存，不批量迁移），useCachedMap 与 fetchChunk 两处接入；③矢量 worker 分支：底图 onRoadsReady 与建筑包在旧层 store 之外并行落巡航缓存（不受 512MB 满额路径限制）；④`refreshCruisePins()`：acceptChunk 换块时更新固定块（当前显示块+待交接块） |
| `ios/tests/cruise-cache/`（新） | 22 项离线回归 |
| `ios/tests/vector-reliability/main.swift` | 新增 10 项瓦片磁盘层用例（51 项总计） |
| 三 harness run.py + building-delivery | 编译清单/桩适配 CruiseMapCache 与 refreshCruisePins（断言未动；TestEnvironment 隔离磁盘根） |

### cruise-cache 22 项覆盖

读写往返一致 / 主题组兼容（1↔2↔3 互读，极简不串）/ 代次隔离 / 块中心隔离 /
重启复用 / 超预算持续写入且总量受限（~64MiB）/ 最旧块淘汰 / 块单位淘汰（道路先走，
建筑随后，同块同进同出）/ 无建筑块 nil / 补建筑包可读 / 固定块在最旧位仍存留 /
解除固定后按 LRU 淘汰 / 身份篡改被拒+损坏事件+文件清除+清除后 miss / 主题组映射 /
写失败（根目录不可写）返回 miss 不抛错。

### vector-reliability 新增瓦片磁盘用例（41→51 项）

首次网络下载+落盘 / 内存命中不再下载 / 重启后磁盘瓦片可用且零网络 / `origin=disk`
事件 / 损坏磁盘瓦片被拒后重新下载 / 磁盘瓦片预算受限+最旧修剪。

## 改动清单（第一、二节）

| 文件 | 改动 |
| --- | --- |
| `ios/MotoNav/VectorTiles.swift` | 客户端整段重写：①数据代次 = 模板规范化+version 联合 FNV-1a 散列（同 version 换模板必换代次；缓存键带代次前缀，旧代次结果不写入新代次）；②可注入依赖 `fetch`（返回数据+响应+URLSessionTaskMetrics 来源）/`now`/`bootstrapDirectory`/`onEvent`；③TileJSON 校验（tiles 模板须含 {z}/{x}/{y}）通过才切换并整体失效缓存，成功后原子写引导记录（排除备份+completeFileProtectionUntilFirstUnlock）；④`ensureReady()` 24h 重验，失败保留最后有效模板；⑤同瓦片合并改为"owner 局部标记 + waiters 计数"：取消只在**无等待者**时丢弃（下载前/排队后/完成后三处检查），有等待者必完成共享结果；⑥成功清除该瓦片冷却，冷却表超 512 条剔除过期项；⑦`VectorMetricsCollector` 走 delegate `didFinishCollecting` 采集 metrics（区分 network/cache），不再依赖不可靠的 `task.metrics` 属性；⑧诊断事件 `tilejson`/`tilejson-bootstrap`/`vector-tile`(origin=memory\|network,bytes)/`vector-tile-fail`(reason,code,retryAfter)，瓦片坐标只出 8 位匿名散列 |
| `ios/MotoNav/VectorMapRaster.swift` | 道路优先重排：底图编码+480000 降级链敲定后**立即** `onRoadsReady`（落缓存+上屏），建筑掩码/组合/打包全部后移；`fullGrid` 拷贝移到降级之后（建筑包与已交付底图一致）；新增 `stageProbe`（roads-encoded/buildings-encoded）供回归断言次序；`fetchTile` 传入块级 `shouldCancel` |
| `ios/MotoNav/MapFeeder.swift` | ①`vectorTiles` 改为初始化闭包：引导目录 Application Support/OpenFreeMap + onEvent 直通 MapPipelineTrace；②`ensureVectorTiles` 改调 `ensureReady()`（bootstrapLock 保留并发首调串行化）；③矢量分支新增 `vector-fetch-start`（serial,style,buildings,generation）/`vector-roads-ready`（serial,bytes）/`vector-fetch-end`（serial,ms,tiles,tileBytes,roadBytes,buildingBytes,buildingStatus=ok\|none\|dropped\|off,degraded,roadPixels,buildingPixels）；④`view-coverage` 增加 `locIntervalMs`（有效定位间隔），`onLocation` 记录 `lastLocationAt` |
| `ios/MotoNav/MotoNavApp.swift` | 生命周期诊断：`app-lifecycle` 事件覆盖 didEnterBackground/willResignActive/didBecomeActive + **受保护数据** protectedDataWillBecomeUnavailable/DidBecomeAvailable（后台入口之前最近一次锁屏通知据此对齐） |
| `ios/tests/vector-reliability/`（新） | 41 项离线回归（第一、二节交付时；第三节后扩至 51 项，见上） |
| `ios/tests/building-delivery/check.py` | 仅桩适配：细路 agent 未提交的 acceptChunk 改动引用了 mapSource/fineSubmitKey/fineSubmitted/DeferredFine/queueCurrentMapForSend 等符号，桩按生产语义补齐（queueCurrentMapForSend 忠实实现 chunkAcked 复位+ID 递增）；**断言一条未动**；FakeFineRoads.baseDigest 替换与既有 Fake* 同模式 |
| `.github/workflows/release-ios.yml` | `Verify vector feeder background gating` 步骤并入 `vector-reliability/check.py` |

## vector-reliability 第一、二节 41 项覆盖

1. 同瓦片并发合并只下载一次、等待者全部拿到数据、缓存命中不再下载、不同瓦片并发峰值 ≤2（8 项）
2. 取消语义：无等待者取消不发起网络；下载完成后取消丢弃不写缓存（需重新下载）；有等待者时 owner 取消不丢弃共享结果且只执行一次（7 项）
3. 429 Retry-After：rateLimited 抛错、冷却期内直接节流不重发、越过后恰好重试一次、成功后同瓦片冷却清除（6 项）
4. 数据代次：代次非空、首代次下载/缓存命中、**同 version 换模板代次变化**、新代次重新下载、旧代次模板不再使用（5 项）
5. 持久化引导：成功后落盘、新客户端同目录离线加载模板零联网、持久化模板参与瓦片 URL、24h 内不重验、过期触发重验、**刷新失败保留旧模板且继续补图**、网络恢复后重验成功、损坏引导丢弃走联网（11 项）
6. 事件出口：network/memory 命中事件、失败事件带原因与状态码、字节数、代次绑定、8 位匿名散列、字段白名单（无 URL/坐标）（8 项中的白名单覆盖 fetchTypes 数组）
7. 原始响应超 4 MiB 拒绝（1 项）

## 回归结果（本机 2026-11-08）

| 套件 | 结果 |
| --- | --- |
| vector-reliability（新） | 51/51 ✓（离线，含瓦片磁盘层） |
| cruise-cache（新） | 22/22 ✓（离线） |
| vector-map（联网真实 OpenFreeMap） | 27/27 组包有效 ✓ |
| vector-feeder | 15/15 ✓ |
| screenoff-maps | 96 项 ✓ |
| map-source-mode（含细路 ACK staging） | ✓ |
| building-offline / building-delivery（两套） | ✓ |
| reroute-recovery | 1301 项 ✓ |
| fine-roads run + cache（他组，断言未动） | ✓ |
| map-delivery / ble-bulk / map-wire | ✓ |
| iOS 全量 Release（arm64） | **BUILD SUCCEEDED**（含第三节后再编译一次，结果见下指纹更新） |

### 预存损坏（他组未提交改动所致，未修复、不在本任务范围）

- `building-capture/check.py`：`SatelliteRaster.swift` 现引用 `FineRoads`，该 harness 文件清单未含 `FineRoads.swift` → 编译失败。
- `smoothing-cache/check.py`：`RasterProcessing.swift` 现引用 `RoadPalette`，清单未含 `RoadPalette.swift` → 编译失败。

两者均非矢量链路改动引起（本任务未触碰 SatelliteRaster/RasterProcessing）；按"保留其他任务断言不放宽、不覆盖他人未提交改动"约束，留给相应任务自行同步。

## 构建指纹

- **最终**：版本 0.16.0 **Build 28**（本地验证构建，含第三节瓦片磁盘层全量源码；`output/vector-closeout/DerivedData/Build/Products/Release-iphoneos/MotoNav.app`，主二进制 SHA-256 前缀 **`bd498dc533c81d26`**，`build-sec3b.log` BUILD SUCCEEDED）
- 中间版（第一节+第二节+第三节初版，无瓦片磁盘层）：SHA-256 前缀 `56542a3b8b1cd6a4`（已被最终版取代，仅存档）
- 源码：HEAD `167f240` + 155 个未提交文件（多 agent 共享工作区；本任务改动见上表）
- 设备 00008130-0004491C1811401C 当前装 **Build 29**（CPU0 任务）：按"版本递增不回退"约束，短测闭环须出新 Build（≥30）覆盖安装，不得装 Build 28

## 诊断事件白名单核对

新增事件字段仅含：serial、style、buildings、generation、bytes/ms/tiles/tileBytes/roadBytes/buildingBytes、buildingStatus、degraded、roadPixels/buildingPixels、locIntervalMs、kmh、origin、tile（8 位散列）、reason/code/retryAfter、fetchTypes（network/cache）、phase。无 Key、无真实坐标、无路线名、无原始地图包。

## 未完成 / 下一步

1. **短测闭环（第一节交付门槛）**：签名 Build 30 已出（见下），待设备空闲后覆盖安装 → 断调试器 → 前台基线 → 锁屏进入 ≥3 个未缓存块，验证后台道路包生成+提交+ACK；建筑按 ok/none/dropped/off 单列。需用户配合手机操作与设备占用协调（设备现装 CPU0 任务 Build 29）。
2. 第四节：真机分级验收（持续 30min/20km、故障恢复、显示覆盖）+ 分析器 + 最终报告。

## 真机现场反馈（用户口述，2026-11-08，Build 29 旧链路）

用户在 Build 29（2026-11-06 共享树构建，含加固前矢量巡航链）上实际锁屏巡航后反馈："锁屏巡航效果很好，能一直刷新地图"。此反馈验证**加固前链路在正常路径下已可锁屏持续补图**（矢量链路方案成立）；本任务三节加固针对的正是其边缘失效模式（重启丢瓦片、512MB 满额、并发重复下载、建筑阻塞道路）。非机器可复算证据，按用户口述记录；正式门槛验证在 Build 30 上进行（见下）。

## 短测候选包：签名 Build 30（2026-11-08）

- `output/vector-closeout/build30/candidate/MotoNav-0.16.0-build30-signed.ipa`，
  SHA256 `9deb04832ebff88d6c98184ab5d55829aec01c678c6045a8a2da61f6add4a972`（47.98 MB）；
- App 与 Share 扩展均 `0.16.0 (30)`，Bundle ID `com.u238zyc.motonav`；
- 签名：`Apple Development: u238zyc@gmail.com (563K9S7RHG)`，Team `H3N5LA55A3`；`codesign --verify --deep` 通过；主二进制 SHA-256 前缀 `b2693085ae84d7d3`；
- 构建：`xcodebuild -workspace ios/MotoNav.xcworkspace -scheme MotoNav -destination generic/platform=iOS -configuration Release -allowProvisioningUpdates DEVELOPMENT_TEAM=H3N5LA55A3 CURRENT_PROJECT_VERSION=30 …`（命令行覆盖构建号，不改共享工程文件；日志 `build30/logs/ios-signed-build30.log`）；
- 源码基线：HEAD `167f240` + 158 个未提交文件（`build30/git-baseline.txt`、`git-diff-stat.txt`）；
- 版本递增合规：设备现装 Build 29，候选 30 > 29，覆盖安装不回退。

## 复现

```
python3 ios/tests/vector-reliability/run.py    # 51 项离线
python3 ios/tests/cruise-cache/run.py         # 22 项离线
python3 ios/tests/vector-feeder/run.py        # 15 项门控
python3 ios/tests/vector-map/check.py         # 27 组联网
python3 ios/tests/screenoff-maps/run.py       # 96 项
```
