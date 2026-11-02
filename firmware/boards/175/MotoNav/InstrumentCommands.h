#pragma once
#include <cstring>
namespace InstrumentCommands {
// Bound each decimal while reading it, before converting or multiplying.
inline bool pair(const char *s,const char *prefix,int &a,int &b){
  const size_t n=std::strlen(prefix);if(std::strncmp(s,prefix,n))return false;
  const char *c=s+n;int values[2]={};
  for(int i=0;i<2;i++){
    if(*c<'0'||*c>'9')return false;
    int digits=0;
    while(*c>='0'&&*c<='9'){
      if(++digits>4)return false;
      values[i]=values[i]*10+(*c++-'0');if(values[i]>1000)return false;
    }
    if(i==0){if(*c++!=',')return false;}else if(*c)return false;
  }
  a=values[0];b=values[1];return true;
}
}
