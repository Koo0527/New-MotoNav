# MotoNav 导航重启与重连补图修复计划

> 执行状态：设备暂停在回退镜像 `2c267899`；本轮只完成取证勘误和修复底座冻结。
> CPU0 诊断、基线复跑、烧录和 iOS 组合验收待设备恢复。

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

## 2. 固件修复 CPU0 调度

- [ ] 诊断版：CPU0 轻量 idle hook（时间/计数）、`help` 起止、`flush` 帧起止、
  SPI acquire 与每笔 `polling_start/end` 最大耗时/最后阶段、任务栈水位（字节），
  正常任务每秒汇总；以首段 TWDT 为主证据。
- [ ] 若帧/分片持续完成但 CPU0 无空闲：导航首帧后每 250 ms 在下一帧前 `flushWait()`，
  保持 `flushDone` 所有权，阻塞 2 个 RTOS tick 再归还；无双缓冲也留窗口。
- [ ] 若某阶段停止：`polling_end` 卡住时在确认余量后设 100 ms 有界等待，超时走
  `fastFlushFatal()` 并保持所有权；`polling_start` 保持 `portMAX_DELAY`；若 acquire/
  start 卡住查面板/快刷持有顺序；若 `help` 单项卡住先重现再修。保留 5 秒 TWDT 和栈尺寸。
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
