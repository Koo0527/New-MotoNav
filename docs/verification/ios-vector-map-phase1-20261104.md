# iOS 锁屏巡航替代地图链路 · 阶段一：OpenFreeMap 矢量瓦片 → CPU 生成验证（2026-11-04）

## 结论

阶段一（数据源验证 + CPU 生成，不接正式调度）**通过**。OpenFreeMap 矢量瓦片可在 Mac 宿主（同构 Swift 代码）上完成：TileJSON 解析 → 受约束下载 → gzip 解压 → MVT 严格解码 → 坐标链转换（瓦片局部 → WGS84 → GCJ-02 → 帧米坐标）→ CPU 栅格化 → 现有 RLE 地图包。三城市（北京/上海/广州固定公开样本）× 风格 1-9 共 27 组包全部有效；其中 9 组（风格 1-3）带独立建筑包。

按规格，OpenFreeMap 目前仍只是**已验证候选**，还不是已批准的正式图源；本阶段未接正式调度（阶段二）、未做真实后台与圆屏连续换图验收（阶段三/四）。

## 交付物

| 文件 | 说明 |
| --- | --- |
| `ios/MotoNav/VectorTiles.swift` | 生产：TileJSON 解析（版本号入缓存键）、下载约束（App 标识 UA、≤2 并发、15s 超时、同瓦片合并、原始 ≤4 MiB / 解压 ≤16 MiB、429 遵循 Retry-After、其余失败 15s 冷却、失败不写缓存）、gzip/zlib 流式解压（ISIZE 校验）、MVT 严格解码（varint 10 字节上限、长度限剩余、几何命令与坐标范围校验、要素/点数上限）、进程内 48 MiB FIFO 瓦片缓存（版本变化整体失效；阶段二叠加持久 LRU） |
| `ios/MotoNav/VectorMapRaster.swift` | 生产：z14 瓦片覆盖计算（块四角 GCJ→WGS→瓦片范围）、图源入口一次坐标转换、水面偶奇扫描线填充 + 河道定宽描边、绿地只盖空地、道路按 brunnel/layer 排序描边（桥面压地面、隧道垫底）、建筑全块掩码→边界→只画在地/绿上且不覆盖道路、风格 1-3 直接产 RoadPalette 语义材质（保留道路分色：高速/干道 11、主/次干道 9、其余 1）、风格 5 仅 0/1、其余普通 0-3、480000 字节降级链（语义主路降级→仍超限报错；建筑包超限丢弃保底图） |
| `ios/tests/vector-map/`（main.swift + check.py） | 宿主验证 harness：三城市 × 9 风格生成 + PNG 对照图 + 有效性断言（RasterPacket.valid / MapStyleTransfer.matches / hasMapContent / ≤480000 / 道路像素下限 / 建筑包 9 取 ≥7） |
| `output/vector-map/` | 27 张 base PNG + 9 张建筑 PNG + 27+9 个包文件 + summary.json（机器可复核） |
| CI | `.github/workflows/release-ios.yml` 新增独立步骤 `Verify OpenFreeMap vector map generation`（联网跑同一 check.py） |
| pbxproj | VectorTiles.swift / VectorMapRaster.swift 已登记经典工程（新 ID 6E11F2A1…C1/C2/D1/D2，plutil 校验通过） |

## 验证结果（本机，2026-11-04）

TileJSON `version: 3.16.0`，模板 `https://tiles.openfreemap.org/planet/20261101_080013_pt/{z}/{x}/{y}.pbf`。服务器对 `Accept-Encoding: identity` 返回原始 pbf（未压缩），gzip 路径为兼容保留。

| 城市 | 瓦片数 | base 包 | 道路像素 | 建筑像素 | 建筑包 |
| --- | --- | --- | --- | --- | --- |
| 北京 | 4 | 103705B（风格5：87000B） | 194900 | 294729 | 181056B |
| 上海 | 6 | 113569B（风格5：103082B） | 300771 | 394955 | 227434B |
| 广州 | 4 | 102221B（风格5：93287B） | 230530 | 328636 | 193224B |

- 27/27 组包 `RasterPacket.valid` + `MapStyleTransfer.matches` + `hasMapContent` 全部通过；全部 ≤480000B（最大 113569B，远低于上限，降级链零触发）。
- 风格 1-3 建筑包 9/9 有效且带屋顶标志；风格 4-9 无建筑包（符合规格）。
- 性能：每城市首个风格含真联网下载 5.8–12.5s；命中 48 MiB 内存缓存后同城市其余风格 18–98ms。
- PNG 目视（模型辅助四张代表图 + 本地全量扫描 36 张）：
  - 北京 base：道路网连续成网、长安街/中轴线/胡同网格、故宫护城河与北海/中海水域位置正确、无接缝、无错误色；
  - 北京建筑：footprint+边线成块、沿街对齐、不覆盖道路/水域/公园、故宫与北海内建筑正确留空；
  - 上海 base：不规则密路网 + 放射汇聚、苏州河/黄浦支流水体形状自然、无接缝；
  - 广州 s4（普通 0-3）：道路统一灰色（无类别分色）、越秀公园大块绿地被识别、无接缝；
  - 36 张全量扫描：无整行/整列空白带（无瓦片缺失或接缝空洞）。

## 过程中的发现与修复

- 首次运行 27 组全部报「无已知图层」：MVT Reader 把 protobuf key（field<<3|wire）当 field 号比较。已修（`key >> 3` 取 field），并用独立 python 最小解析器对照真实瓦片确认图层名（transportation/building/water/waterway/landcover/landuse 与 OpenMapTiles schema 一致）。该 bug 属"解码器返回空但看似成功"类型——由"必须产出有效包"的断言拦下，未流入后续阶段。
- 远端瓦片 z14 实测原始 1.9–6 KB/瓦片（未压缩），约束上限余量充足。

## 边界与未验证范围

- 样本仅三城市中心各一点（固定公开坐标）；未测乡村/高速沿线/边缘城市、弱网重试、429 实测（仅代码路径）、长时间运行缓存行为。
- 未接正式调度：`MapFeeder` 仍只走高德 SDK；source==4 的接入、能力协商、离线缓存归属与状态文字属阶段二。
- 未做真实后台与圆屏连续换图验收（阶段三/四）；圆屏协议与固件未动。
- 生成成功 ≠ 圆屏显示成功 ≠ 实车验收（四级验证中，本报告覆盖：编译通过 ✓、宿主/替身测试 ✓；实车验收 ✗）。
- 图源判定：以现有证据，OpenFreeMap 未出现"明显缺关键道路或不稳定"，满足继续接入（阶段二）的前提；正式批准仍是用户的决定。

## 复现

```
python3 ios/tests/vector-map/check.py     # 需联网；产物落 output/vector-map/
```
