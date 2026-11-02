#include "../boards/175/MotoNav/GameMapStyle.h"
#include <cassert>
int main(){float x[20],y[20];int n=GameMapStyle::destinationVertices(2,0,0,14,x,y);assert(n==16);int tips=0,notches=0;for(int i=0;i<n;i++){if(fabsf(x[i])==14 || fabsf(y[i])==14)tips++;if(fabsf(x[i])==4 && fabsf(y[i])==4)notches++;}assert(tips==4 && notches==4);assert(GameMapStyle::destinationHoleRadius(2)==3);assert(GameMapStyle::destinationHoleRadius(1)==0);assert(GameMapStyle::destinationVertices(1,0,0,14,x,y)==4);assert(GameMapStyle::destinationVertices(3,0,0,14,x,y)==6);}
