# G 记录频率与连续性验收（2026-11-07 至 2026-11-08）

## 当前结论

**记录频率修复已取得设备证据：三组指定窗口均约 20 Hz；另在现有 Build30 完成手机接收/排队/落盘闭环补采。** 这不代表 G 数值精度或整个 G 功能验收完成。Unknown 下明显漂移仍在，卡顿 P95、发热、三姿态和受控 30/60 分钟长测尚未通过。

全部原始资料根目录：`output/g-record-frequency-20261107/`。未清理其他 agent 的未提交修改，未回退当前设备版本。

## 根因与源码改动

旧基线：手机 G 页独立约 18/s，双屏 G 页约 9–10/s，导航约 11/s；三组 overwritten 均为 0，导航记录实际约 9.98 Hz，与固件生成率一致。主因是 A7 生成依附主循环，不是手机保存。

仅降低圆屏 G 页整屏重绘至 5 Hz 不足：d6254442 候选的手机独立 FB1BC517 为 1701/96.636 秒（17.59 Hz），双屏 19A24086 为 1455/100.099 秒（14.54 Hz）。

最终 R2：

- 在既有完整 FIFO 批次逐样本积分后发布真实估计，50 ms 门禁保留相位；8 帧静态队列保留批内多个真实结果。未新增任务/I2C 并发，未重复最后值补帧。
- 输出样本时刻由既有批末时间和积分 dt 回推，非硬件独立绝对时钟；积分时基本身未改。队列满则丢最旧帧并保留序号缺口；失效/换会话/租约结束清队列并计数。
- FIFO 半帧等待跨外层和驱动二次读取保留，仅在完整有效批次或明确故障后重置。生产驱动原本先将非完整 XYZ 计数返回 0，绕过半帧分支；R2 将其统一作为 FifoPairPending，不读取、不积分、不产生有效值。满/溢出/读取失败/饱和仍使姿态失效，Unknown 不强制定重力。
- 保留 CPU0 250 ms/2 tick 空闲窗口、SPI 所有权、Wire、地图行为、配对、安装参数结构、A7 和历史格式。

## 三组设备记录

这三组使用原安装的 iOS Build29 与 R2；后续手机已由其他任务更新为 Build30。

| 场景 | 记录 ID 前缀 | 有效样本与时间 | 选定 60 秒样本 | 缺口 |
| --- | --- | --- | ---: | --- |
| 手机＋圆屏 G 页 | FDEE3ABF | 1506 / 连续 75.249 s，20.0003 Hz | 1200 | 仅结束标记 |
| 手机 G 页独立 | C0C3C0C7 | 1968 / 连续 98.345 s，20.0010 Hz | 1201（端点包含） | 仅结束标记 |
| 模拟导航＋G 手动记录 | B2350C1D | 导航内半开 60 s 窗口，20.0000 Hz | 1200 | 窗口内无 gap |

双屏最大相邻 dt 70 ms；手机独立 83 ms；导航窗口 71 ms。数据和计算结果分别在 `device/records-r2-dual/`、`records-r2-single/`、`records-r2-nav/` 及对应 summary JSON。

双屏手机 GFLOW：record/queued/written 从 3156 增至 4662，增量均 1506，failed=0。后两组未取得稳定控制台计数；后续独立补采见下，未将新计数冒充旧两组的同轮计数。

### 导航窗口边界

模拟驾车 60 km/h，4.2 km 推荐路线，地图和提示持续变化；真实运动依据仍为 Unknown，模拟速度未用于 GMOT 判断。

主机标记 UTC `2026-11-07T16:08:13.621391Z` 至 `16:09:44.562464Z`（北京时间 11 月 8 日 00:08:13 至 00:09:44）。在其内选择开始后 10–70 秒的半开窗口，真实 JSONL 共 1200 有效样本、无 gap。

整条记录在准备路线时已经开始，11723 样本/589.177 秒，不能把整条当导航负载。导航结束后回到 G 页触发入页校准，16:10:31Z 的 `invalid flags 2` 及最终 record ended 均保留；校准缺口在验收窗口外。

固件首末导航 FPSSTAT 之间 119.276 秒：generated=2385（19.9956 Hz）、notifyAttempts=2381；6124 完整样本全部有效；overwritten/skip/discard/error/poseReset 增量均为 0；队列最大 6、最大通知 601 µs、最大 poll 300 ms。生成和通知 4 帧差包含统计边界待发量，不能算作手机丢帧。原始串口日志覆盖整个选定窗口，结束到 16:10:21Z。

资料：`logs/gflow-r2-nav-final.log`、`logs/nav-window-{start,end}.txt`、`device/r2-nav-{summary,firmware-summary,evidence-hashes}.json`。

## Build30 手机计数补采（11 月 8 日）

由于 devicectl 标准输出在 Wi-Fi 中断，USB 冷启动和终端会话也未稳定取得 GFLOW，增加显式测试开关 `MOTONAV_GFLOW_FILE=1`：

- 开启时仅将同一 GFLOW 快照写入 GRecords/GFLOW.log，使用原串行 worker；不增加位置或 G 坐标字段，不改 JSON/JSONL。
- 文件最大 1 MiB，满时保留新的完整快照。默认关闭，无额外文件 I/O；诊断写入失败停止重试，不触发记录停止。
- 当前设备后来已更新 Build30，本轮保留 Build30，没有重装或回退 Build29。确认其包含开关后，带开关重启补采。

记录 `7C4FC011-8D5B-4D40-AB72-CB82EE52F620`：

| 项目 | 结果 |
| --- | ---: |
| 元数据 sampleCount / 实际 JSONL 样本 | 31138 / 31138 |
| 记录接受 / 排队 / 写入 | 31138 / 31138 / 31138 |
| 写入失败 | 0 |
| 完整样本跨度 | 1556.867 s |
| 实际频率 | 19.99978 Hz |
| 首个半开 60 秒 | 1200 |
| 最大相邻 dt | 79 ms |
| 缺口 | 仅 record ended |
| 日志大小 | 131533 字节 |

最终接收账目完全闭合：rx=35322，accepted=35247，invalidFlags=70，tokenReject=5；parse invalid/idle/seqReject 均为 0。35247+70+5=35322。accepted 包含预览，不能全部算进记录；record=31138 与落盘一致。

这段原拟短记录，中途手机切到其他 App，最终持续约 25.9 分钟，包含前后台阶段。**不是规定条件下的受控长测，也不能作为发热、纯前台性能或受控 30/60 分钟验收。** 本轮未同时读回圆屏当前镜像 hash，不能用这段手机补采替代 R2 固件身份验证。

保存并导出后已离开 G 实时页，再以 `MOTONAV_GFLOW_FILE=0` 成功重启当前 Build30，停止诊断 I/O；没有终止未保存记录。资料：

- `device/records-build30-flow/`（含 GFLOW.log、原始记录）；
- `device/build30-flow-{summary,hashes}.json`；
- `logs/phone-app-flow-final.json`（当前安装实例/Build30）；
- `logs/launch-build30-gflow-file.log`、`copy-build30-flow-final.log`、`restore-build30-normal-launch.log`。

## 软件验证与制品

- Native ASAN/UBSAN 的 G 数学、运行、恢复、漂移、运动依据、记录队列、页面预算、真实批次输出、固定页面，以及 map-idle-window、flush-ownership、heap-checks/Wire：`logs/sample-stream-regression.log`。
- 输出相位和队列测试曾在旧实现失败，修复后通过。GSampleStream 在 108 ms 主循环下从 600 个真实积分结果输出 216 个独立估计，验证单调时间、非重复值和 wrap。
- `GFifoDriverHeaderTest.py` 提取并编译生产头部检查：旧代码对部分 XYZ 计数失败；R2 验证 1–5 words 等待、完整 pair 放行、满/溢出拒绝。
- G 记录回归含 72000 样本、长记录、稠密缺口、生命周期等。日志开关测试先以缺少文件失败（`gflow-file-red.log`），实现后全部通过（`gflow-file-green.log`）；新增覆盖实际计数、默认关闭及大小上限。
- 相关 diff check 通过。

R2 app0 SHA256：`25d9dddd9d9218c597ebf50da17d9facd325f731b59ec4198eb6e222ae207348`。归档 `candidate-sample-stream-r2/`，含 app/full/ELF/manifest；仅烧写 0x10000，未烧 full、分区或 NVS。构建应用 1347983 字节、静态 RAM 118292 字节。

原三组结束并退出预览后，esptool 对 0x10000 的 1348240 字节只读校验 digest matched（`verify-after-nav-r2.log`），随后 RTS 重启为主动操作，不算运行崩溃。原始 GFLOW 2576f766 在 `rollback/current-gflow/`；5 Hz d6254442 在 `candidate-5hz/`。

历史诊断包 `candidate-ios-gflow-file/`：Build29，UUID `77BABB3D-25F1-322B-AA6D-C70183EF6624`，IPA SHA256 `1dbd41abf8a111e66a6959bdc4f71e7f2520c5289f3ed810d76e39168c9ceccb`；已被设备 Build30 替代，**不要回装覆盖当前版本**。当时共享地图闭包标注阻断构建，仅在临时副本补一行 @escaping（`build-only-mapfeeder-annotation.patch`），共享地图源码未改；副本 Release 构建、系统信任环境下签名校验通过。该历史包不是最新整包发布候选。

## 异常与未完成项

- 采集重开串口会触发 USB_UART_CHIP_RESET。受干扰 DD48DE8B 记录含 disconnect，已保留但未用于完整一分钟达标判断；之后页内实际重试成功恢复，再开始新的连续记录。
- R2 首次进入采样曾拦截 6 次无效/饱和样本，err=6、resets=7（含启用复位）。三组连续记录期间无新增错误；fault=9 是半帧等待观察，不能据其残留判定新故障。
- **Unknown 下漂移仍不合格**：导航整条记录左向峰值 0.766g，后续 Build30 补采刹车峰值 0.403g；有效帧和无复位不代表重力估计正确。未通过伪造停车或无条件 IMU 归零掩盖。
- Instruments 能列出在线 iPhone，但按名称及已确认 PID 附加都返回找不到进程（`g-live-usb-timeprofiler*.log`）；没有有效 CPU trace，不能宣称找到卡顿/发热热点。
- 可信停车后的恢复、真实 FIFO 故障注入、三姿态、道路精度、P95 卡顿、发热功耗对照、受控 30/60 分钟长测仍未完成。
