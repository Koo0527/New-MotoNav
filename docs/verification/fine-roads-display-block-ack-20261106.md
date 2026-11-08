# 当前显示块补路与增强包准入修复（2026-11-06）

> 后续修订见 `docs/verification/fine-roads-cache-budget-20261106.md`：宽图缓存后继续补路、ACK 后增强包统一预算准入。本报告保留上一轮基线。

本报告修订上一轮 `fine-roads-mode-split-20261106.md` 中“只在 `node == nil` 的当前块补路”和“增强包只按地图块准入”的实现。图源分工、2 米网格、包上限、BLE 协议、固件兼容和用户缓存身份保持不变。

## 技能

- 修改前调用 `swift-concurrency-pro`：审查 `MapFeeder` 主线程状态、取图 worker 回调、取消和 ACK 时序；worker 跳主线程前只传不可变结果（`delivered`/`fine` 已捕获为 `let`）。
- 收尾前调用 `verification-before-completion`：以本轮实际测试退出码和构建输出为准；Release 构建失败未写成成功。
- 未调用 `esp32-test-plan` / `esp32-ble-gatt`：本轮没有设备、烧录或圆屏串口操作；真机验收 agent 应按计划调用。

## 一、当前显示块可以补路

### 目的参数

`MapFeeder` 新增 `FetchPurpose { case display, prepare }`，`fetchChunk(..., node:purpose:)` 由调度入口显式传递：

- `resetChunk`、`requestMapSample`：`.display`。
- `prepareRoute.onReady`：`.display`（该处的 node 是当前显示目标）。
- `onLocation`：只有 `wanted` 与当前 `node` 坐标不同（选了 `futureNode`）时才 `.prepare`；其余 `.display`。
- 默认参数保留 `.display` 供测试/兼容，但生产调用点均显式标注。

`buildings` 也改用 `purpose == .display && buildingMode && mayCaptureBuildings`，不再把“带路线节点”误当成前方准备。

### 补路条件与复用

`fineAllowed = purpose == .display && !Settings.buildings && (1...3).contains(style) && canCapture && kmh < 60`。

- `purpose == .prepare`（沿线预下载/前方准备）只取宽图。
- 高速或建筑开启不补。
- `RouteMapCache.readFine` 只读当前版本 fine 文件；已有有效增强缓存时 `fineCached=true`，`fetchChunk` 走缓存上屏且不再取近景。
- 只有宽图缓存时，`fineRetry=true` 不提前返回；宽图先 `acceptChunk` 上屏，`AmapSdkRaster` 用该宽图作为 `preparedBase`，只补近景，不重复截宽图。
- `fineAttempted` 以 `frame|source|style|block` 记录本会话同一地图块的尝试；失败也不在每次定位重复取图。`onNaviStart`/`onNaviEnd`/`resetChunk`/`prepareRoute` 路线身份变化时清空。
- 冷缓存时一次取宽图 + 一次近景；宽图缓存时一次近景；增强缓存时零近景。

## 二、统一增强包准入

`deferredFine` 从裸包改为 `DeferredFine`：

```swift
struct DeferredFine {
    let packet: MapHandoffBuffer.Packet
    let chunkId: Int          // 宽底图传输 ID
    let requestSerial: Int    // 取图请求身份
    let epoch: Int            // 路线/会话代次
}
```

规则：

1. 增强结果带有 `fineRoads=true`；若宽图尚未上屏（`!haveChunk` 或不同块），`acceptChunk` 记 `fine-cache-only` 并返回。增强包已在 worker 里写入 fine 缓存，不会占用 `handoff` 槽。
2. 当前块宽图在途（同块、`!chunkAcked`）时暂存 `deferredFine`，记录当前 `chunkId`、`requestSerial`、`fineEpoch`。
3. 当前块宽图已 ACK 时，增强后到直接走同一个 `acceptChunk` 入口发送。
4. ACK 后 `flushPreparedMap` → `flushFineRoads` → `tryUpgradeBuildings`。`flushFineRoads` 先消费等待项，再核对：
   - `wait.chunkId == chunkId`、`wait.requestSerial == requestSerial`、`wait.epoch == fineEpoch`；
   - 当前图源/主题/类型/块中心；
   - `chunkAcked`、`handoff.pending == nil`、`BleLink.isReady`、无 bulk pending；
   - 包 valid / hasMapContent / 风格匹配；
   - 当前车速、视野剩余覆盖时间，并用 `chunkRoadBytes`（当前宽图字节数）作为下一块道路预留，调用 `MapDeliveryPolicy.roofsFit`。
5. 预算不足或前方道路待交付时保留宽图和 fine 缓存，只丢弃本次等待；不占用道路槽。
6. 重复 ACK：等待项已消费，不会二次发送。
7. `prepareRoute` 路线身份替换、`onNaviStart`/`onNaviEnd`、`resetChunk`、换区/切主题/切图源：清空等待项并递增 `fineEpoch`；旧宽图 ACK 即使与新路线共用同一地图块，也不会触发旧路线增强。
8. `fineAttempted` 与等待项分离：尝试记录防止重复截图，等待项只负责传输准入。

## 三、回归与红绿

`ios/tests/map-source-mode/main.swift` 扩展到 15 组场景，并从生产 `onLocation`/`prepareRoute` 入口验证：

| 场景 | 结果 |
| --- | --- |
| 显示块带路线节点、低速关建筑 | 请求补路 |
| `prepare` 前方准备、低速关建筑 | 只取宽图 |
| 高速、建筑开启 | 跳过近景 |
| 只有宽图缓存 | 复用宽图作 `preparedBase`，仍请求近景 |
| 已有 fine 缓存 | 不再取近景（`captures==0`） |
| 增强先到、宽图未 ACK | 暂存 |
| 宽图 ACK 后 | 发送一次；重复 ACK 不重发 |
| 增强后到、宽图已 ACK | 立即发送一次 |
| 慢链路/无速率 | `fine-budget-deferred`，不发送；预算恢复后发送一次 |
| 前方道路 pending | `fine-dropped`，道路优先 |
| 模式/路线身份切换后旧 ACK | 不发送旧增强包 |
| `onLocation` 沿已规划路线进入当前块 | 请求补路 |

红绿：把 `MapFeeder` 临时改成旧条件（`fineAllowed = node == nil`，并移除提前返回的 `!fineRetry`）后运行同一测试，首个失败为：

```
Fatal error: display route block should request fine roads
```

恢复当前实现后 `PASS map source mode, cache isolation, stale callback and fine ACK staging`。

其他回归：

| 检查 | 结果 |
| --- | --- |
| `python3 ios/tests/map-source-mode/run.py` | PASS（含上述场景） |
| `python3 ios/tests/fine-roads/run.py` | PASS |
| `python3 ios/tests/fine-roads/cache.py` | PASS |
| `python3 ios/tests/screenoff-maps/run.py` | PASS 96 |
| `python3 ios/tests/vector-feeder/run.py` | PASS 15 |
| `python3 ios/tests/reroute-recovery/run.py` | PASS 1301 |
| `python3 ios/tests/map-smoothing/check.py` | PASS |
| `swiftc ... ios/tests/maps/main.swift` | `Map processing: 689 checks passed` |
| `swiftc ... ios/tests/map-delivery/main.swift` | PASS |
| `swiftc ... ios/tests/four-styles/main.swift` | PASS |
| `python3 ios/tests/vector-map/check.py` | PASS 27/27 |

## 四、性能与两次发送（宿主）

同一明波样片、`swiftc -O`、9 次中位数：

| 项目 | 基线 | 增强 | 增量 |
| --- | ---: | ---: | ---: |
| 耗时 | 2.25 ms | 9.36 ms | **7.11 ms** |
| classify / merge / encode | — | 2.90 / 3.95 / 2.26 ms | — |
| 峰值 RSS | 约 7.1 MB | 10.1 MB | 约 +3.0 MB |
| 宽底图包 | 58,597 B | — | — |
| 增强包 | — | 60,094 B | +1,497 B |
| 两次发送有效载荷 | 58,597 + 60,094 = **118,691 B** | | |

- 7.11 ms 约为 Build28 明波手机整块 CPU 中位数 43.86 ms 的 16.2%，**10% 目标未通过**（宿主增量与手机整块 scope 不同，仍需真机）。
- +3.0 MB 约为手机峰值 52.36 MB 的 5.7%，但不能替代 App 峰值测量。
- 118,691 B 是有效载荷；BLE 分片头、重试、尾包探测和无线开销未计入。宽图 ACK 与增强包 ACK 未在设备上分别记录。
- 圆屏稳定绘制耗时未测；10% 目标未证明。

## 五、构建

`xcodebuild -scheme MotoNav -configuration Release -sdk iphoneos -derivedDataPath ... CODE_SIGNING_ALLOWED=NO` 本轮再次退出 **65**，失败仍在既有 SwiftUI 文件：

```
RideMapViews.swift:160/161:
external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()';
'/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/bin/swift-plugin-server'
produced malformed response
```

本轮 `FineRoads.swift`、`MapSourceMode.swift`、`MapFeeder.swift`、`AmapSdkRaster.swift`、`RouteMapPlan.swift` 等已进入 Release 的 `SwiftCompile` 编译列表，未出现本轮地图文件的编译错误；因宏插件失败，**未生成 IPA**，不能声称 Release 构建成功。完整日志归档：`output/map-edge-bridge/fine-roads-20261106/release-build.log`。

## 六、仍待验证

1. 真机安装、锁屏巡航跨入未缓存区域、圆屏实屏细路。
2. 低速导航细路上屏、重算后的交接、从巡航切导航再切回。
3. 宽图/增强包各自 ACK、实际累计传输字节、道路先到时间。
4. 手机 CPU、峰值内存、圆屏稳定绘制耗时（10% 目标）。
5. 建筑开启时的细路（当前按计划跳过）。
6. Release 构建需在 SwiftUI 宏插件正常的 Xcode/环境重跑。

## 复现

```sh
python3 ios/tests/map-source-mode/run.py
python3 ios/tests/fine-roads/run.py
python3 ios/tests/fine-roads/cache.py
python3 ios/tests/screenoff-maps/run.py
python3 ios/tests/vector-feeder/run.py
python3 ios/tests/reroute-recovery/run.py
python3 ios/tests/map-smoothing/check.py
python3 ios/tests/vector-map/check.py   # 联网

swiftc -O ios/MotoNav/MapGeo.swift ios/MotoNav/RasterProcessing.swift \
  ios/MotoNav/RoadPalette.swift ios/MotoNav/RouteMapPlan.swift \
  ios/tests/maps/main.swift -o /tmp/motonav-maps && /tmp/motonav-maps
```

`map-source-mode/run.py` 支持 `MOTONAV_FEEDER_OVERRIDE=<旧 MapFeeder 副本>` 做红绿基线；正常路径不设该环境变量。
