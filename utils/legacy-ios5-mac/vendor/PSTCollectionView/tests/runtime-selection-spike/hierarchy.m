#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdio.h>
#include <string.h>
// App-defined subclasses must inherit from the same class object runtime lookup sees.
@interface RouteAppCell : UICollectionViewCell @end
@implementation RouteAppCell @end
@interface RouteAppFlow : UICollectionViewFlowLayout @end
@implementation RouteAppFlow @end
@interface RouteAppController : UICollectionViewController @end
@implementation RouteAppController @end
static int failures;
static void check(BOOL ok,const char *name){printf("%s %s\n",ok?"PASS":"FAIL",name);if(!ok)failures++;}
int main(int argc,char **argv){@autoreleasepool{
 setvbuf(stdout,NULL,_IONBF,0);
 if(argc!=2 || (strcmp(argv[1],"native") && strcmp(argv[1],"fallback"))){puts("usage: hierarchy native|fallback");return 64;}
 BOOL fallback=!strcmp(argv[1],"fallback");
 Class classes[]={ [UICollectionView class],[UICollectionReusableView class],[UICollectionViewCell class],
  [UICollectionViewLayout class],[UICollectionViewFlowLayout class],[UICollectionViewLayoutAttributes class],
  [UICollectionViewController class] };
 const char *names[]={"UICollectionView","UICollectionReusableView","UICollectionViewCell","UICollectionViewLayout",
  "UICollectionViewFlowLayout","UICollectionViewLayoutAttributes","UICollectionViewController"};
 for(unsigned i=0;i<sizeof(classes)/sizeof(classes[0]);i++){
  Class runtime=objc_getClass(names[i]);
  BOOL marker=class_getInstanceMethod(classes[i],sel_registerName("routeFallbackMarker"))!=NULL;
  Dl_info info={0};dladdr((__bridge const void *)classes[i],&info);
  printf("%s image=%s fallback=%d\n",names[i],info.dli_fname?:"unknown",marker);
  check(classes[i]==runtime,"compiled/runtime identity agrees");
  check(marker==fallback,"selected requested engine");
 }
 check(class_getSuperclass([UICollectionViewCell class])==[UICollectionReusableView class],"cell inherits reusable view");
 check(class_getSuperclass([UICollectionViewFlowLayout class])==[UICollectionViewLayout class],"flow inherits layout");
 check(class_getSuperclass([RouteAppCell class])==objc_getClass("UICollectionViewCell"),"app cell superclass is canonical");
 check(class_getSuperclass([RouteAppFlow class])==objc_getClass("UICollectionViewFlowLayout"),"app flow superclass is canonical");
 check(class_getSuperclass([RouteAppController class])==objc_getClass("UICollectionViewController"),"app controller superclass is canonical");
 check([RouteAppCell isSubclassOfClass:objc_getClass("UICollectionReusableView")],"app cell passes reusable-view class check");
 check([RouteAppFlow isSubclassOfClass:objc_getClass("UICollectionViewLayout")],"app flow passes layout class check");
 printf("RESULT %s failures=%d\n",failures?"FAIL":"PASS",failures);return failures?2:0;
}}
