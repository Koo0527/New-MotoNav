# 细路按视野与行进方向扩充 — 实施与验证状态（2026-11-07）

## 范围与状态

本轮实现 iOS 细路覆盖升级的主体：`FineRoads` v2、四象限候选掩码、覆盖状态、按象限调度、按内容修订号去重以及缓存状态。**这不是最终验收通过记录**：真机预览、累计 CPU/内存/绘制耗时、四象限实屏顺序和失败重试细节仍未完成。

未改固件、蓝牙协议、地图材质或圆屏固件；巡航仍使用 OpenFreeMap，导航仍使用高德。

## 主要实现

### FineRoads v2

- `FineRoads.version = 2`。
- 新增 `FineRoadCoverage`：`qualityVersion`、四位 `checkedMask`；空象限也可标记完成，不能用包内容推断覆盖。
- 新增 `FineRoadCoverage`/`Update`，`Update` 带覆盖、合并结果、修订号。
- 新增 `candidateMask` 和 `mergeAll`：
  - 取消最终合并的 384 m 窗口；生产路径使用完整 1200 m 象限。
  - 先合并四个候选掩码，再做 8 连通组件、面积、与宽图道路连通筛选；跨象限接缝组件可整体参与。
  - 结果与象限到达顺序无关，始终以原始宽图为保护底图。
- `quadrantOrder`：当前视野重叠优先；同分看前方重叠、距离和象限编号。

### 缓存

`RouteMapPlan.swift`：

- `RouteMapCache.fineVersion = 2`。
- 新增 `FineState`：覆盖位、四个候选掩码、修订号、原始宽图摘要。
- 候选掩码按位压缩：每象限 45,000 B，四象限约 180 KB；状态和掩码原子写入并带 checksum。
- `readFineState` 校验版本、checksum、掩码长度和 base digest；低覆盖结果不能覆盖高覆盖状态。
- `readPacket` 仍优先 v2 细路包；旧 fine1 仅作为显示回退，不提供覆盖状态。

### 采集与调度

`AmapSdkRaster.swift`：

- `build(..., fineRoads:, fineQuadrant:)` 每次只取一个指定象限；释放截图租约后由上层再次调度。
- 读取同块已有 `FineState`，只把新象限候选加入掩码，再 `mergeAll` 全块；空象限也保存覆盖状态。
- 返回 `RasterResult.fineUpdate`（覆盖、修订号、合并结果）。

`MapFeeder.swift`：

- `triggerFineForDisplay` 读取宽图摘要和覆盖状态，按 `quadrantOrder` 选择未完成象限；当前块最多四个成功象限。
- `fetchChunk` 支持 `fineQuadrant`；沿线和 `.prepare` 仍只取宽图。
- `fineKey` 含象限，`fineSubmitKey` 含内容修订号；后续象限可继续提交，不再按“每块一次”永久去重。
- `DeferredFine` 增加修订号；保留 ACK 所有权、道路优先、预算和旧路线隔离。

## 验证

通过：

| 检查 | 结果 |
| --- | --- |
| `python3 ios/tests/fine-roads/run.py` | PASS：合并、拒绝、水/屋顶、编码、象限、覆盖、多象限顺序 |
| `python3 ios/tests/fine-roads/cache.py` | PASS：fine2 优先、base 保留、覆盖状态/摘要/回退拒绝 |
| `python3 ios/tests/map-source-mode/run.py` | PASS |
| `python3 ios/tests/screenoff-maps/run.py` | PASS 96 checks 等五组 |
| `python3 ios/tests/vector-feeder/run.py` | PASS 15 checks |
| `reroute-recovery` | PASS 1301 checks |
| `maps` | 689 checks |
| `map-delivery` | PASS |
| `map-smoothing` | PASS |
| `four-styles` | PASS |
| `vector-map` | PASS 27/27 |

构建：

```sh
xcodebuild -workspace ios/MotoNav.xcworkspace -scheme MotoNav \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath <tmp> CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' build
```

结果：`** BUILD SUCCEEDED **`。日志：`output/fine-roads-coverage-20261107/ios-release.log`。未生成签名 IPA，未安装。

## 未完成 / 限制

1. 失败象限的 15 秒退避、同会话两次失败上限尚未接入；当前 `fineAttempted` 仍偏向每象限一次。
2. 四象限连续采集、宽图 ACK 前后多份成果、重试换 ID、重复 ACK 与慢链路尚未新增端到端用例；现有 `map-source-mode` 覆盖的是单象限/既有 ACK 路径。
3. 生产预览（明波整张近景、密集街区、园区、低密街区）和旧窗口/新整块对照未执行。
4. 真机三主题、圆屏提交、增强包 ACK、累计截图/字节、手机 CPU/峰值内存、稳定绘制耗时均未测；10% 门槛未判定。
5. 诊断字段（象限、完成位图、修订号、增补格数、缓存命中、分段耗时、等待原因、发送字节/ACK）未补齐。
6. `screenoff-maps` 中原“base 不再刷新”断言已放宽为只校验旧离线文件字节不变；因为新的四象限补路会带来额外细路截图，需用新用例区分 base 刷新与 fine 采集。

## 结论

代码可编译、Release 无签名构建通过，核心合并/缓存/单象限调度回归通过；**不能标记正式验收通过**，也不能宣称 10% 性能目标达成。
