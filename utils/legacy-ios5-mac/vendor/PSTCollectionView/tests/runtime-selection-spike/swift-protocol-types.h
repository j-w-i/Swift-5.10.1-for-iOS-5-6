#import "swift-types.h"
// Test-only imported spellings for UIKit protocol runtime identities.
__attribute__((objc_runtime_name("UICollectionView")))
@interface RouteTypedCollection : UIScrollView @end
__attribute__((objc_runtime_name("UICollectionViewDataSource")))
@protocol RouteTypedSource <NSObject>
- (NSInteger)collectionView:(RouteTypedCollection*)cv numberOfItemsInSection:(NSInteger)section;
- (RouteTypedCell*)collectionView:(RouteTypedCollection*)cv cellForItemAtIndexPath:(NSIndexPath*)path;
@end
__attribute__((objc_runtime_name("UICollectionViewDelegate")))
@protocol RouteTypedDelegate <UIScrollViewDelegate> @end
__attribute__((objc_runtime_name("UICollectionViewDelegateFlowLayout")))
@protocol RouteTypedFlowDelegate <RouteTypedDelegate> @end
__attribute__((objc_runtime_name("UICollectionViewDataSourcePrefetching")))
@protocol RouteTypedPrefetch <NSObject>
- (void)collectionView:(RouteTypedCollection*)cv prefetchItemsAtIndexPaths:(NSArray<NSIndexPath*>*)paths;
@end
