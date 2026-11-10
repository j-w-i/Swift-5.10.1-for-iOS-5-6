#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
@interface UpdateCell : UICollectionViewCell
@property(nonatomic) CGFloat wantedHeight;
@end
@implementation UpdateCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)a {
    UICollectionViewLayoutAttributes *result=[a copy]; result.size=CGSizeMake(200,self.wantedHeight); return result;
}
@end
@interface UpdateData : NSObject<UICollectionViewDataSource>
@property(nonatomic,strong) NSMutableArray *heights;
@end
@implementation UpdateData
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return self.heights.count; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p {
    UpdateCell *cell=[cv dequeueReusableCellWithReuseIdentifier:@"u" forIndexPath:p];
    cell.wantedHeight=[[self.heights objectAtIndex:p.item] doubleValue]; return cell;
}
@end
static void check(UICollectionView *cv, UpdateData *data, const char *stage) {
    [cv setNeedsLayout]; [cv layoutIfNeeded];
    // Let completion/retirement work finish before checking the next transaction.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.4,false);
    [cv setNeedsLayout]; [cv layoutIfNeeded];
    for (NSInteger i=0;i<data.heights.count;i++) {
        CGSize size=[cv.collectionViewLayout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]].size;
        CGFloat expected=[[data.heights objectAtIndex:i] doubleValue];
        if (size.width!=200 || size.height!=expected) {
            fprintf(stderr,"FAIL: %s item=%ld expected=200x%g actual=%gx%g\n",stage,(long)i,expected,size.width,size.height); exit(1);
        }
    }
    printf("PASS: %s\n",stage);
}
int main(void) { @autoreleasepool {
    [UIView setAnimationsEnabled:NO];
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];
    layout.estimatedItemSize=CGSizeMake(200,40); layout.minimumLineSpacing=0;
    UICollectionView *cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,600) collectionViewLayout:layout];
    [cv registerClass:[UpdateCell class] forCellWithReuseIdentifier:@"u"];
    UpdateData *data=[UpdateData new]; data.heights=[NSMutableArray arrayWithArray:@[@30,@50,@70]]; cv.dataSource=data;
    check(cv,data,"initial");
    [cv performBatchUpdates:^{ [data.heights insertObject:@90 atIndex:0]; [cv insertItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:0 inSection:0]]]; } completion:nil];
    check(cv,data,"insert shifts measured paths");
    [cv performBatchUpdates:^{ [data.heights removeObjectAtIndex:1]; [cv deleteItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:1 inSection:0]]]; } completion:nil];
    check(cv,data,"delete shifts measured paths");
    [data.heights replaceObjectAtIndex:1 withObject:@110];
    [cv reloadItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:1 inSection:0]]];
    check(cv,data,"reload item changes preferred height");
    [cv performBatchUpdates:^{
        id height=[data.heights objectAtIndex:0]; [data.heights removeObjectAtIndex:0]; [data.heights addObject:height];
        [cv moveItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0] toIndexPath:[NSIndexPath indexPathForItem:2 inSection:0]];
    } completion:nil];
    check(cv,data,"move preserves item preferred heights");
    for (int generation=0;generation<3;generation++) {
        [data.heights replaceObjectAtIndex:0 withObject:@(25+generation*10)];
        [cv reloadItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:0 inSection:0]]];
        check(cv,data,"repeated reload changes preferred height");
    }
} return 0; }
