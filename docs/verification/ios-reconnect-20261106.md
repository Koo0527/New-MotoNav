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
| `python3 ios/tests/map-source-mode/run.py` | PASS：场景 20（未认证重置/新块不入队）、21（v0 在途 v2 接管）、22（未入队不扣预算）及既有 17/17b/18/19 |
| `python3 ios/tests/screenoff-maps/run.py` | PASS：96 checks 等 5 组，建筑首包在途保护 |
| `swiftc … ble-bulk/main.swift` | PASS 27 checks |
| `swiftc … ble-capability/main.swift` | PASS 22 checks |

`map-source-mode` 的重复定位断言改为统计 `fineCaptures`，避免原有离线预取时序造成的偶发 base capture 误报；这仍验证“第二次定位不再请求近景”。

## Release 构建

`xcodebuild -project ios/MotoNav.xcodeproj -scheme MotoNav -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -derivedDataPath <tmp> build`：

- exit 65，失败于宿主 Xcode 的 SwiftUI 宏插件：
  `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`;
  `swift-plugin-server produced malformed response`。
- 该错误发生在 `RideMapViews.swift` 的 `@State` 展开，不是本轮 MapFeeder/BleLink 代码错误。
- 本轮没有可归档的 Release `.app`；宿主测试已通过，实际装机仍为未验证。

## 归档

`output/ios-reconnect-20261106/`

- `source/ios-integration.tar.gz`：`ios/MotoNav`、`ios/tests`、`ios/MotoNav.xcodeproj`，
  SHA256 `83a9c01a…`；
- `source/git-baseline.txt`、`git-status.txt`、`diff-stat.txt`、`working.diff`；
- `logs/`：五项宿主测试与 iOS Release 构建原始日志；
- `manifest.json`、`SHA256SUMS`。

iOS 生产/测试改动仍未单独提交：它们与共享地图 WIP 交织，且测试运行器依赖未提交的 `screenoff-maps/Stubs.swift`。归档快照可复跑；提交范围需与地图 WIP 一起整理。

## 未完成

- 无签名 Release 构建因宿主 Xcode 宏插件失败，需修复 Xcode/插件环境后重试；
- 真机组合重连验收未做，设备继续暂停；
- 后续顺序仍为 CPU0 诊断 → 固件单独验收 → iOS 受控重连组合验收。
