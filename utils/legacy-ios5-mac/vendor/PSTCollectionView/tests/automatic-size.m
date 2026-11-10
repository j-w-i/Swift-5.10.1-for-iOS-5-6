#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
static BOOL firstProposal;
static NSInteger itemCount = 2;
static CGFloat preferredHeight = 30;
@interface AutomaticCell : UICollectionViewCell @end
@implementation AutomaticCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)a {
    if (!firstProposal) {
        firstProposal = YES;
        if (!CGSizeEqualToSize(a.size, CGSizeMake(50,50))) abort();
    }
    UICollectionViewLayoutAttributes *r=[a copy]; r.size=CGSizeMake(80,preferredHeight); return r;
}
@end
@interface AutomaticData : NSObject<UICollectionViewDataSource> @end
@implementation AutomaticData
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)s { return itemCount; }
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)p {
    return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];
}
@end
int main(int argc, char **argv) { @autoreleasepool {
 if (argc == 2 && strcmp(argv[1], "--scale") == 0) { printf("%g\n", UIScreen.mainScreen.scale); return 0; }
 for (itemCount=1;itemCount<=3;itemCount++) {
 for (int horizontal=0;horizontal<2;horizontal++) {
    firstProposal=NO;
    preferredHeight=30;
    UICollectionViewFlowLayout *fl=[UICollectionViewFlowLayout new];
    fl.scrollDirection=horizontal;
    fl.itemSize=CGSizeMake(77,33); fl.estimatedItemSize=CGSizeMake(CGFLOAT_MAX,CGFLOAT_MAX);
    if (!CGSizeEqualToSize(fl.estimatedItemSize,CGSizeMake(CGFLOAT_MAX,CGFLOAT_MAX))) abort();
    UICollectionView *cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,200) collectionViewLayout:fl];
    [cv registerClass:[AutomaticCell class] forCellWithReuseIdentifier:@"c"];
    AutomaticData*d=[AutomaticData new]; cv.dataSource=d;
    [cv layoutIfNeeded];
    if (!firstProposal || !isfinite(cv.contentSize.width) || !isfinite(cv.contentSize.height)) abort();
    if (horizontal && cv.contentSize.height != 200) abort();
    printf("count=%ld axis=%d content=%gx%g\n",(long)itemCount,horizontal,cv.contentSize.width,cv.contentSize.height);
    for (int i=0;i<itemCount;i++) {
        CGRect frame=[fl layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]].frame;
        if (!CGSizeEqualToSize(frame.size,CGSizeMake(80,30))) abort();
        printf("cell=%d frame=%g,%g,%g,%g\n",i,frame.origin.x,frame.origin.y,frame.size.width,frame.size.height);
    }
    preferredHeight=60;
    [cv reloadData]; [cv layoutIfNeeded];
    for (int i=0;i<itemCount;i++) {
        CGSize size=[fl layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]].size;
        if (!CGSizeEqualToSize(size,CGSizeMake(80,60))) {
            fprintf(stderr,"FAIL: reload retained stale size axis=%d count=%ld item=%d size=%gx%g\n",horizontal,(long)itemCount,i,size.width,size.height);
            return 1;
        }
    }
 }
 }
} return 0; }
