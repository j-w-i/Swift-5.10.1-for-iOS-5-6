// Native iOS 27 oracle: delegate size seeds layout, but preferred attributes win
// when estimatedItemSize is enabled.
#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewLayout PSTCollectionViewLayout
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegateFlowLayout PSTCollectionViewDelegateFlowLayout
#endif
static NSUInteger fittingCalls, delegateCalls;
static CGSize firstProposal;
@interface PrecedenceCell : UICollectionViewCell @end
@implementation PrecedenceCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)a {
    if (!fittingCalls) firstProposal=a.size;
    fittingCalls++;
    UICollectionViewLayoutAttributes *result=[a copy]; result.size=CGSizeMake(80,99); return result;
}
@end
@interface PrecedenceData : NSObject<UICollectionViewDataSource,UICollectionViewDelegateFlowLayout> @end
@implementation PrecedenceData
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section { return 1; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)path {
    return [cv dequeueReusableCellWithReuseIdentifier:@"p" forIndexPath:path];
}
- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)path {
    delegateCalls++; return CGSizeMake(80,31);
}
@end
int main(void) { @autoreleasepool {
    [UIApplication sharedApplication];
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];
    layout.estimatedItemSize=CGSizeMake(80,40);
    UICollectionView *cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,200) collectionViewLayout:layout];
    PrecedenceData *data=[PrecedenceData new]; cv.dataSource=data; cv.delegate=data;
    [cv registerClass:[PrecedenceCell class] forCellWithReuseIdentifier:@"p"];
    [cv layoutIfNeeded];
    CGSize size=[layout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]].size;
    printf("delegateCalls=%lu fittingCalls=%lu final=%gx%g\n",(unsigned long)delegateCalls,(unsigned long)fittingCalls,size.width,size.height);
    if (!CGSizeEqualToSize(firstProposal,CGSizeMake(80,31))) {
        fprintf(stderr,"FAIL: first preferred-size proposal must be delegate size, not estimate\n"); return 1;
    }
    if (!delegateCalls || !fittingCalls || !CGSizeEqualToSize(size,CGSizeMake(80,99))) {
        fprintf(stderr,"FAIL: preferred size must override delegate seed when estimatedItemSize is enabled\n"); return 1;
    }
    puts("PASS: preferred attributes override sizing delegate seed");
    // A fresh zero-estimate layout isolates delegate-only sizing from native
    // cached self-sizing state when toggling estimates on an existing layout.
    layout=[UICollectionViewFlowLayout new];
    cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,200) collectionViewLayout:layout];
    cv.dataSource=data; cv.delegate=data;
    [cv registerClass:[PrecedenceCell class] forCellWithReuseIdentifier:@"p"];
    fittingCalls=0; delegateCalls=0;
    [cv layoutIfNeeded];
    size=[layout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]].size;
    printf("zero-estimate delegateCalls=%lu fittingCalls=%lu final=%gx%g\n",(unsigned long)delegateCalls,(unsigned long)fittingCalls,size.width,size.height);
    if (!delegateCalls || !CGSizeEqualToSize(size,CGSizeMake(80,31))) {
        fprintf(stderr,"FAIL: disabling estimates must restore delegate-only sizing\n"); return 1;
    }
    puts("PASS: disabling estimates restores delegate-only sizing");
} return 0; }
