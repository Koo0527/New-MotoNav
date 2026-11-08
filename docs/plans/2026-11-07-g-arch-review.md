# Architecture Review — G 记录频率与连续性（CPU0 r1 基线）

**Verdict: PASS WITH NOTES**（方案可继续，但必须先计数确认，不得直接改算法）

## Tool output

`esp32wb doctor .` 输出 target unknown、66 个 pin errors。该工具把 Arduino 库/多板
pins 当成 ESP-IDF 目标扫描，未识别本工程 FQBN；这些 pin 结论**不作为本工程证据**。
本报告结论来自源码审阅、CPU0 交接文档和已归档制品。

## Critical issues

未确认的 critical 级竞态/内存错误；有一个高风险的候选根因需要计数验证。

## High-risk findings

1. **A7 单 pending 槽可能覆盖帧。**
   `DeviceInstruments.h:241-242` 只在 `gStream.pending` 为真时通知，`:356` 每采样重写
   `gStream.bytes` 并置 `pending=true`；通知比采样慢时，旧帧被覆盖。`notify()` 返回值
   未计数。需要 A7 生成/待发覆盖/通知尝试计数，再决定 8 帧队列。
2. **通知调用没有返回值/失败计数。**
   `Notifications.h`/`DeviceInstruments.h` 中 `txChar->notify()` 未检查；无法区分
   “未生成”“覆盖”“BLE 拒绝”和“手机未收”。
3. **手机 A7 接收无序号/拒收计数。**
   `BleLink.swift:790` 直接 `GRecorder.shared.receive(d)`；`GRecorder.receive`
   (`:607-657`) 只按 token 过滤，没有 A7 序号缺失、无效帧、token 拒收的每秒钟计数。
4. **GRecorder 保存计数缺失。**
   `receive` 增加 `record.sampleCount`，`append` 在 `:659-703` 批量写入；没有
   accepted/enqueued/written/failed 四类计数，无法证明“接受==落盘”。
5. **FIFO 等待跨轮询风险。**
   现有 `FifoWait` 需确认外层完整、驱动二次读取半帧时，等待期限跨轮询累计，而不是
   每次重读清零；需要半帧/空读/二次计数/溢出/饱和测试。
6. **构建基线风险。**
   当前 `firmware/dist` 的 `381aa2a4…` 是旧崩溃候选；CPU0 修复在共享工作树未提交。
   任何诊断构建必须包含 `output/cpu0fix-20261107/source/patch.diff` 的窗口补丁，并
   以 app/ELF 哈希核对。

## Checklist

- FreeRTOS/timing：诊断只每秒汇总，禁止采样/刷屏热路径逐帧 `Serial`；不改变
  `continuousMapDraw` 的 250 ms/2 tick 空闲窗口。**OK（约束）**
- Concurrency：A7 待发队列固定、单写者/单消费者；重连清空旧会话；计数同域。**NOTES**
- Memory：8 帧固定队列，不占 PSRAM/DMA；heap/栈回归。**NOTES**
- Peripheral/SPI：沿用已修复的单在途 polling/所有权，不触碰。**OK**
- Storage/NVS：不改分区、配对、安装参数和历史格式。**OK**
- Phone：GRecorder 仍 20 Hz 入队、5 Hz UI；写入 worker 串行。**NOTES**
- Build：CPU0 补丁必须包含；旧 dist 不得使用。**ISSUE**
- Logging：诊断字段只在 `#GD` 追加，A7/命令不变。**OK**

## Required tests before merge

- A7 生成/覆盖/通知/接收/保存计数守恒测试。
- 8 帧队列边界、溢出缺口、重连清理、token 过滤。
- FIFO 半帧/空读/二次计数/溢出/饱和/跨轮询等待。
- CPU0 idle ≤1 s、flush-ownership、map-idle-window、heap-checks。
- 三组 60 s ≥1,080 样本；断流 gap；首帧新坐标；无 TWDT/canary。

## Not reviewed

地图/栅格 pipeline、完整 BLE 协议栈、iOS 全量并发、六轴物理精度、30/60 分钟长测。
