// Shared variable-height measurement/geometry trace. Not a timing or FPS benchmark.
#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#endif
static NSMutableArray *fitLog;
static NSMutableSet *measured;
static NSUInteger requests;
@interface TraceCell:UICollectionViewCell @property(nonatomic) CGFloat height; @end
@implementation TraceCell
- (UICollectionViewLayoutAttributes*)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes*)attributes{
 [fitLog addObject:@[@(attributes.indexPath.item),@(attributes.size.height),@(self.height)]];
 [measured addObject:@(attributes.indexPath.item)];
 UICollectionViewLayoutAttributes *result=[attributes copy];result.size=CGSizeMake(attributes.size.width,self.height);return result;
}
@end
@interface TraceSource:NSObject<UICollectionViewDataSource> @end
@implementation TraceSource
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)section{return 60;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)path{
 requests++;TraceCell *cell=[cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:path];cell.height=30+2*path.item;return cell;
}
@end
static void settle(UICollectionView *cv){[cv layoutIfNeeded];CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);[cv layoutIfNeeded];}
static void snapshot(NSString*phase,CGFloat requested,UICollectionView*cv,UICollectionViewFlowLayout*layout){
 NSMutableArray *frames=[NSMutableArray array],*visible=[NSMutableArray array];
 for(NSInteger i=0;i<60;i++){
  UICollectionViewLayoutAttributes*a=[layout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]];
  [frames addObject:@[@(a.frame.origin.y),@(a.frame.size.height)]];
 }
 for(NSIndexPath*p in [[cv indexPathsForVisibleItems] sortedArrayUsingSelector:@selector(compare:)])[visible addObject:@(p.item)];
 NSDictionary*record=@{@"phase":phase,@"requested":@(requested),@"offset":@(cv.contentOffset.y),@"contentHeight":@(cv.contentSize.height),
  @"requests":@(requests),@"fittings":fitLog,@"measured":[[measured allObjects] sortedArrayUsingSelector:@selector(compare:)],@"visible":visible,@"frames":frames};
 NSData*data=[NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
 puts([[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding].UTF8String);[fitLog removeAllObjects];
}
int main(void){@autoreleasepool{
 setvbuf(stdout,NULL,_IONBF,0);[UIApplication sharedApplication];fitLog=[NSMutableArray array];measured=[NSMutableSet set];
 UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.estimatedItemSize=CGSizeMake(200,40);l.minimumLineSpacing=0;l.minimumInteritemSpacing=0;
 UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,120) collectionViewLayout:l];
 cv.prefetchingEnabled=NO;[cv registerClass:[TraceCell class] forCellWithReuseIdentifier:@"c"];TraceSource*source=[TraceSource new];cv.dataSource=source;
 [cv reloadData];settle(cv);snapshot(@"initial",0,cv,l);
 for(NSNumber*y in @[@300,@600,@900,@1200,@0]){cv.contentOffset=CGPointMake(0,y.doubleValue);settle(cv);snapshot([NSString stringWithFormat:@"offset-%@",y],y.doubleValue,cv,l);}
}return 0;}
