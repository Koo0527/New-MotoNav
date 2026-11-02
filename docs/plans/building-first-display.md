# 新区域建筑首批显示优化

用户批准计划，2026-11-02。现有功能分支、脏工作区继续开发，不提交／推送／重置。
Ruling: Build20 已由并行 G 修复占用，本轮使用 Build21；保留全部 G/固件175c.5改动，
建筑数据兼容175c.4，不重刷固件。

## 已批准行为

- 仍是2.4km方块、四片1.2km近景、每片开关建筑两张截图；不增加截图数量。
- 道路和前方安全覆盖优先；当前显示块的首片建筑优先于预取块建筑。
- 四片按当前视野重叠、行进前方、距离排序，最先有效片立即发布；剩余合并一次。
- 4m粗格：原2x2像素>=2建筑，过滤不足4粗格(64m²)连通片；道路保持2m且道路/水域优先。
- 采集串行、每对截图为相机原子操作，片间可让路；保留掩码后可取消恢复，不重抓成功片。
- 分开包含建筑与完成状态，空片成功也算已检查；四片都成功才完成。
- 三游戏主题共享同位置同质量缓存；旧有效完整包可用，其他主题隔离，不清空用户离线数据。
- 每块正常路径最多首批+完整两次建筑更新。已在传的不取消；未发送首批可被完整包合并。
- 复用现有BLE预算、前方道路保护、后台仅缓存、重连和迟到回调隔离。
- 记录base/first-ready/first-send/first-ACK/full-ready/full-ACK/bytes/cache/cancel/yield；无Key/cookie/绝对坐标。

## 最小内部接口契约（开工前锁定）

类型放在现有 RasterProcessing.swift，保持测试和CI显式源文件兼容：
- BuildingCoverage: Codable/Equatable，qualityVersion:Int(default1=fast4m)，checkedMask:UInt8(0...15)，isComplete == mask15。
  legacyFull 为quality0/mask15。空白道路也可有mask15；packet flag只表示实际屋顶。
- BuildingUpdate: bytes:Data, coverage:BuildingCoverage。建筑路径必须携带coverage，不能从flag猜完整。
- BuildingView: x:Double,y:Double,bearing:Double?,radius:Double，用于排序；无有效定位按块中心距离排序。
- FastBuildings.order(cx:Double,cy:Double,view:BuildingView?)->[Int]，四片NW/NE/SW/SE=0/1/2/3。
- FastBuildings.simplify(_ raw:[UInt32])->Data：600²差分图到300²二值掩码，过滤小片。
- FastBuildings.packet(base:Data,patches:[Int:Data])->Data：同原1200²/2m/RLE协议，保留道路水域。
- BuildingCheckpoint: coverage:BuildingCoverage,patches:[Int:Data]，不可把已失败片加入mask。

RouteMapCache（同一个根目录、锁和512MB上限）新增：
- buildingCheckpoint(frame:source:node:)->BuildingCheckpoint
- storeBuildingPatch(_ patch:Data,index:Int,frame:source:node:) throws
- buildingUpdate(frame:source:node:style:)->BuildingUpdate?（返回新共享包或有效旧完整包）
- storeBuildingUpdate(_ update:BuildingUpdate,frame:source:node:) throws
  新共享命名按source/frame/origin/quality，不带theme；快掩码逐片原子保存，损坏片只失效自己。
  旧read/store仍兼容。新包与coverage校验匹配，拒绝无效坐标/尺寸/调色板/版本。
MapHandoffBuffer.Packet增加coverage:BuildingCoverage?，默认nil供非建筑路径；建筑路径显式赋值。

AmapSdkRaster.build 保留旧参数并在尾部增加：
  buildingView:BuildingView?=nil,
  onBuildingReady:((BuildingUpdate)->Void)?=nil,
  shouldYield:(()->Bool)?=nil
RasterResult增加coverage:BuildingCoverage?默认nil并保留原三参数初始化。
  支持游戏主题时按checkpoint缺片排序。每成功片先持久化；首个有屋顶的片发布，完成后至多再发布一次。
  全空时完成coverage但返回普通底图；不得无限重试空区域。
  片间yield时返回已完成成果并可恢复；截图lease包围一对截图，不包围整四片。

## 所有权与进度

- Core/cache/order/simplification/packet metadata: implemented and host-tested.
- SDK capture/lease/progressive callback: implemented; production orchestration harness passes.
- Feeder/offline/BLE completion and theme reuse: implemented; extracted production acceptChunk regression passes.
- Parent integration/version/CI/diagnostics/benchmarks: implemented; Build21 signed build passed. Device installation/acceptance tracked in docs/verification/building-first-build21.md.

## 验证目标

先写失败测试，再实现，按状态/缓存/采集/交付分别验证；覆盖空区域、取消续接、失败、慢链路、
移动让路、切主题、旧缓存、损坏缓存及最多两次发布。保留现有地图、设备、G、定位回归。
至少五个独立冷缓存样本，记录Build19链路对照；首批ACK中位数目标-40%，手机峰值内存/总CPU/
圆屏稳定绘制增幅目标<=10%。真实SDK/BLE验收和主机仿真明确区分，未完成不宣称达标。

## 审查后的修正

- 首批在采集继续时即可交付；尾批保留原始字节与覆盖元数据等待首批 ACK，再重算传输预算。
- 已知首批可在续接开始时直接显示；旧完整包直接复用，不重新截图。
- 有 coverage 的部分建筑不写入旧版完整包命名空间，损坏共享记录不会把新部分包误判完整。
- 4m 掩码合并后恢复填充/边线和分片边界连续性，保留差分异常拒绝。
- fast4m 缓存按实际取图原点命名，限制文件读入大小、校验 bytes+coverage、沿用备份排除和文件保护。
- SDK 任务采用随机数标识；只导出数字字段，包含 checked/mask、first/full-send/ack 和蓝牙包编号。
