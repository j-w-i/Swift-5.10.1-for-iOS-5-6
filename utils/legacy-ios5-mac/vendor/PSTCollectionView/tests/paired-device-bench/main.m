#import <UIKit/UIKit.h>
#include <stdio.h>
#include <stdlib.h>
double nativeBench(int,NSInteger);double pstBench(int,NSInteger);
#ifdef INSTALL_BACKPORT_HOOKS
extern void UICInstallCollectionViewDisplay(void);
#endif
static int cmp(const void*a,const void*b){double x=*(double*)a,y=*(double*)b;return x<y?-1:x>y;}
static void run(void){@autoreleasepool{
 FILE*f=fopen(OUTFILE,"w");int saved=dup(1);fflush(stdout);dup2(fileno(f),1);setvbuf(stdout,NULL,_IONBF,0);
 const char*names[6]={"cold layout","reload","batch ins5+del5","selfsize+dlg cold","selfsize+dlg reload","selfsize+dlg batch"};NSInteger sizes[3]={200,1000,5000};
 for(int si=0;si<3;si++)for(int s=0;s<6;s++){
  if(si==2&&s!=3&&s!=4)continue; // 5,000 only for the self-sizing cold/reload rows
  int reps=si==2?5:9;double n[9],p[9];nativeBench(s,sizes[si]);pstBench(s,sizes[si]);
  for(int i=0;i<reps;i++){if(i%2){p[i]=pstBench(s,sizes[si]);n[i]=nativeBench(s,sizes[si]);}else{n[i]=nativeBench(s,sizes[si]);p[i]=pstBench(s,sizes[si]);}}
  qsort(n,reps,sizeof(double),cmp);qsort(p,reps,sizeof(double),cmp);
  printf("%-16s items=%-5ld native=%9.0fus pst=%9.0fus pst/native=%.2f\n",names[s],(long)sizes[si],n[reps/2]/1000,p[reps/2]/1000,p[reps/2]/n[reps/2]);
 }
 printf("DONE\n");fflush(stdout);dup2(saved,1);fclose(f);}}
@interface AD:UIResponder<UIApplicationDelegate> @property(nonatomic,strong) UIWindow*window; @end
@implementation AD
- (BOOL)application:(UIApplication*)a didFinishLaunchingWithOptions:(NSDictionary*)o{
#ifdef INSTALL_BACKPORT_HOOKS
 UICInstallCollectionViewDisplay();
#endif
 self.window=[[UIWindow alloc]initWithFrame:[UIScreen mainScreen].bounds];UIViewController*vc=[UIViewController new];vc.view.backgroundColor=[UIColor whiteColor];
 UILabel*l=[[UILabel alloc]initWithFrame:CGRectMake(10,30,300,60)];l.text=@"Paired bench running";[vc.view addSubview:l];self.window.rootViewController=vc;[self.window makeKeyAndVisible];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{run();l.text=@"Done. Home works normally.";});return YES;}
@end
int main(int c,char**v){@autoreleasepool{return UIApplicationMain(c,v,nil,@"AD");}}
