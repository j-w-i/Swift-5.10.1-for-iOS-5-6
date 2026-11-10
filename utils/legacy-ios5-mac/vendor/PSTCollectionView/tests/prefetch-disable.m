#import <UIKit/UIKit.h>
#import "PSTCollectionView.h"
@interface CancelProbe : NSObject<PSTCollectionViewDataSourcePrefetching>
@property(nonatomic) NSUInteger calls;
@property(nonatomic,strong) NSArray *paths;
@end
@implementation CancelProbe
- (void)collectionView:(PSTCollectionView *)cv prefetchItemsAtIndexPaths:(NSArray *)paths {}
- (void)collectionView:(PSTCollectionView *)cv cancelPrefetchingForItemsAtIndexPaths:(NSArray *)paths {
    self.calls++; self.paths=paths; cv.prefetchingEnabled=NO;
}
@end
int main(void) { @autoreleasepool {
    PSTCollectionView *cv=[[PSTCollectionView alloc]initWithFrame:CGRectZero collectionViewLayout:[PSTCollectionViewFlowLayout new]];
    CancelProbe *source=[CancelProbe new]; cv.prefetchDataSource=source;
    NSArray *paths=@[[NSIndexPath indexPathForItem:8 inSection:0],[NSIndexPath indexPathForItem:9 inSection:0]];
    // Seed the announced-state set directly: this isolates setter lifecycle from
    // the app/runloop-driven scrolling prefetch heuristic.
    [cv setValue:[NSMutableSet setWithArray:paths] forKey:@"pstPrefetchedIndexPaths"];
    cv.prefetchingEnabled=NO;
    if (source.calls!=1 || ![source.paths isEqual:paths] || cv.prefetchingEnabled) return 1;
    cv.prefetchingEnabled=NO;
    if (source.calls!=1) return 1;
    puts("PASS: PST disable cancels outstanding paths once, including reentrant disable");
    cv.prefetchingEnabled=YES;
    [cv setValue:[NSMutableSet setWithArray:paths] forKey:@"pstPrefetchedIndexPaths"];
    CancelProbe *replacement=[CancelProbe new];
    cv.prefetchDataSource=replacement;
    if (source.calls!=1 || replacement.calls!=0) return 1;
    cv.prefetchingEnabled=NO;
    if (source.calls!=1 || replacement.calls!=1 || ![replacement.paths isEqual:paths]) return 1;
    puts("PASS: replacing source preserves outstanding paths and disable cancels through current source");
} return 0; }
