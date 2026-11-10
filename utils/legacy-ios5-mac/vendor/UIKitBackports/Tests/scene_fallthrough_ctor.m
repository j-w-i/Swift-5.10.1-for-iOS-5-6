#import <Foundation/Foundation.h>
#import <objc/runtime.h>
void UICInstallSceneLifecycle(void); void UICInstallTraitCollection(void);
__attribute__((constructor)) static void go(void){
  Class sceneBefore = objc_getClass("UIScene"), traitBefore = objc_getClass("UITraitCollection");
  UICInstallTraitCollection(); UICInstallSceneLifecycle();
  fprintf(stderr,"PROBE BACKPORT-LINKED scene same=%d trait same=%d sceneImage=%s traitImage=%s\n", sceneBefore==objc_getClass("UIScene"), traitBefore==objc_getClass("UITraitCollection"), class_getImageName(objc_getClass("UIScene")), class_getImageName(objc_getClass("UITraitCollection")));
}
