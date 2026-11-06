# 导航首图慢、NO DATA 与圆屏重启修复计划

> 实施 agent 按 `executing-plans` 逐项推进。固件与 iOS 可各自准备回归，圆屏和手机的安装、串口与供电对照由同一人排程。

**目标**　同一导航路线下恢复底图首帧和连续换块，导航数据持续可用，并查清电池供电时的重启原因。先对齐手机取图、BLE、固件收包、上屏和复位的时间，再按证据修复阻塞点。

**现场**　11 月 6 日用户报告最近半小时内，电池供电、赛博朋克样式导航时地图很久才载入，圆屏随后重启，偶尔有 `NO DATA`。用户怀疑其他样式也受影响，需用同一路线实测。当前没有与该时段对应的串口或 coredump。已见的最新刷机记录是 17:18 左右的 SPI/FIFO 候选，实际板上镜像与手机安装包仍需核对。

**范围**　保留已通过的 Wire 扩容与启动保护、导航图源分工、现有 BLE 帧格式、NVS 和用户离线缓存。各项修复以复现为门槛。构建先保存 bin、匹配 ELF、源码基线和哈希，烧录只写 `0x10000` 应用区。共享工作树含地图与 G 值 WIP，按路径核对差异和暂存范围。版本号相同的不同镜像用哈希区分。

## 1. 冻结基线，抓到一次完整事件

- [ ] 记录异常发生的时间、App 构建/安装来源、圆屏 app/ELF 指纹、当前快刷状态、屏速、供电、电量、主题、导航类型和锁屏状态。归档中至少有三份不同的 `175c.16`。

| 镜像 | app SHA256 前缀 | 证据 |
| --- | --- | --- |
| 11 月 4 日地图整合 | `b8af2ef3` | `output/road-multitone/firmware16-artifacts/manifest.json`，132 秒 USB 空闲冒烟 |
| 11 月 6 日 G 恢复首版 | `b54ea31b` | `output/g-live-recovery-20261106/`，当日上午已归档 `spi_intr → spi_bus_lock_bg_exit` 的空指针崩溃。该 bin 与后续刷机前 app0 备份的应用字节一致 |
| 11 月 6 日 SPI polling + FIFO | `2c267899` | `output/g-spi-fifo-fix-20261106/candidate/`，ELF `cd34564c…`，`boot-gd.log` 出现 `lastfifo`。导航负载尚未验收 |

- [ ] 先保全现有 coredump，再做任何重新刷机。分区位置以实读分区表为准，当前归档读的是 `0xff0000`。核对转储 CRC、内嵌 ELF 指纹与先前的 `round-after-reboot-coredump.bin`，防止把上午旧转储算作本次重启。串口开启、ROM 读回可能触发 USB/工具复位，单独标记。电池场景用手机地图时序加录屏，若接电脑会改变供电，改用不供电的可用串口调试方案，或在下一版加低频、可追溯的复位记录。
- [ ] 先在桌面用模拟导航或停放状态复现。固定同一 App、固件、路线、亮度和屏速，先赛博朋克、再一个普通样式对照，逐项切换 USB/电池、前台/锁屏、冷/热缓存。冷缓存用未下载的测试块或隔离的测试缓存。另用同一地点巡航做图源对照，保留现有用户缓存。
- [ ] 手机从屏幕设置的「地图显示问题」开始记录，出现空白、`NO DATA` 或重启后停止并导出。复用 `MapPipelineTrace` 的 `fetch-start`、`tile-start/ready/failed`、`map-staged`、`map-send`、`bulk-queued`、`bulk-backpressure`、`bulk-write-timeout`、`map-wire-finished`、`map-receipt`、`link-disconnected/ready`。检查导出 `dropped` 和字段白名单。缺项只补数值原因码和阶段时间。以 `type/id`、连接代次和动作时刻对齐两端，记录是否真的收到新帧。
- [ ] 固件复用 `HEAP drop_ovs/drop_full/ack_drop`、`RASTER commit`、复位日志。必要时低频记录 BLE 入队、主循环消费、最后一个有效导航/心跳、接收片数、拒绝原因、ACK 发出，以及地图提交后第一帧刷完。`K,3,id` 是固件提交确认，实际刷完需要独立标记或录屏。关键区间尽量不逐包打印，记录启动至首帧、各段耗时、事件顺序和复位签名。

## 2. 固件任务，先闭合 SPI 超时所有权

入口 `firmware/boards/175/MotoNav/src/display/DisplayPipeline.h` 的 `fastPush` / `flushTask` / `flushWait`。已有一次独立宿主复现。以现有 `firmware/tests/flush-ownership/fastpush_check.py` 提取生产 `fastPush`，把假驱动改成 `polling_end` 返回 `ESP_ERR_TIMEOUT` 时保留 `inFlight=true`，`release_bus` 在 `inFlight` 时失败，`polling_start` 的普通失败不启动事务。当前生产函数在该用例会走到 release。原桩在超时时仍无条件清 `inFlight`，因此绿灯掩盖了缺口。实际调用使用 `portMAX_DELAY`，这个注入证明错误路径存在，现场是否到达仍靠日志判定。[ESP-IDF v5.5.4 SPI 驱动](https://github.com/espressif/esp-idf/blob/v5.5.4/components/esp_driver_spi/src/gpspi/spi_master.c#L1263-L1363)

- [x] 让用例先红。区分获取总线失败、未提交就失败、DMA 已回收但返回错误、事务仍在途或完成状态未知。仅对已确认无在途事务的路径拉高 CS、释放总线。对仍在途/状态未知的路径，从事务描述符仍有效的作用域进入单次诊断与现有重启兜底。断言无下一事务、无描述符或 DMA 缓冲复用、无 `flushDone` 发放、无其他面板命令。保留正常刷屏和唤醒场景。`polling_start` 在该 SDK 要求 `portMAX_DELAY`，如引入有界 `polling_end`，以整帧和看门狗预算设计，并覆盖超时后仍在途。
- [ ] 真机原因按签名分流。`fast flush failed` / `flush stalled` / `saveAndRestart fastf=0` 查事务阶段、持有者和快刷持久状态，区分用户设置触发的软件复位。新 panic 用匹配 ELF 解码；TWDT 按最后耗时阶段修阻塞；brownout 或仅电池重复硬复位，用相同负载比较电池接点及输入/3.3 V 瞬态。发现 `fastf` 已为 0 时结合日志/设置历史判断来源。不要把旧 SPI 转储或 `.11` 的 I²C 堆损坏当成本次结论。
- [x] 运行 `python3 firmware/tests/flush-ownership/check.py`、`python3 firmware/tests/heap-checks/check.py`、`python3 firmware/tests/raster-work/check_sources.py`，并按固件工作流编译执行 `raster-work/main.cpp` 和 `receiver.cpp`。（宿主全部通过；面板/WDT、光度与电池负载以真机为准）

## 3. iOS 与接收任务，按首次丢失的阶段修复

- [ ] **未生成宽底图**。看 `NaviBridge.swift` / `RideBridge.swift` 的导航会话和首个定位，再看 `Settings.swift` / `MapFeeder.swift` 的图源切换、`prepareRoute` / `onLocation` 及 `AmapSdkRaster.swift` / `AmapCaptureHost.swift` 的租约与截图。当前普通样式导航走高德，前台未缓存首图依赖截图，单次截图等待上限约 45 秒，等租约另计，失败后的自动取图有 15 秒节流。若证实沿线任务或近景占着首图资源，让当前块宽底图先拿到缓存/截图/发送，增强任务取消或延后。若证实是锁屏无缓存，明确显示可用缓存状态，保留已确认的有效底图，回前台优先补当前块。回归用冷/热缓存、巡航转导航、重算旧回调、锁屏跨块和解锁恢复。
- [ ] **底图已生成但未入队或未收齐**。检查 `MapFeeder.acceptChunk` 是否把首包错误暂存，核对 `BleLink.sendBulk` 的 `maxWrite`、分片数量、认证状态、应用层回执，以及 `BleBulkWriteQueue` 的重连代次和 ACK/ATT 顺序。`maxWrite - 15 < 100` 时当前会直接返回，追踪 `map-send` 后是否实际有 `bulk-queued`。若日志命中，明确进入可恢复状态，确保首次 MTU/认证就绪时能自动发当前块。检查 `drop_*`、ATT 超时、替包和带宽竞争。宽底图、路线和导航更新先于可选细路/建筑。复现重启后自动重连，确认只重发当前会话有效状态，旧 ACK 不得推进当前地图。
- [ ] **圆屏拒绝、ACK 丢失或提交后没显示**。`BulkReceiver.h` 在校验/分配失败时发 `N,3,id`，现有 iOS `BleLink` 与 `MotoNavApp` 没有专门处理这条拒收，主要靠 ACK 超时和定位回调重发。若现场复现拒收，记录实际拒绝理由和字节数；对同会话同包 ID 的 `N` 结束当前等待，按可恢复性安排有界重试，永久无效包等待有效替代。保留原 `K/N` 帧格式。若固件有 `RASTER commit` 和 `K`，沿 `drawNavFrame` 到 `flushTask` 查上屏与刷新耗时，勿重复发送已确认包。
- [ ] **`NO DATA` 在重启前出现**。`MotoNav.ino` 的门槛为已认证且在导航页，超过 6 秒未经过常规 `handleMessage`；地图分片和心跳都能刷新时间。iOS 心跳只在普通队列及 bulk 空闲时发送。对照 `#p`、转向/心跳入队和写出时间、固件入队/处理时间、`drop_full` 与刷屏等待。若 App 队列阻塞，保障有效导航消息有发送机会；若 BLE 已收但主循环未消费，修固件阻塞。保留失联提示本义及 6 秒门槛。
- [ ] 只为命中路径加一个可复现的回归。复跑 `python3 ios/tests/map-source-mode/run.py`、`python3 ios/tests/screenoff-maps/run.py`、`python3 ios/tests/reroute-recovery/run.py`，并编译执行 `ios/tests/ble-bulk/main.swift` 与 `BleBulkWriteQueue.swift`。手机端需要新包时，归档实际 Release 构建/安装的标识，区分当前工作树与用户实装 App。

## 4. 交付门槛

- [ ] 用固定路线对照基线与候选。先用赛博朋克在 USB、电池下各完成 3 次冷缓存启动和 3 次热缓存启动，再复测另一普通样式及前台/锁屏换块、重算和一次受控 BLE 重连。逐次报告首个有效导航帧、首块提交和首帧实显耗时。以同条件下已验证可正常导航的组合为基线，首图耗时对照目标为不回退超过 10%。若没有可用基线，交付前先记录并约定绝对上限。冷缓存取图失败须记录状态与恢复耗时，不能计作成功首帧。
- [ ] 场景内零意外重启、零新 panic/WDT/供电复位、零有数据时误报 `NO DATA`，记录三类丢包计数变化。短测通过后做至少 60 分钟连续导航负载，包含至少 30 分钟电池及反复换块，保留原始日志。主动断连/关闭数据对照应仍能显示原有失联提示并在恢复后清除。空闲冒烟和宿主绿灯单独记录。
- [ ] 报告复位签名、确证的首个故障阶段、所改文件、实际验证结果、匹配 app/ELF 和回退镜像。已知 SPI 缺陷和本次现场根因分列。无法复现时保留测试结果与待抓证据，继续用单一候选及同一基线对照。
