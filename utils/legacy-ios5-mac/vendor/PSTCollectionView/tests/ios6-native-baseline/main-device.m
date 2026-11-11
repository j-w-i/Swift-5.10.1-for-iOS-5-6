#import <UIKit/UIKit.h>
#include <stdio.h>
double nativeBench(int,BOOL,double*,NSInteger*); double pstBench(int,BOOL,double*,NSInteger*);
static int cmp(const void*a,const void*b){ double x=*(double*)a,y=*(double*)b; return x<y?-1:x>y; }
static void runBench(void){@autoreleasepool{
  freopen("/var/mobile/Documents/ios6bench-out.txt","w",stdout);
  const char*names[4]={"layoutIfNeeded only","+ CATransaction flush","+ run loop turn","+ flush + turn"};
  for(int win=0;win<2;win++){
    printf("=== %s\n", win?"WITH a window (rendering involved)":"no window");
    for(int m=0;m<4;m++){
      int reps=9; double n[9],p[9],rn[9],rp[9]; double nv,pv; NSInteger nc,pc;
      nativeBench(m,win,&nv,&nc); pstBench(m,win,&pv,&pc);
      for(int i=0;i<reps;i++){ if(i%2){ p[i]=pstBench(m,win,&pv,&pc); n[i]=nativeBench(m,win,&nv,&nc);} else { n[i]=nativeBench(m,win,&nv,&nc); p[i]=pstBench(m,win,&pv,&pc);} rn[i]=n[i]; rp[i]=p[i]; }
      qsort(n,reps,sizeof(double),cmp); qsort(p,reps,sizeof(double),cmp);
      printf("%-24s native=%7.0fus pst=%7.0fus  pst/native=%.2f   (visible cells native=%d pst=%d, cellForItem native=%ld pst=%ld)\n",
        names[m], n[reps/2]/1000, p[reps/2]/1000, p[reps/2]/n[reps/2], (int)nv,(int)pv,(long)nc,(long)pc);
    }
  }
} }

@interface AD : UIResponder <UIApplicationDelegate> @end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ runBench(); exit(0); });
  return YES; }
@end
int main(int argc,char**argv){ @autoreleasepool { return UIApplicationMain(argc,argv,nil,@"AD"); } }
