#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdio.h>
// No UIApplicationMain, window, allocation, event-loop connection or foreground launch.
int main(void){ @autoreleasepool {
 setvbuf(stdout,NULL,_IONBF,0);
 puts("entered main; no UI application created");
 Class direct=[UICollectionView class];
 Class lookup=objc_getClass("UICollectionView");
 Dl_info directInfo={0},lookupInfo={0}; dladdr((__bridge const void *)direct,&directInfo); dladdr((__bridge const void *)lookup,&lookupInfo);
 printf("direct image=%s marker=%d\n",directInfo.dli_fname ?: "unknown",class_getInstanceMethod(direct,sel_registerName("spikeEngine"))!=NULL);
 printf("runtime image=%s marker=%d equal=%d\n",lookupInfo.dli_fname ?: "unknown",class_getInstanceMethod(lookup,sel_registerName("spikeEngine"))!=NULL,direct==lookup);
 puts("clean normal exit; no UIKit app lifecycle");
 return direct == lookup ? 0 : 2;
}}
