#import <UIKit/UIKit.h>
#import "IBPNSCollectionLayoutEnvironment_Protocol.h"
#import "UIViewController+DDTraitCollection.h"
#import "UIView+DDTraitCollection.h"
#import "DDTraitCollection.h"

NS_ASSUME_NONNULL_BEGIN

@interface IBPNSCollectionLayoutEnvironment : NSObject<IBPNSCollectionLayoutEnvironment>

@property(nonatomic, readwrite) id<IBPNSCollectionLayoutContainer> container;
@property(nonatomic, readwrite) DDTraitCollection *traitCollection;

@end

NS_ASSUME_NONNULL_END
