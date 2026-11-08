# 真实源图分隔证据：离线重放（2026-11-03）

## 结论边界

**最终样式结论：初始化完成门控后的真实对照仍为 9/9 PNG 完全相同、RGB 改变 0。** 公开 `my_style_new.data` 在当前 SDK / 采图配置未产生可见画面变化。初始化、配置及 enable getter 都已记录为 true；不再把未验证时序当作继续试错的理由，也不宣称兼容成功。本结果只针对本候选及本次配置，不等于平台完全没有相关能力。最终状态与下一条有证据的路径见文末。

`04-interchange` 的 base 中央黄色路面在源图就连成面，未见能横跨交叉路面的连续桥边线。基底此处不能靠材质分类恢复一个源图没有的分隔。近景 OFF 的灰白中央分隔线存在：有保留点、纯白部分的分类颜色合并、灰边缘的局部平滑侵蚀。**不能据孤立探针宣称完整高架隔断被封死**，也不把中央分隔带称为桥梁边线；道路层级未获证实。

所有分析只读取真实无建筑 PNG、projection、camera、ARGB 与当前生产源码。无生产、固件、相机或采图修改，无设备操作。蓝/粉/绿彩线不作为桥梁边界，阴影和跨缩放差异不作为分类丢失证据。

## 输入与重放

输入 `output/map-edge-bridge/fresh-default-five/04-interchange/`；输出 `output/map-edge-bridge/bridge-replay/04-verified-{base,building-N-off}/`。

原图 base 2160² → 精确 1200² 采样；4 张 OFF 2880² → 分别精确 600²。base PNG 按归档整数 columns/rows 重采样与归档 ARGB **逐字节相同**。OFF 各自核对 on/off projection 完全相等后独立取样，不把带建筑配对的 ARGB 当 OFF 像素真值。

`ios/tests/bridge-source/replay.py` 临时复制当前 `MapGeo.swift`，仅移除 recoverGrayRoads 的 private 访问级别；完整原源码 SHA-256、输入哈希、相机、ROI、输出 idx 哈希在每份 report.json。所有输入均 assert 最终阶段与生产 `classifyAmapBase(style:1)` 完全相同。

| 输入 | 实际 zoom | gray recovery 变化 | smooth 变化 |
| --- | ---: | ---: | ---: |
| base | 15.55608559 | 0 | 54,949 |
| OFF0 | 17.37833786 | 0 | 44,545 |
| OFF1 | 17.38009262 | 0 | 37,137 |
| OFF2 | 17.38028717 | 0 | 46,563 |
| OFF3 | 17.38028526 | 0 | 47,466 |

变化数是全图像素，不能当成桥梁分隔丢失量。所有 gray recovery 都为 0，因此本样本不支持“recoverGrayRoads 将桥边线变成路”的推断。

## 同像素 ROI 证据

每个目录含 native `source.png`、sampled RGB、三个材质阶段 crop、nearest stage panel、profile.csv 和 ROI 变化量。矩形坐标均为采样图，右/下边界不含。

| 输入 / ROI | 采样矩形 | 原图矩形 | gray/smooth ROI变化 |
| --- | --- | --- | ---: |
| base 中央交叉 | [530,550,640,660] | [965,997,1146,1180] | 0 / 359 |
| base 普通路口负例 | [475,760,565,830] | [874,1346,1022,1462] | 0 / 270 |
| OFF0 北侧交叉 | [410,15,480,75] | [1949,120,2267,395] | 0 / 442 |
| OFF1 交叉细节 | [405,340,450,385] | [1926,1628,2130,1833] | 0 / 244 |
| OFF2 匝道分隔细节 | [400,0,560,55] | [1903,49,2638,301] | 0 / 857 |
| OFF3 灰白中央分隔 | [70,105,130,155] | [381,536,654,765] | 0 / 335 |
| OFF3 普通路口负例 | [120,285,190,345] | [611,1373,931,1648] | 0 / 748 |

关键三点探针按“路面 / 候选分隔 / 路面”排列，材质 0=block，1=road：

- **source-absent**：base (571,600)/(572,600)/(573,600) → 源 (1032,1080)/(1034,1080)/(1036,1080)，RGB 均 (247,223,132)，三个阶段均 [1,1,1]。只说明这条选定剖面，没有凭空重建连续桥线的依据。
- **retained**：OFF3 (90,124)/(92,124)/(94,124) → 源 (473,625)/(482,625)/(492,625)，RGB 分别 (249,223,129)/(230,231,234)/(225,215,178)，三个阶段均 [1,0,1]。
- **smoothing-loss（局部）**：OFF3 (92,125)/(94,125)/(96,125) → 源 (482,629)/(492,629)/(501,629)，RGB (223,214,180)/(225,229,233)/(249,223,127)，classify/recover [1,0,1] → smooth [1,1,1]。这是已见中央分隔灰边缘的一点侵蚀，旁边仍有分隔；不是整条隔断拓扑闭合证明。
- **classification-loss（颜色/局部）**：OFF3 (94,121)/(97,121)/(100,121) → 源 (492,611)/(505,611)/(519,611)，RGB (254,224,122)/(255,255,255)/(246,223,127)，classify 已为 [1,1,1]。源图纯白分隔与纯白普通道路同色，不能用“所有白色设为分隔”解决。
- **smoothing-loss（局部）**：OFF1 (419,371)/(421,371)/(423,371) → 源 (1991,1772)/(2000,1772)/(2009,1772)，RGB (233,202,124)/(238,239,242)/(223,214,181)，classify/recover [1,0,1] → smooth [1,1,1]。仍只证明选定局部像素。

本次没有选定能证实 resampling-loss 的真实连续分隔探针，因此不把该标签算作已发生。OFF0/OFF2 的 crop 是源细节对照，不强行分配 bridge-loss 类别。普通路口负例保留供未来任何候选方案核对：普通白色道路/路口不应被普遍解释为隔断。

## 最小可保留候选：只保留源图已见灰像素

`candidate.py` 仅导出 **OFF3 已人工检查的中央灰分隔短段**：样本 y124–133，人工 trace 周围低饱和灰像素，且 classify/recover 原本为 block。23 个真实源采样灰像素中，8 个被 smooth 改为 road；15 个已保留。`candidate-source-gray-mask.png`、`candidate-points.csv` 和 `candidate-report.json` 保留精确证据。

最小候选是在这类**另有源证据支持的位置**保护现有分隔像素免于平滑扩张。此处仅为可检查的离线候选掩码，未修改生产，未验证通用规则，不补丢失段，不延长穿过彩色线，不赋桥梁层级。全图低饱和灰色也包括普通路缘、文字和建筑细节，因此不能直接把这个局部筛选推广全图。此候选不能恢复 base 无线区域，也不能凭颜色独立识别纯白分隔。

## 复现

```sh
for tile in base building-0-off building-1-off building-2-off building-3-off; do
  python3 ios/tests/bridge-source/replay.py \
    output/map-edge-bridge/fresh-default-five/04-interchange \
    output/map-edge-bridge/bridge-replay/04-rerun-$tile \
    --tile "$tile" --rois "ios/tests/bridge-source/04-$tile-rois.json"
done
python3 ios/tests/bridge-source/candidate.py \
  output/map-edge-bridge/bridge-replay/04-rerun-building-3-off
```

新输出目录不得已存在 report.json。脚本包含五类别 assert 与每个真实输入的生产最终阶段等价 assert。尚未在设备显示效果上验收，也未以本报告承诺官方样式支持新的桥层级功能。官方 style 的真实截图到达后，需先比较同相机/同缩放的实际源边界变化，再讨论材质阶段。

此前单独 `fresh-default/01-dense` 的证据见 `bridge-replay/01-dense-verified/evidence.md`；该旧输入只有两张 OFF，不能替代当前五场景完整度声明。

## 官方 Demo 样式首轮真实对照：画面未变化

已独立核对 `fresh-default-five/04-interchange` 与 `fresh-official-style/04-interchange`：
**9 张 PNG（base + 4 ON + 4 OFF）逐文件 SHA-256、文件字节完全相同，解码 RGB 改变像素总数为 0**；5 份 camera JSON 内容完全相同，projection/zoom 均无差异。逐文件哈希和 metadata 已保存 `output/map-edge-bridge/bridge-replay/04-official-style-comparison.json`，可用 `ios/tests/bridge-source/compare.py` 重跑。

官方导出的 scene.json 标为 `styleRequested=official-demo-style`，`verifiedAssetSHA=69b20d2eee6e2503e294aab4cf46108819ef1b95690f3258daa97c1e35a72d4f`。本地公开原资产实际为 85,241 bytes，SHA 与 metadata 相符；本核查仅计算文件哈希，未读取/反解二进制内部编码。metadata 证明请求/资产校验记录，**不证明 SDK 已视觉应用样式或与 10.1.600 兼容**。

当前能确认的是“此轮对照画面没有变化”。无 callback 错误、设置 API 返回或 customMapStyleEnabled getter 为 true，都不能单独替代真实源图变化验收。也不能由相同画面直接断言资产必然不兼容、权限失败或某个 setter reset 样式。

### mapType 顺序不是已证实根因

本机公共头文件 `ios/Pods/AMapNavi/AMapNaviKit.framework/Headers/MAMapView.h:90` 明确写：

> 地图类型。注意：自定义样式优先级高于mapType，如开启了自定义样式，要关闭自定义样式后mapType才生效

这是直接相反的公开接口语义，不能把 `setCustomMapStyleOptions` / enable 后赋 `.standard` 说成已知会 reset。头文件文档可能不穷尽实现时序，但当前没有可读公开证据支持 reset 归因。

公开 Demo 可读样例提供更具体的初始化时序参照：

- `output/edge-bridge-evidence/CustomMapStyleViewController.m`：viewDidLoad 设置 options，**mapInitComplete 回调**调用切换方法，将 customMapStyleEnabled 设为 YES。
- 同目录 Swift 例：**mapInitComplete 回调**调用切换方法，设 enable 并设置 options。

两个例子的 options/enable 相对先后也不同，因此不能把其中一个先后次序说成唯一官方要求；共同点是在初始化完成后触发启用。首轮采图所用 AmapCaptureHost 在 capture 中直接设样式，未以 mapInitComplete 作为启用条件；这在当时只支持一次受控诊断，不证明根因。后续已完成初始化门控修正和真实采图，结果见最终对照。

### 首轮后的诊断建议（历史，现已完成初始化门控验证）

在 **DEBUG 独立对照**中选择一个真实机位/缩放，不再先采五区：先确保标准 mapType、初始化完成，再按官方可读样例设置/启用原资产；记录 mapInitComplete 是否发生、实际 style getter、资产 SHA、SDK auth callback、camera/projection，并在后续完整渲染完成时保留 PNG。配一张同相机禁用样式的源 PNG，以真实 RGB 差分先证明样式在这台 SDK 上有可见效果。

上述初始化门控建议已由主流程完成并获得 signed 诊断实际输出。本离线分析未执行设备操作。没有公开依据将 setter reset 当作根因；最终结果仍无画面变化，不再提出凭空改调用顺序的后续试验。

若按官方初始化流程仍然零像素差异，停止声称首轮兼容成功；再使用与当前 SDK 明确匹配、已知有明显底色变化的正式导出样式作为控制，或向高德确认 10.1.600 对该 Demo 资产的版本兼容。仍不猜测缺失的独立桥梁层级 API。


## 初始化门控后的最终真实对照：本候选无画面效果

最终输入 `output/map-edge-bridge/fresh-official-style-initialized/04-interchange/` 完整包含 base、4 ON、4 OFF 共 **9 张真实 PNG**，并有 `style-status.json` 和每套 camera 的 `customStyle`。与 `fresh-default-five/04-interchange` 对照结果：

- 9/9 PNG 文件 SHA-256 和字节完全相同；逐像素解码 RGB 改变 **0**。
- 5 套 camera 的 zoom、camera、rotation、视口和 on/off projection 几何完全相同；base.json 与 4 份 ON projection JSON 也全部相同。
- 最终 camera JSON 新增了 customStyle 状态字段，所以原始 JSON 整体不再相同。这不是机位变化；几何等价核对见单独状态报告。
- `style-status.json` 与 5 套 camera.customStyle 一致：`requested=true`、`configuredForFrame=true`、`mapInitComplete=true`、`customMapStyleEnabledGetter=true`，同时 `renderedStyleChangeVerified=false`。
- `verifiedAssetSHA` 与原资产实算 SHA 均为 `69b20d2eee6e2503e294aab4cf46108819ef1b95690f3258daa97c1e35a72d4f`，原资产 85,241 bytes。未检查二进制内部编码。

最终逐 PNG 比较保存在 `output/map-edge-bridge/bridge-replay/04-official-style-initialized-comparison.json`；完整状态、几何相等、投影相等及资产核对保存在同目录 `04-official-style-initialized-status.json`。前一报告的 camera 全对象 equal=false 仅是新增状态字段；后一报告按几何字段逐一核对为 true。所有关键结论经过实际输入 assert 核对。

**因此，该公开 Demo 候选在当前 SDK/采图配置未产生画面改变，未证实其可见应用效果或兼容成功。** 初始时序门控已验证，不再用未获证据的时序猜测或“getter 为 true”替代画面证据，也不将零变化归因于某个未经证明的 SDK 内部行为。默认源图的 ROI 分析仍适用：同一 PNG 没有新增可以保留的桥边界。

本次输入不能恢复真实全路网的高架上下层、遮挡顺序和源图未画出的连续边线。现有 source-only 候选至多保护已可见局部灰分隔；它不是全路网层级方案。要另试样式路径，需要**高德官方明确匹配当前 10.1.600 SDK 的正式导出样式**，并选择已知有明显底色/描边变化的控制，以同机位真实 PNG 先验证有可见差异，再判断目标道路边线；若当前版本分组不明确，先由官方确认。没有这样的匹配资产之前，不继续猜测样式内部内容或添加无来源桥线。

这项结论不表示高德平台完全无能力，也不保证换一份资产就能获得独立桥梁层级。仍须按公开能力及新的真实输入验证。本轮只补离线报告与输出证据，未修改 source、操作设备或构建。
