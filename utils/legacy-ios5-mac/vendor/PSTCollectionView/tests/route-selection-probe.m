#import <UIKit/UIKit.h>
#import "PSTCollectionView.h"
static void dump(void) {
    freopen("/var/mobile/Documents/route-out.txt", "w", stdout);
    Class apple = NSClassFromString(@"UICollectionView");
    printf("Apple UICollectionView class present: %d\n", apple != Nil);
    printf("PSTCollectionView class: %s, its superclass: %s\n", class_getName([PSTCollectionView class]), class_getName(class_getSuperclass([PSTCollectionView class])));
    printf("PSTCollectionView is a subclass of UICollectionView: %d\n", apple ? (int)class_getSuperclass(object_getClass([PSTCollectionView class])) == apple || (int)[PSTCollectionView isSubclassOfClass:apple] : -1);
    PSTCollectionView *cv = [[PSTCollectionView alloc] initWithFrame:CGRectMake(0,0,320,480) collectionViewLayout:[PSTCollectionViewFlowLayout new]];
    printf("an instance is a %s; isKindOfClass:UICollectionView = %d\n", object_getClassName(cv), apple ? (int)[cv isKindOfClass:apple] : -1);
    UICollectionView *native = apple ? [[apple alloc] initWithFrame:CGRectMake(0,0,320,480) collectionViewLayout:[[NSClassFromString(@"UICollectionViewFlowLayout") alloc] init]] : nil;
    printf("Apple's own instance: %s\n", native ? object_getClassName(native) : "(none)");
    fflush(stdout); exit(0);
}
@interface AD : UIResponder <UIApplicationDelegate> @end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o { dump(); return YES; }
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AD"); } }
