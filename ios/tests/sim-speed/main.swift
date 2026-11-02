// 模拟速度策略行为测试：分方式档位、默认值、非法值回退、循环调速与机动车档位不变。
// 自行车 10 / 20 / 30（默认 20）；驾车、摩托车 60 / 100 / 120（默认 60）。
import Foundation

// 档位与默认值
precondition(NavigationSpeed.bicycleValues == [10, 20, 30], "bicycle gears must be 10/20/30")
precondition(NavigationSpeed.motorValues == [60, 100, 120], "motor gears stay 60/100/120")
precondition(NavigationSpeed.defaultSpeed(bicycle: true) == 20, "bicycle default must be 20")
precondition(NavigationSpeed.defaultSpeed(bicycle: false) == 60, "motor default must stay 60")
precondition(NavigationSpeed.values(bicycle: true) == [10, 20, 30])
precondition(NavigationSpeed.values(bicycle: false) == [60, 100, 120])

// 非法值回退：不在该方式档位里的速度回到默认档
precondition(NavigationSpeed.normalized(60, bicycle: true) == 20, "a motor gear must not apply to bicycle")
precondition(NavigationSpeed.normalized(100, bicycle: true) == 20)
precondition(NavigationSpeed.normalized(20, bicycle: false) == 60, "a bicycle gear must not apply to motor")
precondition(NavigationSpeed.normalized(10, bicycle: false) == 60)
precondition(NavigationSpeed.normalized(0, bicycle: true) == 20)
precondition(NavigationSpeed.normalized(-5, bicycle: false) == 60)
precondition(NavigationSpeed.normalized(999, bicycle: true) == 20)
// 合法值原样保留
precondition(NavigationSpeed.normalized(10, bicycle: true) == 10)
precondition(NavigationSpeed.normalized(30, bicycle: true) == 30)
precondition(NavigationSpeed.normalized(120, bicycle: false) == 120)

// 自行车循环：10 → 20 → 30 → 10
precondition(NavigationSpeed.next(10, bicycle: true) == 20)
precondition(NavigationSpeed.next(20, bicycle: true) == 30)
precondition(NavigationSpeed.next(30, bicycle: true) == 10, "bicycle cycling must wrap 30 back to 10")

// 机动车档位不变：60 → 100 → 120 → 60
precondition(NavigationSpeed.next(60, bicycle: false) == 100)
precondition(NavigationSpeed.next(100, bicycle: false) == 120)
precondition(NavigationSpeed.next(120, bicycle: false) == 60, "motor cycling must wrap 120 back to 60")

// 非法值循环从默认档的下一档起步（先回退默认，再循环）
precondition(NavigationSpeed.next(999, bicycle: true) == 30, "invalid bicycle value cycles from the default gear")
precondition(NavigationSpeed.next(999, bicycle: false) == 100, "invalid motor value cycles from the default gear")

print("PASS simulation speed strategy: bicycle 10/20/30 default 20, motor 60/100/120 default 60, invalid fallbacks and cycling")
