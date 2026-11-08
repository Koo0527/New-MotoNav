# 高德平面建筑源图验证（2026-11-08）

## 结论与边界

iPhone 实际采集表明：当前 AMapNavi 10.1.600 在上海人民广场这一处、相同区域和接近相同缩放下，相机严格 0° 的楼块开启截图可以呈现平面建筑形状，原 0.05° 截图中的明显立面消失。当前生产提取链路也能从这一组输入生成建筑包。该证据支持继续验证严格俯视方案，不支持宣称所有区域、所有楼型已通过，更不能证明 4 米轮廓毛刺、资源预算或圆屏实显已解决。

本次只修改临时工程副本，没有将相机设置接入正式源码。巡航图源、导航算路、圆屏固件没有修改。用户重新连接后，已完成下文楼块高度补测，固定 1 米成为另一条有实际源图证据的候选。

## 实际操作

- 核对手机当前安装版本为 MotoNav 0.16.0 (30)。用户明确同意保持解锁并运行临时诊断，测试后恢复原 Build30。
- 临时复制 iOS 工程并复用同一 SDK，Release 编译额外启用 DEBUG 诊断。使用已有独立 MapEdgeCapture、独立临时地图缓存，不使用用户离线包。
- 两场景都查询同一公开 POI，分别使用 0.05° 和 0°，保持原采集范围、取样与楼块 OFF/ON 流程。
- 两组实际 camera 分别为 0.05000000074505806 和 0；building-0 zoom 分别为 17.378196716308594 和 17.378265380859375。缩放存在微小差异，不能当作逐像素完全同机位试验。
- 临时角度诊断签名构建成功、安装成功、启动成功，实际 PNG、相机及投影文件已导出。

## 观察结果

1. 原始 0.05° 截图中有明显的灰色立面、屋顶位移和立体外形。问题在栅格提取之前已存在。
2. 0° 同区域源图仍有建筑平面形状，不能将其简化为“关闭楼块导致建筑全消失”。直接查看原 PNG 才能判断，单看颜色面积减少不足以证明建筑缺失。
3. 两组都导出了 production-building.bin，离线解码均为完整 1200×1200 材质网格。相同左上象限的对照可见形状变化；4 米简化及阶梯边缘仍存在。
4. 0.05° 场景 diagnostics 为 partial，checkedMask=1，报“建筑图层覆盖异常”；严格 0° 场景 complete=true，checkedMask=15。只对双方都已导出的 building-0 与左上象限作形状对照，不比较整包大小或四象限完整性。
5. 0° 样本不是原始建筑多边形的导出，也不等于建筑占地几何精度已经验证。

## 补充公开能力核对

本机 SDK 头文件中存在 MACustomBuildingOverlay / MACustomBuildingOverlayOption，提供 height、heightScale、topColor、sideColor；此前只检查 MAMapView 的楼块开关并不完整。

- 官方参考：https://a.amap.com/lbs/static/unzip/iOS_Map_Doc/AMap_iOS_API_Doc_3D/interface_m_a_custom_building_overlay_option.html
- height 文档范围为 -1 或 1…1000；heightScale 默认 1，指定 height 后忽略 scale。不能将 height=0 当作文档支持的配置。
- 首次构建 heightScale=0 与 height=1 对照后，两次安装因设备 IXRemoteErrorDomain 6 / Connection interrupted 失败。用户随后重新连接并解锁，已成功安装、启动并取得下述真实高度对照。首次失败不再是最终状态。
- 既有官方样式样本测试没有可见画面变化，不能拿来证明二维建筑样式已成功应用。本轮未下载新的控制台样式。

## 证据

目录：`output/amap-flat-source-20261108/`。

- `angle-raw-comparison.png`：左 0.05°、右 0°，同源区域原 PNG 裁剪，无平滑处理。
- `angle-production-comparison.png`：两组生产包同一左上象限局部，最近邻放大，无新增抗锯齿，使用固定示意调色板；不是圆屏固件实帧或新性能证据。
- `angle-summary.json`：相机、左上象限材质计数及原 diagnostics。
- `evidence-manifest.json`：导出文件长度和 SHA-256。
- `capture-angle-final/0BF11463-FD06-4AA9-A09F-C6F516D2945A/`：完整导出。
- `build.log`、`install.log`、`launch.log`：实际角度诊断构建、安装及启动记录。
- `build-height-near.log`、`install-height*.log`：高度对照仅构建成功，安装失败。
- `restore-build30.log`：恢复原签名 Build30 安装退出码 0；`restore-launch.log`：正常启动退出码 0。没有继续保留临时诊断作为日用版本。

## 后续验证条件

正式采用前，应使用同一地点的楼栋参考和多个独立区域检查平面形状完整性、不同相机中心的稳定性、道路遮挡及跨片边界。毛刺优化仍单独验收。真实占地精度、CPU/内存、累计流量和圆屏绘制性能本轮未完成验证。

## 重新连接后的高度接口实测

保持近景 camera=0.05000000074505806，使用 SDK 自带 MACustomBuildingOverlay 与 renderer，关闭默认楼块避免重复绘制。沿用默认顶面、侧面颜色，没有给每栋建筑单独提供几何。

| 场景 | 设置 | 原图观察 | 生产提取 |
| --- | --- | --- | --- |
| 03-height-scale0 | height=-1，heightScale=0 | 仍有明显高楼立面，本设置未达到平面化目标；不推断 SDK 内部处理原因 | partial，checkedMask=1，建筑图层覆盖异常 |
| 04-height-1m | height=1，heightScale=1 | 高楼立面明显消失，建筑平面形状保留 | complete=true，四片齐全，checkedMask=15，无失败 |

两组 building-0 zoom 分别为 17.378196716308594 与 17.378265380859375。0.05° 对照和固定 1 米对照的图形/配色不同，原默认楼块与自定义楼块默认颜色也不同；不将颜色变化误认为形状改善。固定 1 米的侧面厚度变化可从真实 PNG 直接观察。

固定 1 米是近似平面表达，不等于 SDK 导出了原始占地多边形，也不是几何高度严格归零。它符合公开 height 的文档取值范围，值得作为保留现有近俯视采集参数的候选，与严格 0° 继续比较。这里只验证一处，不承诺其他区域、缩放及实屏效果全部通过。

新增证据：

- `capture-height/`：本次实际导出的两组 PNG、camera、projection、生产包及 diagnostics。
- `height-source-comparison.png`：左 heightScale=0，右固定 1 米。
- `original-vs-height1-source.png`：左原高度，右固定 1 米；均为原 PNG 同一区域裁剪，没有额外平滑。
- `height-summary.json`：两个生产包均可展开为 1200×1200 材质网格；不比较部分包与完整包的大小来推断性能。
- `height-probe-source-hashes.json`：临时诊断源码 SHA-256。
- `install-height-reconnected.log`、`launch-height-reconnected.log`：重新连接后的安装和启动成功记录。
- `restore-after-height.log`：高度采集后恢复正常 Build30，安装退出码 0；后续启动结果记录于 `restore-after-height-launch.log`。
