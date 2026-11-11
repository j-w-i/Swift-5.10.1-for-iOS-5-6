#import <UIKit/UIKit.h>
#include <stdio.h>
#include <stdlib.h>
double nativeBench(int); double pstBench(int); void nativeSet(int); void pstSet(int);
static int cmp(const void*a,const void*b){ double x=*(double*)a,y=*(double*)b; return x<y?-1:x>y; }
static void report(const char*name,int sc){ 
  int reps=15; double ratios[15],ns[15],ps[15]; nativeBench(sc); pstBench(sc);
  for(int i=0;i<reps;i++){ double n,p; if(i%2){ p=pstBench(sc); n=nativeBench(sc);} else { n=nativeBench(sc); p=pstBench(sc);} ratios[i]=p/n; ns[i]=n; ps[i]=p; }
  qsort(ratios,reps,sizeof(double),cmp); qsort(ns,reps,sizeof(double),cmp); qsort(ps,reps,sizeof(double),cmp);
  printf("%-22s native=%.0fus pst=%.0fus  PST/native median=%.3f (min %.3f max %.3f)\n",name,ns[reps/2]/1000,ps[reps/2]/1000,ratios[reps/2],ratios[0],ratios[reps-1]); }
int main(int argc,char**argv){@autoreleasepool{[UIApplication sharedApplication];
  for(int n=0;n<=6;n+= (n<1?1:(n<3?2:3))){ nativeSet(n); pstSet(n); char t[64]; snprintf(t,64,"labels=%d item-size",n); report(t,1); snprintf(t,64,"labels=%d scroll",n); report(t,0); } }return 0;}
