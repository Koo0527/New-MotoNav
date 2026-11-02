#pragma once
#include <cmath>
#include <cstdint>
namespace GInstrument {
constexpr float gravity = 9.80665f;
enum class Motion : uint8_t { Stopped=0, Moving=1, Unknown=2 };
struct Vec { float x=0,y=0,z=0; };
inline Vec add(Vec a,Vec b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
inline Vec mul(Vec a,float k){return {a.x*k,a.y*k,a.z*k};}
inline float dot(Vec a,Vec b){return a.x*b.x+a.y*b.y+a.z*b.z;}
inline Vec cross(Vec a,Vec b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
inline float norm(Vec a){return sqrtf(dot(a,a));}
inline Vec unit(Vec a){float n=norm(a);return n>0.0001f?mul(a,1/n):Vec{};}
inline Vec horizontal(Vec a,Vec up){return add(a,mul(up,-dot(a,up)));}
struct Mount { Vec forward{},bias{}; int ref=1,angle=0; bool valid=false; };
// Values are in sensor coordinates, independent of display rotation.
inline bool makeMount(Vec up,Vec bias,int ref,int angle,Mount &out){
  if(ref<0||ref>2||angle<0||angle>359)return false;
  // 1.75C measured axes: USB points -X, screen face +Z; USB-rear right is -Y.
  Vec axis=ref==0?Vec{0,0,-1}:ref==1?Vec{1,0,0}:Vec{0,-1,0};
  Vec f=horizontal(axis,up);
  // USB can point down on a vertical dash; screen-back preserves the forward limit there.
  if(norm(f)<0.15f&&ref==1)f=horizontal({0,0,up.x<0?1.0f:-1.0f},up);
  if(norm(f)<0.15f)return false;
  f=unit(f);float a=angle*0.01745329252f;
  out={add(mul(f,cosf(a)),mul(cross(f,up),sinf(a))),bias,ref,angle,true};return true;
}
struct Estimator {
  Mount mount{};Vec runtimeBias{},up{},meanA{},meanW{},firstA{},firstW{};int stable=0;float gyroM2=0;
  float quietSeconds=0;
  bool initialized=false,available=false;float lateral=0,longitudinal=0;
  void resetQuiet(){stable=0;meanA={};meanW={};gyroM2=0;quietSeconds=0;}
  void reset(){initialized=false;available=false;resetQuiet();}
  // Require three seconds of quiet samples before startup or explicit calibration.
  bool stationary(Vec a,Vec w){
    // Factory gyro zero can be several dps; quiet means stable, not numerically zero.
    bool quiet=fabsf(norm(a)-1)<0.035f&&norm(w)<15.0f;
    if(stable&&(norm(add(a,mul(firstA,-1)))>0.025f||norm(add(w,mul(firstW,-1)))>0.8f))quiet=false;
    if(!quiet){resetQuiet();return false;}
    if(!stable){firstA=a;firstW=w;}
    ++stable;meanA=add(meanA,mul(add(a,mul(meanA,-1)),1.0f/stable));
    Vec delta=add(w,mul(meanW,-1));meanW=add(meanW,mul(delta,1.0f/stable));
    gyroM2+=dot(delta,add(w,mul(meanW,-1)));
    if(stable>=12&&gyroM2/(stable-1)>0.35f*0.35f){resetQuiet();return false;}
    return stable>=168;
  }
  void sample(Vec a,Vec w,float dt=1.0f/56,Motion motion=Motion::Unknown){
    available=false;
    if(!std::isfinite(norm(a))||!std::isfinite(norm(w))||!std::isfinite(dt)||dt<=0||dt>0.1f||fabsf(a.x)>=3.99f||fabsf(a.y)>=3.99f||fabsf(a.z)>=3.99f||fabsf(w.x)>=511||fabsf(w.y)>=511||fabsf(w.z)>=511){reset();return;}
    if(!initialized){
      if(motion!=Motion::Stopped){resetQuiet();return;}
      bool quiet=stationary(a,w);if(stable>0)quietSeconds+=dt;
      if(!quiet||quietSeconds<3-0.0001f)return;
      up=unit(meanA);runtimeBias=meanW;initialized=true;resetQuiet();
    }
    Vec omega=mul(add(w,mul(runtimeBias,-1)),0.01745329252f);
    up=unit(add(up,mul(cross(omega,up),-dt)));
    // Only an independent stop observation may turn acceleration into a gravity reference.
    if(motion==Motion::Stopped&&norm(omega)<0.03f) {
      bool quiet=stationary(a,w);
      if(stable>0)quietSeconds+=dt;
      if(quiet&&quietSeconds>=3) {
        runtimeBias=meanW;up=unit(meanA);Mount adjusted;
        if(mount.valid&&makeMount(up,meanW,mount.ref,mount.angle,adjusted))mount=adjusted;
        resetQuiet();
      }
    }else resetQuiet();
    if(!mount.valid)return;
    Vec f=horizontal(mount.forward,up);if(norm(f)<0.15f)return;
    f=unit(f);Vec right=unit(cross(f,up));
    Vec linear=add(a,mul(up,-1));
    lateral=dot(linear,right);longitudinal=dot(linear,f);available=true;
  }
};
}
