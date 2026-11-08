# 高架视觉分隔：官方样式来源与能力边界（2026-11-03）

## 结论

已从高德官网公开下载的 **iOS 3D SDK 官方示例**中取得 `my_style_new.data`，官方示例明确将它赋给 `MAMapCustomStyleOptions.styleData`。可以原样作为独立诊断的候选离线输入，无需先要求用户登录控制台。**尚未在本机已安装的 10.1.600 SDK 中加载，所以兼容性、目标缩放下桥边线、分类可区分性均未验证。该文件不是桥梁专用方案。**

官方证据支持按道路类别控制填充、描边及其宽度，并按缩放配置；未找到官方公开文档证明有独立的“高架桥梁边线/遮挡顺序”编辑项。不能把“天桥”类别等同于所有机动车高架，也不能从像素恢复真实 z-order。现阶段不能宣称高架分隔已解决。

本次只读生产代码和官方资料，下载公开示例到 ignored `output/edge-bridge-evidence/`；不修改现有采图，不安装、不碰手机、不登录、不发布、不购买服务、不反解二进制样式。

## 官方来源与复现路径

1. [iOS SDK 相关下载](https://lbs.amap.com/api/ios-sdk/download)（页面更新时间 2026-09-22）→“示例代码 / iOS地图SDK全部示例代码”→[官方 ZIP](https://a.amap.com/lbs/static/zip/AMap_iOS_Demo.zip)。官网[示例说明](https://lbs.amap.com/api/ios-sdk/code-example)明确允许以示例代码为基础开发应用；这提供公开官方示例使用的依据，不表示获得额外商业服务权限。
2. 外包 `AMap_iOS_Demo.zip` 中含 `AMap_iOS_Demo/AMap_iOS_3DMap_Demo_V11.3.100.zip`；内包包含 `MAMapKit_3D_Demo/Resources/my_style_new.data`。
3. 内包 `MAMapKit_3D_Demo/MAMapKit_3D_Demo/Samples/misc/CustomMapStyleViewController.m` 和 Swift 对应文件均读取该资源并赋 `options.styleData`，调用 `setCustomMapStyleOptions` 与 `customMapStyleEnabled`。不需要运行整个 Demo 或安装它自带的 framework。
4. 原样候选文件位于 `output/edge-bridge-evidence/my_style_new.data`：**85,241 bytes**，SHA-256 `69b20d2eee6e2503e294aab4cf46108819ef1b95690f3258daa97c1e35a72d4f`。内包预编译 App 的同名资源哈希相同。
5. 外包 317,634,890 bytes，SHA-256 `848f397a059a8d0bfd57d76356920ffbec5c1d539f905960c68dc81945c7c4e1`。本地 `source.json`、`archive-index.txt`、`3d-archive-index.txt`、`style-assets.json` 及两个样例源文件保留来源与路径证据；没有检查二进制内部编码。ZIP 可能被官网原地址更新，应以此次哈希为准。

官网示例页的 GitHub 链接实际导向 `amapapi/iOS_Loc_Demo`（定位 Demo），不足以证明地图自定义样式来源。本报告使用官网直接提供的 ZIP，而非猜测仓库名或引用非官方转载。

## SDK 与资产边界

本项目 `ios/Podfile.lock` 为 AMapNavi **10.1.600**；随包公共 `MAMapVersion.h` 为 `10010600`，公共 `MAMapCustomStyleOptions.h` 有 `styleData`、`styleExtraData`、`styleTextureData`、`styleId`。官方新示例内带 framework 为 **11.3.100**，不能凭接口同名就承诺资产向旧 SDK 兼容。

[官方 iOS 自定义样式指南](https://lbs.amap.com/api/ios-sdk/guide/create-map/custom)要求下载与当前 SDK 对应版本的样式；本地 `MAMapView.h` 的 `setCustomMapStyleOptions` 说明也明确 7.0.0 样式有更新、旧样式必须重新导出。版本号或文件名不是可接受性的证明。

| 资产 | 可以作什么 | 未证明/不能作什么 |
| --- | --- | --- |
| 官网 Demo `Resources/my_style_new.data` | 独立诊断原样加载的官方候选；源代码明确使用公开接口 | 未证实本机 10.1.600 接受、未证实桥梁描边增强或生产分类适用 |
| 本机 `AMap.bundle/customStyle/style-for-custom_0_18_1641525834.data` | SDK 自带资源；确认存在即可 | 不是文档指定的用户导出文件；无公开证据可将它当用户样式、编辑或解码 |
| 控制台导出的匹配版本 `style.data` | 文档支持的正式离线路径 | 仍需同机位同缩放实际加载验证，不能自动保证高架分隔 |
| `style_extra.data` / `textures.zip` | 分别对应 `styleExtraData` / `styleTextureData` | 不表示其中含桥梁层序；本需求无需纹理 |
| Demo `style_json.json` | 官方示例的可读文本资源，含道路 `geometry.fill/stroke` 例子 | 不能把 JSON 直接赋 `styleData`，也不能据此反解或重新编制二进制；该例未含 bridge/elevated 项 |

离线**样式文件**不是离线**底图瓦片/路网数据**；取得前者不能使冷缓存截图不再依赖底图服务。

## 已证实的控制与缩放范围

| 项目 | 官方证据 | 结论边界 |
| --- | --- | --- |
| 道路填充与描边宽度 | [2019-10-31 道路宽度公告](https://lbs.amap.com/news/road-width/)列出填充/描边，整体宽度 = 填充 + 2×描边，调节范围 1–20 像素，支持按地图缩放设置；例子列高速、环线、国省道、铁路、天桥、地道等 | 是道路类别样式，不是全视口真实桥梁几何或 z-order API；当前控制台是否仍有相同范围未登录验证 |
| 颜色、描边、显隐 | [官方产品页](https://developer.amap.com/product/mapstyle)列出显隐、填充、描边、透明度、纹理等能力 | 不保证每个类别都暴露所有属性，不证明独立“机动车高架桥边线” |
| 分缩放配置 | [2018-11-21 官方公告](https://lbs.amap.com/news/room/)描述当时 3–18 级；本机头文件支持分级样式 | 3–18 是历史平台说明，不能据此保证当前 19 级怎样处理、自动外推或继承；需导出配置和实测 |
| SDK 相机 | 本机 `MAMapView.h`：通常 3–19，室内最高 20；实际采图 `setVisibleMapRect` 拟合 | SDK 相机范围不同于样式编辑器范围。记录实际 `zoomLevel`，不要由截图名“1200”猜缩放 |
| 权限 | [官方移动端产品页](https://lbs.amap.com/product/mapstyle/m)说明免费用户可用离线加载；iOS 指南标注在线 styleId 和纹理需相关权限 | 可先试纯离线基础样式；不能推断用户当前账户、Key、商业许可或付费资格，无需为本验证购买纹理/在线服务 |

官方公开接口中未找到单独 bridge-outline 开关，也未找到样式控制遮挡顺序的承诺。**未找到不等于平台绝无此项**：如需确认当前编辑器细目，须在用户已有会话中只读查看道路树/属性面板，或由用户提供截图/正式导出。道路描边可能改善已有立交绘制，但这是待检验推断。

## 最小的下一步与条件性用户操作

先在获准的独立诊断中原样加载上述公开 `my_style_new.data`，保留默认样式对照，监听 SDK 公共 `customMapStyleAuthFailedWithErrorCode:message:` 并确认画面确实改变。成功返回或没有报错不能代替视觉检查。不要把候选样式直接接入生产分类，它可能改变水、绿地、道路等语义颜色。若加载失败、无描边差异、缩放不适用或分类颜色冲突，应如实记录失败。

若候选不能满足要求，最小用户操作是：在[高德控制台](https://console.amap.com/)的自定义地图中，选择已有有权使用的样式（或自行建立一个），确认“道路”相关类别具有可区分的填充/描边，在目标缩放设置较强描边；按官网流程保存/发布后，从“使用方法 → iOS → 当前 SDK 对应版本”下载离线 ZIP，再提供 ZIP 与其选定版本。若没有明确 10.1.600 选项，不猜选最新版，先由高德确认兼容版本分组。样式已发布且合适时只需下载，不必重新发布。发布及账户操作由用户自行完成，本次不代做、不索取密码。

此请求应在独立候选验证后再提出，避免把尚未试过的公开样式也归为“必须用户操作”。不要求在线 styleId、纹理或付费服务。

## 用现有无建筑近景判断“源图没有”还是“分类丢失”

`AmapCaptureHost` 的基底目标是 1200²、覆盖约 2.4 km，但 SDK 渲染视口为 720²；600² 建筑片每片约 1.2 km，SDK 视口为 1200²。后者无建筑参考通常有更高缩放/源分辨率，不能将近景有桥线直接归咎为基底分类丢线。建筑开/关配对同机位检查仅保证该对齐，不能保证与基底同缩放。诊断不增加采图次数。

对每个已采片按以下顺序使用导出的 PNG、projection 和 sampled 数据；基底与近景分别分析：

1. 在 `base.png` 或 `building-N-off.png` 中框定一个明显交叉/桥边线 ROI，记录坐标、`*-camera.json` 的 zoom/camera/rotation、像素 RGB。只有无建筑图已存在的连续可见边界才是本任务可保留的证据。建筑开关差分、阴影和标签不能自动算桥边线。
2. 使用 `base.json` / `building-N-on.json` 中的 `columns/rows` 重放生产取样；近景 off/on 投影需先核对相等。若原 PNG 有窄线，2 m 取样后消失，记为**重采样损失**。`building-N-sampled-2m.argb32le` 由配对 sample 生成，不可未经检查当成逐像素原始 off 图；严谨做法是对 off PNG 单独重放同一采样坐标。
3. 对同一 sampled 输入分别比较 `classifyPixel`、`recoverGrayRoads` 后、`smoothGameRaster`（或非游戏的 cleanup/dilate）后结果。生产 `classifyAmapBase` 将这些阶段组合，不修改它；可在独立分析程序提取精确现有实现，记录源码哈希。
4. `classifyPixel` 将暖色道路、亮度 >=254 的白色归路；深色描边通常归 `PX_BLOCK`。`recoverGrayRoads` 进一步将满足灰度/亮度、跨度、像素数与方向性条件的连通分量改为路。**推断**：长灰描边若被识别为灰路，会与路面合并；只有阶段差分证明才可判定本样本由此丢失。游戏平滑也会添加道路像素，须单独核对。
5. 分隔在原图、取样图存在，分类后变成两侧同一 `PX_ROAD` → **分类合并**；分类后仍存在、平滑后消失 → **后处理损失**；材质仍存在、设备预览看不到 → 检查调色、量化/显示。原始基底无可见分隔、近景有 → **源缩放/采图分辨率限制**；两者均无 → **本输入没有可保留的分隔**，不补画猜测层级。
6. 在相同 ROI 比较普通相交、平行地面路、水岸等负样本，避免把所有道路描边都标为高架。保存原图 crop、取样 RGB、各阶段材质 crop、横穿边线的一条 RGB/材质剖面及阶段变化像素数。原图不可用插值放大来“恢复”缺失证据，展示可用 nearest-neighbor 放大。

最终应逐 ROI 标记 `source-absent / resampling-loss / classification-loss / smoothing-loss / retained`，并把未验证保留为未验证；不赋“上层/下层”道路身份。没有可用真实 PNG 前，这只是可执行判读流程，不是实际视觉验收。

## DEBUG 初始化时序修正（2026-11-03，待设备复验）

前次设备对照中，五区每区 9 张官方样式 PNG 均与默认样式逐字节相同，未收到 `customMapStyleAuthFailedWithErrorCode:message:`。这只证明当次没有观察到源图变化；没有鉴权错误不证明样式成功。上文“尚未加载”的描述属于下载候选时的初始状态。

核对当前实际安装的公共头文件 `ios/Pods/AMapNavi/AMapNaviKit.framework/Headers/MAMapView.h:1099`，初始化完成的公开 delegate selector 是 **`mapInitComplete:`**。官方 Swift Demo 的 `mapInitComplete` 调用 `changeMapStyle`，该方法读取原样资源、开启 `customMapStyleEnabled` 并调用 `setCustomMapStyleOptions`。现诊断代码此前直接在 `ensureMap` 后请求样式，没有观察 SDK 初始化回调：这是已确认的时序缺口，但它是否造成前次全量 PNG 相同仍待设备实验。头文件第 90 行明确说明自定义样式优先于 `mapType`，没有证据说后设 `.standard` 会重置自定义样式，本次未以此作为根因或单独修复。

修正仅作用于 DEBUG 显式 `--edge-capture-check --edge-capture-style` 的诊断样式：

- 新建地图时清理初始化/配置记录，按实际地图实例接收初始化完成回调；释放时清状态。初始化前不请求样式；同一地图、同一 frame 的九张源图共用一次配置，切换 scene/frame 时配置一次。
- 开始 `takeSnapshot` 前同时检查初始化回调已到达、当前 frame 已请求配置、`customMapStyleEnabled` getter 为 true。未满足时走既有 0.8 秒等待重试和原有 24/40 秒总超时；不以默认样式截图假装已经完成样式请求。此门控不增加 SDK 截图调用。
- 取消后清待处理 frame，已排队的鉴权错误通过 serial 过滤；初始化回调通过地图实例与 pending 检查，不能为已取消的任务重新请求样式。前后台/terminal/frame 隔离也应用于 `customStyleData`。
- 每区 `style-status.json` 与每片 `*-camera.json` 的 `customStyle` 字段记录 `mapInitComplete`、`configuredForFrame`、`customMapStyleEnabledGetter`、已校验资产 SHA。只导出布尔与固定资产哈希，不导出 Key、坐标或 SDK 消息。`renderedStyleChangeVerified` 固定 false，明确表示 getter 只反映请求状态，实际生效仍须同机位源 PNG 对照证明。
- 原有 `.standard/.satellite` 行、生产相机、拟合/等待常量、每区基底一张和建筑开关四对均保留。所有新增 SDK 样式操作和日志钩子均在 DEBUG 编译条件内；没有将候选样式接入生产分类。

验证：`python3 ios/tests/edge-capture/check.py` 通过，包含初始化前拒绝配置、同 frame 幂等、新 frame 重配、getter false 拒绝就绪、新地图清状态，以及实际公开 selector、snapshot 前门控、取消/迟到回调和 camera/status 字段源码检查。`building-capture`、`building-delivery`、`building-offline`、`edge-geometry`、`ios-fixes`、`map-smoothing`、`smoothing-cache` 的 `check.py` 均通过。另以显式临时 module cache 编译并执行 `amap-only`（25 checks）、`maps`（688 checks）、`four-styles`、`building-progress`，均通过。原 `run-amap-only.sh` 的默认 module cache 在只读目录受限，因此复用了同一编译输入并仅改 module cache 路径。DEBUG Swift frontend parse 通过。`git -c core.whitespace=cr-at-eol diff --check` 通过（现有 Swift 文件为 CRLF）。`building-offline` 保留原有 Swift 弱引用捕获警告，与本修正无关。

本次没有构建、签名、安装或操作手机。仍需设备重采并检查新增证据与源 PNG；即使 getter 为 true，也不能据此宣称官方样式已生效或桥边线问题已解决。
