# 三主题多色阶道路：Build28 / 175c.15 代码交付

日期：2026-11-04。执行计划：[road-multitone-20261104.md](../plans/road-multitone-20261104.md)。

**代码、独立审查、主机回归和签名构建已完成；实机验收待进行。** 用户已要求“先完成代码，设备稍后再测”，因此本次未安装最终 Build28、未烧录 175c.15，也未把主机计时视为手机或圆屏验收结果。

## 最终行为

- VC、GTA5、赛博朋克共同保留源图暖色道路的三档亮度，分别映射到主题配色；普通道路、道路分隔、建筑、水域等材质维持既有语义。白天与夜间使用各自调色板。
- 只在原先暖色道路内部确定稳定颜色，最多两轮局部传播；缺少支持的边缘沿用原分类。既不推断实际高度，也不新增道路几何。三色阶加普通道路不等于四个真实高度层。
- 继续使用 2 米道路、约 4 米建筑、现有截图数量、两批建筑交付、道路优先预算和前后台约束。没有启用新图源、全屏抗锯齿或 DENSE 原型。
- 新语义版本 v2 使用已有 16 色 RLE 格式的材质 11；固件认证后同时声明 MPAL 1、2。新 App 按已认证最高版本发送，旧 App／固件和旧地图仍有降级与回退路径。
- 三游戏主题共用质量版本 4 的采集缓存；保留有效 v3/v2 楼块成果和旧完整图，旧包不伪装成新版本，不删除用户离线地图。
- 当前和衔接中的上一块地图各自使用对应版本的调色板。新能力迟到时，等待已准入传输及回执结束，再比较实际发送内容；不取消首批地图。

保留已有 G、按键、电源和隧道功能的源码与接口。未接入工作区中未编译的 VectorTiles、VectorMapRaster、MapEdgeGeometry 文件；没有额外启用其他对话的图源方案。

## 审查与修复

三个实现阶段分别独立审查，最终再审查整条链路；最终没有未解决的 Critical／Important 问题。已修复：

- v2 降级时完整重建 v1 调色板，避免只替换部分槽位。
- 固件对语义地图严格执行 480000 字节上限；照片原有容量限制不变。
- 迟到 BLD 能力不再取消已准入地图，且会重建既有沿线建筑队列，保留当前地图与回执。
- 无当前代地图时，旧完整包优先于旧部分包；新代部分成果仍优先于旧代。
- 固件测试生成器改用独立运行目录，重复运行或 dry-run 不删除旧制品。

RLE 校验的版本判断移到循环外，避免每个游程重复解析头部；线上没有新增依赖。

## 自动验证

| 验证 | 结果与边界 |
|---|---|
| `python3 ios/tests/road-palette-core/check.py --real-corpus` | portable 与六区域通过；覆盖三色阶、传播支持和同票规则、偏移窗口共同区域、格式校验、降级、版本保留。明波及城区有效内区与已认可右侧金样一致。 |
| Swift 生产输出 → C++ 生产解码 | 六区域各道路、建筑两包，共 1728 万像素逐一一致；非法标记、索引、截断、边界长度另有回归。 |
| 固件实际 validator／decoder／renderer／queue／通知 | ASan、UBSan 通过；包含新旧双缓冲配色、取消、迟到包、建筑清除、能力通知，以及 480000 接受／480001 拒绝。 |
| raster-work 与 fixture parity | 7455483 项检查通过；相关夹具与生产头文件保持字节一致。 |
| `python3 ios/tests/screenoff-maps/run.py` | 生产 feeder／cache 96 项及附带 map-delivery 回归通过，覆盖迟到能力、道路预算、慢链路、换区、重算与前后台。 |
| building-capture／delivery／offline | 生产调度、缓存和队列回归通过，覆盖旧楼块复用、渐进交付及后台只读缓存。 |
| BLE capability／bulk／palette lifecycle | 能力认证与最大版本、断连清零、诊断字段及 GM 队列兼容回归通过。 |
| `python3 scripts/tests/test_benchmark_road_palette.py` | 两种模式各两次隔离 dry-run，通过旧文件保留检查；未操作设备。 |

iOS harness 的 BLE 回执、UIKit 和高德采集使用 stub；生命周期 harness 执行提取的生产通知／复位语句，而非整个 CoreBluetooth 回调。上述验证不能替代实际 ACK、SDK 取图和硬件运行。现有 Swift 弱引用警告、SensorLib 废弃头警告及主机编译器忽略 ESP optimize 属性的提示未在本轮改动。

最后复跑的 core 六区域、screenoff 96 项、测试生成器和 fixture parity 均通过。带 CRLF 的既有文件按 `cr-at-eol` 规则检查，`git diff --check` 通过。

## 生产预览和包大小

预览用冻结的已交付 v1 源码与当前 v2 源码处理同一原始输入，再由生产固件解码／绘制；没有用旧的单一平色原型充当更新前基线。输出保留原有部分建筑覆盖状态，三主题昼夜及 0°／45°／90°数据均有留档。

- [明波立交 v1／v2 对照](../../output/road-multitone/production-preview/06-mingbo-v1-v2.png)
- [密集城区 v1／v2 对照](../../output/road-multitone/production-preview/01-dense-v1-v2.png)
- [六区域包大小](../../output/road-multitone/production-preview/comparison-inputs.json)

六区域非暖色材质逐像素保持不变。地图包大小增幅为 **0.35%～2.81%**；明波从 148124 增至 148762 字节，增加 638 字节（0.43%）。这是包大小，不包含实际蓝牙分片、重试和两批累计流量。

## 主机性能参考

同五个原始区域、每区七次（一次预热、其余取中位数），比较原生 Swift 读入、分类、编码、四片楼块处理、合成与校验。此范围不含 SDK 截图、网络、BLE、导航 UI 或 G；运行未作系统负载隔离。

| 区域 | 当前处理 CPU 相对基线 |
|---|---:|
| 低密街区 | +6.35% |
| 斜向道路 | +1.29% |
| 立交 | +2.17% |
| 滨水 | +7.84% |
| 明波立交 | −1.81% |

进程峰值 RSS 从 28098560 增至 28901376 字节（+2.86%）。详细数据：[host-pipeline-optimized-comparison.json](../../output/road-multitone/host-pipeline-optimized-comparison.json)。这些是 Mac 主机结果，**不能据此宣布 iPhone／圆屏的 10% 目标达成**。

## 最终制品

最终源码身份：HEAD `f19e758749cbc7c0ce9c3546672a6159a45ed761` 加本轮及保留的工作区改动。没有提交、推送或清理其他对话的改动。165 项源码目录指纹及 PBX 指纹已与构建清单核对一致；指纹也包含保留但未编译的辅助文件，不能由此推断它们已接入。

| 制品 | 路径／验证 |
|---|---|
| iOS 0.16.0 Build28 | `ios/build/DD-multitone28/Build/Products/Release-iphoneos/MotoNav.app`；最终 Release 签名构建成功，strict codesign 校验通过。 |
| App 可执行文件 SHA256 | `abdea79cc43787d3dd5e26397cbba2286c6e46f70f67fccd842868ccdc8bdaf7` |
| 1.75C 固件 175c.15 | `firmware/dist/175/panel0/MotoNav_universal_1.75_v7.12.10-pages.175c.15_panel0_app_0x10000.bin`；Arduino ESP32 3.3.10 编译通过，程序 1344787 字节、静态 RAM 118100 字节。 |
| 固件应用镜像 SHA256 | `5a8da24069e5b58c170c7b6640e33b4aa8cedc75d645a2e14bc5d76dba962c49`；文件 1345040 字节。 |
| 配套调试制品 | `output/road-multitone/firmware15-artifacts/` 中同次构建的 bin、ELF、map 与哈希清单。 |
| 联合交付清单 | `output/road-multitone/delivery/artifact-manifest.json`；明确记录未安装、未烧录及实机暂停。 |

固件 36 场景新旧绘制对照测量镜像已编译，仅构建未上传：`output/road-multitone/device-bench/run-szm80d01/manifest.json`。其 scope 只包含稳定驻留地图绘制，不包含传输、解压或 G；不能用其未运行的镜像声称性能通过。

## 暂缓的实机工作

之前安装诊断包时 CoreDevice 传输反复中断。虽然有一次正常 Build27 恢复安装返回成功，后续安装／恢复又中断，**最后实际 App 内容、启动及正常包恢复状态尚未独立确认**；版本号 27 不能区分当时的诊断包与正常包。没有读到有效手机 CPU 报告。175c.15 没有烧录。

用户恢复设备测试后，先核验并恢复正常 App，再核验圆屏身份、当前固件与新备份。需要重新构建临时手机 current probe（旧中间制品早于最终热循环优化），进行同范围基线／新版对照并恢复正常 App；固件测量也须与当时实际版本匹配。不要直接使用历史临时烧录脚本或把旧版 175c.11 当回退。

尚需验证：手机 CPU／峰值内存、实际两批字节与 ACK、圆屏稳定绘制与换图窗口、G 采样中断，以及明波三主题、隧道、BOOT／PWR 实屏回归。确认预算后再统一安装 Build28、仅烧录应用分区，保留用户数据、配对及校准。本轮没有重新验证既有 G 精度问题；真实全路网高度层级仍未实现。
