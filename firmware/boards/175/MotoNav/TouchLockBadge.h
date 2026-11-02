#pragma once

// 触摸锁定徽标：锁定期间显示在状态栏左上方的黄色挂锁。
// v7.12.10-pages.175c.9 起从屏幕顶部中央移到 CX-44，与蓝牙点、电池及百分比留出间距，
// 不再和任何状态栏内容重叠。几何常量同时给固件绘制与回归测试使用，
// 保证“不与蓝牙/电池/充电标/三位百分比相交”的断言和实机画法永不漂移。
// 依赖包含方先提供 gfx / CX / C_YELLOW / C_BLACK（单翻译单元头文件顺序已满足）。
namespace TouchLockBadge {
constexpr int DX = -44;              // 中心相对 CX 的水平偏移
constexpr int LEFT = -9;            // 锁体左缘相对中心
constexpr int RIGHT = 9;            // 锁体右缘相对中心
constexpr int BODY_TOP = 22, BODY_H = 14;
constexpr int SHACKLE_LEFT = -6, SHACKLE_W = 12, SHACKLE_TOP = 14, SHACKLE_H = 15;
constexpr int TOP = SHACKLE_TOP;                 // 14
constexpr int BOTTOM = BODY_TOP + BODY_H - 1;    // 35
inline int centerX(int cx) { return cx + DX; }

// 徽标整体外接矩形（擦除残留用）
struct Rect { int x, y, w, h; };
inline Rect bounds(int cx) {
  return Rect{centerX(cx) + LEFT, TOP, RIGHT - LEFT + 1, BOTTOM - TOP + 1};
}

inline void erase(int cx) {
  Rect r = bounds(cx);
  gfx->fillRect(r.x, r.y, r.w, r.h, C_BLACK);
}

inline void draw(int cx) {
  const int x = centerX(cx);
  gfx->fillRoundRect(x + LEFT, BODY_TOP, RIGHT - LEFT + 1, BODY_H, 3, C_YELLOW);
  gfx->drawRoundRect(x + SHACKLE_LEFT, SHACKLE_TOP, SHACKLE_W, SHACKLE_H, 5, C_YELLOW);
}
}
