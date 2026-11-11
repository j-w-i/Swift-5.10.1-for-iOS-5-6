#import <UIKit/UIKit.h>
static NSMutableSet *MEASURED;
@interface C : UICollectionViewCell @property CGFloat h; @property NSInteger idx; @end
@implementation C
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)a { [MEASURED addObject:@(a.indexPath.row)]; UICollectionViewLayoutAttributes *r=[a copy]; r.size=CGSizeMake(a.size.width,self.h); return r; }
@end
@interface D : NSObject<UICollectionViewDataSource> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 60; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { C *c=[cv dequeueReusableCellWithReuseIdentifier:@"u" forIndexPath:p]; c.h=30+2*p.row; return c; }
@end
static UICollectionViewFlowLayout *L; static UICollectionView *CV;
static void dump(const char *tag){
    NSMutableString *m=[NSMutableString string]; CGFloat prev=-1; int run=0, start=0;
    for (int i=0;i<60;i++){ CGFloat hh=[L layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0]].size.height;
        BOOL meas=[MEASURED containsObject:@(i)];
        if (meas) { if (run) [m appendFormat:@"[%d-%d]=%.2f ",start,start+run-1,prev]; run=0; prev=-1; [m appendFormat:@"%d:%g* ",i,hh]; continue; }
        if (hh!=prev){ if (run) [m appendFormat:@"[%d-%d]=%.2f ",start,start+run-1,prev]; prev=hh; start=i; run=1;} else run++; }
    if (run) [m appendFormat:@"[%d-%d]=%.2f",start,start+run-1,prev];
    printf("%-22s contentH=%-7.1f off=%-6.0f %s\n",tag,CV.contentSize.height,CV.contentOffset.y,m.UTF8String);
}
int main(){@autoreleasepool{[UIApplication sharedApplication]; MEASURED=[NSMutableSet set];
 L=[UICollectionViewFlowLayout new]; L.estimatedItemSize=CGSizeMake(200,40); L.minimumLineSpacing=0;
 CV=[[UICollectionView alloc] initWithFrame:CGRectMake(0,0,200,120) collectionViewLayout:L];
 [CV registerClass:[C class] forCellWithReuseIdentifier:@"u"]; D *d=[D new]; CV.dataSource=d;
 [CV reloadData]; [CV layoutIfNeeded]; CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false); [CV layoutIfNeeded]; dump("initial");
 for (int step=1; step<=4; step++){ CV.contentOffset=CGPointMake(0,step*300); [CV layoutIfNeeded]; CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false); [CV layoutIfNeeded]; char t[32]; snprintf(t,32,"scrolled to y=%d",step*300); dump(t); }
}return 0;}
