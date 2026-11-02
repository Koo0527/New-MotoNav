# 地图轮廓与立交输入核对（2026-11-02）

结论：公开 iOS SDK 可提供**导航路线内的 link 类型**和 SDK 已绘制的二维底图；没有证据证明它向本项目开放整个视口路网的几何、可靠上下层顺序或真实桥面高度。不能把驾车路线的 bridge/elevated 标签当作全路网 z-order。现有压平材质也不能反推出真实层级。本次不接入新服务，不读取私有接口，不解析 SDK 二进制瓦片。

## 官方能力与适用范围

| 输入 | 汽车 | 摩托车 | 自行车 | 范围与限制 |
| --- | --- | --- | --- | --- |
| `AMapNaviRoute.routeSegments → AMapNaviSegment.links` | 路线内可访问 | 官方提供摩托策略，复用 DriveManager；不能据此保证所有 link 字段覆盖 | RideManager 有路线能力 | 都是已规划路线，不是附近整个路网 |
| `AMapNaviLink.linkType` | 官方明确“只针对驾车” | 同属 DriveManager 不等于文档保证；需要实际返回验证 | 无支持保证，不能套用 | `Null=-1, NormalRoad=0, Fairway=1, UnderPass=2, Bridge=3, ElevatedRd=4`；是类别，不是米制高度或层序 |
| SDK 底图建筑显示、截图 | 可显示与拍平 | 与规划模式无关 | 与规划模式无关 | 二维颜色不是建筑模型导出接口；显示 3D 不等于公开 mesh/高度数据 |
| 全视口道路 elevation / z-order / 桥梁几何导出 | **未证实** | **未证实** | **未证实** | 不能承诺实现可靠的全路网立交分层配色 |

证据：[AMapNaviRoute](https://a.amap.com/lbs/static/unzip/iOS_Navi_Doc/interface_a_map_navi_route.html)、[AMapNaviSegment](https://a.amap.com/lbs/static/unzip/iOS_Navi_Doc/interface_a_map_navi_segment.html)、[AMapNaviLink](https://a.amap.com/lbs/static/unzip/iOS_Navi_Doc/interface_a_map_navi_link.html)、[LinkType 枚举](https://a.amap.com/lbs/static/unzip/iOS_Navi_Doc/AMap_iOS_Navi_Doc/_a_map_navi_common_obj_8h_source.html)、[摩托车规划](https://developer.amap.com/api/ios-navi-sdk/guide/route-plan/motorcycle-route-plan)。同步核对本地公共头文件 `ios/Pods/AMapNavi/AMapNaviKit.framework/Headers/{AMapNaviRoute.h,AMapNaviCommonObj.h,AMapNaviRideManager.h}`，避免仅凭最新网上版本推断已安装 SDK。

本项目 `AmapCaptureHost.swift` 使用近俯视相机（建筑截图 0.05°）同视角开关建筑差分；`FastBuildings` 是 600² 到 300² 的掩码，最后投回 1200² 材质。关闭建筑会移除差分来源。此路径没有楼高或三维网格输入。公开文档中没找到合适的实际桥面高度/全路网层序导出路径，结论仅限所核对公共接口，不声称平台绝无其他商业产品。

## 离线自定义样式：可尝试，但尚无桥梁同捕获证明

[高德 iOS 自定义地图指南](https://lbs.amap.com/api/ios-sdk/guide/create-map/custom)支持在开发者控制台编辑、保存、发布，然后下载**匹配当前 SDK 版本的 iOS 离线包**。`style.data → styleData`，`style_extra.data → styleExtraData`，可选 `textures.zip → styleTextureData`；`setCustomMapStyleOptions` 后启用 `customMapStyleEnabled`。本地公共 `MAMapCustomStyleOptions.h` 有对应属性。指南注明纹理和在线 styleId 拉取需要开通相关权限；离线基础样式未在该指南标为同样的额外权限要求。仍需账户已有 SDK/key 和可合法使用的导出样式，本次未登录控制台、未申请付费权限、未生成或修改私有样式文件。

[官方自定义地图产品页](https://developer.amap.com/product/mapstyle)说明可控制元素填充、描边、透明度及显隐。**推断**：若编辑器允许将桥梁边线与道路填充分为可区分颜色，同一张底图截图有机会保留边界而无需新增截图次数。**未验证**：安装 SDK 对应版本是否暴露独立桥梁边线元素、该颜色是否在目标缩放与近俯视投影稳定出现、当前分类器是否保留它。仅改变样式而仍归并到相同道路编号也会丢掉边线。需要先取得正式导出的最小离线样式包，再对同一区域/同机位原始截图及分类结果核对；没有这些输入就不能写成已实现。

研究使用 agent-reach 的网页/Exa 路由；本机 Exa 解析失败、Jina 无返回正文，改用可用浏览工具读取上述官方主站/官方公共 API 文档。没有引用讨论帖作能力依据。

## 可复现算法证据

运行：`python3 scripts/preview-map-smoothing.py --baseline /private/tmp/motonav-smoothing-baseline`。

脚本复用生产 Swift `MapGeo.classifyAmapBase`、`FastBuildings.simplify/packet`、RLE 编码；C++ 提取基线和当前生产 `rasterRows`，复用 `game_map_preview.cpp` 的主题、路线、玩家、目的地和外环辅助函数。生成输出至被忽略的 `output/map-smoothing/`，包含原始输入哈希、生产源代码哈希、before/after 材质和包、处理耗时、主机峰值 RSS、渲染耗时，以及五张三主题昼夜对照图。每对图片使用同一原始输入。`*-default-comparison.png` 是当前默认 AA 关闭的生产结果；`*-comparison.png` 和 `detail-SYNTHETIC.png` 是显式编译 AA 开启的审阅版本，两者都含真实生产 Swift 处理结果，不能混称已经启用设备 AA。

本地相关 `output/ios`、地图预览/建筑测试临时文件和现有导出文件中未找到可重复处理的真实地理**原始捕获对**；已有 UI/预览图不是合格原始输入。因此图片醒目标为 **SYNTHETIC**，使用 dense-courtyard、river-bridge、parallel-roads、curved-park、tile-seam 五个合成场景及 0/17/43/90/137° 旋转。它们覆盖屋顶内孔、窄路间隔、水岸、斜路和边缘；不是五个真实冷缓存地区。固定目的地、路线与玩家仅作同尺寸视觉参照，未用于测试导航定位精度。没有 AI 生图。

CPU 测量仅含纯处理：每场景一次预热后取三次中位数；渲染为每张 100 次 `rasterRows` 的平均耗时。峰值 RSS 来自独立 Swift 子进程 `getrusage`，包含运行时和合成输入驻留，不代表 iPhone 峰值增量；不含 SDK 首次抓图、UIKit、BLE 等待或 ESP32 双核调度。包长是实际生产编码输出。主机结果不能证明设备绘图增幅 ≤10%、传输一定下降或冷缓存五地区通过。

本轮主机结果如下；主机同时运行其他构建，单次场景的调度噪声也保留在 JSON 中，不筛掉较慢样本：

| 合成场景 | 基线处理 ms | 修改后处理 ms | 基线包 bytes | 修改后包 bytes |
| --- | ---: | ---: | ---: | ---: |
| dense-courtyard | 32.72 | 24.28 | 69,393 | 68,657 |
| river-bridge | 32.62 | 24.22 | 69,104 | 68,372 |
| parallel-roads | 32.37 | 24.01 | 68,878 | 68,147 |
| curved-park | 32.90 | 24.29 | 68,639 | 67,912 |
| tile-seam | 32.71 | 24.27 | 68,342 | 67,620 |

整个 Swift 进程峰值 RSS 为基线 61,145,088 bytes、修改后 33,685,504 bytes。混合材质场景 `rasterRows` 平均：基线 0.169ms、当前默认关闭 AA 0.177ms、审阅开启 AA 0.557ms。纯材质控制场景分别 0.207/0.148/0.400ms。AA 在主机上也明显增加计算，不满足“可以直接假定 ≤10%”的依据，因此生产默认关闭，设备端测量后再决定是否启用。示例图片可审查轮廓与参照物，但没有证实真实立交边线或全网层序。

真实原始捕获、正式样式包和实屏性能尚待设备阶段验证；未在此研究中安装 App、刷机、改动车辆配置或上传数据。
