# iPhone 高德 SDK 后台取图：Metal 与新版 SDK 对照（2026-11-03 第二轮）

## 结论

在 [第一轮基线](ios-sdk-background-capture-20261103.md)（AMapNavi 10.1.600 + OpenGL 后台无法取图）之上，本轮补齐 Metal 渲染与新版 SDK 两个变体。四种组合全部同样失败，且失败签名一致：

| 轮次 | SDK | 渲染 | 真实后台时长 | 后台 `map-loaded` | 后台快照 | 后台瓦片直连 |
| --- | --- | --- | --- | --- | --- | --- |
| home-1 / lock-1（第一轮） | 10.1.600 | OpenGL | 约 50.6 秒 | 0 次（回前台 0.65/0.71 秒后触发） | 20.0 秒超时，state=1 但 0×0，无 PNG | 未测 |
| home-m1 | 10.1.600 | Metal | 63.085277 秒 | 0 次（回前台 0.552815 秒后触发） | 同签名失败 | HTTP 200（旧探针无 metrics 字段） |
| home-s2m | 11.2.100 | Metal | 28.906999 秒 | 0 次（回前台 0.318783 秒后触发） | 图像在回前台后才截到，sha256 与恢复帧相同（迟到回调） | HTTP 200（同上） |
| home-s2b | 11.2.100 | OpenGL | **2389 秒（39.8 分钟），1380 秒起为锁屏** | **0 次** | 20.008 秒超时，state=1 但 0×0，无 PNG | HTTP 200，17595 字节 |

home-s2b 把第一轮遗留的「后台加载只是慢」漏洞关死：39.8 分钟真实后台（含锁屏）窗口内 `map-loaded` 严格为 0，而同一窗口内 2 秒定时器 1195 次无中断（最大间隔 2.01 秒）、后台定位回调 636 次、瓦片 CDN 直连 HTTP 200。**高德 `MAMapView` 的加载完成/截图流水线在 SDK 层被前台门控，与渲染后端（OpenGL/Metal）和 SDK 版本（10.1.600/11.2.100）无关。** `takeSnapshot` 的 state==1 在超时路径下不代表成功，必须核对图像尺寸与内容。

顺带观察：11.2.100 在前台空闲期间约每 91 秒触发一次 `map-loaded`（本轮前台 21.8 分钟内出现 14 次），说明新 SDK 有前台周期刷新，但后台没有任何对应行为。

因此：锁屏巡航补图问题不能通过 Metal 开关、升级 SDK 或删除 App 层前台限制解决；业务层放开只能让请求发出、拿不到图。这不是对所有设备/iOS 组合的结论，仅限本轮测试环境。

## 隔离方式（沿用第一轮，新增两点）

- 仍用 git 忽略的 `output/sdk-background-probe/workspace/` 副本，原 Bundle ID、开发签名、设备内已存 Key；正式源码未改。
- v2 探针新增：
  - `--metal` 启动参数在 `MotoNavApp.init` 任何 `MAMapView` 创建前设置 `MAMapView.metalEnabled = true`；不传即默认 OpenGL。
  - 瓦片 CDN 直连探针：前台基线与后台相机请求时各 GET 一次目标坐标 z17 栅格瓦片（webrd01.is.autonavi.com 公开端点、固定公开样本坐标、URL 不含 key），记录 HTTP 状态与字节数，用于区分「后台网络停摆」与「SDK 内部停摆」。
- SDK 升级只发生在副本内：`pod 'AMapNavi', '11.2.100'`（CocoaPods 最新；11.3.100 仅存在于官方更新日志未上 pod）+ `pod 'AMapSearch', '9.8.1'`（AMapFoundation 1.9.1）。正式 ios/Podfile 未动。

## home-s2b 时间线（判据轮）

第二轮进程事件（`started` 事件确认 `sdk=AMapNavi 11.2.100, metal=false`）：

- 0.54 秒 前台 `map-loaded`（北京样本）；8.5–11.9 秒 前台 base/buildings 两张 2160×2160 截图有效，`baseline-ready`。
- 用户保持前台约 21.8 分钟（期间 14 次周期性 `map-loaded`，约 91 秒一次），1319.834392 秒进入后台；受保护数据不可用通知 1380.147589 秒、事件流首次观察到 `protectedDataAvailable=false` 为 1391.180544 秒（按侧键锁屏；通知时刻与首次观察到 false 分开记录）。
- 1325.09 秒 后台相机移到上海样本；1325.21 秒后台瓦片直连 HTTP 200（17595 字节）。
- 1329.29 秒发起后台快照，1349.29 秒回调：恰好 20.008 秒（SDK 自身超时），state=1，0×0，无 PNG。
- 1319.834392–3708.860092 秒整个后台测试窗口（2389.025701 秒 ≈ 39.8 分钟）：`map-loaded` 0 次；tick 1195 次（最大间隔 2.01 秒，全部 state=background）；定位回调 636 次。
- 3708.860092 秒回前台，3709.02 秒 `map-load-error`、3709.20 秒 `map-loaded`（**激活后 0.336096 秒**；此前报告的 0.18 秒是 map-load-error→map-loaded 间隔，系口径误标，勘误）；3717.41 秒恢复快照 2160×2160 有效，`run-complete`。

## 证据与复验

- 各轮原始事件与 PNG：`output/sdk-background-probe/{home-m1,home-s2m,home-s2b}-pull/`（home-s2b 共 3001 行事件，含被 `--terminate-existing` 终止的首个进程前 12 秒，分析只取最后一个 `started` 之后）。作废的半截 home-s2 留在设备缓存目录未分析。
- 机器复算：`output/sdk-background-probe/round3/analyze_round3.py`（离线自检 7 项 + 历史重算），输出 `round3/summary-historical.json`；本文所有窗口/延迟数字以该重算为准（didEnterBackground→didBecomeActive 配对口径）。
- 副本构建指纹：11.2.100 探针完整留存于 `DerivedData/Build/Products/Debug-iphoneos/MotoNav.app`，主程序 SHA-256 `604dd73a3f5f0172d2af23fdc6628ac7767217b13ee6cbc78acf6cdd73634f8a`；10.1.600 探针（构建时记录截断指纹 `3f3dcd78…`）已被后续构建覆盖，**未留存**，不重建冒充。
- 恢复凭据归属：`output/sdk-background-probe/restore-{install,launch,version}.json` 为**第一轮恢复记录**，不得证明第二轮已恢复；第二轮恢复（Build25 覆盖安装+启动）的会话内工具输出成功，但**未留存文件凭据**，仅以 manifest 布尔值记载。

## 第三轮补测（2026-11-04）：11.2.100 + Metal，≥90 秒窗口与真联网证据

按验收意见补齐证据缺口后重测。探针升级为 v3：`started` 首事件、每事件带 `runID`/UTC/单调 elapsed、进程独立 UUID 目录；SDK 版本改读运行时常量 `AMapNaviVersion`/`MAMapKitVersion`（实测均 11.2.100）；Metal 记录 `requestedMetal=true`、设置后 getter=true，`actualBackend="unknown"`（无公开接口可查实际后端，结论保留该限制）；瓦片探针改 ephemeral URLSession + 禁缓存头 + URLSessionTaskMetrics + 图片解码判定。分析器 `round3/analyze_round3.py` 先过 7 项离线自检（多进程 elapsed 重置、迟到回调、零尺寸、localCache 响应、坏 SHA、旧恢复凭据、PNG 全透明/纯色），历史 5 轮重算全部回归通过。

| 轮次 | 窗口 | 锁屏证据 | 窗口内 map-loaded | tick | 定位 | 后台瓦片（metrics 实测） | 后台快照 | 回前台加载 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| home-r3 | 197.50 秒 | —（桌面） | 0 | 99 次，最大间隔 2.01 秒 | 57 次 | HTTP 200，17595B，decode=true，fetchTypes=[networkLoad] | sdk=1，0×0，无 PNG | 0.301002 秒 |
| lock-r3 | 99.42 秒 | 通知 32.12 秒（按侧键时，早于进后台），首次 false 44.06 秒 | 0 | 49 次，最大间隔 2.01 秒 | 18 次 | HTTP 200，12274B，decode=true，fetchTypes=[networkLoad] | sdk=1，0×0，无 PNG | 0.453063 秒 |

首轮 home-r3 窗口 82.58 秒 <90 秒，按规则判流程未完成作废重跑（目录保留，分析器自动取最新进程并标注 superseded）。两轮前台基线（道路+建筑两张有效图）、后台执行（tick+定位连续）与前台恢复均有效。

**最终判定（analyze_round3.py 自动给出）**：两轮均为 `sdk-background-failure` —— 本设备上，现有公开 SDK 调用（MAMapView + takeSnapshot，公开委托回调）及 Metal 开关方案未达到持续后台补图要求；建议转入不依赖地图视图截图的方案评估。本轮瓦片直连首次取得 metrics 级真联网证据（networkLoad、响应可解码为图），确认后台网络通路完好。

恢复闭环：装机前确认设备为 0.16.0(25)=baseline（`round3/credentials/preinstall-version.json`）；v3 探针安装 2026-11-03T17:39:07Z，正式包恢复安装 2026-11-03T18:00:20Z（勘误：此前把北京时间误标为UTC）（`restore-install.json`），恢复后版本核对 0.16.0(25)（`restore-version.json`），恢复晚于最后一次探针安装；恢复启动当时仅会话文本为证，JSON凭据缺失已如实标注（round3/credentials/restore-launch-note.md）。构建指纹：`round3/build/fingerprint.json`（可执行 SHA-256 `c7fa95f5862d000d97886492f7ced171019eb1d455d288449168846b65d3d8b5`），探针包/Podfile.lock/源码快照/构建日志均独立留存于 `round3/build/`。

## 未验证范围与边界

- 仅一台 iPhone 15 Pro、iOS 27.2、单个高德 Key；样本为固定公开坐标（北京/上海/广州），未测服务端静态图接口、其他 iOS 版本或安卓。
- 后台瓦片直连只证明「手机后台网络 + 该 CDN 端点可达」，不代表把该端点当作正式数据源已获批准——接口非官方公开文档，稳定性与条款需另行评估。
- 本轮只做诊断与讨论，未改生产源码、未迁移数据源、未实现后台补图。四级验证覆盖情况：编译通过 ✓、分析器离线自检 ✓（7 项）、真实 SDK 截图结果 ✓（第三轮两轮 ≥90 秒桌面/锁屏窗口，SDK 路线判定为后台失败）；**实车锁屏巡航验收未做**（SDK 路线已被否定，待替代方案立项后另行验收）。实际渲染后端无法从公开接口确认，结论保留该限制。
