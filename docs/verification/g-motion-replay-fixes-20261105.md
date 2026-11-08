# G 仪表复核：校准触发、回放缺口与运动依据诊断

日期：2026-11-05

源码基线：固件 `v7.12.10-pages.175c.16`、iOS 当前工作区

范围：仅源码修改、宿主机测试与记录核对；本轮未烧录、未安装、未操作设备，也未完成长时真机精度验收。

## 1. 本轮修复

### P1 自动记录／重连订阅不再误触发安装校准

`firmware/boards/175/MotoNav/GInstrumentRuntime.h` 的 `AutoMount` 现在记录触发来源：

- 只有 G 页面的可见上升沿（明确进入仪表）可以在运动状态未知时建立自动校准 `pending`。
- 导航自动记录、断线重连等 `#GS` 订阅只有在可信停车（`Stopped`）时才建立自动校准；运动未知（`Unknown`）时不会重设安装参数。
- 订阅发生在运动中的情况仍等待明确停车，再允许校准；重新进入 G 页仍是明确请求。
- 校准窗口本身仍要求约三秒连续静止，不改变原有稳定性判定。

回归测试：`firmware/tests/GMotionEvidenceTest.cpp` 新增 `poll(false,true,Unknown)==false`、明确入页 `Unknown==true`、订阅 `Stopped==true` 断言；`GInstrumentRuntimeTest` 等四个固件 G 测试通过。

### P2a 历史回放保留缺口边界

`ios/MotoNav/GRecorder.swift` 的 `loadSamples` 不再忽略独立的 `gap` 记录：

- 独立缺口行输出为 `valid=false, gap=true` 的边界点，保留缺口开始时刻。
- 返回时间窗口的请求若从缺口内部开始，会合成窗口起点的前导缺口边界。
- `ios/MotoNav/GChartGeometry.swift` 的 `selected` 按“上一有效样本到下一有效样本”的缺口区间判断；缺口内返回 `nil`，由界面显示“当前时刻数据间断”，不再回退到缺口前的旧值。
- 带 `gap` 标志但本身有效的样本仍保留自身数值，只是不作为跨缺口连线的起点。

回归测试覆盖开头、中间、结尾缺口、窗口内缺口，以及“最后有效样本第 1 秒、记录到第 10 秒”的复现场景。

### P2b 降采样按连续有效段处理

`loadSamples` 删除了 `bucketGap` 向整桶传播的逻辑：

- 遇到独立缺口行或带缺口的样本时，先输出当前段并重置分桶。
- 每个连续有效段独立保留首尾样本及横向／纵向两轴极值。
- 缺口两侧曲线和峰值均保留，不会跨缺口连线，也不会把整桶标记为间断。

回归测试使用 20+20 个样本、单桶降采样和中间缺口，验证缺口标志数量为 1、两侧均有有效点、两侧极值均保留。

## 2. `motion=2` 的调查结果

### 判定链路

`LocationService.gMotionFix` → `GMotionFix.status` → `GMotionReporter` 每秒发送 `#GM,<status>` → 固件 `MotionEvidence`（3 秒 TTL）→ `gCurrentMotion()` → G 采样与校准。

`status=2` 只有以下原因：

1. 原始定位缺失（权限、系统定位开关、软件模拟源、无缓存定位）。
2. 原始定位年龄不在 `0...2s`。
3. 水平精度不在 `0...20m`。
4. 速度无效（`speed < 0`，例如 Core Location 返回 `-1`）。
5. 速度精度不在 `0...0.5 m/s`（包括 `-1` 或较大值）。
6. 速度在 `0.3...1 m/s` 之间，无法判为停车或行驶。
7. App 非前台，或当前定位早于本次前台恢复时刻；非前台只发送一次 `#GM,2`，随后由固件 TTL 过期。

### 源码层面需要下次真机区分的情况

- 非导航时 `LocationService.desiredAccuracy` 仍是 `kCLLocationAccuracyHundredMeters`，且 `pausesLocationUpdatesAutomatically=true`。停车时水平精度可能超过 20m，或定位更新暂停导致年龄超过 2s。只有真实导航／网页导航／巡航会调用 `setPrecise(true)`。
- 静止时 `CLLocation.speed` 或 `speedAccuracy` 可能返回无效值 `-1`；保守策略会把它判为未知，不能据此伪造停车。
- 日志中的 `motion_rx_age_ms=135` 只能证明 `#GM` 消息近期到达，不能证明消息内容是 `0`，也不能单独证明 App 在前台。
- 现有压力日志没有记录原始定位年龄、水平精度、速度、速度精度和 App 前后台状态，因此尚不能把 398 条 `motion=2` 归因于某一个阈值。

### 新增的只读诊断

G 仪表页面的说明卡新增一行“定位依据：...”，显示：

- 可信停车／可信行驶／未知及具体拒绝原因；
- 原始定位年龄、水平精度、速度 ± 速度精度；
- App 非前台、无原始定位、定位早于本次前台等状态。

该诊断只读取现有 `GMotionFix`，不改变 `#GM` 状态、阈值或固件判定。下一次真机测试应同时记录这一行与固件 `motion=`／`motion_rx_age_ms=`，先确认是“定位精度不足”“速度精度无效”“年龄过旧”还是“前后台状态”，再决定是否需要在 G 页面／记录期间申请高精度定位；不能直接放宽阈值。

## 3. 采样连续性

`err=1、ovf=2、resets=20` 的短时压力结果不足以判定静置精度失败。仍需在固定支架、地图／音乐／G 记录并行负载下复测有效样本率、FIFO 故障、姿态重置和零偏。

运动未知时，采样中断后仍采用保守策略：等待重新校准或恢复可靠采样，不沿用旧的静置时间。既有代码检查与测试未发现“采样中断后沿用旧静置时间”的路径。

## 4. 保留项

`175c.13` 的 Wire 缓冲扩容，以及 `175c.15` 的启动失败检查／恢复链保持不动，本轮不回退、不重复当作待修项。

## 5. 本轮验证

宿主机通过：

- iOS Release 全量构建（宿主沙箱内需额外传 `OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'` 才能运行 Xcode 的 SwiftUIMacros 插件服务器；该参数仅用于本轮验证，不修改项目源码）。
- `GInstrumentRuntimeTest`、`GMotionEvidenceTest`、`GInstrumentRecoveryTest`、`GInstrumentDriftTest`
- `ios/tests/g-recording/check.py`（含 72,000 样本压力、缺口回放与分段降采样）
- `ios/tests/g-chart/main.swift`
- `ios/tests/g-motion/main.swift`
- `ios/tests/g-motion/check-location.py`

尚未完成：水平／45°／近竖直各十分钟、地图＋音乐＋G 记录并行六十分钟、道路精度与真实停车分类长测。上述宿主机测试不能替代真机长时精度验收。
