#import <UIKit/UIKit.h>
#import "UIViewController+DDTraitCollection.h"
#import "UIView+DDTraitCollection.h"
#import "DDTraitCollection.h"

@class IBPNSCollectionLayoutContainer;
@class IBPNSCollectionLayoutItem;
@class IBPNSCollectionLayoutSection;
@class IBPUICollectionViewCompositionalLayoutConfiguration;

NS_ASSUME_NONNULL_BEGIN

@interface IBPCollectionCompositionalLayoutSolver : NSObject

@property (nonatomic, readonly, copy) IBPNSCollectionLayoutSection *layoutSection;
@property (nonatomic, readonly) CGRect layoutFrame;

+ (instancetype)solverWithLayoutSection:(IBPNSCollectionLayoutSection *)section
                        scrollDirection:(UICollectionViewScrollDirection)scrollDirection;

- (void)solveForContainer:(IBPNSCollectionLayoutContainer *)container
          traitCollection:(DDTraitCollection *)traitCollection;

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath;
- (IBPNSCollectionLayoutItem *)layoutItemAtIndexPath:(NSIndexPath *)indexPath;

@end

NS_ASSUME_NONNULL_END
