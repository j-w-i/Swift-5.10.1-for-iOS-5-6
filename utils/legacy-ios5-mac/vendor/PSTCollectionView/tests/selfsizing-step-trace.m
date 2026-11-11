// Shared variable-height measurement/geometry trace. Not a timing or FPS benchmark.
// Optional arguments: viewport-height step event-logging final-offset item-width (defaults 120 300 0 0 200).
#import <UIKit/UIKit.h>
#include <stdlib.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#endif
static NSMutableArray *fitLog,*events;
static NSMutableSet *measured;
static NSUInteger requests;
static BOOL snapshotting;
static NSArray *rect(CGRect r){return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)];}
@interface TraceCell:UICollectionViewCell @property(nonatomic) CGFloat height; @end
@implementation TraceCell
- (UICollectionViewLayoutAttributes*)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes*)attributes{
 [fitLog addObject:@[@(attributes.indexPath.item),@(attributes.size.height),@(self.height)]];
 if(events)[events addObject:@[@"fit",@(attributes.indexPath.item),rect(attributes.frame),@(self.height)]];
 [measured addObject:@(attributes.indexPath.item)];
 UICollectionViewLayoutAttributes *result=[attributes copy];result.size=CGSizeMake(attributes.size.width,self.height);return result;
}
@end
@interface TraceFlow:UICollectionViewFlowLayout @end
@implementation TraceFlow
- (void)prepareLayout{if(!snapshotting)[events addObject:@[@"prepare"]];[super prepareLayout];}
- (NSArray*)layoutAttributesForElementsInRect:(CGRect)r{
 NSArray*a=[super layoutAttributesForElementsInRect:r];
 if(!snapshotting){NSMutableArray*paths=[NSMutableArray array];for(UICollectionViewLayoutAttributes*x in a)[paths addObject:@(x.indexPath.item)];[events addObject:@[@"queryRect",rect(r),paths]];}
 return a;
}
- (UICollectionViewLayoutAttributes*)layoutAttributesForItemAtIndexPath:(NSIndexPath*)p{
 UICollectionViewLayoutAttributes*a=[super layoutAttributesForItemAtIndexPath:p];
 if(!snapshotting)[events addObject:@[@"queryItem",@(p.item),rect(a.frame)]];return a;
}
#ifndef TEST_PST
- (UICollectionViewLayoutInvalidationContext*)invalidationContextForPreferredLayoutAttributes:(UICollectionViewLayoutAttributes*)preferred withOriginalAttributes:(UICollectionViewLayoutAttributes*)original{
 UICollectionViewLayoutInvalidationContext*c=[super invalidationContextForPreferredLayoutAttributes:preferred withOriginalAttributes:original];
 [events addObject:@[@"preferredContext",@(preferred.indexPath.item),rect(original.frame),rect(preferred.frame)]];return c;
}
- (void)invalidateLayoutWithContext:(UICollectionViewLayoutInvalidationContext*)context{
 if(!snapshotting){NSMutableArray*paths=[NSMutableArray array];for(NSIndexPath*p in context.invalidatedItemIndexPaths)[paths addObject:@(p.item)];[events addObject:@[@"invalidate",paths,@(context.invalidateEverything),@(context.invalidateDataSourceCounts)]];}
 [super invalidateLayoutWithContext:context];
}
#endif
@end
@interface TraceSource:NSObject<UICollectionViewDataSource> @end
@implementation TraceSource
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)section{return 60;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)path{
 requests++;if(events)[events addObject:@[@"request",@(path.item)]];
 TraceCell *cell=[cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:path];cell.height=30+2*path.item;return cell;
}
@end
static void settle(UICollectionView *cv){[cv layoutIfNeeded];CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);[cv layoutIfNeeded];}
static void snapshot(NSString*phase,CGFloat requested,UICollectionView*cv,UICollectionViewFlowLayout*layout){
 NSMutableArray *frames=[NSMutableArray array],*rects=[NSMutableArray array],*visible=[NSMutableArray array];snapshotting=YES;
 for(NSInteger i=0;i<60;i++){
  UICollectionViewLayoutAttributes*a=[layout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]];
  [frames addObject:@[@(a.frame.origin.y),@(a.frame.size.height)]];[rects addObject:rect(a.frame)];
 }
 for(NSIndexPath*p in [[cv indexPathsForVisibleItems] sortedArrayUsingSelector:@selector(compare:)])[visible addObject:@(p.item)];snapshotting=NO;
 NSDictionary*record=@{@"phase":phase,@"requested":@(requested),@"offset":@(cv.contentOffset.y),@"contentHeight":@(cv.contentSize.height),
  @"requests":@(requests),@"fittings":fitLog,@"measured":[[measured allObjects] sortedArrayUsingSelector:@selector(compare:)],@"visible":visible,@"frames":frames,@"rects":rects,@"itemWidth":@(layout.estimatedItemSize.width),@"events":events?:@[]};
 NSData*data=[NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
 puts([[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding].UTF8String);[fitLog removeAllObjects];[events removeAllObjects];
}
int main(int argc,char**argv){@autoreleasepool{
 CGFloat viewport=argc>1?atof(argv[1]):120,step=argc>2?atof(argv[2]):300,finalOffset=argc>4?atof(argv[4]):0,itemWidth=argc>5?atof(argv[5]):200;
 if(viewport<=0||step<=0||itemWidth<=0||itemWidth>200)return 64;
 setvbuf(stdout,NULL,_IONBF,0);[UIApplication sharedApplication];fitLog=[NSMutableArray array];measured=[NSMutableSet set];if(argc>3&&atoi(argv[3]))events=[NSMutableArray array];
 UICollectionViewFlowLayout*l=events?[TraceFlow new]:[UICollectionViewFlowLayout new];l.estimatedItemSize=CGSizeMake(itemWidth,40);l.minimumLineSpacing=0;l.minimumInteritemSpacing=0;
 UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,viewport) collectionViewLayout:l];
 cv.prefetchingEnabled=NO;[cv registerClass:[TraceCell class] forCellWithReuseIdentifier:@"c"];TraceSource*source=[TraceSource new];cv.dataSource=source;
 [cv reloadData];settle(cv);snapshot(@"initial",0,cv,l);
 for(NSNumber*y in @[@(step),@(2*step),@(3*step),@(4*step),@(finalOffset)]){cv.contentOffset=CGPointMake(0,y.doubleValue);settle(cv);snapshot([NSString stringWithFormat:@"offset-%@",y],y.doubleValue,cv,l);}
}return 0;}
