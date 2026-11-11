#import "swift-types.h"
#import <UIKit/UILabel.h>
#import <UIKit/UIColor.h>
// Test-only declarations of existing selectors; no category implementations or runtime changes.
@interface RouteTypedReusable (InstanceChecks)
- (void)prepareForReuse;
@end
@interface RouteTypedCell (InstanceChecks)
@property(nonatomic,readonly) UIView *contentView;
@end
