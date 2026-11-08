# 圆屏细路真机验收 — 宿主收口与待测项（2026-11-06）

## 范围

本轮属于地图风格实现收尾：生产 Build 29 已按 `docs/verification/ios-reconnect-20261106.md` 覆盖安装并启动。本轮没有改生产地图代码，只补齐 `map-source-mode` 的三组端到端宿主回归和验收记录；真机视觉、ACK、手机性能仍需设备证据。

## 技能

- `swift-concurrency-pro`：复核 `MapFeeder` 取图 worker→主线程回调、取消、路线代次与 ACK 顺序。
- `esp32-test-plan`：按四层验收拆分为宿主回归、签名装机、串口/看门狗、实屏与性能。
- `verification-before-completion`：以实际测试退出码和日志为准。

## 新增宿主端到端回归

`ios/tests/map-source-mode/main.swift` 新增/强化：

| 场景 | 断言 |
| --- | --- |
| 锁屏复用宽图、解锁仍在同块 | 锁屏 `AmapSdkRaster.captures == 0`；前台连续定位只补一次近景，`lastFineRoads == true` |
| 沿线 `onReady` 读到同块增强包 | `1 B/s` 下 fine 零发送并出现 `fine-budget-deferred`；独立充足预算场景 fine 恰好发送一次 |
| 预取块未成为当前块 | `fetchChunk(..., purpose: .prepare)` 零 fine 捕获 |
| 预取块成为当前块 | 只补一次，`lastFinePreparedBase == prefetchBase`，重复定位不再补 |
| 沿线缓存类型 | `RouteOfflineMaps.readPacket(...).isFine == true` |

相关实现位置：

- `MapFeeder.onLocation` 末尾 `evaluateFineForCurrentBlock`，独立于 `needsMap`/`servedCache`。
- `triggerFineForDisplay` 用 `RouteMapCache.readPacket` 的 `isFine` 判断缓存，使用 `fineAttempted`/`fineSubmitted` 去重。
- `fetchChunk` 的 `.prepare` 不进入 fine 闸门；宽图 `preparedBase` 使用 `readWide`。
- `RouteOfflineMaps.readPacket` 把缓存类型带到 `onReady`。

## 宿主结果

| 检查 | 结果 |
| --- | --- |
| `python3 ios/tests/map-source-mode/run.py` | PASS |
| `python3 ios/tests/screenoff-maps/run.py` | PASS 96 checks |
| `python3 ios/tests/fine-roads/run.py` | PASS |
| `python3 ios/tests/fine-roads/cache.py` | PASS |
| `python3 ios/tests/vector-feeder/run.py` | PASS 15 checks |

既有 `reroute-recovery` 1301、`maps` 689、`map-delivery`、`map-smoothing`、`four-styles`、`vector-map` 27/27 仍保留上一轮通过记录；本轮只改测试桩的 `lastFinePreparedBase` 字段和测试，不改变生产路径。

## 真机验收准备与当前阻塞

- 手机：iPhone 15 Pro，UDID `00008130-0004491C1811401C`，`xcrun devicectl list devices` 显示 connected。
- 圆屏：ESP32-S3，`/dev/cu.usbmodem1101`，Build29 对应固件仍为 `v7.12.10-pages.175c.16`。
- 尝试 `xcrun devicectl device info apps` / `process launch` 均返回
  `CoreDeviceError 4016`，`CurrentlyAssertableStates` 为空；手机当前不可执行设备断言，通常需要解锁并保持屏幕常亮后再试。
- 串口已用只读方式打开 8 秒，未捕获到启动/运行输出；不能据此判断固件状态，也不能据此宣称无看门狗。

因此**真机视觉、宽图/增强包 ACK、实际累计字节、手机 CPU/峰值内存、圆屏稳定绘制耗时尚未取得**，10% 性能目标未判定。

## 真机验收步骤（解锁后执行）

1. 解锁 iPhone，保持 MotoNav Build 29 前台；确认 `xcrun devicectl device info apps` 可列出 `com.u238zyc.motonav`。
2. 三主题：罪恶都市、GTA5、赛博朋克，明波/园区路线，关闭「俯视建筑轮廓」，低速（<60 km/h）进入园区；检查细路连续性、跨块衔接、主路分色、水域/建筑边误画。
3. 记录手机导出的地图 JSON：宽图与增强包的 `map-send`/`map-ack`、`packetVersion`、字节、时间差。
4. 锁屏巡航进入未缓存区域，解锁后检查圆屏是否恢复；再从巡航切导航、重算一次，确认地图交接。
5. 串口同时捕获 `/dev/cu.usbmodem1101`；若出现 `task_wdt`、canary 或重启，立即停止该组，保存首段串口、镜像哈希和匹配 ELF。
6. 用同路线、同设备 Build 28 对照；手机 CPU/峰值内存和圆屏稳定绘制耗时按 10% 门槛单独判定。

## 未测与限制

- 真机安装虽已有 Build 29 记录，本轮未重新安装；测试包与固件哈希以 `output/ios-reconnect-20261106/` 和 `docs/verification/ios-reconnect-20261106.md` 为准。
- 真机三主题、ACK、CPU/内存/绘制耗时、锁屏巡航跨未缓存区、重算交接均未在本轮取得新证据。
- 旧固件调色板回退、真实 BLE 分片/重试/探测开销未测。
- 圆屏本轮出现 WDT 历史；任何重启都按停止条件处理，不在未定位前继续长测。
