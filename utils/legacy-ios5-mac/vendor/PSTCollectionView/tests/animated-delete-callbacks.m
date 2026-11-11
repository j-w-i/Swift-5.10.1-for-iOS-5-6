#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegate PSTCollectionViewDelegate
#endif
static NSMutableArray *LOG; static NSMutableArray *ITEMS; static CFAbsoluteTime T0;
static void L(NSString *s){ [LOG addObject:[NSString stringWithFormat:@"%4.0fms %@",(CFAbsoluteTimeGetCurrent()-T0)*1000,s]]; }
@interface D : NSObject<UICollectionViewDataSource,UICollectionViewDelegate> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return ITEMS.count; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { UICollectionViewCell *c=[cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; c.tag=[[ITEMS objectAtIndex:p.row] intValue]; return c; }
- (void)collectionView:(UICollectionView *)cv didEndDisplayingCell:(UICollectionViewCell *)c forItemAtIndexPath:(NSIndexPath *)p { L([NSString stringWithFormat:@"didEnd row %ld (tag %ld) alpha=%.2f hidden=%d",(long)p.row,(long)c.tag,c.alpha,c.hidden]); }
@end
int main(){@autoreleasepool{[UIApplication sharedApplication]; LOG=[NSMutableArray array]; ITEMS=[NSMutableArray array]; for(int i=0;i<6;i++)[ITEMS addObject:@(i)];
UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(200,40);l.minimumLineSpacing=0;
UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,300) collectionViewLayout:l];
[cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];D*d=[D new];cv.dataSource=d;cv.delegate=d;UIWindow*w=[[UIWindow alloc] initWithFrame:CGRectMake(0,0,200,300)];[w addSubview:cv];w.hidden=NO;[cv layoutIfNeeded];CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.2,false);
T0=CFAbsoluteTimeGetCurrent(); L(@"performBatchUpdates (delete rows 1,2)");
[cv performBatchUpdates:^{ [ITEMS removeObjectAtIndex:2]; [ITEMS removeObjectAtIndex:1]; [cv deleteItemsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:0],[NSIndexPath indexPathForRow:2 inSection:0]]]; } completion:^(BOOL f){ L(@"completion"); }];
L(@"performBatchUpdates returned");
CFRunLoopRunInMode(kCFRunLoopDefaultMode,1.0,false);
for(NSString*s in LOG)printf("%s\n",s.UTF8String);}return 0;}
