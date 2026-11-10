#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionReusableView PSTCollectionReusableView
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegate PSTCollectionViewDelegate
#define UICollectionElementKindSectionHeader PSTCollectionElementKindSectionHeader
#endif
static void require(BOOL ok,const char *message) { if (!ok) { fprintf(stderr,"FAIL: %s\n",message); exit(1); } }
@interface DisplayData : NSObject<UICollectionViewDataSource,UICollectionViewDelegate>
@property(nonatomic) NSUInteger cells,headers;
@property(nonatomic,strong) NSMutableSet *paths;
@property(nonatomic,strong) UICollectionReusableView *header;
@end
@implementation DisplayData
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section { return 3; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)path {
    UICollectionViewCell *cell=[cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:path]; cell.tag=100+path.item; return cell;
}
- (UICollectionReusableView *)collectionView:(UICollectionView *)cv viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)path {
    UICollectionReusableView *view=[cv dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"h" forIndexPath:path]; view.tag=200; return view;
}
- (void)collectionView:(UICollectionView *)cv willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)path {
    require(cell.superview==cv,"cell attached before willDisplay");
    require(cell.tag==100+path.item,"cell configured before willDisplay");
    require(![self.paths containsObject:path],"no duplicate initial cell callback");
    [self.paths addObject:path]; self.cells++;
}
- (void)collectionView:(UICollectionView *)cv willDisplaySupplementaryView:(UICollectionReusableView *)view forElementKind:(NSString *)kind atIndexPath:(NSIndexPath *)path {
    require(view.superview==cv && view.tag==200,"header configured and attached before willDisplay");
    require([kind isEqual:UICollectionElementKindSectionHeader] && path.section==0,"header identity");
    self.headers++; self.header=view;
}
@end
int main(void) { @autoreleasepool {
    [UIApplication sharedApplication];
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];
    layout.itemSize=CGSizeMake(80,30); layout.headerReferenceSize=CGSizeMake(200,20);
    UICollectionView *cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,200) collectionViewLayout:layout];
    [cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];
    [cv registerClass:[UICollectionReusableView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"h"];
    DisplayData *data=[DisplayData new]; data.paths=[NSMutableSet set]; cv.dataSource=data; cv.delegate=data;
    [cv layoutIfNeeded];
    require(data.cells==3 && data.headers==1,"initial callback counts");
    NSArray *views=[cv visibleSupplementaryViewsOfKind:UICollectionElementKindSectionHeader];
    NSArray *paths=[cv indexPathsForVisibleSupplementaryElementsOfKind:UICollectionElementKindSectionHeader];
    require(views.count==1 && [views objectAtIndex:0]==data.header,"visible header query matches callback");
    require(paths.count==1 && [[paths objectAtIndex:0] isEqual:[NSIndexPath indexPathForItem:0 inSection:0]],"visible header path query");
    require([cv visibleSupplementaryViewsOfKind:@"absent-kind"].count==0,"unknown supplementary kind empty");
    [cv setNeedsLayout]; [cv layoutIfNeeded];
    require(data.cells==3 && data.headers==1,"idle layout does not repeat display callbacks");
    puts("PASS: configured/attached cell and header callbacks, counts, idle stability and supplementary queries");
} return 0; }
