// Self-sizing across layout shapes the single-section fixtures do not cover: sections, headers/footers, insets,
// spacing and horizontal scroll. One JSON line per scenario and step: every item rect, header/footer frames,
// content size, visible items. Args: scenario-index. Same source runs on native UIKit and PST.
#import <UIKit/UIKit.h>
#include <stdlib.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegateFlowLayout PSTCollectionViewDelegateFlowLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewScrollDirectionHorizontal PSTCollectionViewScrollDirectionHorizontal
#define UICollectionElementKindSectionHeader PSTCollectionElementKindSectionHeader
#define UICollectionElementKindSectionFooter PSTCollectionElementKindSectionFooter
#define UICollectionReusableView PSTCollectionReusableView
#endif
static BOOL horizontal_;
@interface LC:UICollectionViewCell @end
@implementation LC
- (UICollectionViewLayoutAttributes*)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes*)a{
 UICollectionViewLayoutAttributes*r=[a copy];CGFloat d=30+((a.indexPath.item*7+a.indexPath.section*3)%5)*8;
 r.size=horizontal_?CGSizeMake(d,a.size.height):CGSizeMake(a.size.width,d);return r;}
@end
@interface LH:UICollectionReusableView @end
@implementation LH @end
@interface LS:NSObject<UICollectionViewDataSource,UICollectionViewDelegateFlowLayout> @property NSInteger sections,items; @end
@implementation LS
- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView*)cv{return self.sections;}
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)s{return self.items;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)p{return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];}
- (UICollectionReusableView*)collectionView:(UICollectionView*)cv viewForSupplementaryElementOfKind:(NSString*)k atIndexPath:(NSIndexPath*)p{return [cv dequeueReusableSupplementaryViewOfKind:k withReuseIdentifier:@"h" forIndexPath:p];}
@end
static NSArray *r4(CGRect r){return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)];}
static void settle(UICollectionView*cv){[cv layoutIfNeeded];CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);[cv layoutIfNeeded];}
static void snap(NSString*name,UICollectionView*cv,UICollectionViewFlowLayout*l,LS*s){
 NSMutableArray*rects=[NSMutableArray array],*heads=[NSMutableArray array],*vis=[NSMutableArray array];
 for(NSInteger sec=0;sec<s.sections;sec++){
  for(NSInteger i=0;i<s.items;i++)[rects addObject:r4([l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:sec]].frame)];
  UICollectionViewLayoutAttributes*h=[l layoutAttributesForSupplementaryViewOfKind:UICollectionElementKindSectionHeader atIndexPath:[NSIndexPath indexPathForItem:0 inSection:sec]];
  UICollectionViewLayoutAttributes*f=[l layoutAttributesForSupplementaryViewOfKind:UICollectionElementKindSectionFooter atIndexPath:[NSIndexPath indexPathForItem:0 inSection:sec]];
  [heads addObject:@[h?r4(h.frame):@[],f?r4(f.frame):@[]]];}
 NSMutableArray*cellFrames=[NSMutableArray array],*suppFrames=[NSMutableArray array];
 for(NSIndexPath*p in [cv.indexPathsForVisibleItems sortedArrayUsingSelector:@selector(compare:)]){[vis addObject:@[@(p.section),@(p.item)]];[cellFrames addObject:r4([cv cellForItemAtIndexPath:p].frame)];}
 for(NSString*kind in @[UICollectionElementKindSectionHeader,UICollectionElementKindSectionFooter])for(NSIndexPath*p in [[cv indexPathsForVisibleSupplementaryElementsOfKind:kind] sortedArrayUsingSelector:@selector(compare:)]){
  UICollectionReusableView*v=[l.collectionView.subviews filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id o,id b){return [o isKindOfClass:[UICollectionReusableView class]]&&![o isKindOfClass:[UICollectionViewCell class]];}]].firstObject;(void)v;
  UICollectionViewLayoutAttributes*sa=[l layoutAttributesForSupplementaryViewOfKind:kind atIndexPath:p];[suppFrames addObject:@[kind,@(p.section),r4(sa.frame)]];}
 NSDictionary*rec=@{@"step":name,@"rects":rects,@"supp":heads,@"content":r4((CGRect){.size=cv.contentSize}),@"visible":vis,@"cellFrames":cellFrames,@"visibleSupp":suppFrames};
 puts([[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:rec options:0 error:NULL] encoding:NSUTF8StringEncoding].UTF8String);}
int main(int argc,char**argv){@autoreleasepool{[UIApplication sharedApplication];setvbuf(stdout,NULL,_IONBF,0);
 int sc=argc>1?atoi(argv[1]):0;
 // scenario: sections, items, horizontal, header, inset, spacing(line,inter), estimate width
 struct{int sec,items;BOOL h;CGFloat hdr;UIEdgeInsets in;CGFloat line,inter,ew;}S[]={
  {3,14,NO,30,{0,0,0,0},0,0,200},
  {3,14,NO,30,{10,12,16,12},4,6,200},
  {2,16,NO,0,{8,8,8,8},6,6,90},
  {3,14,YES,30,{0,0,0,0},0,0,200},
  {2,16,YES,0,{8,8,8,8},6,6,90},
  {4,9,NO,24,{4,0,12,0},0,0,200},
 };
 if(sc<0||sc>=(int)(sizeof S/sizeof S[0]))return 64;
 horizontal_=S[sc].h;
 UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.minimumLineSpacing=S[sc].line;l.minimumInteritemSpacing=S[sc].inter;l.sectionInset=S[sc].in;
 if(S[sc].h)l.scrollDirection=UICollectionViewScrollDirectionHorizontal;
 l.estimatedItemSize=S[sc].h?CGSizeMake(60,S[sc].ew<150?90:200):CGSizeMake(S[sc].ew,40);
 l.headerReferenceSize=S[sc].h?CGSizeMake(S[sc].hdr,0):CGSizeMake(0,S[sc].hdr);
 CGRect fr=S[sc].h?CGRectMake(0,0,200,300):CGRectMake(0,0,200,240);
 UICollectionView*cv=[[UICollectionView alloc]initWithFrame:fr collectionViewLayout:l];cv.prefetchingEnabled=NO;
 [cv registerClass:[LC class] forCellWithReuseIdentifier:@"c"];
 [cv registerClass:[LH class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"h"];
 LS*s=[LS new];s.sections=S[sc].sec;s.items=S[sc].items;cv.dataSource=s;
 [cv reloadData];settle(cv);snap(@"initial",cv,l,s);
 CGFloat step=S[sc].h?160:150;
 for(int i=1;i<=3;i++){cv.contentOffset=S[sc].h?CGPointMake(step*i,0):CGPointMake(0,step*i);settle(cv);snap([NSString stringWithFormat:@"step%d",i],cv,l,s);}
}return 0;}
