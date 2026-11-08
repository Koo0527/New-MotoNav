# Implementation Contract — G 记录频率与连续性

**Status: ACCEPTED — 2026-11-07，用户明确接受“开始诊断计数”；可按契约修改。**
**Date: 2026-11-07**

## Change summary

先加入端到端、每秒汇总的诊断计数，定位 G 记录 7.66–9.4 Hz 的损失环节；按计数只修
一个根因。若确认 A7 单 pending 槽覆盖，则将固件待发槽改为最多 8 帧的固定队列，保留
真实生成时间/序号，溢出留可识别缺口，重连清空旧会话。目标连续有效区间 18–20 Hz。
同时扩展 FIFO 半帧等待跨轮询累计与校准恢复测试。

## Non-goals

- 不改变 A7、`#GS`、`#GE`、`GMOT`、`#GD` 既有字段语义或历史记录格式。
- 不改地图/栅格 pipeline、CPU0 空闲窗口、SPI/DMA 所有权、Wire 启动修复、配对、
  安装参数结构。
- 不执行 30/60 分钟长测；不以放宽阈值或补造样本达成目标。

## Affected files

| Path | Action | Description |
| --- | --- | --- |
| `firmware/boards/175/MotoNav/DeviceInstruments.h` | MODIFY | A7 待发队列/覆盖与通知计数，调度汇总，保留 G 校准状态机 |
| `firmware/boards/175/MotoNav/GInstrumentRuntime.h` | MODIFY | Stream 固定队列、生成序号/时间、FIFO 跨轮询等待 |
| `firmware/boards/175/MotoNav/src/connectivity/Notifications.h` | MODIFY | 通知尝试/成功/失败计数；不改能力与命令 |
| `firmware/boards/175/MotoNav/MotoNav.ino` | MODIFY | 每秒诊断汇总；不改 `continuousMapDraw`/250 ms/2 tick 窗口 |
| `firmware/boards/175/MotoNav/src/display/DisplayPipeline.h` | MODIFY (仅计数) | 刷屏/FIFO 调度耗时计数；不改快刷所有权 |
| `firmware/libraries/SensorLib/src/sensor/imu/qmi8658/SensorQMI8658.*` | MODIFY | FIFO 二次读取计数与跨轮询等待期限；不改量程 |
| `ios/MotoNav/BleLink.swift` | MODIFY | A7 回调/无效帧/序号缺失/拒收计数 |
| `ios/MotoNav/GRecorder.swift` | MODIFY | 接受/入队/写入/失败计数；记录仍 20 Hz 入队、界面 5 Hz 发布；显式测试环境开关下保存有界计数日志 |
| `firmware/tests/` | ADD/MODIFY | G 流计数、A7 队列、FIFO 跨轮询、CPU0 窗口回归 |
| `firmware/boards/175/MotoNav/src/pages/GPageBudget.h` | ADD | 圆屏 G 页整屏重绘限制为 5 Hz，给采样和 A7 生成留出主循环预算 |
| `firmware/boards/175/MotoNav/src/pages/PageNavigation.h` | MODIFY | G 页使用预算门禁，保留入页、操作和分页布局 |
| `ios/tests/g-recording/`、`ios/tests/ble-*` | MODIFY | 保存计数与 A7 接收回归 |
| `docs/verification/g-short-acceptance-20261106.md`、新验收记录 | MODIFY/ADD | 计数、三组基线、短测结果 |

## APIs touched

- A7 帧格式、`#GS`/`#GE`/`GMOT` 不变；`#GD` 仅追加诊断字段。
- 内部计数器/队列为增量 API；不改 NVS key、分区表、OTA/配对。
- 历史 JSONL 不新增字段；缺口继续用现有 gap 行。

## Risk assessment

- **Concurrency — HIGH**：A7 生成在主循环、通知在 BLE 路径；单 pending 槽
  (`DeviceInstruments.h:241-242`) 在 `:356` 每次覆盖。固定队列必须有边界、序号和
  重连清理；计数器仅主循环写、每秒读一次，避免多任务竞争。
- **Timing — HIGH**：诊断不得在采样/刷屏热路径逐帧 `Serial`；每秒汇总。不得改变
  CPU0 250 ms/2 tick 空闲窗口或 SPI 在途事务。
- **Memory — MEDIUM**：8 帧队列按现有 A7 大小静态分配；不得用堆或 PSRAM DMA；
  需要栈高水位/heap 回归。
- **Phone concurrency — MEDIUM**：GRecorder 的 UI 发布 5 Hz，写入 worker 串行；
  计数必须在同一串行域，避免主线程与 worker 数据竞争。
- **Build/baseline — HIGH**：工作树含未提交 CPU0 修复；构建必须使用
  `output/cpu0fix-20261107/source/build.sh` 的窗口补丁/当前工作树，并核对 app/ELF。
- **Backward compatibility — LOW/MEDIUM**：A7/命令/记录格式不变；诊断字段追加。
- **Boot/peripheral — LOW**：不触碰启动、分区、strapping、SPI 引脚或配对数据。

## Test plan

- TDD：先加能复现 107–108 ms 节奏和 A7 单槽覆盖/队列边界的宿主测试，再实现。
- 固件：GInstrument 数学/恢复/运行、flush-ownership、map-idle-window、heap-checks、
  raster-work；CPU0 idle 间隔 ≤1 s。
- iOS：g-recording（接受=落盘、5 Hz 发布）、g-chart、g-motion、ble-capability、
  ble-pacing、ble-bulk、ble-palette-lifecycle、ride-ble-parity。
- 真机三组各 60 s：G 页独立、手机+圆屏、导航+G 并行；每组从首个有效样本计时，
  至少 1,080 样本/60 s，无无法解释丢帧；故意断流留 gap；恢复首帧无旧黄点；
  accepted == saved；无 TWDT/panic/canary/意外重启。
- 性能/发热：连续性通过后，再对照非 G 页、正常 G 页、关闭额外定位的测试模式。

## Rollback

烧录前实读当前 app0 3 MB 作为回退镜像；只写 `0x10000` 应用区，不写分区表/NVS/
配对/安装参数；候选 app、ELF、日志和哈希归档。失败恢复旧 app0，不动持久数据。

## Acceptance criteria

1. 三组 60 秒至少 1,080 样本/组，连续区间 18–20 Hz；每一处减少由计数器解释。
2. A7 生成/待发/通知/手机接收/保存计数守恒（允许明确 gap）。
3. 断流缺口落盘；恢复首帧显示新坐标；无旧黄点。
4. 无 TWDT/panic/canary/意外重启；CPU0 最长 idle ≤1 秒。
5. 不改变地图、CPU0 空闲窗口、SPI、Wire、配对、安装参数和历史格式。
6. 30/60 分钟、三姿态和道路精度仍为后续验收，不在本契约内。

## Acceptance

2026-11-07 接续实施范围包含上述 G 页预算两文件。三组 GFLOW 显示手机独立约 18/s、双屏约 9–10/s、导航约 11/s，且 overwritten 均为 0。先验证 5 Hz 重绘预算，再按实测决定后续调度修复。

5 Hz 候选 d6254442 已实测：手机独立记录 FB1BC517 为 1701 样本/96.636 秒（17.59 Hz），双屏约 14–15 Hz。手机 record/queued/written=1701，failed=0。后续将 A7 生成移入真实完整 FIFO 样本的积分循环，输出时间戳由既有 BatchClock 的批末时刻和 dt 回推，积分时基不变。输出使用 50 ms 相位门禁和 8 帧静态队列，以保存批内真实估计，不重复最后值补帧。队列溢出保留序号缺口，失效/换会话清队列并计数。

**Accepted 2026-11-07 by user: “接受契约，开始诊断计数”.** Firmware edits may proceed
only within the affected-file list and diagnostic-first scope.

诊断补采：USB 和 Wi-Fi 的 devicectl 标准输出均未稳定取得 GFLOW，新增 `MOTONAV_GFLOW_FILE=1` 测试启动开关。仅开启时在现有 GRecords 目录写入 GFLOW.log，使用原串行 worker，最大 1 MiB，达到上限后保留新的完整快照。默认关闭，不写入诊断文件；不增加位置或 G 坐标字段，不更改记录 JSON/JSONL。诊断文件失败独立于记录保存，停止继续重试。测试先证明缺少日志失败，再验证实际计数、默认关闭和大小上限。
