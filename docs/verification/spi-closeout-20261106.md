# `d710337` SPI 整改收尾 — 2026-11-06

## 范围

关闭 `d710337` 遗留的两项宿主验收阻断：

- 未终止的 SPI 事务在 `fastPush` 返回后仍持有已失效的栈描述符；
- 刷屏测试依赖未提交的 `controlWake()` 唤醒屏障。

不改变等待参数、正常帧流程、看门狗配置、面板命令序列或地图/G 逻辑。

## 事务描述符生命周期

`flushTask` 原有的故障日志、`saveAndRestart("fastf", 0, true)`、`ESP.restart()` 和
死循环提取为 `[[noreturn]] fastFlushFatal()`。

- `fastPush` 在结束超时、未知结束状态或 `polling_start` 报告旧事务未终止时，仍在
  局部描述符 `t` 和 DMA 缓冲 `fastBuf[bi]` 的作用域内直接调用 `fastFlushFatal()`。
- 该路径不拉高 CS、不释放总线、不启动下一笔、不发放 `flushDone`。
- 获取总线失败、普通启动失败、DMA 已回收（`ESP_ERR_INVALID_STATE`）仍按原逻辑收尾，
  再由 `flushTask` 调用同一个 `fastFlushFatal()`。

### ASan RED → GREEN

`firmware/tests/flush-ownership/fastpush_check.py` 现在从生产 `flushTask` 入口注入故障，
假驱动在 `polling_start` 成功后保存真实描述符指针；`saveAndRestart` 在模拟复位回调中
读取 `lastTrans->length`、`tx_buffer` 和 DMA 缓冲首字节。

- 修复前（`d710337`）：`clang++ -fsanitize=address -fsanitize-address-use-after-return=always`
  运行，报 `stack-use-after-return`，访问对象为 `fastPush` 的 `t`，位置在
  `saveAndRestart`。
- 修复后：同一用例通过。超时、未知结束错误和旧事务未终止三条路径均只进入一次复位，
  没有下一笔事务、提前拉高 CS、总线释放或 `flushDone` 发放；描述符与 DMA 缓冲可读。
- 保留正常多块传输、获取总线失败、普通启动失败、DMA 已回收四类回归。

## 唤醒屏障

仅暂存 `DeviceControlRuntime.h` 中 `controlWake()` 的屏障 hunk：

```cpp
if (flushDone) {
  flushWait();
  panel->displayOn();panel->setBrightness(0);controlBrightness=0;
  xSemaphoreGive(flushDone);
} else {
  panel->displayOn();panel->setBrightness(0);controlBrightness=0;
}
```

`controlDrawLock()` 的徽标 hunk 保留在工作树，未进入提交。

## 提交与独立副本

- 生命周期提交：`df63e19`，只含 `DisplayPipeline.h`、`fastpush_check.py` 和
  `DeviceControlRuntime.h` 的 `controlWake` hunk。
- 纯 HEAD archive `df63e19` 中 `flush-ownership` 和 `heap-checks` 通过；
  `raster-work/check_sources.py` 因 iOS `RasterDecoder` 夹具尚未包含工作树的
  `rasSemanticVersion` 同步而失败。
- 为避免把地图 WIP 混入生命周期提交，使用 `git stash create` 生成的完整源码快照
  `0409dac91bd54850ec37ddab6312911dab451b03` 作为独立副本。三项测试在该快照中全部通过：
  - `flush-ownership/check.py`
  - `heap-checks/check.py`
  - `raster-work/check_sources.py`

## 候选构建

- Git 基线：`df63e19`（`git rev-parse HEAD`），完整源码快照 `0409dac`。
- 工具链：Arduino ESP32 core 3.3.10；FQBN
  `esp32:esp32:esp32s3:FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,PSRAM=opi,CDCOnBoot=cdc`。
- 命令：`python3 firmware/build.py --jobs 4`，exit 0。
- Sketch 1,346,867 bytes（42%）；静态 RAM 118,068 bytes（36%）。
- 版本仍 `7.12.10-pages.175c.16`，`manifest.deviceTested=false`。

归档目录：`output/spi-closeout-20261106/`。

| 文件 | SHA256 |
| --- | --- |
| app `0x10000` | `381aa2a4fa02db298b1e58de7cfb9ecc0eb584776cab9587afb4cc201a0bf5fb` |
| full `0x0` | `22ec144c70689c23478c25562f1af3a549f71cf5dbcecfc04ac6e39973157370` |
| ELF | `5cb1886be82ecbf13c6018949c5ebb6998f82ec1bf33b84e8ea3a73c3bd4dfc7` |
| manifest | `787fed1ec55c0c81366a500ae0482cb6e653e37f3b85b13de2d000edeb659901` |

镜像核对：

- full 镜像 `0x10000` 切片 SHA256 = app SHA256 = `381aa2a4…`。
- app 内嵌 `esp_app_desc_t` 位于 `0x20`，`app_elf_sha256` =
  ELF SHA256 = `5cb1886b…`。
- 旧候选 `f3e6b794…`（`output/spi-ownership-20261106/`）保留作对照，未烧录。

## 真机交接（未完成）

1. 先保全板上现有 coredump；从**当时板上实际应用**读回回退镜像。
   旧 `6c1444ad…` 对应上午 SPI 崩溃的 `b54ea31b…`，只作历史证据，不能当作当前回退。
2. 只写应用区 `0x10000`，保留分区表、NVS、配对、校准和离线缓存。
3. 先验证启动、亮屏、息屏，再跑 USB/电池导航对照：
   - 赛博朋克冷/热缓存各 3 次首图；
   - 普通样式换块、锁屏、重算、一次受控重连；
   - 至少 60 分钟连续导航，其中至少 30 分钟电池。
4. 记录新复位签名、首帧实显时间、`NO DATA` 前后时序和三类丢包计数。
   只有拿到匹配现场证据，才把最近一次电池重启归因到具体路径。
