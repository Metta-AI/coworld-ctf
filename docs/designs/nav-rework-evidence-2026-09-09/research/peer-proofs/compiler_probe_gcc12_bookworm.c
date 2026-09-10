#include <math.h>
#include <stdint.h>
double f_floor(double x){ return floor(x); }
long f_floor_int(double x){ return (long)floor(x); }
double f_round(double x){ return round(x); }
double f_hypot(double a,double b){ return hypot(a,b); }
double f_sqrt(double x){ return sqrt(x); }
/* shape of packedDangerQ8 applied over a raster */
void pack(const float *v, uint16_t *w, long n){
  for(long i=0;i<n;i++){
    float value=v[i];
    if(value<=0){ w[i]=0; continue; }
    double scaled=(double)value*256.0;
    long lower=(long)floor(scaled);
    double fraction=scaled-(double)lower;
    long rounded=(fraction>0.5||(fraction==0.5&&(lower&1)!=0))?lower+1:lower;
    w[i]=(uint16_t)rounded;
  }
}
