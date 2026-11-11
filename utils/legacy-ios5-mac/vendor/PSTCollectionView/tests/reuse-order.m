#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegate PSTCollectionViewDelegate
#endif
static NSMutableArray *LOG; static int SERIAL;
@interface RC : UICollectionViewCell @property int serial; @end
@implementation RC
- (id)initWithFrame:(CGRect)f { self=[super initWithFrame:f]; self.serial=++SERIAL; [LOG addObject:[NSString stringWithFormat:@"new#%d",self.serial]]; return self; }
- (void)prepareForReuse { [LOG addObject:[NSString stringWithFormat:@"prepare#%d",self.serial]]; [super prepareForReuse]; }
@end
@interface D : NSObject<UICollectionViewDataSource,UICollectionViewDelegate> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 30; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { RC *c=(RC*)[cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; [LOG addObject:[NSString stringWithFormat:@"cfi %ld -> #%d",(long)p.row,c.serial]]; return c; }
- (void)collectionView:(UICollectionView *)cv didEndDisplayingCell:(UICollectionViewCell *)c forItemAtIndexPath:(NSIndexPath *)p { [LOG addObject:[NSString stringWithFormat:@"end %ld #%d",(long)p.row,((RC*)c).serial]]; }
@end
int main(void){@autoreleasepool{[UIApplication sharedApplication];LOG=[NSMutableArray array];
UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(200,50);l.minimumLineSpacing=0;
UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,100) collectionViewLayout:l];
[cv registerClass:[RC class] forCellWithReuseIdentifier:@"c"];D*d=[D new];cv.dataSource=d;cv.delegate=d;[cv layoutIfNeeded];
[LOG addObject:@"--scroll 100"];cv.contentOffset=CGPointMake(0,100);[cv layoutIfNeeded];
[LOG addObject:@"--scroll 200"];cv.contentOffset=CGPointMake(0,200);[cv layoutIfNeeded];
for(NSString*s in LOG)printf("%s\n",s.UTF8String);}return 0;}
