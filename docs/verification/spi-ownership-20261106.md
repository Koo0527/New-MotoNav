# fastPush SPI 超时所有权修复 — 2026-11-06

## 范围

本轮只闭合 `firmware/boards/175/MotoNav/src/display/DisplayPipeline.h` 中 `fastPush` 的 SPI 事务收尾所有权，不改变等待参数、看门狗预算、快刷帧格式或面板命令序列。

## 缺陷

`spi_device_polling_end()` 返回超时或其他未知错误时，事务可能仍在途。原实现在 `break` 后无条件拉高 CS 并 `spi_device_release_bus()`；ESP-IDF v5.5.4 会在 `spi_device_release_bus()` 中断言“polling transaction in progress”，同时 DMA 缓冲可能仍被驱动持有。旧宿主桩在超时时无条件清 `inFlight`，因此绿灯掩盖了该缺口。

ESP-IDF v5.5.4 `spi_device_polling_end()` 的语义：

- `ESP_ERR_TIMEOUT`：`spi_hal_usr_is_done` 未置位，`host->polling` 仍为 true，事务在途。
- `ESP_ERR_INVALID_STATE`：DMA 描述符已回收后，由 `SPI_TRANS_DMA_RX_FAIL/TX_FAIL` 返回。
- 其他错误：完成状态不明，按在途处理。

## 修复

- 新增 `transactionUnresolved`。
- `polling_end` 返回 `ESP_ERR_TIMEOUT` 或未知错误：记录 `fastFlushFaultStage=3` / `fastFlushError`，不拉高 CS、不释放总线、不启动下一笔，直接返回 false；由既有 `flushTask` 的 `saveAndRestart`/`ESP.restart` 兜底。
- `polling_end` 返回 `ESP_ERR_INVALID_STATE`（DMA 已回收）：正常拉高 CS、释放总线，但仍不启动下一笔。
- `polling_start` 返回 `ESP_ERR_INVALID_STATE`（设备已有未终止 polling 事务）：同样保留 CS/总线；普通启动失败（未提交）正常收尾。
- 获取总线失败保持原行为：记录 stage 1，拉高 CS，不释放。

## 宿主 RED → GREEN

- 先改 `firmware/tests/flush-ownership/fastpush_check.py` 的假驱动：
  - `polling_end` 超时保留 `inFlight=true`；
  - `release_bus` 在 `inFlight` 时断言失败；
  - `polling_start` 普通失败不置在途；
  - `ESP_ERR_INVALID_STATE` 模拟 DMA 已回收。
- 修复前：`python3 firmware/tests/flush-ownership/fastpush_check.py` → `Assertion failed: (!inFlight), function spi_device_release_bus`，退出 1。
- 修复后：同一命令通过；`check.py` 的 fastPush、controlWake、production flush ownership 三项全部 passed。
- stale-start 用例另行临时移除所有权判断验证会变红，恢复后再次全绿。

## 回归

| 测试 | 结果 |
| --- | --- |
| `python3 firmware/tests/flush-ownership/check.py` | PASS（fastPush / controlWake / flush ownership） |
| `python3 firmware/tests/heap-checks/check.py` | PASS |
| `python3 firmware/tests/raster-work/check_sources.py` | PASS（生产头文件字节一致） |
| `raster-work/main.cpp` | PASS 7,455,483 checks |
| `raster-work/receiver.cpp` | PASS 131 checks |
| `python3 ios/tests/screenoff-maps/run.py` | PASS（96 checks 等 5 组） |
| `python3 ios/tests/reroute-recovery/run.py` | PASS 1301 checks |
| `ble-bulk`（`BleBulkWriteQueue.swift` + `BleWritePacer.swift`） | PASS 27 checks |
| `python3 ios/tests/map-source-mode/run.py` | 连续 3 次 PASS；首跑曾出现一次未复现的异步时序失败 |

`map-source-mode` 首跑失败为一次性时序抖动（`captures=2, fine=false`），未改动产品代码，随后含调试运行与三次复跑均为 `captures=1`。真机首图/换块仍需按计划现场验收。

## 构建候选

- 构建：`python3 firmware/build.py --jobs 4`（Arduino ESP32 core 3.3.10），exit 0。
- Sketch 1,346,883 bytes（42%）；静态 RAM 118,068 bytes（36%）。
- 版本仍为 `v7.12.10-pages.175c.16`。
- 归档目录：`output/spi-ownership-20261106/`。

| 文件 | SHA256 |
| --- | --- |
| app `0x10000` | `f3e6b7949d5fee12dfd456918156b9ecf8929fcb089cc54f916cc69052f2b044` |
| full `0x0` | `9e07cb560f9e0cd2148aa497fff96b4b37cfc95ed39b3ac7c53e265dbfeb43df` |
| ELF | `744b172767e3214a759cd84b585c9e92ee9ad18f612718c04f200e50c8b56e50` |
| manifest | `77ce389d50134cbe6b21ded44fb4f918e18a9a508396456d786228b82787de21` |

该镜像尚未烧录，`manifest.deviceTested` 为 `false`。

## 真机待办

- 按计划第 1 节冻结现场并抓取完整事件；本次没有新增 coredump 或带时间戳的串口日志。
- 电池/USB 对照、首图冷/热缓存 3+3 次、换块/锁屏/重算/受控重连。
- 至少 60 分钟连续导航，其中 30 分钟电池供电；零意外重启、零新 panic/WDT、零误报 `NO DATA`。
- 烧录只写 `0x10000` 应用区，保留 NVS/配对/缓存。

## 回退

- 上一候选回退镜像：`output/g-spi-fifo-fix-20261106/rollback/pre-spi-fifo-app0.bin`，SHA256 `6c1444ad431561a59912faac47ebd2e095a5cf9f33cdc9b56255a5b227647701`。
- 源文件回退：`DisplayPipeline.h` 与 `firmware/tests/flush-ownership/` 对应改动。
- 不修改分区表、NVS、配对数据或用户离线缓存。
