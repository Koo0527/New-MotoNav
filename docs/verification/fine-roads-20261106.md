# 圆屏底图细路显示优化：高德局部近景补路、矢量审计与极简修复（2026-11-06）

## 结论

本轮完成了三件事，按验证等级分开表述：

1. **高德链路的局部近景补路已接入源码**。实时当前块、关闭建筑、低于 60 km/h 时，最多取一张 600² 无建筑近景（1200 m 象限），只把与宽图道路连通的浅色细路补到地面/绿地上；主路、材质、水域、屋顶和建筑完成位图都不改。宽底图先上屏，补路完成后再发同块增强包；失败、取消、超时或没有可补细路时保留已可用的宽底图。
2. **明波离线重现已接近用户认可的样片**：同一 2 米网格、同一 ROI 下补入 **2,930** 个道路格，整包 **58,597 → 60,094 B（+1,497 B，+2.56%）**；认可样片为 3,120 格、60,113 B（+1,516 B）。生产规则保留了样片补路像素的 **93.9%**，包体只差 19 B。水域、屋顶、既有主路均未被覆盖。
3. **极简黑白一格宽细路丢失已修复**：120 格长、1 格宽的水平/垂直/斜向白路从 0 恢复为 120 个道路像素；短支路保留；3×3 杂点和孤立点仍被清除。

**矢量链路不需要改绘制逻辑。** OpenFreeMap 明波周边 49 个 z14 瓦片中实际存在 `path 1243 / service 677 / minor 620 / track 68` 等要素；现有 `VectorMapRaster` 已按类别绘制，明波同地点底图能看到园区支路和步道。27/27 矢量地图包回归通过。因此本轮只记录覆盖情况，没有改类别筛选、坐标转换或线宽。

**未完成、不能据此宣称的部分**：没有重新构建出可安装的 App（见“构建”），没有安装到设备，没有圆屏实屏观察，没有 BLE 发送次数/ACK/道路先到时间，也没有手机 CPU 和峰值内存实测。补路在建筑开启时不执行；跨块连续性、极简真实截图和矢量链路真机效果仍待验证。

## 输入与对照口径

- 实机基线：`docs/verification/road-multitone-device-20261104.md`（Build28 / 175c.16）。
- 明波归档：`output/map-edge-bridge/fresh-mingbo/06-mingbo/`（base + 4 张 building-*-off，1200²、2 m/格）。
- 认可样片：`/var/folders/9r/w54jr4gn0hnf3s4z7xctwh6c0000gn/T/motonav-fine-roads-y2xptcrn/`（临时）。失效时用归档的 `base.png`、`building-*-off.png` 和投影重新采样：
  `python3 ios/tests/bridge-source/near_mosaic.py output/map-edge-bridge/fresh-mingbo/06-mingbo <新目录>`。
- 对照区域（1200×1200 网格）：`x=[740,930)`、`y=[830,1000)`，位于右下象限（生产单次近景可选到的同一象限）。
- 样片合成规则：只把近景道路材质 1 补到宽图地面 0/绿地 2；本轮生产规则在此基础上增加白度、连通、面积、窗口和材质保护。

## 数据审计：三处细路分别在哪里丢失

### 1. 高德宽图与近景（明波）

- 宽图在 ROI 内补路前有 **0** 个道路像素；近景同 ROI 有 **3,120** 个道路像素。细路不是 iOS 分类丢失，而是宽图（z15.64）源数据本身没有这些园区支路。
- 近景 z17.47 的无建筑图能看到并分类出这些线；ROI 内近景道路颜色以纯白为主（1,804/3,120 为 255），另有 240–254 的抗锯齿边缘。深灰楼边、场地线在 `classifyFineRoads` 的白度阈值以下，不进入候选。
- ROI 内有 71 个近景道路像素落在宽图水域材质 3 上；生产合成不覆盖水域，因此这 71 个不会被补入。
- 结论：**高德宽图缺的是源数据覆盖**，局部近景补路是对现有宽图的增量，不改变算路。

### 2. OpenFreeMap 矢量瓦片（同地点）

- 扫描明波周边 49 个 z14 瓦片，`transportation` 图层类别计数：`path 1243、primary 1241、secondary 1021、tertiary 784、service 677、minor 620、motorway 338、trunk 317、track 68`。细路要素确实存在。
- 用同一坐标链（瓦片 → WGS84 → GCJ → 帧米 → 像素）生成 1200²、风格 2 底图：4 个瓦片、93,148 B、180,368 个道路像素；同地点图中能看到园区支路、水岸步道和主路分级。
- 因此没有修改 `VectorMapRaster.RoadKind.from`、`widthPx` 或 `zoom`。矢量的 `path` 仍为 3 m、`minor/service` 为 6 m，主路 8–16 m；这与“细路较细、主路醒目”的目标一致。
- 第二处公开园区：上海世纪公园（WGS 31.2185, 121.5480）用同一代码生成 4 个瓦片、114,646 B、193,377 个道路像素；园区内部环路、步道、水岸支路都显示为细线，主路保持暖色宽线。圆屏 0.6 px/m 比例下仍连续可见。
- 审计图：`docs/verification/fine-roads-vector.png`（明波）、`docs/verification/fine-roads-vector-park.png`（世纪公园），均为 1200² → 圆屏 0.6 px/m 比例裁剪到 480。

### 3. 极简黑白的一格宽路

复现：1200²、背景 238、水平/垂直/斜向 120 格长、1 格宽白线。旧 `MapStyles.minimal` 输出均为 0 个道路像素，原因有两层：

- `cleanRaster` 的 4 连通组件会把一格宽斜线拆成单点，面积小于 `minRoad=60`；
- 3×3 多数投票把 1 格宽线（3 票道路、6 票背景）改成背景。

修复只作用于 `MapStyles.minimal`：道路按 8 连通计组件，`minRoad` 降为 16，3×3 中保留至少 2 票的原始道路像素。其他调用方仍用原默认值（4 连通、60、旧投票），行为不变。

## 实现规则

`FineRoads.merge`（`ios/MotoNav/FineRoads.swift`）：

1. 近景候选 = `classifyFineRoads` 的白色道路（亮度 ≥254，与 `classifyPixel` 的白色阈值一致）且源色亮度 ≥230、饱和度 ≤14%。暖色主路、灰色楼边/场地线、水边不进入候选。
2. 近景候选按 8 连通分组；面积 <16 格（约 64 m²）视为杂点。
3. 每个组件必须有一个像素距宽图既有道路（材质 1/8/9/11）≤2 格（4 m），才认为通过出入口/路口接入；否则整组拒绝。
4. 只写窗口内的像素；只覆盖宽图 0/2；写材质 1。窗口为当前视野中心 384 m 见方（`windowHalf=96` 格），裁剪到所选 1200 m 象限。没有视野时取右下象限中心，与认可样片一致。
5. 编码仍为 1200²、2000 mm、语义 RLE；用 `RoadPalette.encode(..., like:)` 保留现有 v1/v2 调色板和屋顶标记；超过 480,000 B 或校验失败则返回 nil，保留宽图。

`AmapSdkRaster.build` 的补路时机：

- 宽底图完成 → `onBaseReady(base)` 先发宽图/落普通缓存；
- 之后执行一次 `takeFine`（600²，`pairBuildings=false`，只拍第一张无建筑图，共用现有截图租约、取消门和 45 s 等待上限）；
- 成功 → 返回增强包（`RasterResult.fineRoads=true`），`MapFeeder` 在同块 `acceptChunk` 发出增强包，并写入独立 fine 缓存；
- 失败/取消/超时/没有可补像素 → 返回原宽图，不阻断道路优先。

触发范围：`MapFeeder.fetchChunk` 只在 `node == nil`（实时当前块）且 `pose.kmh < 60` 时传 `fineRoads: true`。沿线预下载（`RouteOfflineMaps`）、高速块、建筑开启（`includeBuildings=true`）都不补。建筑开启时现有 4 张近景已经覆盖整块，本轮没有复用它们做补路，避免增加建筑路径的内存和 CPU。

缓存：

- 新增 fine 版本维度：`RouteMapCache.fineVersion=1`，文件名为 `x_y-fine1.bin`；读取顺序 fine → 原宽图 → 旧材料版本。
- 原宽图始终保留；删除 fine 文件后回退到原底图（宿主测试断言）。
- 不写建筑完成位图；不改变 `FastBuildings.qualityVersion` 或建筑 patch。

## 改动清单

| 文件 | 改动 |
| --- | --- |
| `ios/MotoNav/FineRoads.swift`（新） | 白度候选、8 连通组件、连通/面积过滤、窗口裁剪、编码校验、象限/窗口选择 |
| `ios/MotoNav/MapGeo.swift` | 新增 `classifyFineRoads`（白色细路掩码 + 现有平滑）；`cleanRaster` 新增可选 `fineRoads` 参数（仅极简使用 8 连通和 2 票保留） |
| `ios/MotoNav/MapStyles.swift` | 极简黑白传 `minRoad:16, fineRoads:true` |
| `ios/MotoNav/AmapSdkRaster.swift` | 新增 `fineRoads` 参数和 `takeFine`；宽图后补路；返回 `fineRoads` 标记 |
| `ios/MotoNav/AmapCaptureHost.swift` | `capture(..., pairBuildings:)`；补路只拍第一张无建筑图，默认仍双拍 |
| `ios/MotoNav/MapFeeder.swift` | 低速实时块传 `fineRoads`；最终缓存按 `fine` 版本写入；记录 `deliveredBase`，补路失败或无新增时不重复发送已上屏的同一宽图 |
| `ios/MotoNav/RouteMapPlan.swift` | `RouteMapCache.fineVersion`；`file/read/store` 支持 fine 文件名；读取优先 fine |
| `ios/MotoNav/SatelliteRaster.swift` | `RasterResult.fineRoads` 默认 false |
| `ios/MotoNav.xcodeproj/project.pbxproj` | 登记 `FineRoads.swift` |
| `ios/tests/fine-roads/`（新） | 合并/拒绝/水域/屋顶/边界/编码/象限回归、缓存版本回归、样片准备/重放/渲染/报告脚本 |
| `ios/tests/four-styles/main.swift` | 新增极简一格宽水平/垂直/斜向、短支路、杂点、虚线用例 |
| `ios/tests/vector-feeder/Stubs.swift`、`ios/tests/screenoff-maps/Stubs.swift` | 仅给假 `AmapSdkRaster.build` 增加 `fineRoads` 默认参数 |

## 验证结果

| 检查 | 结果 |
| --- | --- |
| `python3 ios/tests/fine-roads/run.py` | PASS：连通支路、孤立场地线、灰楼边、水域、屋顶、小杂点、越界、编码上限、象限 |
| `python3 ios/tests/fine-roads/cache.py` | PASS：fine 文件优先、删除 fine 后原宽图仍可读、版本号一致 |
| `python3 ios/tests/fine-roads/prepare_sample.py` + Swift sample + `render.py` | 样片重放：added 2,930、58,597→60,094 B、RLE 有效 |
| `swiftc ... ios/tests/four-styles/main.swift` | PASS：既有四风格/调色板隔离；极简 120/120/120/≥239/0/0 |
| `python3 ios/tests/vector-feeder/run.py` | PASS 15 项 |
| `python3 ios/tests/screenoff-maps/run.py` | PASS 96 项 |
| `python3 ios/tests/road-palette-core/check.py` | PASS 便携 fixture |
| `python3 ios/tests/vector-map/check.py` | PASS 27/27 包有效（联网；明波审计同一代码） |
| `python3 ios/tests/map-smoothing/check.py` | **既有失败**：测试仍断言 `FastBuildings.qualityVersion==3`，工作树为 4；本轮未改该常量，也未改其清理默认行为 |

## 性能与预算（Mac 宿主，非手机）

同一明波样片、`swiftc -O`、9 次中位数：

| 项目 | 基线（只编码宽图） | 增强（分类+合并+再编码） | 增量 |
| --- | ---: | ---: | ---: |
| 耗时 | 2.15 ms | 8.60 ms | **6.45 ms** |
| 其中分类/合并/编码 | — | 2.95 / 3.59 / 2.15 ms | — |
| 进程峰值 RSS | 7.1 MB | 9.7 MB | **2.6 MB** |
| 地图包 | 58,597 B | 60,094 B | **+1,497 B（+2.56%）** |
| 取图 | 0 次近景 | +1 次 600² 单张无建筑近景 | — |

- 6.45 ms 相当于 Build28 明波手机整块 CPU 中位数 43.86 ms 的 **14.7%**，但两者范围不同（宿主补路增量 vs 手机整块处理），**不能当作 10% 目标已通过**。本轮没有手机测量。
- 2.6 MB 相当于 Build28 手机峰值 52.36 MB 的约 **5.0%**，但这是宿主进程增量，不是 App 峰值；只能作为量级参考。
- 地图包 60,094 B 远低于 480,000 B 上限；建筑开关、主路、水域和原有材质未改。
- 发送：宽图 1 次 + 补路成功后的同块增强包 1 次；补路失败、取消或没有可补像素时，`deliveredBase` 去重会跳过同一宽图的第二次发送。ACK、道路先到时间和增强包延迟未实测。

## 构建

- `swiftc -typecheck FineRoads/MapGeo/RasterProcessing/RoadPalette/RouteMapPlan`：通过。
- `xcodebuild`（arm64 与 x86_64 模拟器）：`FineRoads.swift`、`AmapSdkRaster.swift`、`MapFeeder.swift`、`MapGeo.swift`、`RouteMapPlan.swift`、`AmapCaptureHost.swift` 均完成 `SwiftCompile`，没有本轮文件的编译错误。
- 完整 App 构建未成功：本机 Xcode 27.2 在既有 SwiftUI 文件 `RideMapViews.swift`、`ScreenSettings.swift` 报
  `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found ... swift-plugin-server produced malformed response`。
  这是工具链/宏插件错误，不是本轮地图代码错误；本轮没有生成 IPA、没有改签名或设备配置。

## 剩余限制与待测

1. 设备安装、圆屏实屏观察、三主题/建筑开关回归、跨块和相邻块连续性。
2. 实机 BLE 发送次数、ACK、道路先到时间、增强包晚到窗口；冷缓存与城市道路行驶。
3. 手机 CPU 和峰值内存（当前只有 Mac 宿主增量）；10% 目标未证明。
4. 建筑开启时的细路（当前不补；可复用 4 张近景，但会增加建筑路径开销）。
5. 极简黑白真实高德截图；本轮只用合成白线复现。
6. 矢量链路真机；本轮为宿主 27/27 包 + 明波同地点审计图。
7. Build28 是已安装旧二进制；当前源码普通风格 1–9 已走矢量，高德补路主要覆盖风格 0/10/11 和回退/旧构建路径。本轮没有覆盖设备上的 Build28。

## 复现

```sh
# 纯逻辑与缓存回归
python3 ios/tests/fine-roads/run.py
python3 ios/tests/fine-roads/cache.py

# 明波样片重放（临时样片目录失效时先用 near_mosaic.py 重新采样）
python3 ios/tests/fine-roads/prepare_sample.py
swiftc -O ios/MotoNav/FineRoads.swift ios/MotoNav/MapGeo.swift \
  ios/MotoNav/RasterProcessing.swift ios/MotoNav/RoadPalette.swift \
  ios/tests/fine-roads/sample/main.swift -o /tmp/motonav-fine-sample
/tmp/motonav-fine-sample output/map-edge-bridge/fine-roads-sample \
  output/map-edge-bridge/fine-roads-sample/result
python3 ios/tests/fine-roads/render.py
python3 ios/tests/fine-roads/report.py

# 现有回归
python3 ios/tests/four-styles  # 见文件头的 swiftc 编译方式
python3 ios/tests/vector-feeder/run.py
python3 ios/tests/screenoff-maps/run.py
python3 ios/tests/road-palette-core/check.py
python3 ios/tests/vector-map/check.py   # 联网
```

交付图：`docs/verification/fine-roads-comparison.png`（同地点 ROI 3×，左现有宽图/右补路）、`docs/verification/fine-roads-vector.png`（明波矢量链路圆屏比例）、`docs/verification/fine-roads-vector-park.png`（上海世纪公园矢量链路圆屏比例）。完整数据：`output/map-edge-bridge/fine-roads-20261106/report.json`。
