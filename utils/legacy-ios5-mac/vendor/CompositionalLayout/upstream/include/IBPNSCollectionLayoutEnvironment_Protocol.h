#import <UIKit/UIKit.h>
#import "../UIViewController+DDTraitCollection.h"
#import "../UIView+DDTraitCollection.h"
#import "../DDTraitCollection.h"

NS_ASSUME_NONNULL_BEGIN

@protocol IBPNSCollectionLayoutContainer;

@protocol IBPNSCollectionLayoutEnvironment<NSObject>

@property(nonatomic, readonly) id<IBPNSCollectionLayoutContainer> container;
@property(nonatomic, readonly) DDTraitCollection *traitCollection;

@end

NS_ASSUME_NONNULL_END
