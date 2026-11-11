#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
static NSMutableArray *ITEMS;
@interface D : NSObject<UICollectionViewDataSource> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return ITEMS.count; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { UICollectionViewCell *c=[cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; c.tag=[[ITEMS objectAtIndex:p.row] intValue]; return c; }
@end
static UICollectionViewCell *byTag(UICollectionView*cv,int t){ for(UIView*v in cv.subviews) if([v isKindOfClass:[UICollectionViewCell class]]&&v.tag==t) return (UICollectionViewCell*)v; return nil; }
int main(){@autoreleasepool{[UIApplication sharedApplication]; ITEMS=[NSMutableArray array]; for(int i=0;i<6;i++)[ITEMS addObject:@(i)];
UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(200,40);l.minimumLineSpacing=0;
UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,300) collectionViewLayout:l];
[cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];D*d=[D new];cv.dataSource=d;
UIWindow*w=[[UIWindow alloc] initWithFrame:CGRectMake(0,0,200,300)];[w addSubview:cv];w.hidden=NO;[cv layoutIfNeeded];CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.2,false);
[cv performBatchUpdates:^{ [ITEMS removeObjectAtIndex:1]; [cv deleteItemsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:0]]]; } completion:nil];
for(int k=0;k<4;k++){ CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.15,false);
  UICollectionViewCell*gone=byTag(cv,1),*moved=byTag(cv,2);
  printf("t=%3dms  deleted(tag1): %s  | tag2 frame y=%s\n",(k+1)*150,gone?[[NSString stringWithFormat:@"alpha=%.2f hidden=%d presentationAlpha=%.2f",gone.alpha,gone.hidden,gone.layer.presentationLayer?gone.layer.presentationLayer.opacity:-1] UTF8String]:"(removed)",moved?[[NSString stringWithFormat:@"model=%g presentation=%g",moved.frame.origin.y,moved.layer.presentationLayer.frame.origin.y] UTF8String]:"nil"); }
}return 0;}
