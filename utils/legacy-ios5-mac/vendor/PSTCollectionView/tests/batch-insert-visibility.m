// Inserts outside and inside the viewport: data source requests, willDisplay, visible cells, content size.
// Same scenarios on native UIKit and PST; output must match.
#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegate PSTCollectionViewDelegate
#endif
static NSMutableArray *log_;static NSInteger COUNT;
@interface DS:NSObject<UICollectionViewDataSource,UICollectionViewDelegate> @end
@implementation DS
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)s{return COUNT;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)p{[log_ addObject:[NSString stringWithFormat:@"request %ld",(long)p.item]];return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];}
- (void)collectionView:(UICollectionView*)cv willDisplayCell:(UICollectionViewCell*)c forItemAtIndexPath:(NSIndexPath*)p{[log_ addObject:[NSString stringWithFormat:@"willDisplay %ld",(long)p.item]];}
@end
static NSArray *sorted(UICollectionView*cv){NSMutableArray*a=[NSMutableArray array];for(NSIndexPath*p in cv.indexPathsForVisibleItems)[a addObject:@(p.item)];return [a sortedArrayUsingSelector:@selector(compare:)];}
static void scenario(NSString*name,CGFloat offset,NSInteger startCount,NSArray*inserts,NSArray*deletes){
 COUNT=startCount;log_=[NSMutableArray array];
 UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(320,58);l.minimumLineSpacing=0;
 UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,320,480) collectionViewLayout:l];
 [cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];DS*d=[DS new];cv.dataSource=d;cv.delegate=d;
 [cv layoutIfNeeded];if(offset>0){cv.contentOffset=CGPointMake(0,offset);[cv layoutIfNeeded];}
 [log_ removeAllObjects];
 [UIView performWithoutAnimation:^{[cv performBatchUpdates:^{
   for(NSNumber*n in deletes){COUNT--;[cv deleteItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:n.integerValue inSection:0]]];}
   for(NSNumber*n in inserts){COUNT++;[cv insertItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:n.integerValue inSection:0]]];}
  } completion:nil];}];
 [cv layoutIfNeeded];
 NSDictionary*r=@{@"scenario":name,@"events":log_,@"visible":sorted(cv),@"content":@(cv.contentSize.height),@"count":@(COUNT)};
 NSData*j=[NSJSONSerialization dataWithJSONObject:r options:0 error:NULL];puts([[NSString alloc]initWithData:j encoding:NSUTF8StringEncoding].UTF8String);
}
int main(){@autoreleasepool{[UIApplication sharedApplication];
 scenario(@"insert far below, at top",0,200,@[@200,@201,@202,@203,@204],@[]);
 scenario(@"insert far below, scrolled",1000,200,@[@199,@200],@[]);
 scenario(@"insert inside viewport",0,200,@[@2,@3],@[]);
 scenario(@"insert just past viewport edge",0,200,@[@8,@9,@10],@[]);
 scenario(@"insert above viewport, scrolled",2000,200,@[@0,@1],@[]);
 scenario(@"insert inside while scrolled",1000,200,@[@18,@19],@[]);
 scenario(@"delete and insert mix",0,200,@[@6,@100],@[@1,@2]);
 scenario(@"insert into empty",0,0,@[@0,@1,@2],@[]);
 scenario(@"insert at end of short list",0,5,@[@5,@6],@[]);
}return 0;}
