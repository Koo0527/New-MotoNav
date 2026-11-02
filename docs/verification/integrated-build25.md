# Build25 最终 UI 整合

2026-11-02，用户确认其他对话和 agent 已完成，按此前“完成后统一安装”的授权整合。

## 相对已安装 Build24

- 导航首页按搜索、收藏与最近、路线与分享、巡航排列；最近目的地首页最多五项，通过“全部”管理。
- 轨迹页只保留轨迹；圆屏设置拆为显示与地图、按键与电源、开机设置、音乐控制、G 仪表与校准、连接管理六组。
- 四标签保留统一回到导航状态条，取消按标签重建整个 NavigationView。
- 路线选项与模拟设置采用可展开入口。保留已合入的自行车 10/20/30 km/h（默认20）、机动车60/100/120（默认60）策略。
- 保留 Build24 已通过用户模拟验收的统一车道/路口图片及 175c.8 圆屏车道显示修复。

## 本轮审查补修

收藏管理的 `onDelete` 先正向索引可变数组，再逐项同步删除，多个选中项会错删或越界。真实 Favorites 模型和实际视图回调在独立 UserDefaults 中测试 `[0,2,3]`，修复前 SIGTRAP，改为降序索引后通过；同时检查持久化存活项、空选中和最后一项。测试已放入现有 `ios-fixes` 发布回归。

## 验证与交付

- 十组回归通过：ios-fixes、unified-navi-ui、unified-planner、ride-bridge、ride-preempt、ride-ble-parity、webmotor、tunnel-settings、lane-guidance、nav-coordinator。
- 实际 NavigationSpeed 策略测试通过。收藏补修后重新运行 ios-fixes，全部通过。
- 独立只读审查发现上述收藏删除问题，未发现其他确定阻塞。审查未代替真机布局验收。
- 签名 Release Build25 最终构建成功，全部 App Swift 文件和 pbxproj 的构建前后 SHA 一致。日志在 `/private/tmp/motonav-integrated25-*`，快照与清单在 `output/integrated-build25`。
- 固件源码没有晚于已验收 175c.8 镜像的修改，本轮保留该固件，不重复烧录。

Build25 已覆盖安装；首次启动被锁屏拒绝，用户解锁后由 devicectl 启动成功。交付清单记录 appInstalled/appLaunched=true。尚未人工验证全部新设置入口、大字体、横屏及实际道路低速模拟；本轮没有解决地图抗锯齿和真实全图道路层级问题。
