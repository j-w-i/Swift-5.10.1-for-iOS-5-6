#import <UIKit/UIScrollView.h>
@interface UICollectionView : UIScrollView
- (NSString *)spikeEngine;
@end
@implementation UICollectionView
- (NSString *)spikeEngine { return @"injected-engine"; }
@end
