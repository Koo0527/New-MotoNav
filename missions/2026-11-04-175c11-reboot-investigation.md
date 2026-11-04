# Mission: 175c.11 intermittent reboot investigation

## Goal

排查 175c.11 偶发返回开机 logo，使用真实复位原因和匹配 ELF 区分崩溃、看门狗、flush 自愈及供电问题，再确定最早损坏内存的位置。不把发现问题的调用栈当作写坏内存的调用栈。

## Board / Target

- ESP32-S3，Waveshare ESP32-S3-Touch-AMOLED-1.75，8MB OPI PSRAM。
- Arduino ESP32 core 3.3.10；安装 SDK 的 `esp_idf_version.h` 为 ESP-IDF 5.5.4。
- 当前设备：`v7.12.10-pages.175c.11`。本次只读取 Flash，没有烧录。

## Constraints

- 不改 BLE 协议、配对、设置、NVS 和分区表；不提交现有 WIP。
- 不通过删除 HEAP 日志、扩大 flush 超时或额外喂狗掩盖崩溃。
- 解码必须使用 bin 的 app description 中 ELF SHA256 对应的 ELF。

## Files in Scope

本轮只新增此档案；下方诊断固件方案尚未实施，固件源文件未改动。

## Findings and Evidence

### Confirmed panic during this investigation

用户确认复现操作：打开 G 仪表页或校准，并转动设备。

原始抓取 `/tmp/motonav-reboot-watch.log`：

```text
[  2553.6s] G state=3 ... n=0 ...
[  2557.7s] HEAP int free=83556 min=82960 largest=42996 | psram free=3381064 largest=3342324 | drop_ovs=0 drop_full=0 ack_drop=0
[  2566.9s] G state=3 ... n=710 ...
[  2568.1s] Guru Meditation Error: Core  1 panic'ed (LoadProhibited). Exception was unhandled.
[  2568.1s] PC      : 0x4209805a ... A2 : 0x8bbdecec
[  2568.1s] EXCVADDR: 0x8bbdecf0
[  2568.1s] ELF file SHA256: f8ec82942
[  2568.4s] Reset reason=4, sleep wake=0
[  2571.8s] MotoNav ready, firmware v7.12.10-pages.175c.11
```

崩溃前未出现 `saveAndRestart`、`flush stalled`、TWDT 或 Brownout 标记。本次复位已确认为 panic；这不能排除其他尚未捕获的重启具有不同原因。

匹配 ELF：`firmware/.build/road-palette11/output/MotoNav.ino.elf`，完整 SHA256：

```text
f8ec82942a0348afa1b81b4f9096674f29a22d59702639202eceea5eca6ccb3c
```

175c.11 app bin SHA256：

```text
1c2ba88d6603bbcd9294af7fdde744e56e91221321aa73dc8cf05165266a9c53
```

`xtensa-esp32s3-elf-addr2line -pfiaC` 解码结果：

| Address | Function | Source |
|---|---|---|
| 0x42098057 / PC 0x4209805a | tlsf_walk_pool | tlsf.c:212 |
| 0x42097f24 | multi_heap_get_info_impl | multi_heap.c:427 |
| 0x42097fc9 | multi_heap_get_info | multi_heap_poisoning.c:397 |
| 0x42039f1b | heap_caps_get_info | heap_caps.c:375 |
| 0x42039f69 | heap_caps_get_largest_free_block | heap_caps.c:304 |
| 0x4201a09a | updateStats | src/map/MapFrame.h:162 |
| 0x420228c8 | loop | MotoNav.ino:264 |
| 0x42034514 | loopTask | Arduino cores/esp32/main.cpp:82 |
| 0x40383a9d | vPortTaskWrapper | FreeRTOS port.c:139 |

反汇编进一步确认 `0x4201a09a` 的参数是 `0x800 = MALLOC_CAP_INTERNAL`。在 TLSF 遍历下一块的过程中，堆块长度值为 `0x4bef2346`，去掉标志位后为 `0x4bef2344`，导致下一块指针落到 `0x8bbdecec`，再读取 `+4` 时异常。内部堆元数据损坏的置信度高，具体写入者尚未知。由寄存器和指令逆推的上一块头地址候选为 `0x3fcec9a4`，不能当作跨重启稳定地址直接硬编码监视。

G 采样/校准与本次崩溃有明确时间关联，优先追踪 `DeviceInstruments.h` 的采样开关、FIFO 读取、校准和 G 页面绘制。现有静态检查中，SensorQMI8658 的双传感器 FIFO 分支会将输出数量限制在传入数组容量内，读取缓冲也按 fifo_bytes 分配；尚未发现可直接认定为根因的溢出语句。

### Preserved Flash core dump

- 通过 esptool 只读 `0xFF0000` 的 `0x10000` 字节；原抓取先暂停，提取后恢复。
- 转储有效长度 19,652 字节，CRC32 `0x53ddd4ad` 与尾部校验相同。
- 内含 ELF core，`ESP_CORE_DUMP_INFO` 的 ELF 哈希前缀为 `f8ec82942`，对应本次固件。
- 解析到 11 个任务快照；首个崩溃任务 TCB `0x3fcec394`，名称 `loopTask`。
- SDK 已启用 Light heap poisoning、5 秒 TWDT panic、栈 canary/watchpoint 及 Flash core dump；`CONFIG_ESP_COREDUMP_CAPTURE_DRAM` 未启用，因此这份 core 不包含完整堆，不能直接还原损坏块的分配者或写入者。
- 完整日志、app bin、匹配 ELF、原始 dump 和抽出的 core ELF 保存在 `/tmp/motonav-175c11-reboot-evidence/`。此目录在临时存储，需长期保留时另行归档。
- 恢复后的抓取：`/tmp/motonav-reboot-watch-after-coredump.log`，启动时的 `Reset reason=11` 是工具打开串口造成；恢复抓取时长 4,200 秒。

### What 175c.10 optimized; comparison with 175c.11

| Change | Purpose | Reboot relevance |
|---|---|---|
| 455eda4: HUD String → bounded snprintf; const char* drawing overloads | 减少逐帧堆分配，保持文字一致 | 降低分配压力；不能防止其他代码写坏堆 |
| ab67f9d: initLaneBuf startup allocation | 将车道约 42KB 缓冲从首次绘制移到启动，分配失败可诊断 | 与已有日志一致，空闲 PSRAM 少约 43KB；不等同于泄漏 |
| ab67f9d: RX/ACK drop counters | 观测丢包 | 本次崩溃前计数为 0 |
| 1f4be49: HudText test + mission | 回归和证据 | 本轮重新运行 HudTextTest 通过 |

第二轮 mission 明确记录：实际烧录的 175c.10 已包含当时语义栅格 WIP 和 `flush stalled 5s; restarting` 兜底。直接扫描保留的 .10/.11 app bin，两者均含该 restart 字符串、均不含旧 `continuing degraded` 字符串。因此不能把这些直接归为 .11 新增。

.10 ELF SHA256 为 `face07c6302263fc9772a599d261b8b4470f75e947bdfc2acb8862b82aed8c78`，与保留的 .10 app description 匹配。两份 ELF 均有 4,833 个文本函数；按符号名称和大小比较，只有 `controlDrawLock()` 大小从 163 变成 167 字节，与工作树中的解锁时不擦黑背景 WIP 相符。函数大小相同不能证明字节或语义完全相同，不能据此宣称 .10/.11 仅有一个变化；实际构建均未保存完整源码快照。

### Other audited risks, not this panic's established cause

- `controlWake()` 在 flushDone 等待 100ms 失败后仍操作 panel。库内部的 SPI bus acquisition 不保证同一个 panel device 被多个任务并发访问时安全；该风险仍存在，但本次栈不支持把它认定为重启原因。
- fastf 关闭时 flushWait 的 3+2 秒等待与 5 秒 TWDT 存在竞争；不能保证总是先打印软件重启日志。
- `parallelRows()` 的 helpDone 等待仍为无限等待；若工作任务出问题，也可能触发 loopTask watchdog。
- 应用层 #f/#q 在 CommandReceiver 也有直接 ESP.restart 的分支；正常短命令优先被 BLE callback 拦截并打印 saveAndRestart，但不能将现有日志清单理解为所有调用点都具有同样日志。
- `/tmp/motonav_longcapture.py` 的 boots 变量同时计数 ESP-ROM 和 ready，一次完整启动会计为两次。分析应独立计数 ROM/Reset reason/ready，不能直接采用脚本的 boots 数字。

### Second-pass audit (2026-11-04 下午, crash-writer hunt)

**损坏窗口收窄（重要）**：2557.7s 的 HEAP 行打印成功（TLSF 遍历完好），2568.1s 崩溃发生在下一个 10s tick——**首次非法写入落在 [2557.7s, 2568.1s] 的 ~10.4 秒窗口内**，与 G 采样流（n 0→710）、校准、用户转动完全重合。触发条件明确且窗口极窄，适合分段完整性检查定位。

**coredump 二次挖掘**（ELF32 段解析）：
- 11 个任务确认：loopTask、IDLE0/1、Tmr Svc、help、ipc0、ipc1、esp_timer、btController、nimble_host、flush。**无独立 G 任务，G 采样在 loopTask 内同步执行**。
- 0x4bef2344/0x4bef2346/0x8bbdecec 在全部已捕获内存中**仅出现于 loopTask 栈上的 panic 寄存器保存区**（0x3fcebd1c-0x3fcebd28），非写入者痕迹；堆区未捕获，写入者原始现场不可得。
- 坏"块头"0x3FCEC9A8 位于 loopTask TCB（0x3fcec394+0x160）之后的未捕获间隙（+0x614），归属分配未知。两种假说并存：(a) 更早的空闲链指针被改导致遍历跳入任意位置；(b) 该处真实块头被覆写。0x4bef2344 也可能是无辜载荷。

**静态审计结果（未发现活跃越界写）**：
| 对象 | 结论 |
|---|---|
| 第二轮 W6 全部栈缓冲（spd[8]/lim[8]/dist[12]/sec[8]/wt[8]/msg[16,28]/t[8,12]/a[8]/b[16]/c[8]） | snprintf 天然有界；memcpy(9)+memset(≤3)+NUL 有界 |
| printCentered/printOutlined/drawBanner const char* 重载 | 只读 |
| 车道缓冲 laneCol/laneA | k=y*W+x，x<W/y<H 全程钳制 |
| GInstrumentRuntime（Stream::frame→bytes[17]、Output::trail[%100]、FifoStatus count 门禁） | 有界 |
| GInstrumentMath（Estimator/CalibrationWindow） | 纯浮点无数组 |
| SensorQMI8658::readFromFifo 6DOF 分支（本固件实际路径） | usable 钳到 min(32,32)；_fifo_buffer 按 fifo_bytes≤1536 精确分配，分块读有界 |
| drawGInstrument / gInstrumentTap / touchPoll（getPoint(x,y,1) 入 [5]） | 有界 |
| I2C 并发 | gSensor、触摸、开机编解码器全部在 loopTask，未发现跨任务 Wire 并发 |

**发现一个休眠缺陷（非本崩溃路径，记录待修）**：`SensorQMI8658.cpp:1050` 单传感器分支 `return samples_read`（最大 256）不带钳制返回——若未来只开单传感器，调用方 `for(i<n)` 会读越 a[32]/w[32]（越界**读**）。当前固件 accel+gyro 恒成对启用（6DOF 分支），不触发。与 GSampling 相关的另一观察：驱动每次 poll 在 `_fifo_buffer` 增长时 free+malloc 内部堆（churn），机制合法但可作为诊断版打点对象。

PSRAM 较首 boot 少 ~885KB（4,265,808→3,381,064）：崩溃前用户推送过栅格地图，与本次堆损坏无既证关联。

**结论**：静态审计与既有证据已穷尽，写入者无法从当前证据定位。档案中已起草的分段堆完整性诊断方案（阶段边界 heap_caps_check_integrity + COREDUMP_DRAM_ATTR 阶段记录 + 发现即 abort）是正确的下一步；建议检查点在 G 路径加密布置（readFromFifo 前后、校准完成写 NVS 前后、drawGInstrument 后、gInstrumentNotify 后），并顺带按 poll 打印 `_fifo_buffer` 指针/大小（其 free/malloc 与损坏窗口同任务同 timeframe）。恢复抓取（`/tmp/motonav-reboot-watch-after-coredump.log`）36 分钟静置稳定，无新崩溃。

## Test Plan

本轮未改固件源码，执行针对性检查：

| Check | Result |
|---|---|
| esp32wb doctor firmware/boards/175/MotoNav --target esp32s3 --json | 0 errors，1 pin warning；扫描器报告 tasks=0，不能作为栈审查通过的证据 |
| firmware/tests/flush-ownership/check.py | PASS |
| firmware/tests/touch-lock/check.py | PASS，ASan/UBSan |
| firmware/tests/HudTextTest.cpp | PASS |
| firmware/tests/FixedPagesTest.cpp | PASS，ASan/UBSan |
| firmware/tests/GInstrumentRuntimeTest.cpp | PASS，ASan/UBSan |
| firmware/tests/GInstrumentRecoveryTest.cpp | PASS，ASan/UBSan |
| Flash dump CRC + embedded ELF hash | PASS |

这些宿主检查不覆盖真实 SensorLib/I2C、BLE 并发或硬件上的非法内存写入。没有重新编译、烧录或运行全套测试。

## Implementation Contract — ACCEPTED 2026-11-04（用户指示"实施诊断吧"）

**Summary:** 制作单独标明版本的临时诊断固件，用已有 `heap_caps_check_integrity(MALLOC_CAP_INTERNAL, true)` 在主循环阶段边界收窄最早损坏位置。阶段编号和 loopTask 栈余量用 `COREDUMP_DRAM_ATTR` 保存，避免检查本身崩溃后丢失阶段；发现损坏立即留下串口错误并 abort。先确定责任阶段，再决定是否需要更细的 FIFO 检查或硬件 watchpoint。

**Non-goals:** 不修猜测中的业务路径；不删除现有统计、关闭 fastf、增大看门狗、修改 BLE/NVS/分区/已有 WIP；不将诊断版宣称为修复版。

**Affected files:**

1. `firmware/boards/175/MotoNav/src/diagnostics/HeapChecks.h` — CREATE；内部堆检查及 core dump 阶段记录，不动态分配。
2. `firmware/boards/175/MotoNav/MotoNav.ino` — MODIFY；在消息处理、raster work、G 采样、页面绘制、flush 边界插入检查，保留现有调用顺序。
3. `firmware/boards/175/MotoNav/src/core/FirmwareConfig.h` — MODIFY；递增并明确诊断版身份，保留 .10/.11 二进制及对应 ELF。
4. `firmware/tests/heap-checks/check.py` — CREATE；测试正常路径、检测损坏后停止执行及阶段记录。
5. 此 mission — UPDATE；接受记录和真机证据。

**APIs touched:** 只新增诊断 helper、堆完整性 API 和 COREDUMP_DRAM_ATTR 数据；BLE 协议、设置 API、NVS keys 均不变。

**Risks:** 并发/性能 MED：完整性检查会占用内部堆锁、改变时序，可能影响复现；只检查已经确认损坏的内部 RAM，避免全 PSRAM 扫描。内存 LOW：少量固定记录，不增加动态缓冲。外设 LOW：不改引脚或驱动。Boot LOW：不改 setup 初始化、分区或启动行为。兼容 LOW：仅诊断固件，协议及 NVS 不变。

**Acceptance criteria / tests:** 新增 helper 检查通过；本档案 6 项针对性宿主回归通过；Arduino 3.3.10 编译通过；只在用户接受诊断方案后进行 app-only 烧录；以同样 G 仪表/校准/转动步骤重试，获取最早损坏阶段、地址、匹配 ELF 和 core。若无法复现，明确记录次数及时间，不宣称修复。

**Rollback:** 精确移除本次诊断增量，不回退用户 WIP；app-only 恢复本档案哈希的 175c.11，保留配对和设置。没有 NVS、分区迁移或 eFuse 操作。

### 实施补充（接受时并入范围）

- 除契约 3 个固件文件外，G 密集打点按 Second-pass 建议落在 `DeviceInstruments.h`（GFIFO_PRE/GFIFO_POST/GNOTIFY/GCAL_PRE/GCAL_POST）与 `src/pages/PageNavigation.h`（GDRAW），均为单行插入、不改变现有调用顺序。
- 遍历策略：轮转（每阶段命中 `nextWalk` 才做全内部堆遍历）+ S_MSG 兜底（上一轮零遍历时强制），空闲也 ≥1 次遍历/loop；任何损坏在数个阶段内被抓，环形记录给出 last-ok 遍历→失败遍历之间的全部阶段过渡。
- 阶段记录/计数器全部 `COREDUMP_DRAM_ATTR`（.dram2.coredump，随 flash core dump 保存）；失败路径只用 <64 字符串口行（避免 Arduino printf 长行触发堆分配）后 `abort()`（复位原因与真实崩溃同类，留 core dump）。
- 每轮 loop 在 S_MSG 挂 10s 自证行 `HEAPCHK n= walks= maxus= stMinB=`，不触碰 MapFrame HEAP 行。
- `_fifo_buffer` 指针/大小打印按第二次审计建议放弃：驱动成员私有不可达，且 GFIFO_PRE/POST 遍历括号本身已精确覆盖其 free/malloc churn，证据价值更高。
- 宿主测试 `firmware/tests/heap-checks/`（stub 头 + main.cpp + check.py，ASan/UBSan）：正常轮转、空闲强制遍历、损坏即停（abort 以异常验证）、环形回绕、10s 节流、固件布线 grep 断言（正式版移除 = `HEAPCHK(` 在固件源零残留）。`FixedPagesTest.cpp` 因 PageNavigation 引入打点增加 `HEAPCHK` 空定义兼容。

## ROOT CAUSE FOUND (2026-11-04, 175c.12diag 两事件 + 代码取证)

**SensorLib 读 QMI8658 FIFO 的单次 I2C 请求超过 ESP32 Arduino Wire 默认 rxBuffer 容量，IDF 驱动按请求长度直接写入，溢出的原始样本包打坏相邻堆块。**

证据链（全部为实测，非猜测）：
1. **两次触发同地址**：`CORRUPT HEAP: Bad tail at 0x3fcec9a0`（事件 1 得 0xff45fb3c/0x009ffb3c@9ac，事件 2 得 0x01a8fd1c@9a0）——与原始 .11 崩溃推导的坏块头 0x3fcec9a8 同区。rxBuffer 为 setup 早期 Wire.begin 时 malloc(128)，位置跨版本确定 → 同地址。
2. **地址算术**：rxBuffer 恰结束于 0x3fcec9a0（128B 块尾毒药位）；txBuffer 紧随其后 malloc → 0x3fcec9ac 为其块头毒药位。溢出从 rxBuffer+128 即 0x3fcec9a0 开始，与两次"Bad tail/head"位置精确吻合。
3. **溢出内容 = 原始 6 轴样本包**：事件 1 两写入值按 12 字节包解析，第 0 个 int16 均为 -1204（相邻样本加速度 X 稳定，合理）；事件 2 写入值 0x01a8fd1c 在 loopTask 栈 a[]/w[] 数组区（0x3fcebd4a/d8c/dfc）出现 3 次——同一批 FIFO 数据流经路径。
4. **代码路径**：SensorQMI8658.cpp:976 `kFifoReadChunk=240` → readRegBuff → SensorCommArduino_I2C.hpp:90 `wire.requestFrom(addr,(uint8_t)len)` → Wire.cpp:525 `i2cRead(num,addr,rxBuffer,size,…)` → IDF `i2c_master_read_from_device` 按写满 size 字节入 rxBuffer；Wire.h:49 `I2C_BUFFER_LENGTH 128`，固件从未调用 setBufferSize。fifo_bytes>128（≥11 组样本）即溢出 4~112B。
5. **触发条件吻合**：G 采样 56Hz 下 poll 间隔 >约 200ms（校准 NVS 写、G 页整屏重绘、flush 造成的偶发停顿）→ FIFO 积累 11~32 组（低于固件 32 组门禁）→ 单块请求 132~240B > 128B。静置 poll 15-57ms（1~3 组=12~36B）永不触发；事件 1 括号内 GFIFO_PRE→POST 19ms 与一次 >128B 的 100kHz I2C 读耗时一致。
6. **阶段括号**（事件 1）：STATS 遍历干净(1168752) → GFIFO_PRE(1168974) → readFromFifo → GFIFO_POST(1168993) → S_G 遍历 FAIL——损坏产生于这一次 readFromFifo 内。
7. 事件 2：同一 walk 在 tlsf.c:212 踩到已坏元数据直接 MMU fault（Cache error）——walk 本身踩雷不影响定位；abort() 写 coredump 时再次遇坏 cache 只留部分转储（.dram2.coredump 环未捕获，但任务栈已足够完成上述取证）。

排除项复核：readFromFifo 自身解析循环（usable 钳 min(32,32)）、单传感器分支（每写有 accel_idx<accel_count 钳制；仅返回值未钳制=越界读，休眠缺陷另记）、_fifo_buffer malloc 尺寸（=fifo_bytes，分块读 offset+chunk≤fifo_bytes）——全部有界，与堆写入越界无关。

## VERIFICATION RESULT (175c.13fixdiag 真机验证, 2026-11-04 下午)

用户以原始触发方式（G 仪表页 + 校准 + 转动，多轮，穿插 BLE/息屏）在 175c.13fixdiag 上复现验证：

| 判据 | 结果 |
|---|---|
| 复现暴露窗口 | **995s（16.6min）**，G 活动（174s 起）约 13.7min——与修复前两次触发（均在 G 密集活动开始后 ≤20min 内）对等 |
| G 活动 | 398 条 G state 行（81 条校准流 state=3），多轮校准+转动 |
| 堆完整性遍历 | **122,466 次全部干净**（maxus=520），零 `HEAPCHK FAIL`、零 `CORRUPT` |
| 重启 | 1 次 boot（烧录后首启），0 Guru/backtrace/看门狗 |
| 堆水位 | free 81,640 / min 80,896 恒定，无劣化 |
| loopTask 栈 | stMinB=16,064 健康 |

对照：175c.12diag 同等操作下两次触发（1169.2s、1200.6s），损坏确定性复现；加 `Wire.setBufferSize(512)` 后同等暴露零异常。结合根因的确定性证明（地址算术 + 内容指纹 + 阶段括号），判定修复有效。

日志：`missions/evidence/175c11-reboot/fixdiag-verification-run1.log`（原始 `/tmp/motonav-175c13fixdiag-run1.log`）。

## RELEASE (175c.13 正式版)

- 诊断打点全部移除（MotoNav.ino 六处、DeviceInstruments.h 五处、PageNavigation.h 一处；净改动为零，git 干净）；`HeapChecks.h` 与 `firmware/tests/heap-checks/` 作为独立工具保留在树中，宿主测试改断言"诊断零残留 + 修复布线在场"。
- FW_VERSION `v7.12.10-pages.175c.13`；保留 175c.10 修复与 175c.11 用户 WIP（RasterEdge 等）。
- App bin：`MotoNav_universal_1.75_v7.12.10-pages.175c.13_panel0_app_0x10000.bin`，SHA256 `b7af272edbe866e8e6fe328cfadffc3f67905c633a0561627c4516895f4f3cbd`；匹配 ELF SHA256 `a0ade6ce28d50ab08b53aa3fb604aa54cf48dcfe76faeaa93c36b7a97367ee89`。
- 烧录 app-only @0x10000（NVS/分区/配对不动）。
- 130s 冒烟 **PASS**：1 次 boot 3.8s ready（自报 175c.13）、0 看门狗/backtrace/ALLOC FAIL、HEAP 行每 10s 共 12 条、drop_* 全 0、`HEAPCHK` 行 0（诊断移除验证）、内部堆 free 83,172。
- 回滚路径更新：如需回退，app-only 重刷 dist 中的 175c.11（SHA256 见档案开头）或本版之前任意包；本修复不涉及 NVS/分区，无迁移。

## Evidence archive

`missions/evidence/175c11-reboot/`：
- `capture-run1.log` — 175c.12diag 两次触发的完整原始串口日志（事件 1 阶段环 + 事件 2 Cache error）
- `coredump2.bin` / `coredump2.elf` — 事件 2 部分转储（任务栈含 a[]/w[] 指纹 0x01a8fd1c×3）
- `fixdiag-verification-run1.log` — 修复验证全程
- `motonav-175c13-smoke.log` — 正式版冒烟

其余大文件（.10/.11 bin/ELF、第一次 core dump）仍在 `/tmp/motonav-175c11-reboot-evidence/`（临时，可丢失；dist 保留 .11 包）。

## FIX (175c.13fixdiag, 用户批准"修复吧，但保留 175c.10 修复与 175c.11 改进")

`MotoNav.ino` setup `Wire.begin(IIC_SDA,IIC_SCL)` 之后：

```cpp
Wire.setBufferSize(512);   // rx/tx 各 512B（净增 ~768B 内部堆），覆盖驱动最大单块 240B 且留 2 倍余量
```

- 建立在当前树（我的 .10 提交 + 用户 .11 WIP 全保留）；零协议/NVS/分区变化。
- FW_VERSION → `v7.12.10-pages.175c.13fixdiag`（修复 + HeapChecks 验证保留；正式版再移除诊断）。
- 宿主回归 8/8 PASS（heap-checks 布线断言新增：`Wire.setBufferSize(>=256) 必须紧跟 Wire.begin`，防止未来移除）。
- app bin SHA256 前缀 `cafad5a7da29f42d`；匹配 ELF `firmware/.build/universal/175/build/MotoNav.ino.elf` 前缀 `72b76ee8e8ec959d`。
- 烧录 app-only @0x10000；boot 3.8s；空闲 HEAPCHK 正常（maxus=410）；内部堆 free 82,904（较修复前 −300B ≈ 扩容净增，符合预期）。
- 验证抓取：`/tmp/motonav-175c13fixdiag-run1.log`（60min 计划）。判据：≥10 轮 G 页/校准/转动（穿插 BLE 断连、息屏）零 `HEAPCHK FAIL`、零重启；通过后才宣称修复并出正式版。

## Diagnostic build & hardware evidence (175c.12diag)

| Item | Value |
|---|---|
| App bin | `firmware/dist/175/panel0/MotoNav_universal_1.75_v7.12.10-pages.175c.12diag_panel0_app_0x10000.bin`（1,346,736B） |
| App bin SHA256 前缀 | `8d0721f217b6a54f`（完整值见 dist；烧录校验 Hash of data verified） |
| 匹配 ELF | `firmware/.build/universal/175/build/MotoNav.ino.elf`，SHA256 前缀 `d50ffab87dd86d8f`（解码诊断 abort 用） |
| 编译 | Arduino 3.3.10 通过：1,346,490B（42%）/ RAM 118,932B（36%） |
| 宿主回归 | heap-checks + flush-ownership + touch-lock + HudText + FixedPages + GInstrumentRuntime + GInstrumentRecovery 全部 PASS |
| 烧录 | app-only @0x10000（/dev/cu.usbmodem2101），NVS/分区不动，3.8s ready 自报 v7.12.10-pages.175c.12diag |
| 自证（空闲） | `HEAPCHK n=14263 walks=4757 maxus=400 stMinB=21440`（30s 内）——遍历峰值 400µs、loopTask 栈余量最低 21.4KB、检查自活跃 |
| 抓取 | `/tmp/motonav-175c12diag-run1.log`（60min 计划，含启动复位 1 次为工具 DTR 所致） |
| 上一段静置证据 | 恢复抓取完整跑满 4200s：1 boot、0 panic（Reset reason=11 为开串口工具所致）——静置不触发，损坏需 G 交互 |

## Acceptance Criteria

- [x] 捕获真实重启，并区分 panic / 软件重启 / 看门狗 / brownout。
- [x] 使用与实际 175c.11 bin 哈希匹配的 ELF 解码，保存原始现场。
- [x] 对比 175c.10 的质量优化和两版保留制品，不将既有 WIP 错认作 .11 新增。
- [x] 确定写坏内部堆的具体代码及触发条件：SensorLib `kFifoReadChunk=240` 单块 I2C 读超过 Wire rxBuffer 默认 128B，IDF 驱动溢出写相邻堆块；触发 = G 采样下 poll 间隔 >约 200ms（校准 NVS 写/整屏重绘等停顿）使 FIFO 积累 ≥11 组样本。
- [x] 诊断固件阶段：方案经用户接受后实施、编译、真机复现两次，均落在 G 采样括号内。
- [x] 最小修复（Wire.setBufferSize(512)）经同操作 ≥16min 真机验证零异常后发布 175c.13；结论基于真机验证而非宿主测试。

## Design Notes

诊断阶段优先复用已有 SDK 堆检查和 core dump，不新增 NVS 重启计数或 brownout 钩子：本次已经获得完整 panic 分类，下一步需要的是首次损坏边界。官方说明堆崩溃通常在实际写坏之后才被发现，建议移动完整性检查逐步收窄责任范围：
https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/api-reference/system/heap_debug.html#finding-heap-corruption

core dump 未开启完整 DRAM 捕获时只能读取已保存的任务/寄存器/标注变量，不能把 ELF 中未保存的全局值当成现场值：
https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/api-guides/core_dump.html

诊断版验证补充：宿主正常/失败分支测试；真实 ESP32-S3 上至少 10 轮打开 G 页、校准、转动、返回页面，并穿插 BLE 连接/断开和息屏/唤醒。记录每轮阶段、检查耗时、loopTask 最小栈余量及异常；失败保留完整日志/bin/ELF/core。此为后续测试计划，本轮没有执行。

## Known Risks

- 尚未识别越界写入者；不能将删除 HEAP 统计视作修复，也不能将 G 采样时间关联视作已证明的根因。
- 诊断完整性检查会改变调度与时间，可能掩盖竞争；若不复现需记录边界而非贸然关闭问题。
- 转储含运行期内存，仅保存在本地；临时目录中的证据重启或清理后可能丢失。
- 当前未检查：离线骑行/电池负载、其他重启类型、真实 SensorLib/驱动的边界测试、全量固件回归；本轮没有固件变更，因此未重建或烧录。

## Current Status

- **State:** COMPLETED — 根因定位（Wire rxBuffer 128B < SensorLib FIFO 单块读 240B 溢出）、最小修复（setBufferSize 512）发布为 175c.13，同等暴露真机验证零异常。
- **Last updated:** 2026-11-04（Asia/Shanghai）。
- **Completed:** 全部验收标准；证据归档 `missions/evidence/175c11-reboot/`。
- **遗留（独立问题，不属本次范围）**：SensorLib 单传感器分支返回值未钳制（越界读，休眠）；离线骑行/电池负载重启类未验证；用户报告的"偶发重启"若后续再现在非 G 场景，需按新证据另行分类。

## Next Step

无（本轮闭环）。若后续再出现重启：先看 Reset reason 与是否有 G 采样关联；G 相关先查本档案根因是否回归（Wire 缓冲被改回），非 G 相关按新 mission 立案。

## History

| Date | Action | Evidence |
|---|---|---|
| 2026-11-04 | Investigation started | 175c.11 身份、匹配 bin/ELF 已核验 |
| 2026-11-04 ~10:44 | Real panic captured | LoadProhibited / Reset reason=4 / TLSF internal heap walk |
| 2026-11-04 | User confirmed operation | 打开 G 仪表页或校准、转动设备 |
| 2026-11-04 | Read-only Flash dump | CRC32 and ELF hash match；恢复独占串口抓取 |
| 2026-11-04 | Diagnostic contract drafted | 尚未接受；无固件源码变更 |
| 2026-11-04 | Second-pass audit | 损坏窗口收窄至 [2557.7s,2568.1s]；coredump 任务名/全段 0x4bef2344 搜索；G 路径+第二轮改动静态审计全部有界；记录 SensorLib 单传感器分支休眠缺陷；方案维持待接受，建议 G 路径加密打点 |
| 2026-11-04 | Contract ACCEPTED（"实施诊断吧"） | G 密集打点并入范围（DeviceInstruments.h/PageNavigation.h） |
| 2026-11-04 | 175c.12diag 实施 | HeapChecks.h + 12 阶段打点 + 宿主测试 7/7 PASS + 编译 + app-only 烧录；空闲自证 maxus=400 stMinB=21440 |
| 2026-11-04 | **两次触发，根因定位** | 事件1: S_G 遍历 FAIL @0x3fcec9a0/9ac + 阶段括号锁死 readFromFifo 调用；事件2: 同址 walk 踩雷 Cache error + coredump 任务栈取证；代码取证锁定 Wire rxBuffer 128B < FIFO 单块 240B 溢出 |
| 2026-11-04 | 修复实施 | 用户批准（保留 .10/.11）；Wire.setBufferSize(512) + 布线断言 + FW 175c.13fixdiag；宿主 8/8；烧录后进入 ≥10 轮真机验证 |
| 2026-11-04 | **真机验证通过** | 995s/398 条 G 行/122,466 次遍历零异常（对照 .12diag 同操作 2 次触发）；暴露窗口与触发前对等 |
| 2026-11-04 | 发布 175c.13 | 诊断零残留（git 净改动为零）+ 130s 冒烟 PASS；证据归档 missions/evidence/175c11-reboot/；mission 置 COMPLETED |
