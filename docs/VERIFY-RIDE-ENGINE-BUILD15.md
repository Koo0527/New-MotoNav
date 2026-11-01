# 2026-11-01 Build15 真机验收记录（agent 可执行部分）

对应计划：骑行引擎升级与三模式统一UI（分支 `codex/ios-unified-planner-tunnel`，实现合入至 `96c3266`，16 套回归测试全绿）。本记录只覆盖 agent 可执行部分；圆屏联测、实车骑行/停车/偏航/弱GPS/断网恢复为 deferred-user-validation（见文末清单）。

## 已完成（agent）

### 1. 构建号 14→15（commit `9010aef`）

- `ios/MotoNav.xcodeproj/project.pbxproj`：4 处 `CURRENT_PROJECT_VERSION = 14` 全部改为 `15`（Debug/Release × 主 App/Share 扩展）。版本号 `0.16.0` 不变。
- 同步更新 `README.md`、`docs/RELEASE-IOS-0.16.0.md`（新增 Build15 小节）、`ios/README.md` 的构建号引用，方式沿用 Build13→14 先例。

### 2. 签名 Release 构建（BUILD SUCCEEDED）

命令（与任务简报一致）：

```sh
cd /Users/zhaoyuancun/MotoNav/ios && xcodebuild -workspace MotoNav.xcworkspace \
  -scheme MotoNav -destination 'generic/platform=iOS' -configuration Release \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=H3N5LA55A3 -derivedDataPath build/DD build
```

- 结果：`** BUILD SUCCEEDED **`，退出码 0。
- 签名：`Apple Development: u238zyc@gmail.com (563K9S7RHG)`；描述文件 `iOS Team Provisioning Profile: com.u238zyc.motonav`。含 MotoNavShare 扩展的嵌入二进制校验。
- 产物：`ios/build/DD/Build/Products/Release-iphoneos/MotoNav.app`；`Info.plist` 实测 `CFBundleShortVersionString=0.16.0`、`CFBundleVersion=15`，主二进制约 99.7 MB。
- 构建输出中的大量 `unable to open object file` warning 全部来自高德 SDK 预编译静态库（dSYM 缺失），不影响签名与安装，与此前 Build13/14 构建现象一致。

## 未完成（被阻断，如实记录）

### 3. 覆盖安装到 iPhone —— 被设备锁定阻断

目标设备：`Yc's iPhone`（UDID `00008130-0004491C1811401C`，iPhone 15 Pro）。USB 层始终可见（`xcrun devicectl list devices` 全程显示 `available (paired)`），但所有依赖 RemotePairing 隧道的操作均失败：

```
ERROR: The tunnel connection failed while the system tried to connect to the device.
       (com.apple.dt.CoreDeviceError error 4 (0x04) / com.apple.dt.RemotePairingError error 4)
```

- 安装命令共尝试 5 次（`xcrun devicectl device install app --device 00008130-0004491C1811401C <app路径>`），间隔约 30s / 60s / 90s，并在文档整理后再试 1 次（简报要求重试一次，已超额多试），错误完全相同。
- 诊断：`xcrun devicectl device info details` 返回 `Connection: Device State: disconnected`；`info lockState` 亦因同一隧道错误不可用。USB 可见但隧道起不来，符合"手机处于锁屏状态"的表现（CoreDevice 隧道需要设备解锁后才建立）。本机 `remoted` 进程在运行；无 sudo 权限重启它；libimobiledevice（idevicesyslog 等）未安装。
- 结论：安装、启动验证、日志检查均未执行——不是构建问题，是设备侧状态问题。**不伪造任何验证结果。**

### 4. 启动验证与日志检查 —— 未执行（依赖上一步），能力边界已查明

供后续执行时参考（已通过 `--help` 核实语法）：

- 启动：`xcrun devicectl device process launch --device 00008130-0004491C1811401C com.u238zyc.motonav`
- 进程存活：`xcrun devicectl device info processes --device 00008130-0004491C1811401C`（约 10 秒后复查 motonav 进程仍在）
- 日志：devicectl **没有**通用设备 syslog 子命令；尽力而为的替代是 `process launch --console`（桥接 App stdout，但会阻塞至 App 退出）。idevicesyslog 本机不可用。故启动日志中 ride-engine/NavigationCoordinator 初始化检查为能力受限项，如实记为未完成。

### 5. 用户解锁手机后的补装步骤（约 2 分钟）

保持手机解锁 + USB 连接，然后在仓库根目录执行：

```sh
xcrun devicectl device install app --device 00008130-0004491C \
  /Users/zhaoyuancun/MotoNav/ios/build/DD/Build/Products/Release-iphoneos/MotoNav.app
xcrun devicectl device process launch --device 00008130-0004491C1811401C com.u238zyc.motonav
sleep 10 && xcrun devicectl device info processes --device 00008130-0004491C1811401C | grep -i motonav
```

覆盖安装沿用同一 Bundle ID/签名，不卸载，手机上的高德 Key、设置与历史记录保留。若安装仍报隧道错误，解锁手机后在"设置 > 开发者"确认 Developer Mode 仍开启，重新插拔 USB 再试。安装成功后先核对：设置页版本应显示 `iOS v0.16.0`，历史记录、收藏、Key 均在。

## 用户待办验收清单（逐条勾选）

以下为计划要求、agent 无法替代的实操项。建议按顺序执行；涉及骑行的一律在安全场地或短途熟路进行。每条"操作要点"为通过标准。

### A. 安装与基础（先做）

- [ ] **A1 覆盖安装 Build15 并首次启动**：解锁手机后按第 5 节命令安装；App 能打开、四栏目（导航/轨迹/圆屏/我的）正常，设置页显示 `iOS v0.16.0`，Key/收藏/历史仍在。
- [ ] **A2 骑行链路最小冒烟**：首页搜索一个 1–3 km 的自行车目的地 → 出现规划结果与路线预览（默认官方骑行引擎，后端标识 rideSDK）→ 模拟导航可开始、有转向播报与到达结束。

### B. 模式切换稳定性（计划核心项）

- [ ] **B1 10 轮切换**：同一目的地下 汽车→自行车→摩托车→自行车… 循环切换并各发起一次规划/模拟，累计 ≥10 次切换。要点：每次切换都正常出路线（摩托车走网页、自行车走官方引擎）；无"创建引擎失败/互斥冲突"提示；导航中切换会先结束当前导航；第 10 次后仍能正常开始一次模拟导航。若出现引擎切换失败提示，记录当时模式与复现步骤。
- [ ] **B2 切换后地图正确**：驾车用 Drive 地图、官方骑行用 Ride 地图、网页/分享兼容沿用原地图；切换后旧地图数据被取消、不残留上一模式底图。

### C. 骑行引擎行为（模拟可完成部分）

- [ ] **C1 模拟暂停/退出**：自行车模拟导航中：暂停→继续（状态与播报正常）；长按/更多菜单退出→返回规划页，可立即再次规划同一路线（引擎实例被正确释放重建）。
- [ ] **C2 分享原线**：从高德分享导入一条骑行轨迹 → 默认保留原轨迹独立导航（independent），沿线显示正常；规划页"用官方引擎重新规划"能出官方骑行方案并展示后再开始。
- [ ] **C3 官方引擎失败回退**：断网状态下让官方骑行规划失败 → 应出现明确失败提示并可手动选兼容引擎，而不是静默切换或一直转圈。

### D. 锁屏与后台（≥20 分钟）

- [ ] **D1 锁屏 20 分钟导航存活**：骑行导航（模拟即可）进行中锁屏 ≥20 分钟。要点：解锁后导航仍在进行、轨迹连续不跳变；期间圆屏（若连接）转向/距离持续更新；语音播报在锁屏下可出声（含静音开关生效）。注意：出发前先让沿线地图完成准备，弱网/超远途的补图行为不在本条标准内。

### E. 真实骑行（实车，安全第一）

- [ ] **E1 真实骑行基本导航**：真实自行车骑行一段熟路。要点：定位吸附到路、转向播报时机合理、剩余距离/ETA 正常递减；轨迹页新增一条真实轨迹记录（模拟导航不应产生轨迹，可顺带核对）。
- [ ] **E2 偏航重算**：故意偏离路线 → SDK 自动重算并回到引导，无需手动重选路线；重算失败时应保留当前路线并提供重试，而不是中断导航。
- [ ] **E3 停车/短暂停留**：中途停车 ≥5 分钟再出发。要点：导航不误判到达、不丢失会话；确认"到达"仅在真正接近终点时触发。
- [ ] **E4 弱GPS**：高楼/高架/隧道口等弱定位路段。要点：状态条如实显示弱定位，恢复后继续引导；不出现漂移路线或错误转向。
- [ ] **E5 断网恢复**：骑行中开飞行模式数十秒再恢复（注意安全，建议停靠时做）。要点：断网期间已缓存的引导继续；恢复后若 SDK 重算失败，保留原路线并可重试；不崩溃、不静默切引擎。

### F. 圆屏联测（硬件到货后）

- [ ] **F1 骑行数据上圆屏**：官方骑行导航连接圆屏。要点：转向箭头、下次距离、道路文字、速度、剩余里程/ETA、GPS 状态、到达事件与驾车版一致（同一套 BLE 消息，L,120/#e/#v/#x/#y/#O/A,0/slot 格式）；速度为骑行实际速度而非模拟值残留。
- [ ] **F2 断连重连**：骑行中断开圆屏再 reconnect。要点：重连后同步当前会话（转向/距离立即恢复为当前值，不是旧值或空白）；锁屏期间圆屏更新不中断。
- [ ] **F3 三模式切换时圆屏不串台**：B1 的 10 轮切换中连着圆屏做几轮。要点：切引擎/换模式时圆屏数据跟随正确模式，无残留上一模式的转向或距离。

## 边界说明

- 本轮 agent 侧仅改动构建号与文档，未改任何产品代码；产品代码为 Task 1–4 已评审合入的实现（`2741a7f..96c3266`）。
- 16 套 macOS 回归测试在 Task 4 已全绿；本记录的真机项（安装/启动/日志）因设备锁屏未执行，不以上述测试替代。
- 实车与圆屏项受硬件与安全条件限制，只能由用户完成；E 类请勿为测试目的违反交规或在开放道路操作手机。
