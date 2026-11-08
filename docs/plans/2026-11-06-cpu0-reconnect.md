# MotoNav 导航重启与重连补图修复计划

> 2026-11-07：诊断 R2 捕获两次 IDLE0 TWDT 的完整 RTC 快照，已落地帧间空闲窗口。
> 板上候选 `36e41316…` 的 USB 导航对照最长 idle 间隔为 295 ms，无意外复位。
> Build 29 三次受控重连均目检出图，其中一次可闭合新底图的提交及回执证据。
> 详细记录见 `docs/verification/cpu0diag-r2-20261107.md`，电池与长测继续暂停。

## 1. 固定基线与取证

- [x] 勘误验收档案：串口三次 `IDLE0` TWDT（`E 249450`、`E 35536`、`E 58170`），
  首段在 CPU0 backtrace 后截断，后两段在写 coredump 时二次 canary；手机 JSON
  443 事件、4 个 map-ack、3 次断连，ACK 后 6.22–6.24 s 断连，7 次回执超时均在重连后。
  原始日志和转储保持原样。
- [ ] 用板上 `2c267899` 和原手机 Build 28 在桌面复跑同一路线、赛博朋克、同亮度/屏速/
  快刷，热缓存 3 次、每次 90 秒；复现则保全日志后停止该组。
- [x] 冻结 `381aa2a4` 构建源码：`output/build-base-381aa2a4/`，Git 基线 `df63e19`，
  快照 `0409dac`（父 `df63e19`），21 个未跟踪固件/测试文件，`source.tar.gz`
  SHA256 `a9e519df…`；候选 app/ELF 哈希已复核。
- [x] 2026-11-06 现场复现（Build 29 直装，非计划中的 Build 28 基线）：圆屏仍为
  `2c267899…`，串口 `E (557980) task_wdt`，`IDLE0 (CPU 0)`，`CPU 0: help`，
  `Stack canary watchpoint triggered (help)`，`Re-entered core dump`，复位原因 6；
  coredump CRC `26b416bf` / image `ffffffff` 无效。手机 JSON 415 事件、12 个
  `map-send` 全为 v2、7 ACK、2 超时、3 `link-ready`，最后事件是录制后 228.78s；
  UART 的 557980 是固件开机后的毫秒数，两端无法直接对时。匹配 ELF 显示
  canary 发生于写 coredump 时。该组已停止，首发的 CPU0 IDLE0 超时待取证。证据见
  `docs/verification/ios-reconnect-20261106.md` 与 `output/ios-reconnect-20261106/`。

## 2. 固件修复 CPU0 调度

- [x] 诊断版：CPU0 轻量 idle hook（时间/计数）、`help` 起止、`flush` 帧起止、
  SPI acquire 与每笔 `polling_start/end` 最大耗时/最后阶段、任务栈水位（字节），
  正常任务每秒汇总；以首段 TWDT 为主证据。
- [x] 帧/分片持续完成而 CPU0 无空闲：导航首帧后每 250 ms 在下一帧前 `flushWait()`，
  保持 `flushDone` 所有权，阻塞 2 个 RTOS tick 再归还；无双缓冲也留窗口。
- R2 的两次快照中刷屏、渲染和 SPI 分片持续完成，保持现有 SPI 超时、5 秒 TWDT 和任务栈。
- [ ] 转储故障单列；后续需要完整转储时另用诊断镜像扩大 coredump 栈并做受控注入。

## 3. iOS 修复重连后的底图发送顺序

- [x] 先红灯：`link-ready → CAP,CTL,1 → CAP,MPAL,1 → CAP,MPAL,2 → U,1`，
  捕捉 MPAL 确定前提交 v0；另测 `CAP,MPAL,2` 为首个认证通知。
  （宿主：`ble-palette-lifecycle` 先失败于“auth must not resend the map before capability settles”。）
- [x] 底图补发收口一个入口：认证 + MPAL v2 发当前块一次；认证后 1 秒能力协商；
  到期用本连接最高能力；无 MPAL 走 v0；期间只保留最新底图；断连清等待/旧回调；
  迟到能力改变格式时保留在途 ATT 回调槽，取消旧包分片/回执，以新 ID 重发一次；
  重复能力通知不重发。
  （宿主：`MapFeeder.onLinkReady/onAuthenticated/flushReconnectMap`，`map-source-mode` 17/17b/18 覆盖。）
- [x] 同一底图全量重发上限一次；`N,3,id` 或最终超时允许一次完整重试；再次失败等待
  替代块/能力变化/新连接；连续定位不重开预算；只有当前会话 `K` 更新确认状态。
  （宿主：`onReject/onReceiptTimeout/mapRetryUsed`，`map-source-mode` 19 与 `ble-palette-lifecycle` K/N 覆盖。）

## 4. 回归、烧录与验收

- [ ] 宿主：固件 `flush-ownership`、`heap-checks`、栅格源/接收；iOS
  `ble-palette-lifecycle`、`ble-bulk`、`map-source-mode`、`screenoff-maps`；
  纯提交与集成快照结果分列。
- [ ] 先验固件（原 App）3 轮短测：实际出图、无意外重启、无 `IDLE0` TWDT，
  诊断最大空闲间隔 ≤1 秒；再换 iOS 候选做受控重连，确认 v2 板不在协商期先发 v0。
- [ ] 完整短测：赛博朋克 USB/电池各 3 冷 + 3 热首图；普通样式、锁屏、重算、换块；
  通过后 60 分钟连续导航（≥30 分钟电池），零重启/新 panic/WDT/误报 `NO DATA`。
- [ ] 每份候选保存完整源码、app、ELF、构建参数和哈希；只写 `0x10000`；再次重启先保全
  首段串口和转储，再回退到实读镜像。CPU0、重连补图和电池重启结论分开报告。
