#include <cstdio>
#include "../../../../firmware/boards/175/MotoNav/GameMapStyle.h"
int main() {
  for(int theme=1;theme<=3;theme++) {
    const auto p=GameMapStyle::palette(theme,false);
    std::printf("%d %u %u %u %u %u %u\n",theme,p.base,p.road,p.park,p.water,p.roof,p.outline);
  }
}
