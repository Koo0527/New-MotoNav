# Mission: review-fixes-r2

## Goal

第二轮固件质量修复（范围 C）：消除导航渲染热路径的每帧 String 堆分配（W6）、车道缓冲启动期分配（W8）、丢包可观测性计数器进 10s 串口日志；并归档 C1 的 iOS 侧证据。不改业务逻辑、协议报文零变化、屏幕文字逐字节相同。

## Board / Target

- **Chip**: esp32s3
- **Board**: Waveshare ESP32-S3-Touch-AMOLED-1.75（board 175，universal firmware）
- **ESP-IDF version**: Arduino ESP32 core 3.3.10（ESP-IDF 5.x），FQBN esp32:esp32:esp32s3:FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,PSRAM=opi

## Constraints

- 不改业务逻辑 / BLE 协议 / 视觉行为；屏幕文字逐字节相同（含 float 舍入）。
- 屏幕文字等价依据：arduino-esp32 的 `String(double,1)` 底层是 `dtostrf`，而 `dtostrf` 实现为 `sprintf("%.*f")`（cores/esp32/avr/dtostrf.c）——`hudDistText` 用 `snprintf("%.1fkm")` 与它走同一个 newlib 格式化，任何输入输出一致。
- 非目标：handleText String 解析重构、pendingStat/pendingEvt 低频单槽、协议级 CRC/流控、RasterEdge 集成（用户 map-edge WIP）、MapFrame.h pendingStat 协议串。

## Files in Scope

| File | Action | Notes |
|------|--------|-------|
| `firmware/boards/175/MotoNav/src/graphics/HudText.h` | CREATE | 纯 C、宿主可测：hudDistText / hudFmtInt |
| `firmware/boards/175/MotoNav/src/graphics/VectorDrawing.h` | MODIFY | printCentered 加 const char* 重载（防隐式 String 构造） |
| `firmware/boards/175/MotoNav/src/map/MapHud.h` | MODIFY | printOutlined 加 const char* 重载；:59,66-69,87-92 热路径改栈缓冲 |
| `firmware/boards/175/MotoNav/src/graphics/StatusWidgets.h` | MODIFY | :6,25,40,46-49 同上 |
| `firmware/boards/175/MotoNav/src/graphics/JunctionOverlay.h` | MODIFY | :13,37,39,40 字面量/整型直出 |
| `firmware/boards/175/MotoNav/src/map/NavigationMarkers.h` | MODIFY | :19-22,38-49,203-218（drawBanner 加 char* 版，String 版委托） |
| `firmware/boards/175/MotoNav/src/map/CameraOverlay.h` | MODIFY | :79-80 电子眼限速数字 |
| `firmware/boards/175/MotoNav/src/graphics/LaneDrawing.h` | MODIFY | initLaneBuf() 启动期分配（mallocHalt）；删懒分配分支留防御 |
| `firmware/boards/175/MotoNav/MotoNav.ino` | MODIFY | setup() 在 mapInit() 后调用 initLaneBuf() |
| `firmware/boards/175/MotoNav/src/core/DeviceContext.h` | MODIFY | 新增 volatile rxqDroppedFull 计数器 |
| `firmware/boards/175/MotoNav/src/connectivity/Bluetooth.h` | MODIFY | 环满丢最旧处 ++rxqDroppedFull（临界区内） |
| `firmware/boards/175/MotoNav/src/map/MapFrame.h` | MODIFY | 10s HEAP 行追加 drop_ovs/drop_full/ack_drop |
| `firmware/tests/HudTextTest.cpp` | CREATE | hudDistText/hudFmtInt 边界断言 |

## Design Notes

- **W6 关键点**：`printCentered(const String&)` 传 `char*` 会隐式构造 String（等于没改），必须加 `const char*` 重载才能真正做到零堆分配。原 String 版保留（ArrivalAnimation 等低频调用点继续用）。
- 等价格式表：`String(int)`≡`"%d"`；`distText(m)`≡`m>=1000?"%.1fkm":"%dm"`；`tripRemainM>=100000` 分支≡`"%dkm"`（整数除）；宽度计算 `String::length()`≡`strlen`。
- W8：laneCol(28,160B)>16KB 由 malloc 默认策略落 PSRAM、laneA(14,080B) 落内部堆——initLaneBuf 用同样的 malloc（allocFailHalt 包裹），放置策略不变。
- C1 iOS 证据（2026-11-03 核实，代码见 ios/MotoNav/BleLink.swift）：`MAX_WRITE=500`(:18)；maxWrite=min(两侧 MTU 派生值, 500)(:313-314)；bulk 'M' 载荷=maxWrite−15≤485(:434-448)；位图 'B'=maxWrite−10≤490(:488-496)。**iOS 恒 ≤500 < 固件 RXQ_MAX 514，兼容。** Android 源码不在本仓库 → 用户动作项：核对 Android 单次写入 ≤512。
- 工具链在 /private/tmp（重启即失）：build 需 ARDUINO_DIRECTORIES_DATA/DOWNLOADS/USER 指向 /private/tmp/motonav-esp32-toolchain；本轮顺带复制到 ~/motonav-esp32-toolchain 持久化。

## Acceptance Criteria

- [ ] HudTextTest 通过（999→"999m"、1000→"1.0km"、9999→"10.0km"、hudFmtInt 边界）
- [ ] 全量桌面测试回归通过（27 存量 + 1 新增 = 28）
- [ ] 热路径 grep 无 String 构造残留（MapHud/StatusWidgets/JunctionOverlay/NavigationMarkers/CameraOverlay 目标行）
- [ ] `python3 firmware/build.py` 编译通过、manifest 生成
- [ ] 真机 120s 冒烟：1 次 boot / 0 看门狗 / 0 backtrace / HEAP 行每 10s 且含 drop_ovs/drop_full/ack_drop=0
- [ ] 屏幕文字逐字节相同（用户目检，可与骑行实路一起做）
- [ ] 协议报文零变化（本轮不触碰任何 pendingAck/notify 构造路径的报文内容）

## Test Plan

- [ ] HudTextTest.cpp（clang++ -std=c++17，assert+main 既有模式）
- [ ] 全量 firmware/tests 桌面回归
- [ ] build.py 编译（/private/tmp 工具链环境变量）
- [ ] app-only 烧录 @0x10000 + 120s 串口冒烟（判据同第一轮）
- [ ] 实路骑行后串口日志 drop_* 计数应为 0（用户配合）
- [ ] 可选：8h USB soak 看 HEAP min/largest 碎片化趋势

## Known Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| 视觉不等价（float 舍入） | LOW | String(double,1) 与 %.1f 同走 newlib sprintf（dtostrf 实测如此）；HudTextTest + 真机目检兜底 |
| char* 重载遗漏导致隐式 String 回流 | LOW | 实施后 grep 目标热路径确认无 String( 残留 |
| 车道启动期提前占 42KB（PSRAM 28K + 内部 14K） | LOW | 内部堆预算已核对（上轮冒烟 free 84,728B） |
| 环满计数器在临界区内自增 | LOW | volatile uint32 自增，与 oversize 计数器同模式 |

## Current Status

- **State**: COMPLETED (hardware smoke passed)
- **Last updated**: 2026-11-04
- **Completed items**: P1-P5 全部完成；桌面 28/28；175c.10 烧录 + 120s 冒烟 PASS
- **Blocking issues**: none

## Next Step

用户侧验证：① 屏幕文字逐字节目检（车速/限速牌/行程行/路口灯/红绿灯距离/电量，可与骑行一起）；② 实路骑行后看串口 drop_* 计数是否恒 0；③ 核对 Android 端单次 BLE 写入 ≤512（源码不在本仓库）。

## Hardware Test Evidence (2026-11-04, board on /dev/cu.usbmodem1101, battery removed)

| Build | Result |
|-------|--------|
| 175c.10 app-only @0x10000（校验 OK，硬复位） | **PASS**：120s = 1 次 boot（3.8s ready，串口自报 v7.12.10-pages.175c.10），0 看门狗/0 backtrace/0 ALLOC FAIL；HEAP 行每 10s 共 11 条，drop_ovs=0 drop_full=0 ack_drop=0 |

Log: /tmp/motonav-r2-smoke.log

堆水位对比上轮（175c.9，空闲态）：
- 内部堆 free 83,448（上轮 84,728，−1,280B 静态增量）
- PSRAM free 4,265,808（上轮 4,308,824，−43,016B ≈ laneCol 28,160 + laneA 14,080 + 开销）
- **实测修正**：两个车道缓冲都落在 PSRAM（计划预估 laneA 落内部堆）。malloc 的放置策略与原懒分配语句逐字节相同（同一条 malloc 挪到 setup），落点由 IDF 默认堆策略决定；结果反而更省内部堆。车道混合每帧 ≤210×30 像素走缓存 PSRAM，性能代价可忽略（raster/iconBuf 本就在 PSRAM）。

## 构建说明

- FW_VERSION 175c.9 → 175c.10（第一轮两次烧录共用了 .9 名导致 dist 覆盖；本轮起每轮交付递增，回退用 175c.8 或从 bc6aa71 重建）。
- **烧录的 175c.10 = 本轮提交 + 用户未提交 WIP**（GameMapStyle.h / RasterBuildingCarry.h / RasterContinuity.h / RasterRenderer.h / DisplayPipeline.h 的 flushWait 兜底从"降级"改为 restart）——与第一轮烧录口径一致（当时 WIP 同样在树中）。提交不含任何 WIP。
- 工具链已从 /private/tmp 复制到 ~/motonav-esp32-toolchain（APFS clone，2.1G）并验证可编译。后续构建环境变量：
  `ARDUINO_DIRECTORIES_DATA=~/motonav-esp32-toolchain/data ARDUINO_DIRECTORIES_DOWNLOADS=~/motonav-esp32-toolchain/downloads ARDUINO_DIRECTORIES_USER=~/motonav-esp32-toolchain/user python3 firmware/build.py`

## History

| Date | Action | Notes |
|------|--------|-------|
| 2026-11-04 | Created | Initial mission（esp32wb mission new） |
| 2026-11-04 | Contract accepted | 第二轮修复计划经 plan-mode 批准（含 iOS MAX_WRITE=500 证据） |
| 2026-11-04 | P1 W6 | HudText.h + printCentered/printOutlined/drawBanner char* 重载 + 5 文件热路径替换 |
| 2026-11-04 | P2+P3 W8/观测 | initLaneBuf 启动分配；rxqDroppedFull + HEAP 行 drop_* 计数 |
| 2026-11-04 | P4 验证 | 桌面 28/28；FW_VERSION→175c.10 构建；烧录 + 120s 冒烟 PASS |
| 2026-11-04 | P5 | 工具链持久化 ~/motonav-esp32-toolchain 并验证 |
