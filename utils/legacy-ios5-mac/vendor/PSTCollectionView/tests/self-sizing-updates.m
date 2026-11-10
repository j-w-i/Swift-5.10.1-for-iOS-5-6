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
static void visit(UICollectionView *cv, UpdateData *data, NSInteger item, const char *stage) {
    NSIndexPath *path=[NSIndexPath indexPathForItem:item inSection:0];
    // One public call must keep its destination visible as estimates are measured.
    [cv scrollToItemAtIndexPath:path atScrollPosition:0 animated:NO];
    [cv setNeedsLayout]; [cv layoutIfNeeded];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);
    [cv setNeedsLayout]; [cv layoutIfNeeded];
    UpdateCell *cell=(UpdateCell *)[cv cellForItemAtIndexPath:path];
    CGSize size=[cv.collectionViewLayout layoutAttributesForItemAtIndexPath:path].size;
    CGFloat expected=[[data.heights objectAtIndex:item] doubleValue];
    if (!cell || cell.wantedHeight!=expected || size.width!=200 || size.height!=expected) {
        fprintf(stderr,"FAIL: %s item=%ld expected=200x%g actual=%gx%g cell=%p\n",stage,(long)item,expected,size.width,size.height,cell); exit(1);
    }
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
    cv.frame=CGRectMake(0,0,200,120);
    [data.heights removeAllObjects];
    for (int i=0;i<40;i++) [data.heights addObject:@(30+i*2)];
    [cv reloadData]; [cv layoutIfNeeded];
    visit(cv,data,0,"measure front");
    visit(cv,data,39,"measure back");
    [cv performBatchUpdates:^{
        [data.heights insertObject:@125 atIndex:0];
        [cv insertItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:0 inSection:0]]];
    } completion:nil];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.4,false);
    visit(cv,data,40,"shifted back after insertion");
    visit(cv,data,0,"new front after insertion");
    visit(cv,data,1,"shifted front after insertion");
    puts("PASS: offscreen measured items after insertion");
    [data.heights replaceObjectAtIndex:40 withObject:@155];
    [cv reloadItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:40 inSection:0]]];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.4,false);
    visit(cv,data,40,"offscreen reload");
    puts("PASS: offscreen item reload");
    // Interior target avoids clamping at content boundaries. Its preferred height
    // differs from the estimate, so check alignment using the resolved frame.
    for (NSUInteger position=1;position<=4;position*=2) {
        [cv reloadData];
        [cv setContentOffset:CGPointZero animated:NO]; [cv layoutIfNeeded];
        NSIndexPath *target=[NSIndexPath indexPathForItem:20 inSection:0];
        [cv scrollToItemAtIndexPath:target atScrollPosition:position animated:NO];
        [cv setNeedsLayout]; [cv layoutIfNeeded];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);
        [cv setNeedsLayout]; [cv layoutIfNeeded];
        CGRect frame=[layout layoutAttributesForItemAtIndexPath:target].frame;
        CGFloat expected=position==1 ? CGRectGetMinY(frame) : position==2 ? CGRectGetMidY(frame)-cv.bounds.size.height/2 : CGRectGetMaxY(frame)-cv.bounds.size.height;
        if (fabs(cv.contentOffset.y-expected)>1.0/UIScreen.mainScreen.scale+0.0001) {
            fprintf(stderr,"FAIL: alignment position=%lu expected=%g actual=%g\n",(unsigned long)position,expected,cv.contentOffset.y); return 1;
        }
    }
    puts("PASS: single-call top center bottom alignment");
    cv.contentInset=UIEdgeInsetsMake(13,0,29,0);
    for (NSUInteger position=1;position<=4;position*=2) {
        [cv reloadData]; [cv setContentOffset:CGPointZero animated:NO]; [cv layoutIfNeeded];
        NSIndexPath *target=[NSIndexPath indexPathForItem:20 inSection:0];
        [cv scrollToItemAtIndexPath:target atScrollPosition:position animated:NO];
        [cv setNeedsLayout]; [cv layoutIfNeeded];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);
        [cv setNeedsLayout]; [cv layoutIfNeeded];
        CGRect frame=[layout layoutAttributesForItemAtIndexPath:target].frame;
        CGFloat usable=cv.bounds.size.height-cv.contentInset.top-cv.contentInset.bottom;
        CGFloat expected=position==1 ? CGRectGetMinY(frame)-cv.contentInset.top : position==2 ? CGRectGetMidY(frame)-cv.contentInset.top-usable/2 : CGRectGetMaxY(frame)-cv.bounds.size.height+cv.contentInset.bottom;
        if (fabs(cv.contentOffset.y-expected)>1.0/UIScreen.mainScreen.scale+0.0001) {
            fprintf(stderr,"FAIL: inset alignment position=%lu expected=%g actual=%g\n",(unsigned long)position,expected,cv.contentOffset.y); return 1;
        }
    }
    puts("PASS: asymmetric inset top center bottom alignment");
} return 0; }
