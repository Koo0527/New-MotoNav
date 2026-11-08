# iOS 重连补图整改 — 2026-11-06

## 范围

修复共享工作树中 iOS 重连补图的三个遗留问题：

1. 地图重置/切图源绕过连接认证与能力窗口；
2. type 3 的旧 `N` 提前清掉当前回执，失败预算在未实际入队时被消耗；
3. 普通 v0 底图在途时，迟到 v2 只能等待而不能接管。

以 `3fdebd1` 验收记录和当前共享工作树实现为基线。设备仍暂停；本轮只做 iOS 宿主与构建交付。

## 实现

`ios/MotoNav/BleLink.swift`

- `connectionGeneration` 在 link-ready 和断连时递增；延迟能力回调只能作用于创建它的连接。
- `sendBulk` 改为 `@discardableResult -> Bool`，只有分片真正进入 `BleBulkWriteQueue` 才返回 `true`。
- type 3 的 `K/N` 只处理当前 `mapReceipt.current.id`；旧 `K/N` 不推进/清理当前回执。
- 当前 `N`、最终回执超时和当前栅格 ATT 最终失败统一走 `failCurrentMap`，保留尾片探测与旧 ATT 回调槽。

`ios/MotoNav/MapFeeder.swift`

- `sendChunk` 是底图统一发送门：必须 `isReady`、`verified` 且不在能力窗口；成功入队后才更新 ID、发送时间、实际 wire 格式和 `lastWire`。
- `onLinkReady` 关闭底图发送并等待首次认证；认证后开启 1 秒单调时钟窗口；v2 到达立即放行，无 MPAL 走 v0；窗口回调带连接代次。
- `resetChunk`/切主题/切图源/`resendAll` 只替换待发底图，保留当前连接的认证状态、窗口和截止时间；未认证时不入队。
- 首次失败用相同 `lastWire` 字节和新 8 位 ID 完整重试一次；未成功入队不扣预算；第二次失败后等待新块/新连接/显式重发。
- 迟到 v2：普通 v0 在途时撤旧余片/回执、保留 ATT 槽、换新 ID 入队 v2；建筑首包在途时只标记待升级，等 ACK/发送结束/槽释放后处理；重复能力按实际版本去重。

## 宿主回归

| 测试 | 结果 |
| --- | --- |
| `python3 ios/tests/ble-palette-lifecycle/run.py` | PASS：认证窗口、首个 v2、K/N、旧/当前 N、生命周期重置 |
| `python3 ios/tests/map-source-mode/run.py` | PASS：场景 20（未认证重置/新块不入队）、21（v0 在途 v2 接管）、22（未入队不扣预算）、23（建筑 v0 重试后 ACK 补发 v2）、24（建筑最终失败补发 v2）及既有 17/17b/18/19 |
| `python3 ios/tests/screenoff-maps/run.py` | PASS：96 checks 等 5 组，建筑首包在途保护 |
| `swiftc … ble-bulk/main.swift` | PASS 28 checks，含旧 ATT token 过期与按包撤销 |
| `swiftc … ble-capability/main.swift` | PASS 22 checks |

`map-source-mode` 的重复定位断言改为统计 `fineCaptures`，避免原有离线预取时序造成的偶发 base capture 误报；这仍验证“第二次定位不再请求近景”。

## 签名 Release 构建

```sh
xcodebuild -workspace ios/MotoNav.xcworkspace -scheme MotoNav \
  -destination generic/platform=iOS -configuration Release \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=H3N5LA55A3 \
  CURRENT_PROJECT_VERSION=29 -derivedDataPath <tmp> \
  "OTHER_SWIFT_FLAGS=-Xfrontend -disable-sandbox" build
```

- `BUILD SUCCEEDED`，App 与 Share 扩展均为 `0.16.0 (29)`，Bundle ID `com.u238zyc.motonav`；
- 签名：`Apple Development: u238zyc@gmail.com (563K9S7RHG)`，Team `H3N5LA55A3`；
- App UUID `EB7ACE71-FD0D-38C1-A394-E520A9FB4B11`，扩展 UUID
  `FDF3E9F3-D712-3303-8082-CE1BE6B3C638`；
- 签名 IPA：`output/ios-reconnect-20261106/candidate/MotoNav-0.16.0-build29-signed.ipa`，
  SHA256 `9fb5ea5490d2e050fffe7b75ebc3ac46cbe3a09026097ba3f4dd37b38d432d4d`；
- 基线 Build 28 签名包保留：
  `output/g-calibration-replay-20261105/MotoNav-0.16.0-build28-signed.ipa`，
  SHA256 `ed73c65c…`。

`-Xfrontend -disable-sandbox` 仅用于宿主 Xcode 的 SwiftUI 宏插件沙箱；不修改项目配置。

## 归档

`output/ios-reconnect-20261106/`

- `source/ios-integration.tar.gz`：`ios/MotoNav`、`ios/tests`、`ios/MotoNav.xcodeproj`，
  SHA256 `6191d48e…`；
- `candidate/MotoNav-0.16.0-build29-signed.ipa`、`candidate/Payload/MotoNav.app`；
- `source/git-baseline.txt`、`git-status.txt`、`diff-stat.txt`、`working.diff`；
- `logs/`：五项宿主测试、无签名构建尝试与签名 Build 29 原始日志；
- `manifest.json`、`SHA256SUMS`。

iOS 生产/测试改动仍未单独提交：它们与共享地图 WIP 交织，且测试运行器依赖未提交的 `screenoff-maps/Stubs.swift`。归档快照可复跑；提交范围需与地图 WIP 一起整理。

## 真机测试中断（2026-11-06）

Build 29 已覆盖安装并启动。在圆屏 `2c267899…` 上测试时再次重启，串口首段记录：

- `E (557980) task_wdt: Task watchdog got triggered`，`IDLE0 (CPU 0)`；
- `CPU 0: help`，`CPU 1: loopTask`；
- `Stack canary watchpoint triggered (help)`；
- `Re-entered core dump!`，随后 `rst:0xc (RTC_SW_CPU_RST)`，启动日志仍为
  `MotoNav ready, firmware v7.12.10-pages.175c.16`；
- 读取 `0xff0000` 的 coredump：UART 报
  `Calculated checksum='26b416bf'`、`Image checksum='ffffffff'`，内容不可用于回溯。

手机 JSON：415 个事件、`dropped=0`、12 个 `map-send` 全部 `packetVersion=2`、
7 个 `map-ack`、2 个回执超时、3 个 `link-ready`；最后事件 `228.776s` 为
`session-stop`。串口的 `557980` 是板端启动后的毫秒数，手机使用录制起点的相对时间。
两端缺少共同时间锚点，本次故障无法对齐到具体地图包。

证据：

| 文件 | SHA256 |
| --- | --- |
| `logs/uart-reconnect.log` | `be1595a8…` |
| `logs/uart-reconnect-first-segment.log` | `da2276e9…` |
| `logs/map-timing-EEBA1C67-…json` | `5bee991d…` |
| `device/coredump-reconnect-2313.bin` | `c4fdb287…` |
| `device/coredump-reconnect-2313.elf` | `79721598…` |

**首发故障为 CPU0 `IDLE0` TWDT。** 匹配 `2c267899` 应用的 ELF `cd34564c9…` 显示
首段回溯在 `rasterRows → helperLoop`。随后的 canary 出现在写 Flash coredump 时，
栈指针 `0x3fcb82f0` 低于转储专用栈下界 `0x3fcb830c`。
三次受控重连被中断。先通过固件单独短测，再用 Build 29 重跑组合验收。

## 未完成

- 三次受控重连因固件 CPU0 重启中断，未形成完整验收；
- 设备圆屏 `2c267899…` 已再次复现 `IDLE0` 超时，具体阻塞点待取证；
- 后续顺序：CPU0 诊断候选 → 固件单独短测 → 恢复设备后重跑 Build 29 受控重连。
