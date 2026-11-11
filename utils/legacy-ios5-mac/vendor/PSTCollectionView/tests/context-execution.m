#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewLayout PSTCollectionViewLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewLayoutInvalidationContext PSTCollectionViewLayoutInvalidationContext
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
static NSUInteger prepares,counts;
@interface ExecutionLayout : UICollectionViewLayout @end
@implementation ExecutionLayout
- (void)prepareLayout { [super prepareLayout]; prepares++; }
- (CGSize)collectionViewContentSize { return CGSizeMake(200,400); }
- (NSArray *)layoutAttributesForElementsInRect:(CGRect)r { return @[]; }
@end
@interface ExecutionSource : NSObject<UICollectionViewDataSource> @end
@implementation ExecutionSource
- (NSInteger)collectionView:(UICollectionView *)v numberOfItemsInSection:(NSInteger)s { counts++;return 1; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)v cellForItemAtIndexPath:(NSIndexPath *)p { return nil; }
@end
int main(void){@autoreleasepool{
 [UIApplication sharedApplication];
 ExecutionLayout*l=[ExecutionLayout new];UICollectionView*v=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,120) collectionViewLayout:l];
 ExecutionSource*d=[ExecutionSource new];v.dataSource=d;[v layoutIfNeeded];
 for(int mode=0;mode<2;mode++){
 NSUInteger p=prepares,c=counts;
 UICollectionViewLayoutInvalidationContext*x=[UICollectionViewLayoutInvalidationContext new];
 if(mode)[x invalidateItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:0 inSection:0]]];
 [l invalidateLayoutWithContext:x];[v layoutIfNeeded];
 printf("mode=%d prepared=%d recounted=%d\n",mode,prepares>p,counts>c);
 }
}return 0;}
