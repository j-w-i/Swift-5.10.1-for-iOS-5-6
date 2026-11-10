#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewLayout PSTCollectionViewLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
static BOOL hiddenInput;
static NSUInteger callbacks;
static BOOL callbackHidden;
@interface HiddenCell : UICollectionViewCell @end
@implementation HiddenCell
- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)attributes {
    [super applyLayoutAttributes:attributes];
    callbacks++; callbackHidden=self.hidden;
}
@end
@interface HiddenLayout : UICollectionViewLayout @end
@implementation HiddenLayout
- (CGSize)collectionViewContentSize { return CGSizeMake(200,200); }
- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)path {
    UICollectionViewLayoutAttributes *a=[UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:path];
    a.frame=CGRectMake(10,20,80,30); a.hidden=hiddenInput; a.alpha=0.4; return a;
}
- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect {
    return @[[self layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]]];
}
@end
@interface HiddenData : NSObject<UICollectionViewDataSource> @end
@implementation HiddenData
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section { return 1; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)path {
    return [cv dequeueReusableCellWithReuseIdentifier:@"h" forIndexPath:path];
}
@end
int main(void) { @autoreleasepool {
    HiddenLayout *layout=[HiddenLayout new];
    UICollectionView *cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,200) collectionViewLayout:layout];
    [cv registerClass:[HiddenCell class] forCellWithReuseIdentifier:@"h"];
    HiddenData *data=[HiddenData new]; cv.dataSource=data;
    UICollectionViewCell *previous=nil;
    for (int stage=0;stage<3;stage++) {
        hiddenInput=stage==1; callbacks=0;
        [layout invalidateLayout]; [cv setNeedsLayout]; [cv layoutIfNeeded];
        UICollectionViewCell *cell=[cv cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
        printf("stage=%d inputHidden=%d cellPresent=%d callbacks=%lu callbackHidden=%d previousHidden=%d previousAttached=%d\n",stage,hiddenInput,cell!=nil,(unsigned long)callbacks,callbackHidden,previous.hidden,previous.superview!=nil);
        if (cell) previous=cell;
        // Query membership/callback counts vary in this command-line fixture;
        // only assert the retained view's final presentation state here.
        if (!previous || previous.hidden!=hiddenInput || fabs(previous.alpha-0.4)>0.0001) {
            fprintf(stderr,"FAIL: final hidden/alpha state at stage %d\n",stage); return 1;
        }
    }
    puts("PASS: retained cell final hidden/alpha transitions; callback and query parity NOT established");
} return 0; }
