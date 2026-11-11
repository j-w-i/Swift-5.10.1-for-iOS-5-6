// Minimal native scene app for run-scene-fallthrough-test.sh. The probe constructor in
// scene_fallthrough_ctor.m prints the classes and their images; this main only has to keep a
// process alive long enough for the runner to capture that line, without requiring a scene manifest.
#import <UIKit/UIKit.h>

@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = [UIColor whiteColor];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"ProbeDelegate"); }
}
