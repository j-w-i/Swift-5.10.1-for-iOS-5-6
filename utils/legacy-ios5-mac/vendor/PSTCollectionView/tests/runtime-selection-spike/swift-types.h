#import <UIKit/UIScrollView.h>
#import <UIKit/UIViewController.h>
// Test-only imported names with native runtime names. No production importer changes.
__attribute__((objc_runtime_name("UICollectionReusableView")))
@interface RouteTypedReusable : UIView @end
__attribute__((objc_runtime_name("UICollectionViewCell")))
@interface RouteTypedCell : RouteTypedReusable @end
__attribute__((objc_runtime_name("UICollectionViewLayout")))
@interface RouteTypedLayout : NSObject @end
__attribute__((objc_runtime_name("UICollectionViewFlowLayout")))
@interface RouteTypedFlow : RouteTypedLayout @end
