# CPU0 修复接手基线（2026-11-07）

> 状态：其他 agent 已完成 CPU0 导航重启修复；**修复尚未提交**，共享工作树的 HEAD
> 构建会漏掉它。接手时先检查工作树，再改代码或构建。

## 设备与制品身份

| 项目 | 值 |
| --- | --- |
| 圆屏末次确认版本 | `175c.16-cpu0fix-r1` |
| fix app SHA256 | `36e41316587231ae884fe3c58a823b3be8f38c5126f6fc4cdbc6cbb410cf86b4` |
| fix ELF SHA256 | `c1629b89f1b7e69941b5f4fa1cd531bc5f8844300f7ea35f8d8a5fc69a8dd5ef` |
| merged bin SHA256 | `5370456a4b3f78319f734c0819972a67d94302e5ee591f2c7b4f186d4e37b23a` |
| iPhone | MotoNav `0.16.0` Build 29 |
| 验收报告 | `docs/verification/cpu0diag-r2-20261107.md` |
| 制品/源码/日志 | `output/cpu0fix-20261107/` |
| 补丁 | `output/cpu0fix-20261107/source/patch.diff`（SHA256 `7367fce5…`） |

2026-11-07 接手检查：候选 app/ELF 哈希与 `manifest.json`、`SHA256SUMS` 一致；
`python3 firmware/tests/map-idle-window/check.py` 通过。

## 必须保留的导航绘制顺序

`firmware/boards/175/MotoNav/MotoNav.ino` 的 `continuousMapDraw` / `mapIdleWindowAt`
逻辑不得在重构中丢失：

1. 首帧和唤醒首帧立即 `drawNavFrame()` 出图。
2. 连续地图绘制时，距上次窗口至少 **250 ms**，在下一帧开始前：
   - `flushWait()` 取得 `flushDone` 所有权，确认上一帧已刷完；
   - 持有令牌 `vTaskDelay(2)`，阻塞 **2 个 RTOS tick**；
   - 归还 `flushDone`，再 `drawNavFrame()`。
3. 单缓冲也要保留等待窗口；无双缓冲时跳过信号量，但不能跳过同样的空闲窗口。
4. 不得把 2 tick 等待替换成 `yield()`、`delay(0)`，也不得移到刷屏任务仍在途的位置。
5. 保留现有 5 秒 TWDT、SPI 在途事务与 DMA 缓冲生命周期、唤醒屏障，以及 Wire 启动
   扩容与失败恢复。地图、G 仪表和 iOS 的其他 WIP 分开处理。

## 已确认证据

- 两次实机 RTC 快照首发故障均为 `IDLE0` 超时：idle 未闭合间隔分别为
  **5,013 ms / 5,012 ms**；同期 `help`、刷屏帧和 SPI 分片仍在完成。后续 canary
  出现在写 coredump 时，不应按 `help` 栈溢出或 `polling_end` 卡死改。
- 修复候选 USB 三轮导航加补测累计约 **284 秒**实际渲染，最大闭合 idle 间隔
  **295 ms**；零意外复位、零 `NO DATA`，`drop_ovs` / `drop_full` / `ack_drop` 全零。
- Build 29 三次受控重连均发送 v2 并目检恢复出图；仅一次能完整匹配新底图的板端
  `RASTER commit` 与手机 type 3 回执。
- 电池场景与 60 分钟长测仍未验收。

## 改动后的最低回归

```sh
python3 firmware/tests/map-idle-window/check.py
python3 firmware/tests/flush-ownership/check.py
python3 firmware/tests/heap-checks/check.py
python3 firmware/tests/raster-work/check_sources.py
```

另外按固件工作流编译运行栅格 `main.cpp` 与 `receiver.cpp`。真机对照固定手机版本、
路线和设置，要求实际出图、最长 idle 间隔 ≤1 秒、无意外复位或 `NO DATA`。

烧录前按 app 哈希和匹配 ELF 核对身份，实读当前应用作回退，只写应用区 `0x10000`。
