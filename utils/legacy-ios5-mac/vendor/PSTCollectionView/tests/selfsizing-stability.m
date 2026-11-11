// Stability caching must preserve explicit invalidation, frame-dependent sizing and reconfiguration.
#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#endif
@interface StableCell:UICollectionViewCell @property(nonatomic) CGFloat target;@property(nonatomic) NSInteger row;@end
@implementation StableCell
- (UICollectionViewLayoutAttributes*)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes*)a{
 UICollectionViewLayoutAttributes*r=[a copy];
 CGFloat height=self.row==1?(a.frame.origin.y<100?50:70):self.target;
 r.size=CGSizeMake(a.size.width,height);return r;
}
@end
@interface StableSource:NSObject<UICollectionViewDataSource> @property(nonatomic) CGFloat firstHeight;@end
@implementation StableSource
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)s{return 20;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)p{
 StableCell*c=[cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];c.row=p.item;c.target=p.item==0?self.firstHeight:80;return c;
}
@end
static void settle(UICollectionView*cv){[cv layoutIfNeeded];CFRunLoopRunInMode(kCFRunLoopDefaultMode,.05,false);[cv layoutIfNeeded];}
static int failures;
static void check(BOOL ok,const char*name){printf("%s %s\n",ok?"PASS":"FAIL",name);if(!ok)failures++;}
static CGFloat height(UICollectionViewFlowLayout*l,NSInteger row){return [l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:row inSection:0]].size.height;}
int main(void){@autoreleasepool{
 [UIApplication sharedApplication];UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.estimatedItemSize=CGSizeMake(200,80);l.minimumLineSpacing=0;
 UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,240) collectionViewLayout:l];cv.prefetchingEnabled=NO;
 [cv registerClass:[StableCell class] forCellWithReuseIdentifier:@"c"];StableSource*s=[StableSource new];s.firstHeight=90;cv.dataSource=s;
 [cv reloadData];settle(cv);check(height(l,0)==90&&height(l,1)==50,"initial origin-dependent preferred size");
 StableCell*first=(id)[cv cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];s.firstHeight=110;first.target=110;
 [first setNeedsLayout];[l invalidateLayout];[cv setNeedsLayout];settle(cv);
 check(height(l,0)==110,"explicit invalidation remeasures an unchanged proposal frame");
 check(height(l,1)==70,"shifted proposal origin invalidates a previously stable size");
 cv.contentOffset=CGPointMake(0,700);settle(cv);s.firstHeight=140;
 cv.contentOffset=CGPointZero;settle(cv);first=(id)[cv cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
 check(first&&first.target==140&&height(l,0)==140,"newly configured returning cell is measured again");
}return failures?1:0;}
