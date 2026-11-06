# `d710337` SPI 整改收尾计划

> 执行记录见 `docs/verification/spi-closeout-20261106.md`。宿主项已完成；真机项待现场。

## 1. 保持事务描述符有效，直到复位

- [x] 先修改 `fastpush_check.py`，让假驱动在 `polling_start` 成功后保存真实描述符指针。`polling_end` 超时或完成状态不明时，保留指针及 `inFlight=true`。从生产 `flushTask` 入口注入超时，在模拟重启回调里读取描述符长度和缓冲地址。用 Clang 的 `-fsanitize=address -fsanitize-address-use-after-return=always` 跑 `d710337`，验收红灯为 `stack-use-after-return`。
- [x] 把 `flushTask` 现有的故障日志、保存 `fastf=0` 和复位代码提取为一个 `[[noreturn]]` 函数。`fastPush` 遇到未终止的旧事务、结束超时或未知结束状态时，在局部描述符 `t` 仍有效的位置直接调用它。此路径保持 CS、总线和 `flushDone` 的所有权，直到复位。对明确未提交或已经回收的失败，沿用当前收尾，再由 `flushTask` 调用同一个复位函数。保留现有等待参数、正常帧流程和看门狗配置。
- [x] 用同一宿主用例转绿。超时、未知结束错误和旧事务未终止时均只进入一次复位，没有下一笔事务、提前拉高 CS、总线释放或 `flushDone` 发放。模拟重启时描述符与 DMA 缓冲仍可读。保留获取总线失败、普通启动失败、DMA 已回收但返回错误、正常多块传输四类回归。

## 2. 把唤醒屏障纳入同一交付

- [x] 仅暂存 `DeviceControlRuntime.h` 中 `controlWake()` 的现有屏障 hunk。初始化了 `flushDone` 时，先 `flushWait()` 取得所有权，再唤醒面板、设置亮度并归还信号量。同文件的 `controlDrawLock()` 属于另一路改动，保留在工作树。
- [x] 将生命周期修复、宿主回归和唤醒 hunk 放进一个后续提交。提交前检查暂存区，确认没有地图、G 值和触摸锁徽标改动。从该提交 `git archive` 到临时目录，运行 `flush-ownership/check.py`、`heap-checks/check.py` 和 `raster-work/check_sources.py`。验收以独立副本的结果为准。刷屏套件同时通过正常推屏、故障恢复和忙时唤醒三项。

  记录：生命周期提交 `df63e19`；纯 HEAD archive 的 `raster-work/check_sources.py` 因未提交的 `RasterDecoder` 夹具同步失败，独立副本改用完整源码快照 `0409dac`，三项全绿。

## 3. 重新归档候选，再交接真机

- [x] 干净检出通过后，从冻结的 `.16` 集成源码构建新候选。记录 Git 基线、实际参与构建的未提交源码、工具链和构建参数。立即归档新 app bin、ELF、manifest 及完整 SHA256，核对完整镜像 `0x10000` 切片和 bin 内嵌 ELF 摘要。新旧候选按哈希区分。

  记录：app `381aa2a4…`，full `22ec144c…`，ELF `5cb1886b…`；归档 `output/spi-closeout-20261106/`；旧候选 `f3e6b794…` 保留对照。

- [ ] 真机负责人先保全现有 coredump，读回**当时板上实际应用**作为回退镜像。旧 `6c1444ad…` 备份对应上午出现 SPI 崩溃的 `b54ea31b…`，保留作历史证据。候选只写应用区 `0x10000`，先验证启动、亮屏和息屏，再跑原定 USB／电池导航对照。
- [ ] 软件收尾以**描述符生命周期回归通过、干净检出全绿、候选指纹匹配**为完成条件。现场另交付新复位签名、首图实显时间、`NO DATA` 前后时序及 60 分钟导航结果，其中至少 30 分钟使用电池。只有拿到匹配的现场证据，才把最近一次电池重启归因到具体路径。

  记录：前三项宿主条件已满足（ASan 回归、完整源码快照三项全绿、候选指纹与切片/内嵌 ELF 一致）；现场证据仍未取得。
