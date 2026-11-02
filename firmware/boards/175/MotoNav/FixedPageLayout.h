#pragma once

// Screen positions: music(-1,0), navigation(0,0), weather(1,0),
// rain(1,-1), alerts(1,1), G meter(0,1). sign is the corrected finger movement.
namespace FixedPageLayout {
struct Target { int page; int detail; bool allowed; };
inline Target move(int page, int detail, bool horizontal, int sign) {
  Target none{page, detail, false};
  if (sign != -1 && sign != 1) return none;
  if (horizontal) {
    if (page == 2 && sign < 0) return {0, 0, true};
    if (page == 0) return sign < 0 ? Target{1, 0, true} : Target{2, 0, true};
    if (page == 1 && detail == 0 && sign > 0) return {0, 0, true};
    return none;
  }
  if (page == 0 && sign < 0) return {3, 0, true};
  if (page == 3 && sign > 0) return {0, 0, true};
  if (page != 1) return none;
  if (detail == 0) return {1, sign > 0 ? 1 : 2, true};
  if (detail == 1 && sign < 0) return {1, 0, true};
  if (detail == 2 && sign > 0) return {1, 0, true};
  return none;
}
inline int weatherRow(int detail) { return detail == 1 ? 0 : detail == 2 ? 2 : 1; }

// 页面提示点的共享实现：底部三个横向点表示左右页（音乐/首页/天气），
// 右侧纵向点表示上下页（首页/天气行/G 仪表）。G 仪表页(page==3)只有
// 上下切换，因此不画底部横向点，只画右侧两个纵向点且下点高亮。
// 依赖包含方先提供 aaDisc / C_WHITE / CX（首页与本地 G 仪表页、回归测试均满足）。
constexpr int DOT_DIM = 0x4208;
inline void drawPageDots(int page, int detail, bool inNav) {
  if (page == 0 && inNav) return;
  if (page != 3) {
    const int pageOrder[] = {2, 0, 1};
    for (int i = 0; i < 3; i++) {
      aaDisc(CX + (i - 1) * 20, 444, 4, page == pageOrder[i] ? C_WHITE : DOT_DIM);
    }
  }
  if (page == 0 || page == 3) for (int i = 0; i < 2; i++) {
    aaDisc(438, CX + (i * 2 - 1) * 9, 3, (page == 3) == (i == 1) ? C_WHITE : DOT_DIM);
  }
  if (page == 1) for (int i = 0; i < 3; i++) {
    aaDisc(438, CX + (i - 1) * 18, 3, i == weatherRow(detail) ? C_WHITE : DOT_DIM);
  }
}
}
