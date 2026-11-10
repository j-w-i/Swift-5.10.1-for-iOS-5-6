// Native iOS 27 oracle: delegate size seeds layout, but preferred attributes win
// when estimatedItemSize is enabled. PST currently fails this regression.
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
@interface PrecedenceCell : UICollectionViewCell @end
@implementation PrecedenceCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)a {
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
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];
    layout.estimatedItemSize=CGSizeMake(80,40);
    UICollectionView *cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,200) collectionViewLayout:layout];
    PrecedenceData *data=[PrecedenceData new]; cv.dataSource=data; cv.delegate=data;
    [cv registerClass:[PrecedenceCell class] forCellWithReuseIdentifier:@"p"];
    [cv layoutIfNeeded];
    CGSize size=[layout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]].size;
    printf("delegateCalls=%lu fittingCalls=%lu final=%gx%g\n",(unsigned long)delegateCalls,(unsigned long)fittingCalls,size.width,size.height);
    if (!delegateCalls || !fittingCalls || !CGSizeEqualToSize(size,CGSizeMake(80,99))) {
        fprintf(stderr,"FAIL: preferred size must override delegate seed when estimatedItemSize is enabled\n"); return 1;
    }
    puts("PASS: preferred attributes override sizing delegate seed");
} return 0; }
