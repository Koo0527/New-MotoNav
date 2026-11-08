# 三主题多色阶道路正式接入

用户已批准右侧完整源亮度重映射，并确认三个主题同时更新。实现不新增图源、付费服务、日常截图或地图几何；保留2m道路、4m建筑、两批交付、道路优先、G/按键/电源/隧道功能。官方直接样式路径不阻塞本交付。

## 冻结接口与约束

- Native分类与 `ios/tests/road-multitone-preview` 右侧规则等价；只修改已分类暖色8/9；3x3暖色内部RGB各通道极差<=12，Y=30R+59G+11B，<21400→8、<22600→9、其余→11。最多两轮从原暖色掩码传播，>=3邻点支持，最多票数、同票依左上至右下首遇顺序；两轮必须用前轮快照。无支持/缺邻域保留旧分类。对边界缺依赖区域不外推，重叠测试排除三格外沿。10和非暖色材质不变。
- 后台现有串行队列执行；额外最多两张1200² UInt8标签缓冲（2.88MB），不复制全图RGB通道；有限局部遍历，取消复用原任务机制。
- 日间8/9/11：VC #202023/#404044/#606065，GTA5 #707A7A/#9AA4A4/#C6CACA，Cyber #214648/#388281/#50AAA8；RGB565统一。普通道路和其他材质不变，夜间VC45%、其余75%。不更改旧v1地图配色。
- Wire仍1200²、2000mm、16色4bit RLE、<=480000B。14=0x4D4E；15 v1=0x5201/0x5211，v2=0x5202/0x5212。v1像素0..10，v2 0..11；未知版本、12..15像素、屋顶标记不符、溢出/截断/额外尾部严格拒绝，不误认成照片包。普通16色图和旧0..7不变。
- iOS `RoadPalette.packetVersion(_ data:Data)->Int` 返回0/1/2；`isPacket`识别受支持1/2；`isCurrentPacket`仅版本2。`forWire(_ data:Data,paletteVersion:Int,buildingsSupported:Bool)->Data`，0/1/2能力；v2→v1流式11→9且标记和canonical调色板改为v1，8/9/10不变；无能力8/9/10/11→普通路1；屋顶仍按BLD处理。`encode(...like:)`、清除/合成/compact保留输入版本；新源图encode默认v2。旧包不得假升级。
- Core提供 `FastBuildings.qualityVersion=4`。缓存材料与fast4m代次4；v4游戏材料使用共享game键（source3主题1/2/3），旧v3/v2按主题包只读回退。v3/v2有效同算法楼块patch校验后复用（v1沿既有转换），不重新截图楼块，不清旧包。未有原始颜色的旧包只作回退，前台按需重新取道路；currentOnly及isCurrent不能把v1视为当前。
- BLE状态改 `roadPaletteVersion:Int`，默认0，max已认证1/2，断开/attach/失效复位0。新固件认证后继续CAP,MPAL,1并新增CAP,MPAL,2，均10字节，重试及#GB?同发。新APP两者均可恢复认证；顺序/重复不得降级。迟到版本等既有bulk/receipt结束，比实际wire不变则不重发。
- 固件 `RasterHeader` 加 `uint8_t semanticVersion`；current/header/queue/front/back/屋顶清除中保留。版本0普通材质沿旧色，版本1保留现有两暖色，版本2用新三色。RM增加backPal[16]（32B）在帧准备时计算；沿既有front/back空间分支分别查自己的颜色表，不增加逐像素版本运算。其他实际主题8/9/11→普通路，10→地面；minimal覆盖及纸地图夜间别名亦正确。
- 新代base/partial优先旧完整图，当前代覆盖位图不倒退，先road ACK再跨代roof，已准入建筑包不能在姿态/速率不变时立即撤销。锁屏只缓存，失败/超限沿已有冷却保留可用图，不立即重试，不造超限包。
- 诊断仍用户主动、有界；map-send记录包版本/能力版本，记录带实际build。无Key/Cookie/绝对坐标。手机CPU/峰值内存/圆屏稳定绘制增幅<=10%为目标；超标先同算法优化，未达标不默认发布，不换成中间控制组。
- 保留HEAD2aeaa9d的Wire.setBufferSize(512)等已验证175c.13 G堆修复；当前Build27，发布按执行最高版本+1，最低28/.14。签名构建，设备核验实际包/进程，app-only flash保持NVS及校准，提前备份当前稳定固件，不用175c.11当回退。
- 不commit/push、不清工作树。现有其他改动保留；新旧代码审查用本轮开始快照避免untracked旧工作混入。

### Task 1: 原生分类与iOS格式核心

Owner: ios/MotoNav/RoadPalette.swift、RasterProcessing.swift，ios/tests/road-palette-core、road-palette-export及独立原生多色阶测试。不要修改其他生产文件/固件/版本/设备，集成调用者由Task3适配。消费上面冻结接口；提供新分类/packetVersion/isCurrentPacket/forWire/保留版本合成及quality4。

先加入可失败的portable fixture与真实样本检查，移植为整数Swift，验证与右侧同输入金样有效内区完全相同。新增位图支持、fallback、版本1/2、坏标记/非法索引、BLD有无、流式RLE降级、屋顶合成/清除、未知保留family必须拒绝。检查不能依赖ignored output作为portable默认；真实六区用显式参数。不增加线上依赖/重复实现/无用兼容overload。编译优化版做同scope native v1/v2 CPU和额外缓冲自检，不把Python结果当手机。记录脚本命令/输出/限制。同步消费新核心的export脚本可更新，但不要覆盖历史QA金样原目录。

### Task 2: 固件v2解码、双代调色和能力通知

Owner: firmware/boards/175/MotoNav/{GameMapStyle.h,RasterContinuity.h,RasterBuildingCarry.h,src/map/RasterDecoder.h,RasterWorkQueue.h,RasterRenderer.h,src/connectivity/Notifications.h}及相关firmware测试/ios building-continuity仅头文件夹具。不动G/power/control/version，不刷设备。

严格实现冻结v1/v2语义及header版本传播；清除/旧屋顶carry不得覆盖8/9/10/11。旧v1外观不变，语义新旧front/back过渡各用自己的帧外准备palette。原采样/packed nibble/原子换图不变，不开启AA/DENSE。补actual production validator/queue/renderer/通知测试，v1+v2+普通+照片交叉，其他主题/minimal/纸夜，坏包/迟到/取消/开关，六palette和0/45/90旋转。ASan/UBSan、fixtures parity及Arduino3.3.10正确FQBN compile-only，保存报告及精确限制。

### Task 3: iOS链路、缓存代次与端到端回归

Owner: ios/MotoNav/{BleLink.swift,BleHandshakeClock.swift,MapFeeder.swift,RouteMapPlan.swift,RouteOfflineMaps.swift,AmapSdkRaster.swift}和其消费新核心的相关ios/tests（可改stubs）。只消费Task1接口；若需要改核心/固件先告知root协调，不自行覆盖。不改版本、部署或操作设备。

实现冻结cap2认证与max版本/复位、v4共用game缓存键及v3/v2/旧style回退、patch3/2复用、代次优先和cache-only后台。所有wire发送/重发使用能力版本转换。扩展现有有界map-send版本字段。测试旧完整挡新base/partial及迟到旧full、同代覆盖不倒退、首尾ACK/能力等待重发/不互取消、当前姿态速率预算、慢蓝牙/高速/重算/前后台、cache坏包/旧数据不删除/非游戏隔离/跨三主题复用。运行screenoff、building-capture/offline/delivery、mapdelivery、能力等实际生产回归和iOS compile。测试不得只字符串匹配实现，报告注明stubs和真实边界。

### Task 4: 联合审查、预览、实测与交付

Root负责统一审查和交付；每Task独立审查通过后继续，最终整条链路review。生产Swift输出→真实固件decoder/render导出三主题六palette与0/45/90对照，沿现有六区域但如实保留partial建筑状态；原图/当前/新版统一pose/RGB565，独立测试缓存不清用户数据。性能对照必须同语言/同scope，host和设备分开，至少五区域；稳定绘制可沿现有36case helper扩展v1/v2、新旧缓冲、真实wire，解压/传输/G不混作稳定采样。手机CPU/peak、实际BLE ACK、换图窗口/G需真实设备，缺设备时先完成能完成的工作再一次性请求连接。保存timing与artifact hashes/actualbuild验证，目标不达不默认上线。最终签名Build>=28/175c>=14发布，核验实际安装进程版本、仅app0烧录、备份现在稳定固件，实屏明波三主题及G/BOOT/PWR/隧道回归。
