# 圆屏真机验收记录 — 2026-11-06（候选 381aa2a4 未通过）

## 结论

候选 `381aa2a4…`（宿主提交 `df63e19`，记录 `ed5e815`）在导航短测中出现 **两次栈 canary 重启**，
已回退到烧录前实读的 `2c267899…` 并确认启动。该候选不进入长测。

这不是 `fast flush failed` / `spi_bus_lock_bg_exit` 的旧 SPI 超时签名；`fastFlushFatal` 未触发，
串口日志没有该行。两次故障分别是：

1. `flush` 任务在 `fastPush` 写像素缓冲时触发栈 canary（`DisplayPipeline.h:162`）；
2. `help` 任务在 `rasterRows` 写屏幕行时触发栈 canary（`RasterRenderer.h:44`）。

两次任务栈均为 4096；ELF 中 `fastPush` / `rasterRows` 的栈帧序言均为 `entry a1, 144`。
当前证据不足以判断是调用链栈不足、像素缓冲指针被写坏，还是地图 WIP 的全局越界写；
core dump 在转储过程中再次异常，checksum 校验失败，不能作为归因证据。

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
| 手机 JSON | `map-timing-1ED2166B-F3A1-42F6-BE5C-8A888271402F.json`，`3479db97…`，979 事件，`dropped=0` |
| 串口原始日志 | `uart-session.log`，`38caca1f…`，392 行 |

## 时间线

- 手机 JSON `33.06 s`：第一次 `link-disconnected`；`45.35 s` 重连。`id 40` 多次
  `map-receipt-timeout`，重连后以 `packetVersion=0` 重发。
- 圆屏 `RASTER commit type=3 id=41 theme=3 elapsed_us=302562 processing_us=126271
  max_slice_us=94216` 后约 5 s：
  - `E (35536) task_wdt ... - IDLE0 (CPU 0)`，`CPU 0: flush`，`CPU 1: loopTask`；
  - `Stack canary watchpoint triggered (flush)`；
  - `fastPush`（`DisplayPipeline.h:162`）→ `flushTask`（`:226`）→ `vPortTaskWrapper`；
  - `Re-entered core dump!` → `Rebooting...`，`rst:0xc (RTC_SW_CPU_RST)`，`Reset reason=6`；
  - 启动报 `Core dump data check failed`，checksum 不匹配。
- 手机 JSON `68.72 s`：第二次 `link-disconnected`；`72.45 s` 重连。`id 41` 同样反复
  `map-receipt-timeout` 并重发。
- 圆屏 `RASTER commit type=3 id=42` 后：
  - `E (58170) task_wdt ... - IDLE0 (CPU 0)`，`CPU 0: help`，`CPU 1: IDLE1`；
  - `Stack canary watchpoint triggered (help)`；
  - `rasterRows`（`RasterRenderer.h:44`）→ `helperLoop`（`RowWorker.h:12`）；
  - 同样 `Re-entered core dump`、`RTC_SW_CPU_RST`、checksum 失败。

## 与旧证据的关系

- 烧录前应用 `2c267899` 是 11 月 6 日 SPI polling + FIFO 候选，导航负载尚未验收。
- 旧 `6c1444ad…` 回退镜像对应上午 `b54ea31b…` 的 SPI 崩溃，仅作历史证据；
  本轮回退使用实读的 `2c267899…`。
- 用户这次电池重启的归因仍未完成；本次两次重启是候选导航负载下的栈 canary，
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

## 后续

修复顺序建议：

1. 先在 `2c267899` 回退镜像上复跑同一路线/样式，确认旧版是否也出现栈 canary，
   以分离本次候选改动与共享地图 WIP；
2. 若旧版稳定，审查 `fastPush` 的 `fastBuf[bi]` 与 `RM.fb` 指针/长度校验，
   并检查 `rasterSmoothColor` 与地图 WIP 的全局数组越界；
3. 修复后重新构建候选、归档新哈希，再按原短测/长测流程验收。
