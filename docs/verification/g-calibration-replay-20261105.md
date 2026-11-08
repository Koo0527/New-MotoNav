# G 校准来源与历史回放窗口补修（175c.16 源码）

日期：2026-11-05

源码基线：固件 `v7.12.10-pages.175c.16`、当前 iOS 工作区。

范围：源码、回归测试、iOS Release 整包构建、ESP32 固件整包构建；未安装、未烧录、未操作设备，未递增交付版本。

## 1. 校准来源与手机入页

### 校准来源

`GInstrumentRuntime.h` 新增 `CalibrationSource`：

- `TrustedStop`：自动记录／重连订阅启动的自动校准。稳定窗口内每次采样都必须是 `Stopped`；变为 `Unknown` 或 `Moving` 立即取消，清空稳定窗口，不写安装参数。
- `ScreenPage`：圆屏 G 页明确入页。允许 `Unknown`（用户确认停车），禁止 `Moving`。
- `PhonePage`：手机 G 页明确入页，经 `#GE` 绑定当前认证会话和流令牌。允许 `Unknown`，禁止 `Moving`。
- `Manual`：`#GC` 手动校准。允许 `Unknown`，禁止 `Moving`，15 秒未完成失败。

保存前（NVS 写入之前）重新检查来源、当前运动状态和会话有效性，而不是只检查启动状态。取消只清空候选窗口和 pending，不改写已保存安装参数；取消后不因运动状态过期变成 `Unknown` 而自动重试，需要新的明确入页、手动命令或可信停车订阅。

手机入页与数据订阅分离：

- 新增能力 `CAP,GENT,1`，保留 `GLOG`、`GMOT` 和 A7 帧。
- 新增 `#GE,<8 位十六进制令牌>,1/0`（14 字节）。`1` 只在手机实际进入 G 页时发送；离页、后台发送 `0`。前台恢复、自动记录、重连、令牌更新和续租不自动重发 `1`。
- 固件按入队时的认证、连接代次、接收时间和当前 `#GS` 令牌校验；旧会话、旧令牌、排队超过 3 秒和重复 `1` 都不会重新触发校准。流结束、令牌变化、断连或离页清除请求；只取消由 `PhonePage` 启动且尚未完成的校准。
- `BleLink.sendGPhoneEntry` 在未 ready/未认证时直接丢弃，不把入页命令缓存到重连；队列以 `#GE` 为 key 只保留最新值。旧固件不广告 `GENT`，不会收到新命令，手动校准入口保留。

## 2. 历史回放窗口与预算

`GRecorder.loadReplayWindow` 返回 `GReplayWindow`：

- `samples`：绘图样本，按连续有效段保留首尾和两轴极值；缺口后的首个有效样本带 `gap` 标志。
- `missing`：裁剪到请求窗口的 `GTimeRange`，带 `startIsSample`/`endIsSample` 边界语义。有效边界样本本身可选；缺口内部返回无数据。
- `peaks`：从原始有效样本统计的窗口峰值，不从降采样结果推算。
- `mergedGaps`：密集缺口是否切换为保守合并。

窗口读取保留窗口前最后有效状态，并继续读取窗口后必要的首个有效样本或尾部缺口。窗口外尾部缺口（记录结束 100 秒、最后样本 43 秒、回看 40–50 秒）会在 49 秒返回间断；窗口起点落在缺口内、开头、中间、结尾和窗口完全位于缺口内均覆盖。

默认预算 2,400，低于 8 按 8 处理。一次流式扫描并行维护详细桶和固定数量的保守摘要：

- 详细模式按连续有效段分桶，保留首尾与两轴极值；缺口不扩散到整桶。
- 详细结果超预算时切换保守合并：桶数为 `floor(limit/8)`，无缺口桶最多 6 个候选点，含缺口桶整段空白，相邻空白桶合并，最多使用两个边界名额。
- 结果和缺失区间均为 `O(limit)`，不随记录总时长或缺口次数无限增长。
- 界面显示“缺口较密，已合并显示，放大查看细节”；放大/移动窗口重新请求详细结果。绘图不跨缺失区间连线，窗口峰值保持原始数据。

## 3. 软件验证

宿主机通过：

- 固件 `GInstrumentRuntimeTest`、`GMotionEvidenceTest`、`GInstrumentRecoveryTest`、`GInstrumentDriftTest`（ASAN/UBSAN）。
- iOS `g-recording`：72,000 样本压力、7,200 点密集缺口、200,000 样本长记录、窗口外/跨窗口缺口、预算与保守合并、手机入页生命周期。
- iOS `g-chart`：缺失区间边界、游标选择、分段与峰值降采样。
- iOS `g-motion`、`check-location`：运动状态、信任边界和定位适配。
- iOS `ble-capability`：22 项（包含 `CAP,GENT,1`）。
- iOS `ble-bulk`：27 项；`ble-pacing`：15 项。
- iOS `ios-fixes`：favorites/search/rides/navigation UI/position/BLE navigation state 六组均通过。
- iOS Release 整包：`xcodebuild ... -configuration Release ... build` 退出码 0，日志 `BUILD SUCCEEDED`。宿主沙箱需要 `OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` 才能运行 Xcode 的 SwiftUIMacros 插件服务器；该参数只用于验证，不修改项目。
- ESP32 固件整包：Arduino CLI 核心 `esp32:esp32@3.3.10` 安装在会话 scratch；`python3 firmware/build.py --jobs 4` 退出码 0，生成 `firmware/dist/175/panel0/MotoNav_universal_1.75_v7.12.10-pages.175c.16_panel0_{app_0x10000,full_0x0,manifest}`。未烧录。

## 4. 硬件待验收

以下仍未完成，不能把软件测试或构建成功当作通过：

- 三个姿态（水平／45°／近竖直）各预热一分钟、持续十分钟；
- 固定支架下地图＋音乐＋G 记录并行六十分钟，统计有效样本率、FIFO 故障、姿态重置和零偏；
- 道路精度与真实停车分类长测，继续采集 `motion=2` 的原始定位年龄、水平精度、速度精度和前后台状态；
- `#GE` 在真实手机→圆屏链路上的到达、令牌绑定、离页/后台清除和校准效果；
- 六轴物理歧义未解决；离线明确校准仍要求设备确实静止。

## 5. 保留项

FIFO Wire 缓冲扩容、启动失败检查与恢复链保持不动；本轮不修改地图链路、配对、安装参数结构或历史记录格式。未递增版本、未安装、未烧录。

## 6. 2026-11-05 设备短时验证尝试

- 圆屏已识别为 ESP32-S3（MAC `c4:9e:7e:0b:7a:54`，32MB flash）。按计划只用 esptool 5.3.0 写入应用区 `0x10000`，写入 1,347,216 字节，返回 `Hash of data verified`；未写分区表、NVS 或配对数据。
- 写前读取当前 app0 备份在约 20% 处中断，esptool 报 `Serial data stream stopped`；未获得可回滚备份。日志：`output/g-calibration-replay-20261105/read-app0.log`。
- 配套 iOS App 已签名构建（0.16.0 / build 28，Bundle ID `com.u238zyc.motonav`），并打包为 `output/g-calibration-replay-20261105/MotoNav-0.16.0-build28-signed.ipa`。
- iPhone 重新通过 USB 枚举后，`devicectl` 覆盖安装成功，设备上的 App 版本核验为 0.16.0 / 28，并已启动。首次未连接时的 CoreDeviceError 4016 已排除。
- 未能抓取圆屏串口启动 banner；需要用户确认首页 `fw v7.12.10-pages.175c.16`。手机入页自动校准、离页取消、手动校准中断连、历史缺口/合并显示四项短时验证待用户实际操作确认。
- 首次安装后 App 启动闪退。崩溃日志显示 `Settings.shared` 初始化调用 `syncMapSource()`，`mapSource` 的 `didSet` 访问 `MapFeeder.shared.resetChunk()`，而 `MapFeeder.shared` 初始化又读取 `Settings.shared`，造成 `dispatch_once` 递归锁（EXC_BREAKPOINT / SIGTRAP）。日志：`output/g-calibration-replay-20261105/MotoNav-2026-11-05-174621.ips`。
- 修复：`Settings` 增加 `initialized` 门禁，初始化完成前 `mapSource.didSet` 不访问 `MapFeeder`；初始化完成后恢复重置行为。`tunnel-settings` 测试桩按真实依赖让 `MapFeeder` 初始化读取 `Settings.shared`，修复前复现 SIGTRAP，修复后通过。
- 修复版签名 App 的 UUID 为 `1B06F38E-464A-3C84-9442-2E8DAB087E11`，已覆盖安装并启动；进程在启动后持续存活，设备上最后的崩溃日志仍属于旧包 UUID `ce3ca4ce-4472-35cf-ae62-e1f12fb3e3ea`。
- 修复后的 IPA 已覆盖 `output/g-calibration-replay-20261105/MotoNav-0.16.0-build28-signed.ipa`。四项短时验证需在修复版上重新执行。
- 短测中又发现实时 G 仪表页滚动/缩放卡顿、黄点间歇消失或固定。根因是时间曲线的 `DragGesture(minimumDistance: 0)` 会把纵向滚动当作游标选择，游标一旦被误设就会停住并在滑出 30 秒窗口后消失；同时 20 Hz 的 1,200 点每帧被完整重复绘制。修复为：仅横向拖动才选择游标、与 ScrollView 并行识别；实时默认跟随最新有效点，游标滑出窗口后回到实时；实时仪表和时间曲线按 120 像素预算做保留首尾/极值的降采样。
- 包含该修复的签名 App UUID 为 `FA011865-8145-33A7-9C9A-DD13E6F55B17`，已覆盖安装并启动（PID 12975），启动后无新崩溃日志。IPA SHA256：`f1f410bbb699b7bef997df0560cea36661b26764147518813e97d6f591503b49`。
- 复测仍报告实时页卡顿/黄点异常，进一步把 `GRecorder` 的界面发布合并到 5 Hz（`liveSamples`、`activeRecord`、`activePeaks`、`status`），记录和落盘仍保持 20 Hz 全量；`g-recording` 新增测试确认节流期间缓冲样本不丢失。最新签名 App UUID 为 `D81C5B62-6E8C-373A-8572-2B426F8883D7`，已覆盖安装并启动（PID 13023），无新崩溃日志。最新 IPA SHA256：`c2a87ac6639f2036401c28f8c23a46a24a447ae4e894f764002be91046c929e6`。
- 圆屏 `WAITING FOR STATIONARY` 的现场诊断为 `state=1 motion=2 mount=1/0 quiet=0.00 err=14 ovf=10 resets=46`：有已保存安装参数，但姿态估计被采样故障/重连重置后，手机定位年龄超过 2 秒，无法给出可信停车。按保守策略不自动放宽停车阈值。
- 进一步修复：G 页前台期间调用 `LocationService.setMotionEvidence(true)`，禁止 iOS 因静止自动暂停定位，离页恢复；入页请求在 GENT 能力或流令牌尚未就绪时保留一次，同一连接能力到达后补发，`resetPhoneEntry`/重连清除，不跨重连重放。最新签名 App UUID `44444324-2BC0-3F7E-9C1C-2B763B596732`，IPA SHA256 `1c12b2706604b627c07175d66300c3c9240bc7cd5110016334ec63cebac3768a`。
- 该最新包已在 iPhone 恢复 `available` 后覆盖安装并启动（PID 19505），启动后无新崩溃日志；四项短测需在最新包上重新执行。
- 现场快速离页/重入时，`#GE,0` 与 `#GE,1` 可能落在同一个固件控制 tick 内；`AutoMount` 只观察 `phoneEntry` 布尔边沿会漏掉新事件，圆屏因此停在 `state=1`。已为 `PhoneEntry` 增加单调 `generation()`，`AutoMount` 按事件代次触发；重复 `1` 仍不重复校准。`GMotionEvidenceTest` 新增“重复 1”和“0+1 同 tick”用例并通过。
- 修复后的固件应用区镜像已构建：`MotoNav_universal_1.75_v7.12.10-pages.175c.16_panel0_app_0x10000.bin`，1,347,264 bytes，SHA256 `0ea8d356bcd3c3f4b0f066ca2b7669f32654f4deef4f0c6ffc917fc7bddde405`，`verifiedApplicationOffset: 0x10000`。
- 圆屏 MAC `c4:9e:7e:0b:7a:54` 已在 `/dev/cu.usbmodem101` 确认；已用 esptool 仅写应用区 `0x10000`，写入 1,347,264 bytes、`Hash of data verified`，未改分区表/NVS/配对数据。现场慢速离页再入已能进入校准/输出，确认了入页边沿问题；快速重入及四项短测待确认。
- 现场进一步反馈：校准成功运行一段时间后会进入 `WAITING`，必须退出/重入 G 页；手机定位依据在“速度无效”和“年龄超出 0–2 秒”之间跳。已增加显式 G 页的故障后自动重校准：仅当圆屏 G 页或手机 G 页仍打开时，采样故障使 `gResets` 变化后重新 arm，仍要求完整 3 秒静止窗口，不覆盖安装参数；自动记录/重连订阅不重 arm。`GMotionEvidenceTest` 覆盖显式页重 arm 与订阅不重 arm。
- 自动重校准固件已重新构建并烧录：`app_0x10000.bin` 1,348,128 bytes，SHA256 `6ab8b317ce287d9970c95b2fbb8c85f72e047110e3483d1f89f96cd6874ccca0`，写入 `Hash of data verified`，仍只写应用区。四项短测与“无需退出页面自动恢复”待用户确认。
- 自动重校准仍未覆盖“页面保持打开但入页意图已被令牌/连接清掉”的情况。G 页新增“重新请求校准”按钮：点击时显式发送一次 `#GE,0` 后 `#GE,1`，强制新入页事件，仍要求静止 3 秒；不改变自动订阅策略。`g-recording` 新增 0→1 事件测试并通过。
- 含按钮的签名包 UUID `897B54F0-5701-3F38-B001-C34DD374A7B0`，IPA SHA256 `ed73c65c9a3d8797676f35e281fa034fda5c7e8ecb9b29ca409b6e548b9f2b28`，已更新到 `output/g-calibration-replay-20261105/MotoNav-0.16.0-build28-signed.ipa`。该包已在 iPhone 恢复 `available` 后覆盖安装并启动（PID 19829），启动后无新崩溃日志。
- 现场确认“重新请求校准”按钮可见、可点；点击并静止约 3 秒后圆屏直接恢复 G 输出，无需退出/重入页面。故障后的自动恢复仍未解决，按钮作为显式恢复入口；手机定位依据仍可能显示速度无效/年龄超限，固件按显式页来源允许 Unknown 校准，不放宽自动订阅策略。
- 现场确认四项短测全部通过：圆屏 `fw v7.12.10-pages.175c.16`；实际进入 G 页约 3 秒自动校准、离页取消；同连接手动校准保存、校准中断连不保存；历史缺口无旧黄点、密集缺口合并提示、放大恢复。实时 G 仪表页滚动/缩放仍卡顿，黄点问题随卡顿仍待定位；故障后的自动恢复仍未解决，需要点击“重新请求校准”按钮。三姿态十分钟、并行六十分钟和道路精度长测仍未恢复。
- 实时页滚动/缩放及四项短测仍需在最终包上由用户确认。
- 相关日志：`output/g-calibration-replay-20261105/flash-round2.log`、`xcodebuild-signed.log`。
