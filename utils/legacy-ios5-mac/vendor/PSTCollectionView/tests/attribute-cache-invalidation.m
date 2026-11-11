#import "PSTCollectionView.h"
#import "PSTCollectionViewData.h"
static NSUInteger counts,prepares,queries;
@interface CacheLayout : PSTCollectionViewLayout
@property CGFloat height;
@end
@implementation CacheLayout
- (void)prepareLayout { prepares++; }
- (CGSize)collectionViewContentSize { return CGSizeMake(200,self.height); }
- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect {
 queries++;
 PSTCollectionViewLayoutAttributes *a=[PSTCollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
 a.frame=CGRectMake(0,0,200,self.height); return @[a];
}
@end
@interface CacheSource : NSObject<PSTCollectionViewDataSource> @end
@implementation CacheSource
- (NSInteger)collectionView:(PSTCollectionView *)v numberOfItemsInSection:(NSInteger)s { counts++; return 1; }
- (PSTCollectionViewCell *)collectionView:(PSTCollectionView *)v cellForItemAtIndexPath:(NSIndexPath *)p { return nil; }
@end
#define CHECK(x) do {if(!(x)){fprintf(stderr,"FAIL: %s at %d\n",#x,__LINE__);return 1;}}while(0)
int main(void){@autoreleasepool{
 [UIApplication sharedApplication];
 CacheLayout *layout=[CacheLayout new];layout.height=40;
 PSTCollectionView *view=[[PSTCollectionView alloc]initWithFrame:CGRectMake(0,0,200,120) collectionViewLayout:layout];
 CacheSource *source=[CacheSource new];view.dataSource=source;
 PSTCollectionViewData *data=[[PSTCollectionViewData alloc]initWithCollectionView:view layout:layout];
 CGRect rect=CGRectMake(0,0,200,120);[data validateLayoutInRect:rect];
 NSUInteger oldCounts=counts,oldPrepares=prepares,oldQueries=queries,oldGeneration=data.layoutAttributesGeneration;
 CHECK(data.layoutIsPrepared);CHECK(oldCounts>0);CHECK(oldPrepares>0);
 layout.height=75;[data invalidateLayoutAttributes];
 CHECK(data.layoutIsPrepared);CHECK(counts==oldCounts);CHECK(prepares==oldPrepares);
 [data validateLayoutInRect:rect];
 CHECK(counts==oldCounts);CHECK(prepares==oldPrepares);CHECK(queries==oldQueries+1);
 CHECK(data.layoutAttributesGeneration==oldGeneration+1);
 CHECK(data.collectionViewContentRect.size.height==75);
 CHECK(((PSTCollectionViewLayoutAttributes *)[[data layoutAttributesForElementsInRect:rect] objectAtIndex:0]).size.height==75);
 [data validateLayoutInRect:rect];CHECK(queries==oldQueries+1);
 puts("PASS: geometry cache refresh preserves counts/preparation, refreshes content and attributes once");
}return 0;}
