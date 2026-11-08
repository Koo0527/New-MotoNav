// Host-only residual admission probe; frozen C encoder and renderer remain untouched.
#include <cstdlib>
static double residualLimit=.14;
static unsigned binaryResidualReject=0,binaryCenterReject=0,bandResidualReject=0,bandCenterReject=0;
#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <set>
#include <vector>

constexpr double pi = 3.14159265358979323846;
static int pairID(int a, int b) { return a * 7 - a * (a - 1) / 2 + b - a; }
static std::array<int,2> pairMaterials(int id) {
    for (int a=0;a<8;++a) for (int b=a+1;b<8;++b)
        if (pairID(a,b)==id) return {{a,b}};
    assert(false); return {{0,0}};
}
static int sample(uint16_t word, double x, double y) {
    if (word & 0x8000) return (word >> (3*((y>=0)*2+(x>=0))))&7;
    int pair=(word>>10)&31;
    if (!pair) return word&7;
    double angle=((word>>5)&31)*pi/16, d=(int(word&31)-16)/32.0;
    if(pair==29 || pair==30) {
        double nx=std::cos(angle),ny=std::sin(angle),side=nx*x+ny*y-d;
        int ground=pair==29?0:2,fill=pair==29?4:6;
        return side<0?ground:side>=.5*std::max(std::abs(nx),std::abs(ny))?fill:fill+1;
    }
    auto ab=pairMaterials(pair);
    return ab[std::cos(angle)*x+std::sin(angle)*y-d>=0];
}
static uint16_t fitBand(const std::vector<uint8_t>& p,int w,int h,int x,int y) {
    if(x<1 || y<1 || x+2>=w || y+2>=h)return 0;
    int mask=0;for(int j=-1;j<=2;++j)for(int i=-1;i<=2;++i)mask|=1<<p[(y+j)*w+x+i];
    int ground=mask==0x31?0:mask==0xc4?2:-1;
    if(ground<0)return 0;
    int fill=ground==0?4:6;
    std::vector<std::array<double,2>> outer,inner;
    auto transition=[&](int a,int b,double px,double py) {
        if(a==b)return;
        if((a==ground)!=(b==ground))outer.push_back({{px,py}});
        else inner.push_back({{px,py}});
    };
    for(int j=-1;j<=2;++j)for(int i=-1;i<=2;++i) {
        int v=p[(y+j)*w+x+i];double px=(i-.5)*.5,py=(j-.5)*.5;
        if(i<2)transition(v,p[(y+j)*w+x+i+1],px+.25,py);
        if(j<2)transition(v,p[(y+j+1)*w+x+i],px,py+.25);
    }
    if(outer.size()<3 || inner.size()<2)return 0;
    double mx=0,my=0;for(auto q:outer){mx+=q[0];my+=q[1];}mx/=outer.size();my/=outer.size();
    double xx=0,yy=0,xy=0;for(auto q:outer){double dx=q[0]-mx,dy=q[1]-my;xx+=dx*dx;yy+=dy*dy;xy+=dx*dy;}
    double angle=.5*std::atan2(2*xy,xx-yy)+pi/2,orient=0;
    for(int j=-1;j<=2;++j)for(int i=-1;i<=2;++i)
        orient+=(p[(y+j)*w+x+i]==ground?-1:1)*(std::cos(angle)*(i-.5)+std::sin(angle)*(j-.5));
    if(orient<0)angle+=pi;
    int normal=int(std::lround(angle*16/pi))&31;
    double nx=std::cos(normal*pi/16),ny=std::sin(normal*pi/16);
    int offset=int(std::lround((nx*mx+ny*my)*32))+16;
    if(offset<0 || offset>31)return 0;
    double d=(offset-16)/32.0,band=.5*std::max(std::abs(nx),std::abs(ny));
    for(auto q:outer)if(std::abs(nx*q[0]+ny*q[1]-d)>residualLimit){++bandResidualReject;return 0;}
    for(auto q:inner)if(std::abs(nx*q[0]+ny*q[1]-d-band)>residualLimit){++bandResidualReject;return 0;}
    uint16_t word=uint16_t((ground==0?29:30)<<10 | normal<<5 | offset);
    for(int j=-1;j<=2;++j)for(int i=-1;i<=2;++i) {
        double px=(i-.5)*.5,py=(j-.5)*.5,side=nx*px+ny*py-d;
        if(std::abs(side)<.001 || std::abs(side-band)<.001 || sample(word,px,py)!=p[(y+j)*w+x+i]){++bandCenterReject;return 0;}
    }
    return word;
}
struct Stats { int pure=0, plane=0, band=0, fallback=0, outerMixed=0,outerAccepted=0,rejected[6]={},fallbackMasks[256]={},bandCalls=0; double bandMs=0; };
static std::vector<uint16_t> encode(const std::vector<uint8_t>& p,int w,int h,Stats& st,bool allowThree=false,bool allowBand=false) {
    assert(w>0 && h>0 && !(w&1) && !(h&1) && p.size()==size_t(w*h));
    assert(std::all_of(p.begin(),p.end(),[](uint8_t v){return v<8;}));
    std::vector<uint16_t> out(w*h/4);
    for (int cy=0;cy<h/2;++cy) for(int cx=0;cx<w/2;++cx) {
        int x=2*cx,y=2*cy; int m[4]={p[y*w+x],p[y*w+x+1],p[(y+1)*w+x],p[(y+1)*w+x+1]};
        uint16_t word=0x8000; for(int i=0;i<4;++i) word|=m[i]<<(i*3);
        int mask=0;for(auto v:m) mask|=1<<v;
        int reason=0;
        if (!(mask&(mask-1))) {word=m[0];++st.pure;}
        else {
            bool silhouette=(mask&0x0f) && (mask&0xf0);
            if(silhouette)++st.outerMixed;
            bool ok=true;
            if (__builtin_popcount(unsigned(mask))!=2) {ok=false;reason=0;}
            int a=__builtin_ctz(unsigned(mask)),b=31-__builtin_clz(unsigned(mask)), n=0;
            for(int v:m) n+=v==a;
            // Variant A keeps ambiguous 3:1 corners; B admits them only with the full 4x4 line evidence below.
            if (ok && ((!allowThree && n!=2) || (m[0]==m[3] && m[1]==m[2]))) {ok=false;reason=1;}
            if(ok && (x<1 || y<1 || x+2>=w || y+2>=h)) {ok=false;reason=2;}
            // Preserve road/water against all building contacts, as the existing EDGE fitter does.
            if(ok && (mask&0x0a) && (mask&0xf0)) {ok=false;reason=3;}
            std::vector<std::array<double,2>> points;
            if(ok) {
                for(int j=-1;j<=2;++j) for(int i=-1;i<=2;++i) {
                    int v=p[(y+j)*w+x+i];
                    if(v!=a && v!=b) ok=false;
                    double px=(i-.5)*.5,py=(j-.5)*.5;
                    if(i<2 && v!=p[(y+j)*w+x+i+1]) points.push_back({{px+.25,py}});
                    if(j<2 && v!=p[(y+j+1)*w+x+i]) points.push_back({{px,py+.25}});
                }
                if(!ok || points.size()<3) {ok=false;reason=4;}
            }
            if(ok) {
                double mx=0,my=0;for(auto q:points){mx+=q[0];my+=q[1];} mx/=points.size();my/=points.size();
                double xx=0,yy=0,xy=0;
                for(auto q:points){double dx=q[0]-mx,dy=q[1]-my;xx+=dx*dx;yy+=dy*dy;xy+=dx*dy;}
                double angle=.5*std::atan2(2*xy,xx-yy)+pi/2, orient=0;
                for(int j=-1;j<=2;++j)for(int i=-1;i<=2;++i)
                    orient+=(p[(y+j)*w+x+i]==b?1:-1)*(std::cos(angle)*(i-.5)+std::sin(angle)*(j-.5));
                if(orient<0) angle+=pi;
                int normal=int(std::lround(angle*16/pi))&31;
                double nx=std::cos(normal*pi/16),ny=std::sin(normal*pi/16);
                int offset=int(std::lround((nx*mx+ny*my)*32))+16;
                double d=(offset-16)/32.0;
                if(offset<0 || offset>31 || std::abs(d)>(std::abs(nx)+std::abs(ny))*.5) ok=false;
                bool residualFailed=false,centerFailed=false;
                for(auto q:points) if(std::abs(nx*q[0]+ny*q[1]-d)>residualLimit) {ok=false;residualFailed=true;}
                if(residualFailed)++binaryResidualReject;
                for(int j=-1;j<=2;++j)for(int i=-1;i<=2;++i) {
                    double side=nx*(i-.5)*.5+ny*(j-.5)*.5-d;
                    // Nonzero margin prevents platform sign/tie differences at original 2m centers.
                    if((p[(y+j)*w+x+i]==a && side>=-.001) || (p[(y+j)*w+x+i]==b && side<=.001)) {ok=false;centerFailed=true;}
                }
                if(centerFailed)++binaryCenterReject;
                if(ok) {word=uint16_t(pairID(a,b)<<10 | normal<<5 | offset);++st.plane;}
                else reason=5;
            }
            if(!ok && allowBand) {
                auto start=std::chrono::steady_clock::now();
                uint16_t band=fitBand(p,w,h,x,y);
                st.bandMs+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();++st.bandCalls;
                if(band){word=band;ok=true;++st.plane;++st.band;}
            }
            if(ok && silhouette)++st.outerAccepted;
            if(!ok){
                ++st.fallback;++st.rejected[reason];
                int halo=mask;
                if(x>=1 && y>=1 && x+2<w && y+2<h)
                    for(int j=-1;j<=2;++j)for(int i=-1;i<=2;++i)halo|=1<<p[(y+j)*w+x+i];
                ++st.fallbackMasks[halo];
            }
        }
        out[cy*(w/2)+cx]=word;
        for(int j=0;j<2;++j)for(int i=0;i<2;++i) assert(sample(word,(i-.5)*.5,(j-.5)*.5)==m[j*2+i]);
    }
    return out;
}
static void selfcheck(bool allowThree=false) {
    for(int pattern=0;pattern<4096;++pattern) {
        std::vector<uint8_t> p(4); for(int i=0;i<4;++i)p[i]=(pattern>>(3*i))&7;
        Stats st;auto out=encode(p,2,2,st,allowThree);
        for(int j=0;j<2;++j)for(int i=0;i<2;++i) assert(sample(out[0],(i-.5)*.5,(j-.5)*.5)==p[j*2+i]);
    }
    for(int fixture=0;fixture<9;++fixture) {
        int n=24;std::vector<uint8_t> p(n*n);
        for(int y=0;y<n;++y)for(int x=0;x<n;++x) {
            bool inside=false;
            if(fixture==0) inside=x>=11;
            if(fixture==1) inside=y>=11;
            if(fixture==2) inside=x>=11 && y>=11; // hard L corner
            if(fixture==3) inside=x>=7&&x<=16&&y>=7&&y<=16 && !(x>=9&&x<=14&&y>=9&&y<=14); // courtyard
            if(fixture==4) inside=x==11 || y==11; // narrow crossing
            if(fixture==5) inside=(x+y)&1;
            if(fixture==6) inside=x>=11;
            if(fixture==7) inside=x+y>=23;
            if(fixture==8) inside=x>=11;
            p[y*n+x]=inside?1:0;
            if(fixture==6 && y>=12)p[y*n+x]=4; // triple junction and road/building
            if(fixture==8)p[y*n+x]=inside?3:4; // water/building contact
        }
        Stats st;auto words=encode(p,n,n,st,allowThree);
        if(fixture<2) assert(st.plane>0);
        if(fixture==2) assert(words[5*12+5]&0x8000);
        if(fixture==5) assert(st.fallback==n*n/4 && st.plane==0);
        if(fixture==4) assert(st.plane==0);
        if(fixture==3) { assert(words[3*12+3]&0x8000);assert(words[4*12+4]&0x8000); }
        if(fixture==6) assert(words[5*12+5]&0x8000);
        if(fixture==7 && allowThree) assert(st.plane>0);
        if(fixture==8) assert(st.plane==0);
    }
    for(int orientation=0;orientation<4;++orientation) {
        std::vector<uint8_t> p(24*24);
        for(int y=0;y<24;++y)for(int x=0;x<24;++x)
            p[y*24+x]=((orientation&1)?x<=10:x>=11)&&((orientation&2)?y<=10:y>=11);
        Stats st;auto words=encode(p,24,24,st,allowThree);
        assert(words[5*12+5]&0x8000); // True orthogonal L, both arms present in the 4x4 halo.
    }
}
static void bandSelfcheck() {
    const int n=24;
    for(int park=0;park<2;++park)for(int shape=0;shape<7;++shape)for(int orientation=0;orientation<(shape==2?4:1);++orientation) {
        std::vector<uint8_t> mask(n*n),p(n*n);
        for(int y=0;y<n;++y)for(int x=0;x<n;++x) {
            if(shape==0 || shape==5 || shape==6)mask[y*n+x]=x>=11;
            if(shape==1)mask[y*n+x]=x+y>=23;
            if(shape==2)mask[y*n+x]=((orientation&1)?x<=10:x>=11)&&((orientation&2)?y<=10:y>=11);
            if(shape==3)mask[y*n+x]=x>=5&&x<=18&&y>=5&&y<=18 && !(x>=9&&x<=14&&y>=9&&y<=14);
            if(shape==4)mask[y*n+x]=((x>=2&&x<=7)||(x>=16&&x<=21))&&y>=7&&y<=16 || (y==11&&x>=7&&x<=16);
        }
        int ground=shape==5?1:shape==6?3:park?2:0,fill=park?6:4;
        for(int y=0;y<n;++y)for(int x=0;x<n;++x) {
            bool outline=mask[y*n+x] && (x==0||y==0||x==n-1||y==n-1||!mask[y*n+x-1]||!mask[y*n+x+1]||!mask[(y-1)*n+x]||!mask[(y+1)*n+x]);
            p[y*n+x]=!mask[y*n+x]?ground:outline?fill+1:fill;
        }
        Stats st;auto words=encode(p,n,n,st,true,true);
        if(shape<2)assert(st.band>0);
        if(shape==2)assert(words[5*12+5]&0x8000);
        if(shape==3){assert(words[2*12+2]&0x8000);assert(words[4*12+4]&0x8000);}
        if(shape==4)assert(words[5*12+5]&0x8000);
        if(shape>=5)assert(st.band==0 && st.outerAccepted==0);
    }
}
int main(int argc,char** argv) {
    if(argc==5){residualLimit=std::strtod(argv[4],nullptr);assert(residualLimit==.14 || residualLimit==.20 || residualLimit==.25);}
    selfcheck();selfcheck(true);bandSelfcheck();
    binaryResidualReject=binaryCenterReject=bandResidualReject=bandCenterReject=0;
    if(argc==1){std::cout<<"selfchecks passed\n";return 0;}
    assert(argc==3 || argc==4 || argc==5);
    std::ifstream f(argv[1],std::ios::binary);std::vector<uint8_t> p((std::istreambuf_iterator<char>(f)),{});
    Stats st;auto start=std::chrono::steady_clock::now();
    auto words=encode(p,1200,1200,st,argc>=4,argc>=4 && argv[3][0]=='C');
    double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    std::set<uint16_t> binaryPatterns;std::set<uint32_t> bandPatterns;
    for(int y=2;y<1198;y+=2)for(int x=2;x<1198;x+=2) {
        if(p[y*1200+x]==p[y*1200+x+1] && p[y*1200+x]==p[(y+1)*1200+x] && p[y*1200+x]==p[(y+1)*1200+x+1])continue;
        int mask=0;for(int j=-1;j<=2;++j)for(int i=-1;i<=2;++i)mask|=1<<p[(y+j)*1200+x+i];
        if(__builtin_popcount(unsigned(mask))==2) {
            int b=31-__builtin_clz(unsigned(mask));uint16_t pattern=0;
            for(int j=-1;j<=2;++j)for(int i=-1;i<=2;++i)if(p[(y+j)*1200+x+i]==b)pattern|=1<<((j+1)*4+i+1);
            binaryPatterns.insert(pattern);
        }
        if(mask==0x31 || mask==0xc4) {
            int ground=mask==0x31?0:2,fill=ground==0?4:6;uint32_t pattern=0;
            for(int j=-1;j<=2;++j)for(int i=-1;i<=2;++i) {
                int v=p[(y+j)*1200+x+i],bit=(j+1)*4+i+1;
                if(v!=ground)pattern|=1u<<bit;
                if(v==fill)pattern|=1u<<(bit+16);
            }
            bandPatterns.insert(pattern);
        }
    }
    std::ofstream o(argv[2],std::ios::binary);for(auto w:words){o.put(w&255);o.put(w>>8);}
    std::cout<<"{\"residualLimit\":"<<residualLimit<<",\"binaryResidualReject\":"<<binaryResidualReject<<",\"binaryCenterReject\":"<<binaryCenterReject<<",\"bandResidualReject\":"<<bandResidualReject<<",\"bandCenterReject\":"<<bandCenterReject<<",\"pure\":"<<st.pure<<",\"plane\":"<<st.plane<<",\"fallback\":"<<st.fallback<<",\"rejected\":[";
    for(int i=0;i<6;++i)std::cout<<(i?",":"")<<st.rejected[i];
    std::cout<<"],\"hostGeometryMs\":"<<ms<<",\"uniqueBinaryPatterns\":"<<binaryPatterns.size()<<",\"uniqueBandPatterns\":"<<bandPatterns.size()<<",\"bandFitMs\":"<<st.bandMs<<",\"bandFitCalls\":"<<st.bandCalls<<",\"band\":"<<st.band<<",\"outerMixed\":"<<st.outerMixed<<",\"outerAccepted\":"<<st.outerAccepted<<",\"fallbackHaloMaterialSets\":{";
    bool first=true;for(int i=0;i<256;++i)if(st.fallbackMasks[i]){std::cout<<(first?"":",")<<"\""<<i<<"\":"<<st.fallbackMasks[i];first=false;}
    std::cout<<"},\"nearest2mMismatches\":0,\"checkedCenters\":"<<p.size()<<"}\n";
}
