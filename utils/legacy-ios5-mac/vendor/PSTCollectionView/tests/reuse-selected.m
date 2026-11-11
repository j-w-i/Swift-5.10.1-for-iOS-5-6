#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
static NSMutableArray *LOG;
@interface RC : UICollectionViewCell @end
@implementation RC
- (void)setSelected:(BOOL)s { [LOG addObject:[NSString stringWithFormat:@"setSelected %d",s]]; [super setSelected:s]; }
- (void)setHighlighted:(BOOL)h { [LOG addObject:[NSString stringWithFormat:@"setHighlighted %d",h]]; [super setHighlighted:h]; }
- (void)prepareForReuse { [LOG addObject:@"prepareForReuse"]; [super prepareForReuse]; }
@end
@interface D : NSObject<UICollectionViewDataSource> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 30; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
@end
int main(void){@autoreleasepool{[UIApplication sharedApplication];LOG=[NSMutableArray array];
UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(200,50);l.minimumLineSpacing=0;
UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,100) collectionViewLayout:l];
[cv registerClass:[RC class] forCellWithReuseIdentifier:@"c"];D*d=[D new];cv.dataSource=d;[cv layoutIfNeeded];
UICollectionViewCell*c=[cv cellForItemAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
[LOG addObject:@"--select"];c.selected=YES;c.highlighted=YES;
[LOG addObject:@"--scroll away and back"];cv.contentOffset=CGPointMake(0,1000);[cv layoutIfNeeded];cv.contentOffset=CGPointZero;[cv layoutIfNeeded];
[LOG addObject:@"--end"];
for(NSString*s in LOG)printf("%s\n",s.UTF8String);}return 0;}
