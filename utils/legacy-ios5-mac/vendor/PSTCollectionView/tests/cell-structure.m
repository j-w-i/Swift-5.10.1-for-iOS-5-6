#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
static NSString *desc(UICollectionViewCell *c, UIView *bg, UIView *sbg){
  NSMutableString *m=[NSMutableString string];
  for(UIView*v in c.subviews){ NSString*n=v==c.contentView?@"content":(v==bg?@"bg":(v==sbg?@"selbg":@"?")); [m appendFormat:@"%@(%@) ",n,NSStringFromCGRect(v.frame)]; }
  return m;
}
@interface D : NSObject<UICollectionViewDataSource> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 3; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
@end
int main(){@autoreleasepool{[UIApplication sharedApplication];
UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(200,50);l.minimumLineSpacing=0;
UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,200) collectionViewLayout:l];
[cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];D*d=[D new];cv.dataSource=d;[cv layoutIfNeeded];
UICollectionViewCell*c=(UICollectionViewCell*)[cv cellForItemAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]]; printf("subviews count before touching contentView: %lu\n",(unsigned long)c.subviews.count);
printf("contentView accessed: %p; subviews now: %s\n",c.contentView,[desc(c,nil,nil) UTF8String]);
printf("default:        bg=%s selbg=%s subviews: %s\n",c.backgroundView?"set":"nil",c.selectedBackgroundView?"set":"nil",[desc(c,nil,nil) UTF8String]);
UIView*bg=[[UIView alloc] init]; c.backgroundView=bg;
printf("after set bg:   subviews: %s\n",[desc(c,bg,nil) UTF8String]);
UIView*sbg=[[UIView alloc] init]; c.selectedBackgroundView=sbg;
printf("after set sel:  subviews: %s\n",[desc(c,bg,sbg) UTF8String]);
l.itemSize=CGSizeMake(120,70);[l invalidateLayout];[cv layoutIfNeeded];
printf("after resize:   cell=%s subviews: %s\n",[NSStringFromCGRect(c.bounds) UTF8String],[desc(c,bg,sbg) UTF8String]);
c.backgroundView=nil;
printf("bg set to nil:  subviews: %s\n",[desc(c,nil,sbg) UTF8String]);
c.selected=YES; printf("selected:       selbg alpha=%g\n",sbg.alpha);
}return 0;}
