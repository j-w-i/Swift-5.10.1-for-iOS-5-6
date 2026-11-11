#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#endif
static NSArray *H;
@interface C : UICollectionViewCell @property CGFloat h; @end
@implementation C
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)a { UICollectionViewLayoutAttributes *r=[a copy]; r.size=CGSizeMake(a.size.width,self.h); return r; }
@end
@interface D : NSObject<UICollectionViewDataSource> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return H.count; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { C *c=[cv dequeueReusableCellWithReuseIdentifier:@"u" forIndexPath:p]; c.h=[H[p.row] doubleValue]; return c; }
@end
static void run(const char *name, NSArray *heights, CGFloat est, CGFloat viewH) {
    H=heights;
    UICollectionViewFlowLayout *l=[UICollectionViewFlowLayout new]; l.estimatedItemSize=CGSizeMake(200,est); l.minimumLineSpacing=0;
    UICollectionView *cv=[[UICollectionView alloc] initWithFrame:CGRectMake(0,0,200,viewH) collectionViewLayout:l];
    [cv registerClass:[C class] forCellWithReuseIdentifier:@"u"]; D *d=[D new]; cv.dataSource=d;
    [cv reloadData]; [cv layoutIfNeeded]; CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false); [cv layoutIfNeeded];
    NSMutableString *m=[NSMutableString string]; CGFloat prev=-1; int run=0;
    for (NSUInteger i=0;i<H.count;i++){ CGFloat hh=[l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0]].size.height;
        if (hh!=prev){ if (run>1) [m appendFormat:@"(x%d) ",run]; [m appendFormat:@"%g ",hh]; prev=hh; run=1;} else run++; }
    if (run>1) [m appendFormat:@"(x%d)",run];
    printf("%-34s est=%g viewH=%g contentH=%g  sizes: %s\n",name,est,viewH,cv.contentSize.height,m.UTF8String);
}
static NSArray *seq(int n, double (^f)(int)){ NSMutableArray *a=[NSMutableArray array]; for(int i=0;i<n;i++)[a addObject:@(f(i))]; return a; }
int main(){@autoreleasepool{[UIApplication sharedApplication];
 run("uniform 100", seq(30,^double(int i){return 100;}), 40, 120);
 run("uniform 100, est 200", seq(30,^double(int i){return 100;}), 200, 120);
 run("ramp 30+2i", seq(30,^double(int i){return 30+2*i;}), 40, 120);
 run("ramp 30+2i tall view", seq(30,^double(int i){return 30+2*i;}), 40, 400);
 run("alternating 20/80", seq(30,^double(int i){return i%2?80:20;}), 40, 160);
 run("single item", seq(1,^double(int i){return 77;}), 40, 120);
 run("all fit (3 items)", seq(3,^double(int i){return 20+10*i;}), 40, 400);
}return 0;}
