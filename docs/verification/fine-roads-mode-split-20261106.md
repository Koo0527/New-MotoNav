# 圆屏图源按巡航/导航拆分、细路交付与增强包 ACK 修复（2026-11-06）

> 后续修正见 `docs/verification/fine-roads-display-block-ack-20261106.md`：当前显示块可带路线节点补路，增强包增加传输 ID/请求身份/路线代次准入。本报告保留上一轮基线。

## 结论

本轮在现有实现上完成三项收窄，不改 2 米网格、480,000 B 包上限、BLE 协议、固件兼容性和用户离线缓存身份：

1. **图源按会话切换**：巡航时普通主题 1–9 使用 OpenFreeMap（亮屏/锁屏同一条链路）；开始导航后普通主题 1–9 使用高德。高德原版(0)、卫星图(10)继续高德；龙珠雷达(11)沿用无需底图。模式只控制圆屏底图和地图预下载，算路、路线线条、定位、转向和车道提示仍由原导航链路提供。
2. **增强包 ACK 修复**：宽底图在途时，同块细路增强包不再被 `base-kept-inflight` 丢弃，而是暂存为 `deferredFine`；底图 ACK 后先让前方道路，再按模式/主题/图源/地图块/预算检查发送一次。
3. **两条链路细路验收**：导航低速、关闭建筑时从正常取图入口触发一次局部近景补路；巡航矢量链路 27/27 包通过，明波和上海世纪公园四主题预览见下。极简黑白一格宽道路修复保留。

**未完成**：没有安装到设备、没有圆屏实屏、没有真实 BLE ACK/时序和手机 CPU/峰值内存/稳定绘制测量。iOS Release 无签名构建被本机 Xcode 27.2 的 `SwiftUIMacros.StateMacro` 插件错误阻塞，未生成 IPA（见“构建”）。

## 分支与工作区

- 分支：`codex/map-edge-bridge`。
- 工作区保留此前未提交的固件、矢量、G、Wire、细路等改动；本轮只在其上增量修改，没有 commit、push、清理或回退其他 agent 的改动。
- 测试使用隔离缓存；`RouteMapCache` 的文件路径保留 source/style/frame 身份，细路增强文件使用 `-fine1` 版本后缀。

## 一、巡航/导航图源策略

### 规则

| 主题 | 巡航 | 导航 |
| --- | --- | --- |
| 1–9（罪恶都市/GTA5/赛博朋克/纸地图/极简/蓝图/掌机/雷达/罗盘） | OpenFreeMap (`source=4`) | 高德 (`source=3`) |
| 0 高德原版 | 高德 | 高德 |
| 10 卫星图 | 高德 | 高德 |
| 11 龙珠雷达 | 无底图 | 无底图 |

纯策略在 `ios/MotoNav/MapSourceMode.swift`：

```swift
static func source(theme: Int, navigating: Bool) -> Int {
    (1...9).contains(theme) && !navigating ? vector : amap
}
```

### 入口

`Settings.navigationActive` + `Settings.setNavigationActive(_:)` 驱动 `mapSource`；`mapSource` 变化通过现有 `didSet` 调用 `MapFeeder.resetChunk()`，取消在途取图、清理当前块并按新图源重建/关闭沿线预下载。

`MapFeeder` 提供：

- `beginCruise()`：设 navigationActive=false，普通主题回到矢量，`onNaviStart()`。
- `beginNavigation()`：设 navigationActive=true，普通主题切高德，`onNaviStart()`。
- `endSession()`：先 `onNaviEnd()` 关闭预下载/取消任务，再设 navigationActive=false，回到巡航图源。

调用点：

- 驾车/模拟导航：`NaviBridge.start()` → `beginNavigation()`；`finish()` → `endSession()`。
- 巡航：`NaviBridge.startCruise()` → `beginCruise()`；`endCruiseQuietly()` → `endSession()`。
- 取消规划/引擎切换：`NaviBridge.clearPlan()`、`unbindForEngineSwitch()` → `endSession()`。
- 骑行导航：`RideBridge.start(emulate:)` → `beginNavigation()`；`finish()`/`resetPlan()`/`resetState()` → `endSession()`。
- 网页/摩托路线导航：`WebMotor.start` → `beginNavigation()`；`WebMotor.stop` → `endSession()`。
- `NaviBridge.replan()` 仍先 `onNaviEnd()` 关闭旧预下载；导航真正开始时由 `start()` 切到高德。规划阶段不额外切换，避免巡航→规划→开始的来回抖动。

### 隔离

- 缓存路径已按 source 隔离；同一地点的高德和矢量包互不读取（`map-source-mode` 回归断言）。
- `acceptChunk` 增加当前图源校验：`src != Settings.mapSource` 的迟到回调写入 `map-source-stale` 并丢弃，不能覆盖新模式地图。
- `RouteOfflineMaps` 的 `source` 是创建时捕获；`resetChunk` 的 `reuseOffline` 按 theme/source/buildings 判断，不匹配即关闭，避免旧模式预下载继续写缓存。

## 二、增强包在宽底图等待 ACK 时的修复

原症状：宽底图在途（`haveChunk && !chunkAcked`）时，同块增强包命中 `base-kept-inflight` 直接返回，既没入 handoff，也没在底图 ACK 后发送。

修复：

1. `acceptChunk` 增加 `fineRoads: Bool = false` 参数。命中同块在途条件且 `fineRoads` 为真、字节不同于当前宽图、包有效/有内容/风格匹配时，写入 `deferredFine`，并记录 `fine-staged-inflight`。
2. `onAck` 后的主线程顺序改为：
   `flushPreparedMap()`（前方道路）→ `flushFineRoads()`（增强包）→ `tryUpgradeBuildings()`（建筑）。
3. `flushFineRoads` 重新检查：enabled/theme、source、style、type、地图块中心、`chunkAcked`、`handoff.pending == nil`、链路空闲、包有效/有内容/风格匹配；再用当前 pose 和 `MapDeliveryPolicy.roofsFit` 检查覆盖率预算。通过后调用 `acceptChunk(..., fineRoads: true)` 发送一次。
4. 一次性：发送前清空 `deferredFine`；增强包 ACK 后再次 `flushFineRoads` 不会重发。
5. 淘汰：`onNaviStart`/`onNaviEnd`/`resetChunk`/图源或主题变化/换到不同地图块时清空；前方道路 pending、坐标变化或预算不足时丢弃并记录 `fine-dropped` / `fine-budget-deferred`。
6. 取图失败或没有新增细路时 `fineRoads=false`，保留宽底图；`MapFeeder` 的 `deliveredBase` 去重避免再发同一宽图。

生产 feeder 回归 `ios/tests/map-source-mode/` 覆盖：底图在途暂存、ACK 后发送一次、二次 ACK 不重发、前方道路抢占、模式切换丢弃旧包、旧图源迟到回调、缓存 source 隔离，以及导航低速入口 `fineRoads=true` / 高速 `false`。

## 三、两条链路的细路验收

### 导航：高德局部近景补路

- 触发条件：实时当前块、`includeBuildings == false`（用户关闭建筑）、`kmh < 60`；每块最多一次 600² 无建筑近景（单张，`pairBuildings=false`）。
- 宽底图先 `onBaseReady` 上屏；补路成功才在同块发送增强包。失败/取消/超时/无新增保留宽图。
- 明波同一 1200² 2 米网格、ROI `[740,830,930,1000]`：补入 **2,930** 个道路格，包 **58,597 → 60,094 B（+1,497 B）**。认可样片为 3,120 格、60,113 B（+1,516 B）。
- 生产规则保留样片补路像素的 93.9%；水域、屋顶、既有主路不覆盖。

预览：

- `docs/verification/fine-roads-mingbo-themes.png`：主题 1/2/3 的明波 ROI“宽图 vs 近景补路”3× 对照；第 4 行是极简真实源图的 1 格宽恢复（附近白色道路裁剪，恢复 225 格）。公园 ROI 在极简 mask 中没有白色道路，因此不能在同一 ROI 展示极简差异。
- `docs/verification/fine-roads-comparison.png`：上一轮认可样片的同地点 ROI 对照。
- 主题 1/2/3 的暖色主路仍按各自调色板（VC 深暖、GTA5 亮暖、Cyber 青暖）；补入细路统一为普通道路材质，保持“细路细、主路醒目”。

极简黑白：

- `MapStyles.minimal` 仍使用 `cleanRaster(minRoad:16, fineRoads:true)`；道路按 8 连通计组件，3×3 中保留至少 2 票的原始道路。
- 合成回归：120 格长、1 格宽的水平/垂直/斜线均为 120 个道路像素；短支路保留；3×3 杂点和孤立点删除。
- 明波真实源图：旧 minimal 172,350 个道路像素，新 minimal 174,694；附近白色道路裁剪恢复 225 格。

### 巡航：OpenFreeMap 矢量

- 明波周边 49 个 z14 瓦片：`path 1243 / service 677 / minor 620 / track 68`；现有 `VectorMapRaster` 已按类别绘制，没有改筛选、坐标转换或线宽。
- 上海世纪公园（WGS 31.2185, 121.5480）：4 个瓦片、114,646 B、193,377 道路像素；园区环路、步道、水岸支路可见。
- `docs/verification/fine-roads-park-themes.png`：世纪公园主题 1/2/3/极简，左 600×600、2 米网格裁片，右 480 圆屏比例（`R=212, sc=0.6`）。
- `docs/verification/fine-roads-vector.png`、`docs/verification/fine-roads-vector-park.png`：圆屏比例矢量审计。
- `vector-map` 27/27 包有效；没有把源瓦片缺路误记成分类丢失。

## 回归

| 检查 | 结果 |
| --- | --- |
| `python3 ios/tests/map-source-mode/run.py` | PASS：巡航→导航→巡航、缓存 source 隔离、迟到回调、fine ACK 一次、前方道路抢占、模式切换丢弃、低速/高速 fineRoads |
| `python3 ios/tests/fine-roads/run.py` | PASS：合成细路、水面/屋顶/灰线拒绝、边界、编码、象限 |
| `python3 ios/tests/fine-roads/cache.py` | PASS：fine 文件优先、原宽图保留 |
| `python3 ios/tests/screenoff-maps/run.py` | PASS 96：锁屏、换图、缓存、取消、道路优先、建筑恢复 |
| `python3 ios/tests/vector-feeder/run.py` / `check.py` | PASS 15 |
| `python3 ios/tests/reroute-recovery/run.py` | PASS 1301：重算超时/空结果/失败/取消/迟到结果/几何一致性 |
| `python3 ios/tests/map-smoothing/check.py` | PASS：质量版本断言已更新到当前 v4 |
| `swiftc ... ios/tests/maps/main.swift` | PASS：`Map processing: 689 checks passed` |
| `swiftc ... ios/tests/map-delivery/main.swift` | PASS：道路优先、缓存、转弯/高速/建筑门控 |
| `swiftc ... ios/tests/four-styles/main.swift` | PASS：四风格/调色板隔离 + 极简细路 |
| `python3 ios/tests/vector-map/check.py` | PASS 27/27 |
| `swiftc ... ios/tests/building-progress/main.swift` | PASS |
| `swiftc ... ios/tests/map-wire/main.swift` | PASS |

发布工作流 `.github/workflows/release-ios.yml`：

- 5 条 `swiftc` 测试命令补齐 `ios/MotoNav/RoadPalette.swift`（map-wire、building-progress、maps、four-styles、map-delivery）。
- 新增 `Verify cruise/navigation source split and fine roads` 步骤，运行 `map-source-mode`、`fine-roads`、`fine-roads/cache`。
- `ios/tests/maps/main.swift` 缓存代次路径更新为 `materials-v4-game`；旧 `styles-v3-1` 回退保留测试。
- `ios/tests/reroute-recovery/Stubs.swift` 的 `MapFeeder` 桩补齐 `beginCruise/beginNavigation/endSession`。

## 性能与包体（Mac 宿主，非手机）

同一明波样片、`swiftc -O`、9 次中位数：

| 项目 | 基线（只编码宽图） | 增强（分类+合并+再编码） | 增量 |
| --- | ---: | ---: | ---: |
| 耗时 | 2.25 ms | 9.36 ms | **7.11 ms** |
| 其中 classify / merge / encode | — | 2.90 / 3.95 / 2.26 ms | — |
| 进程峰值 RSS | 约 7.1 MB（上一轮单独 baseline 运行） | 10.1 MB | 约 **+3.0 MB** |
| 宽底图包 | 58,597 B | — | — |
| 增强包 | — | 60,094 B | +1,497 B |
| 两次发送有效载荷 | 58,597 + 60,094 = **118,691 B** | | |

- 7.11 ms 约为 Build28 明波整块手机 CPU 中位数 43.86 ms 的 **16.2%**；宿主增量与手机整块处理 scope 不同，**不能宣称 10% 目标通过**。
- 约 3.0 MB 增量约为 Build28 手机峰值 52.36 MB 的 **5.7%**，但这是宿主进程增量，不是 App 峰值，**不能替代手机内存验收**。
- 118,691 B 是两次发送的有效载荷（`paletteVersion=2`、`buildingsSupported=true` 时 `forWire` 不改变包）；BLE 分片头、重试、探测和无线开销未计入，实际累计流量需要真机日志。
- 宽底图 ACK 与增强包 ACK 未在设备上分别记录；宿主回归只验证状态机“ACK 后发送一次”。
- 圆屏稳定绘制耗时、手机 CPU、峰值内存均未测；10% 目标未证明。

## 构建

- 宿主核心类型检查：`FineRoads / MapGeo / RasterProcessing / RoadPalette / RouteMapPlan` 通过。
- iOS Release 无签名构建尝试两种方式：
  1. `xcodebuild -scheme MotoNav -configuration Release -sdk iphoneos -derivedDataPath ... CODE_SIGNING_ALLOWED=NO`
  2. `xcodebuild -target MotoNav -configuration Release -sdk iphoneos SYMROOT/OBJROOT ... CODE_SIGNING_ALLOWED=NO`
- 两次均退出 65，失败在既有 SwiftUI 文件：
  `RideMapViews.swift:160/161`、`ScreenSettings.swift:85/298/299` 报
  `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found ... swift-plugin-server produced malformed response`。
- Release 编译命令已包含本轮 `FineRoads.swift`、`MapSourceMode.swift`、`MapFeeder.swift`、`AmapSdkRaster.swift`、`Settings.swift` 等；没有本轮地图文件的编译错误。**未生成 IPA，不能声称构建成功。**

## 限制与待测

1. 真机安装、锁屏巡航跨入未缓存区域、圆屏实屏。
2. 从巡航切导航再切回巡航的圆屏连续性、换图窗口和跨块衔接。
3. 真实 BLE：宽底图/增强包分别的发送次数、ACK、道路先到时间、实际累计字节。
4. 手机 CPU、峰值内存、圆屏稳定绘制耗时；10% 目标均未验收。
5. 建筑开启时的细路（当前不补，沿用建筑链路）。
6. 极简真实高德截图；当前用合成 1 格宽用例 + 明波真实 minimal 源图验证。
7. Release 构建受本机 Xcode 27.2 宏插件阻塞；需在可正常编译 SwiftUI 宏的 Xcode/环境重跑。
8. 规划阶段（`NaviBridge.replan`）仍保持当前图源，真正 `start()` 时才切到高德；如果要求“规划一开始就切高德”，需要另做入口级调整。

## 复现

```sh
python3 ios/tests/map-source-mode/run.py
python3 ios/tests/fine-roads/run.py
python3 ios/tests/fine-roads/cache.py
python3 ios/tests/screenoff-maps/run.py
python3 ios/tests/vector-feeder/run.py
python3 ios/tests/reroute-recovery/run.py
python3 ios/tests/map-smoothing/check.py
python3 ios/tests/vector-map/check.py          # 联网
python3 ios/tests/fine-roads/theme_preview.py  # 生成两地四主题预览

swiftc -O ios/MotoNav/MapGeo.swift ios/MotoNav/RasterProcessing.swift \
  ios/MotoNav/RoadPalette.swift ios/MotoNav/RouteMapPlan.swift \
  ios/tests/maps/main.swift -o /tmp/motonav-maps && /tmp/motonav-maps

swiftc -O ios/MotoNav/MapGeo.swift ios/MotoNav/RasterProcessing.swift \
  ios/MotoNav/RoadPalette.swift ios/MotoNav/MapStyles.swift \
  ios/MotoNav/RouteMapPlan.swift ios/tests/map-delivery/main.swift \
  -o /tmp/motonav-map-delivery && /tmp/motonav-map-delivery
```

预览：`docs/verification/fine-roads-mingbo-themes.png`、`docs/verification/fine-roads-park-themes.png`、`docs/verification/fine-roads-comparison.png`、`docs/verification/fine-roads-vector.png`、`docs/verification/fine-roads-vector-park.png`。
