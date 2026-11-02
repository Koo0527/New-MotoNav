# iOS Build16 + 1.75C 设备能力验收

本次修改只覆盖 iOS 和 `firmware/boards/175`，保留当前分支已有修改；
没有提交或推送。圆屏已在用户授权后完成应用区烧录，iOS Build16 也已签名并覆盖安装，记录见下方。iOS 红绿灯读秒继续暂缓。

## 使用方式

- PWR 短按：熄屏／唤醒（固件 175c.1 起）；长按保留电源芯片原有关机行为。
- BOOT 短按：切换隧道调光，可离线使用；长按 1.2 秒：锁定／解除全部触摸。
- 熄屏时第一次 BOOT 按压仅唤醒，下一次才执行按键功能。
- 圆屏设置中可分别选择插电／电池熄屏时间，默认 10／2 分钟。
  电池供电且无导航时，仍在总计闲置 5 分钟时关机，不是熄屏后再等 5 分钟。
- 默认开机音效开启、音量 20%；可以在 App 关闭或调整。熄屏唤醒不重播。
- 导航页上滑进入 G 仪表，下滑返回；原有音乐、天气左右切换位置不变。
- App 安装校准中选择朝向车头的圆屏参考方向，必要时调整偏转角。
  静止、扶正车辆并保持 3 秒完成校准，期间须结束导航／巡航。
  重新安装设备需要重新校准；单纯调整画面旋转不需要改变安装参数。
- 新设备设置仅在支持该能力的固件上启用，显示圆屏确认后的配置。

## 自动验证

- 固件：13 套 C++ 测试（含按键、休眠、G 估计、标记旋转、手势）通过
  AddressSanitizer / UndefinedBehaviorSanitizer；原 C 闲置定时测试通过。
- macOS 刷写规则 6 项单元测试通过。
- iOS：完整 unsigned arm64 Debug Build16 编译成功；隧道设置与新设备
  状态同步、旧固件渐变、导航定位／车道队列、隧道 SDK、骑行 BLE 回归通过。
- 最终固件完整编译成功，Flash 1,329,019 字节（42%）、静态 RAM 115,076 字节（35%）；协议交叉审查发现的参数溢出、保存失败假回执及快速调光确认竞争均已修正。
- 保留 CRLF 的文件使用 `git -c core.whitespace=cr-at-eol diff --check` 检查。

地图配色及标记对比见 [示意预览](175c-map-style-preview.png)。
该图片使用示意道路展示生产配色和标记几何，不是真实路段或 SDK 截图。

## 尚需实机验收

1. 原配喇叭的音量、爆音、音效关闭及重新开机持久化。
2. BOOT 消抖、锁屏、未解锁触摸屏、唤醒首按；断连按键后重连不回跳。
3. 充满但仍插电时按外接电源计时；拔插电源、导航开始、来电及配对唤醒。
4. 电池 2 分钟熄屏、总计 5 分钟关机，USB 10 分钟仅熄屏。
5. G 球前后左右实际方向与校准图示对应，静止零点、普通起步／制动、左右
   转弯、侧撑开机、颠簸及断连。传感器坐标到屏幕方向目前需要实机核实。
6. 持续骑行的 G 漂移、地图配色可读性、功耗及采集对地图帧率的影响。

G 为六轴估算显示，不能视为经过标定的测量仪表；持续运动可能有重力估计
误差。异常、饱和或中断采样会显示不可用并等待静止恢复，不显示旧数值。
固件升级应仅写应用区 0x10000，保留现有分区和配对数据。

## 构建产物

- iOS 0.16.0 Build16：`/private/tmp/motonav-175c-ios/Build/Products/Debug-iphoneos/MotoNav.app`，unsigned arm64，仅用于编译验证，安装前需要签名。
- 固件：`firmware/dist/175/panel0/MotoNav_universal_1.75_v7.12.10-pages.175c_panel0_app_0x10000.bin`。
- 应用区包 1,329,264 字节，SHA256 `a31e7dc74c6aee375e4de80b233ab61fddc1e6937e975e372d0d6b8554c15553`。
- 同目录 manifest 中 `deviceTested=false`；完整包仅作恢复用途，日常升级使用应用区包。
- 已独立核对 manifest 字节数、SHA256 与完整包的 0x10000 应用区内容一致。

## 2026-11-01 USB 应用区烧录

用户将 1.75C 接入 Mac 并拆下电池，以 USB 供电。已读取确认 ESP32-S3，
分区表显示 app0=0x10000/0x300000、app1=0x310000/0x300000，OTA 序列 1
对应 app0。分区表、NVS 和 OTA 数据已在本机临时目录备份，权限设为 0600。
较大的原应用备份因串口读取中断未完成，不作为可恢复的完整备份。

以 115200 串口配置写入应用区包，`--flash-size keep`；只擦写
0x00010000–0x00154fff，未写引导、分区表、NVS 或 OTA 启动配置。
esptool 5.3.0 返回退出码 0，报告 `Hash of data verified` 并重启。
随后读取到：

```text
Reset reason=11, sleep wake=0
touch ok
IPC stacks bytes=4096/4096 free-min=3152/3160
MotoNav ready, firmware v7.12.10-pages.175c
```

串口日志：`/private/tmp/motonav-175c-afterflash-serial.log`。
已确认写入和启动，不能据此推断喇叭、G 轴向、按键手感或电池管理已完成
实机验收；上述功能清单仍需逐项验证。iOS Build16 后续已签名安装，启动验证状态见下方。

## 2026-11-01 iPhone 签名安装

用户连接手机并明确授权安装更新。使用现有 DEVELOPMENT_TEAM=H3N5LA55A3
签名 Release 构建成功，版本核对为 `com.u238zyc.motonav` / `0.16.0` / `16`。
产物：`ios/build/DD/Build/Products/Release-iphoneos/MotoNav.app`；
构建日志：`/private/tmp/motonav-build16-signed.log`。

`devicectl device install app` 退出码 0，返回 `App installed`。
远程启动返回 Locked：手机未解锁，尚不能据此确认 App 运行结果；已请用户
解锁后继续验证。没有卸载旧应用或清除其数据。

PWR 状态：此前计划保留原电源键行为，目前没有 PWR 短按休眠事件处理。
已实现的手动唤醒为 BOOT，自动熄屏依照供电状态计时。


用户解锁后再次远程启动成功（退出码 0，`Launched application`）；随后
`device info processes` 确认 MotoNav.app 进程仍在运行。安装、启动和进程
存活验证完成，功能体验及圆屏联调仍需实际操作验收。

## 2026-11-01 PWR 短按补充更新：175c.1

用户明确授权加入 PWR 短按熄屏／唤醒，长按保留原有关机行为。
固件 `7.12.10-pages.175c.1` 只增加 PMIC 按键 IRQ 读取，更新 IRQ 使能
0x41 并对 0x49 已读出的短／长按位写 1 确认；未改关机使能、长按时长、
供电轨或电池设置。开机时丢弃残留按键事件；I2C 失败不切换屏幕。

导航中手动熄屏不会被持续导航数据立即点亮。新导航／来电／配对事件仍可
唤醒，BOOT 及未锁定触摸唤醒仍可用。PWR 在触摸锁定时也可切换屏幕。

验证：14 套 C++ 测试通过 ASAN/UBSAN（新增生产 PMIC IRQ 读写和手动熄屏
状态测试），原 C 闲置测试及 6 项 macOS 刷写规则测试通过。完整固件编译
退出码 0，Flash 1,329,531 字节（42%）、静态 RAM 115,084 字节（35%）。
已打包并只写入 0x10000 应用区，esptool 返回 `Hash of data verified`。
启动串口确认 `PWR short-press ready` 与新版本 `175c.1`。

构建日志 `/private/tmp/motonav-pwr-build.log`；启动／按键日志
`/private/tmp/motonav-pwr-afterflash.log`。iOS Build16 协议兼容，无需重装。
用户已确认“能熄屏，也能唤醒”；串口日志同步记录两轮 `screen off` / `screen on`，短按实机验收通过。尚未进行物理长按关机或电池供电验收。
