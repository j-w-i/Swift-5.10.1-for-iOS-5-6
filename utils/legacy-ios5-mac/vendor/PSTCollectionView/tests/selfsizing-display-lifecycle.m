#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegate PSTCollectionViewDelegate
#endif
// This probes ordering on each actual cell instance, not ordering between different cells.
// No assertion about Foundation dictionary enumeration order is necessary.
static NSMutableArray *events;
static NSUInteger displays, unfittedDisplays;
static BOOL changed;
@interface LifecycleCell : UICollectionViewCell
@property BOOL fitted;
@end
@implementation LifecycleCell
- (void)prepareForReuse { [super prepareForReuse]; self.fitted=NO; }
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)a {
    self.fitted=YES;
    [events addObject:@[@"fit",@(a.indexPath.item)]];
    UICollectionViewLayoutAttributes *result=[a copy];
    if(changed) result.size=CGSizeMake(200,60);
    return result;
}
@end
@interface LifecycleSource : NSObject<UICollectionViewDataSource,UICollectionViewDelegate> @end
@implementation LifecycleSource
- (NSInteger)collectionView:(UICollectionView *)v numberOfItemsInSection:(NSInteger)s { return 30; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)v cellForItemAtIndexPath:(NSIndexPath *)p {
    LifecycleCell *cell=(id)[v dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:p];
    [events addObject:@[@"request",@(p.item)]];
    return cell;
}
- (void)collectionView:(UICollectionView *)v willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)p {
    BOOL fitted=((LifecycleCell *)cell).fitted;
    displays++; if(!fitted) unfittedDisplays++;
    [events addObject:@[@"will",@(p.item),@(fitted)]];
}
@end
int main(void) { @autoreleasepool {
    [UIApplication sharedApplication];
    NSMutableArray *results=[NSMutableArray array];
    for(int scenario=0;scenario<2;scenario++) {
        changed=scenario; events=[NSMutableArray array]; displays=unfittedDisplays=0;
        UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];
        layout.estimatedItemSize=CGSizeMake(200,40); layout.minimumLineSpacing=0;
        UICollectionView *view=[[UICollectionView alloc] initWithFrame:CGRectMake(0,0,200,120) collectionViewLayout:layout];
        [view registerClass:[LifecycleCell class] forCellWithReuseIdentifier:@"cell"];
        LifecycleSource *source=[LifecycleSource new]; view.dataSource=source; view.delegate=source;
        [view layoutIfNeeded];
        [events addObject:@[@"scroll"]]; view.contentOffset=CGPointMake(0,400); [view layoutIfNeeded];
        [events addObject:@[@"reload"]]; [view reloadData]; [view layoutIfNeeded];
        [results addObject:@{@"changed":@(changed),@"displays":@(displays),@"unfittedDisplays":@(unfittedDisplays),@"events":[events copy]}];
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:results options:0 error:NULL];
    fwrite(json.bytes,1,json.length,stdout); putchar('\n');
} return 0; }
