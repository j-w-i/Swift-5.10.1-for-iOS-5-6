#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
@interface RC : UICollectionViewCell @property(nonatomic,strong) UIView *extra; @property(nonatomic,strong) UIView *inner; @end
@implementation RC
- (id)initWithFrame:(CGRect)f { self=[super initWithFrame:f];
  self.extra=[[UIView alloc] initWithFrame:CGRectMake(5,5,f.size.width-10,10)]; self.extra.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleBottomMargin; [self addSubview:self.extra];
  self.inner=[[UIView alloc] initWithFrame:CGRectMake(0,0,f.size.width,f.size.height)]; self.inner.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; [self.contentView addSubview:self.inner]; return self; }
@end
@interface D : NSObject<UICollectionViewDataSource> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 2; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
@end
int main(){@autoreleasepool{[UIApplication sharedApplication];
UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(100,50);
UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,320,200) collectionViewLayout:l];
[cv registerClass:[RC class] forCellWithReuseIdentifier:@"c"];D*d=[D new];cv.dataSource=d;[cv layoutIfNeeded];
l.itemSize=CGSizeMake(80,70);[l invalidateLayout];[cv layoutIfNeeded];
RC*c=(RC*)[cv cellForItemAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
NSString *line=[NSString stringWithFormat:@"cell=%s content=%s extra=%s inner=%s",NSStringFromCGRect(c.bounds).UTF8String,NSStringFromCGRect(c.contentView.frame).UTF8String,NSStringFromCGRect(c.extra.frame).UTF8String,NSStringFromCGRect(c.inner.frame).UTF8String]; printf("%s\n",line.UTF8String);}return 0;}
