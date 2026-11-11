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
for(int k=0;k<1;k++){ UICollectionViewCell*moved=byTag(cv,2),*gone=byTag(cv,1);
  for(int pass=0;pass<2;pass++){ UICollectionViewCell*c=pass?gone:moved; printf("%s (tag %ld) animationKeys=%s\n",pass?"deleted":"moved",(long)c.tag,[[[c.layer animationKeys] description] UTF8String]);
    for(NSString*key in c.layer.animationKeys){ CAAnimation*a=[c.layer animationForKey:key]; CAMediaTimingFunction*tf=a.timingFunction; float p1[2],p2[2]; if(tf){[tf getControlPointAtIndex:1 values:p1];[tf getControlPointAtIndex:2 values:p2];}
      printf("  key=%s class=%s duration=%.3f beginTime=%.3f tf=(%.2f,%.2f,%.2f,%.2f)",[key UTF8String],object_getClassName(a),a.duration,a.beginTime,tf?p1[0]:-1,tf?p1[1]:-1,tf?p2[0]:-1,tf?p2[1]:-1);
      if([a isKindOfClass:[CABasicAnimation class]]) printf(" keyPath=%s from=%s to=%s",[[(CABasicAnimation*)a keyPath] UTF8String],[[[(CABasicAnimation*)a fromValue] description] UTF8String],[[[(CABasicAnimation*)a toValue] description] UTF8String]);
      if([a isKindOfClass:[CASpringAnimation class]]){ CASpringAnimation*sp=(CASpringAnimation*)a; printf(" spring mass=%.3f stiffness=%.3f damping=%.3f initialVelocity=%.3f settling=%.3f",sp.mass,sp.stiffness,sp.damping,sp.initialVelocity,sp.settlingDuration); }
      printf("\n"); } } }
}return 0;}
