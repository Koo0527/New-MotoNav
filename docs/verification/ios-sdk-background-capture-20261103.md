# iPhone 高德 SDK 后台取图真机对照（2026-11-03）

## 结论

在用户的 iPhone 15 Pro、iOS 27.2、项目现用 AMapNavi 10.1.600、默认 `MAMapView.metalEnabled == false` 配置下，独立地图视图在桌面后台和锁屏后台均未返回可用的新区域截图。真实后台定位和定时器一直运行；恢复前台后，同一目标区域能够加载并截图。

因此，这组环境下的问题不能只归因于 App 的前台检查或 Build23 蓝牙空闲省电。单纯删除业务层后台取图拦截，尚不能达到任意方向长距离后台补图的目标。这不是对所有高德版本、渲染配置和 iOS 版本的结论。

## 隔离方式

- 在 ignored `output/sdk-background-probe/workspace/` 中复制当前 iOS 工程与依赖，使用原 Bundle ID、现有开发签名和设备中保存的高德 Key。正式源码、工程文件、固件均未因本测试修改。
- 临时工程仅把 App 根入口替换成独立诊断页，直接创建 `MAMapView` 并调用公开 `takeSnapshot(in:timeoutInterval:)`，不启动 `MapFeeder`、`AmapCaptureHost` 或 `BleLink`，不存在它们的后台取消、前台守卫和蓝牙省电策略干扰。
- 使用独立 `CLLocationManager`，启用后台定位、禁止自动暂停，沿用 App 已获得的定位授权。不导出手机真实位置，仅记录定位回调数量。
- 未附加调试器，也未调用 `beginBackgroundTask` 来延长执行时间。前台用北京固定公开样本；进入后台后移动相机到上海／广州固定样本。目标不是本轮前台的截图画面。没有清除用户原 SDK 磁盘缓存，不能将样本称为严格冷缓存。
- 画面为 720×720 points、zoom 17、普通地图、关闭文字与交通；截图原始分辨率为 2160×2160。前台分别开关建筑采图；后台先请求无建筑底图，只有得到可用底图才继续建筑截图。
- 日志保存到 App 缓存独立目录，使用首次解锁后可访问的文件保护；锁屏期间日志确实可追加。临时页面不连接圆屏，不改收藏、路线或地图设置。

## 实测

用户分别执行回桌面与按侧键锁屏、随后回到 App 的操作。日志确认两次真实 background 时长分别为 50.615963 秒（home-1）与 50.575018 秒（lock-1）；锁屏轮次另观测到受保护数据不可用及解锁恢复通知（通知时刻 44.710747 秒，事件流首次观察到 `protectedDataAvailable=false` 为 56.058341 秒，两者分开记录）。

| 检查 | 桌面后台 `home-1` | 锁屏后台 `lock-1` |
| --- | --- | --- |
| 前台道路、建筑开关截图 | 均返回 2160×2160，完整不透明 PNG | 均返回 2160×2160，完整不透明 PNG |
| 后台相机请求和截图请求 | 均在真实 background 状态执行 | 均在真实 background 状态执行 |
| 后台定位回调 | 8 次 | 10 次 |
| 后台 2 秒定时器 tick | 25 次 | 25 次 |
| 截图请求至 SDK 回调 | 20.0069 秒 | 20.0064 秒 |
| 后台可用截图 | 无 CGImage 尺寸，未产生 PNG | 无 CGImage 尺寸，未产生 PNG |
| SDK 回调 state | 1，但未返回可用图片 | 1，但未返回可用图片 |
| 回前台至地图加载完成回调 | 0.644818 秒 | 0.713459 秒 |
| 前台恢复截图 | 2160×2160，PNG 有真实地图内容 | 2160×2160，PNG 有真实地图内容 |
| 恢复截图请求至回调 | 约 0.138 秒 | 约 0.137 秒 |

恢复截图在回前台后主动等待约 8 秒才发起；表中 0.14 秒是截图调用耗时，不是从解锁到整张地图就绪的总耗时。`state == 1` 不能单独作为截图成功证据，必须同时验证图片、尺寸及内容。

## 证据与复验

- 临时诊断源：`output/sdk-background-probe/SDKBackgroundProbe.swift`；实际构建入口为隔离副本的 `MotoNav/MotoNavApp.swift`。构建、签名验证和覆盖安装成功。
- 两轮原始事件：`output/sdk-background-probe/{home-1,lock-1}/events.jsonl`；同目录保存前台 base、buildings、recovery PNG。
- 汇总：`output/sdk-background-probe/results.json`；只读分析脚本 `analyze_probe.py` 的 5 项自检通过，明确拒绝把前台迟到回调、不完整状态、零尺寸或图片落盘失败当作后台成功。
- 汇总生成另断言了真实请求／回调状态、后台定位和 tick、缺失后台图片、恢复前台后的有效尺寸。
- 原包为 `output/map-edge-bridge/baseline/MotoNav.app`，Build25，主可执行文件 SHA-256 `8fc14561e7590bfdb103a023934734645fa7c38a8f3a31acf54f4ce9c1ed77b7`，与此前 Build25 交付清单一致。覆盖恢复保留 App 数据；`output/sdk-background-probe/restore-{install,launch,version}.json` 为**第一轮恢复记录**，仅证明第一轮结束后已恢复，不得用于证明后续轮次已恢复。本表数字已由 `round3/analyze_round3.py --historical` 机器复算回归（见 `round3/summary-historical.json`）。

## 未验证范围

没有测试 Metal 渲染、新版 SDK、其他 iPhone／iOS 组合或服务端静态图接口；没有因本测试更换地图源，也未实现后台补图修复。后台底图未成功，因此这两轮没有进入独立建筑差分提取，不宣称已单独测完后台建筑采集。前台建筑开关图仅用于验证 SDK 截图基线，不等同于正式圆屏建筑包验收。
