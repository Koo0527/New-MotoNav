#include <cstdio>
#include "../../../firmware/boards/175/MotoNav/GameMapStyle.h"
int main(){for(int t=1;t<=3;t++)for(int n=0;n<=1;n++){auto p=GameMapStyle::palette(t,n);uint16_t c[16]={p.base,p.road,p.park,p.water,p.roof,p.outline,p.roof,p.outline};GameMapStyle::roadPalette(t,n,c);printf("%d %d",t,n);for(auto v:c)printf(" %u",v);puts("");}}
