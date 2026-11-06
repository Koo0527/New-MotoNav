# 圆屏真机验收记录 — 2026-11-06（候选 381aa2a4 未通过）

## 勘误

原记录写“两次栈 canary 重启、979 个事件”，与原始证据不符，现更正：

- 串口共有 **三次 `IDLE0` 任务看门狗超时**（`E (249450)`、`E (35536)`、`E (58170)`）。
- 首段在打印 CPU0 backtrace 后串口断开，没有保留 panic/canary 段，属于截断证据。
- 后两段在写 coredump 时再次触发 canary（`Re-entered core dump!`），
  flash 转储 checksum 校验失败。
- 手机 JSON 实际为 **443 个事件**（`dropped=0`），不是 979。
- 四个 `map-ack` 后分别在 6.244 s、6.224 s、6.242 s（`id 42` 的第二个 ACK 为 6.124 s）
  出现断连；7 次 `map-receipt-timeout` 全部发生在对应 `link-ready` 之后。
- 原始日志和转储保持原样，未覆盖或重写。

## 结论

候选 `381aa2a4…`（宿主提交 `df63e19`，记录 `ed5e815`）在导航短测中三次触发 CPU0
`IDLE0` TWDT，已回退到烧录前实读的 `2c267899…` 并确认启动。该候选不进入长测。

这不是 `fast flush failed` / `spi_bus_lock_bg_exit` 的旧 SPI 超时签名；`fastFlushFatal`
未触发。三次 TWDT 的 CPU0 运行位置分别是 `flush`、`flush`、`help`；后两次在写 coredump
时出现栈 canary：

1. 首段 `E (249450)`：`CPU 0: flush`，`CPU 1: IDLE1`；backtrace 打印后串口断开，无 canary；
2. `E (35536)`：`CPU 0: flush`，`CPU 1: loopTask`；`Stack canary watchpoint triggered (flush)`，
   `fastPush`（`DisplayPipeline.h:162`）→ `flushTask`（`:226`）；
3. `E (58170)`：`CPU 0: help`，`CPU 1: IDLE1`；`Stack canary watchpoint triggered (help)`，
   `rasterRows`（`RasterRenderer.h:44`）→ `helperLoop`（`RowWorker.h:12`）。

`fastPush` 和 `rasterRows` 是看门狗触发时的运行位置，不是已确认的根因。两个任务栈均为
4096；ELF 中两者栈帧序言均为 `entry a1, 144`。当前证据不足以区分“CPU0 长期无空闲”、
“调用链栈不足”和“像素缓冲/全局指针被写坏”；需用 idle hook 和阶段计数先测空闲间隔。
core dump 在转储过程中再次异常，checksum 失败，不能作为归因证据。

## 现场

| 项目 | 值 |
| --- | --- |
| 设备 | ESP32-S3，MAC `c4:9e:7e:0b:7a:54`，`/dev/cu.usbmodem1101` |
| 手机 | iPhone 15 Pro，MotoNav 0.16.0 Build 28，bundle `com.u238zyc.motonav` |
| 候选 app | `381aa2a4fa02db298b1e58de7cfb9ecc0eb584776cab9587afb4cc201a0bf5fb` |
| 候选 ELF | `5cb1886be82ecbf13c6018949c5ebb6998f82ec1bf33b84e8ea3a73c3bd4dfc7` |
| 烧录前应用 | `2c26789991ca82895192cdecc7eee73cc96caee9f5d64971be8abf9ec65ce91c` |
| 回退镜像 | `output/device-acceptance-20261106/device/rollback-app0-2c267899.bin` |
| 烧录前 coredump | `da09a493336757a1bc298226c1b04a280b635252d6517344c0ebfac8ff773265` |
| 崩溃后 coredump | `e51d513aeba39bb68de581a4951a8b24303820261794aef434a0842b1bfc9896` |
| 手机 JSON | `map-timing-1ED2166B-F3A1-42F6-BE5C-8A888271402F.json`，`3479db97…`，443 事件，`dropped=0` |
| 串口原始日志 | `uart-session.log`，`38caca1f…`，392 行 |

## 时间线

设备各段的时间戳在重启后从零开始，手机 JSON 时间连续；下列断连与 WDT 按“地图 ACK 后
约 6.2 秒”对齐。

### 第一次

- 手机 JSON：`map-ack id 40` 在 `26.820 s`；`link-disconnected` 在 `33.064 s`
  （+6.244 s）；`link-ready` 在 `45.347 s`。`map-receipt-timeout id 40` 在 `57.922 s`，
  即重连之后。
- 圆屏：`RASTER commit id=40` 后，`E (249450) task_wdt`，`IDLE0 (CPU 0)`，
  `CPU 0: flush`，`CPU 1: IDLE1`；backtrace 后串口断开（`Device not configured`），
  首段截断，没有 panic/canary/coredump 结论。

### 第二次

- 手机 JSON：`map-ack id 41` 在 `62.497 s`；`link-disconnected` 在 `68.721 s`
  （+6.224 s）；`link-ready` 在 `72.448 s`。`id 41` 的 `map-receipt-timeout` 在
  `78.151/83.652/89.106/94.487/99.984/105.823 s`，均在重连之后。
- 圆屏：`RASTER commit id=41` 后，`E (35536) task_wdt`，`CPU 0: flush`，
  `CPU 1: loopTask`；`Stack canary watchpoint triggered (flush)`；
  `fastPush`（`DisplayPipeline.h:162`）→ `flushTask`（`:226`）→ `vPortTaskWrapper`；
  `Re-entered core dump!` → `Rebooting...`，`rst:0xc (RTC_SW_CPU_RST)`，
  `Reset reason=6`；启动报 `Core dump data check failed`。

### 第三次

- 手机 JSON：`map-ack id 42` 在 `109.866/109.984 s`；`link-disconnected` 在
  `116.108 s`（+6.242/+6.124 s）；`link-ready` 在 `119.890 s`。
- 圆屏：`RASTER commit id=42` 后，`E (58170) task_wdt`，`CPU 0: help`，
  `CPU 1: IDLE1`；`Stack canary watchpoint triggered (help)`；
  `rasterRows`（`RasterRenderer.h:44`）→ `helperLoop`（`RowWorker.h:12`）；
  同样 `Re-entered core dump`、`RTC_SW_CPU_RST`、checksum 失败。

## 与旧证据的关系

- 烧录前应用 `2c267899` 是 11 月 6 日 SPI polling + FIFO 候选，导航负载尚未验收。
- 旧 `6c1444ad…` 回退镜像对应上午 `b54ea31b…` 的 SPI 崩溃，仅作历史证据；
  本轮回退使用实读的 `2c267899…`。
- 用户这次电池重启的归因仍未完成；本次三次 CPU0 TWDT 是候选导航负载下的现象，
  与电池供电重启分开报告。

## 回退结果

- 只写应用区 `0x10000`：`Wrote 1347408 bytes ... Hash of data verified`；
- 回退后串口确认 `MotoNav ready, firmware v7.12.10-pages.175c.16`，HEAP 正常；
- 设备当前运行 `2c267899`，串口未被占用。

## 证据文件

根目录：`output/device-acceptance-20261106/`

- `README.md`：现场、烧录、短测结果与回退；
- `SHA256SUMS`：19 个文件的完整哈希；
- `device/`：分区表、当前/崩溃后 coredump、当前 app0、回退镜像；
- `mobile/`：手机导出的地图时序 JSON；
- `logs/`：烧录、读回、串口原始日志、回退日志。

## 后续（按新计划）

1. 用 `2c267899` 与原 Build 28 在桌面复跑同一路线、赛博朋克、同亮度/屏速/快刷，
   热缓存 3 次、每次 90 秒；若复现 `IDLE0` 超时，保全日志后停止该组。
2. 冻结 `381aa2a4` 的实际构建源码（`0409dac` + 未跟踪固件文件）作为修复底座。
3. 诊断版先测 CPU0 idle 间隔、`help`/`flush` 起止、SPI acquire/polling 最大耗时、
   最后阶段和任务栈水位；按“帧/分片是否持续完成”决定加 250 ms 休息窗口，
   还是修 `polling_end`/`help` 卡点。不要先把栈 canary 当作根因。
4. iOS 重连补图按“认证后 1 秒能力协商、只保留最新底图、同一负载最多完整重试一次”
   单独修复和回归；与 CPU0 结论分开报告。
