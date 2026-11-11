#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewScrollPositionTop PSTCollectionViewScrollPositionTop
#endif
static NSMutableArray *g_log;
@interface C : UICollectionViewCell @property CGFloat h; @end
@implementation C
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)a { if (g_log) [g_log addObject:@(a.indexPath.item)]; UICollectionViewLayoutAttributes *r=[a copy]; r.size=CGSizeMake(a.size.width,self.h); return r; }
@end
@interface D : NSObject<UICollectionViewDataSource> @property NSMutableArray *h; @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return self.h.count; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { C *c=[cv dequeueReusableCellWithReuseIdentifier:@"u" forIndexPath:p]; c.h=[self.h[p.item] doubleValue]; return c; }
@end
static void probe(const char *name, BOOL warmup) {
    UICollectionViewFlowLayout *l=[UICollectionViewFlowLayout new]; l.estimatedItemSize=CGSizeMake(200,40); l.minimumLineSpacing=0;
    UICollectionView *cv=[[UICollectionView alloc] initWithFrame:CGRectMake(0,0,200,120) collectionViewLayout:l];
    [cv registerClass:[C class] forCellWithReuseIdentifier:@"u"];
    D *d=[D new]; d.h=[NSMutableArray array]; cv.dataSource=d;
    if (warmup) { for (int i=0;i<3;i++) [d.h addObject:@(30+i*20)]; [cv reloadData]; [cv layoutIfNeeded]; [d.h removeAllObjects]; }
    for (int i=0;i<40;i++) [d.h addObject:@(30+i*2)];
    g_log=[NSMutableArray array];
    [cv reloadData]; [cv layoutIfNeeded];
    printf("%s: queried after initial layout: %s\n",name,[[g_log componentsJoinedByString:@","] UTF8String]); [g_log removeAllObjects];
    @try {
        [cv scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:39 inSection:0] atScrollPosition:UICollectionViewScrollPositionTop animated:NO];
        [cv setNeedsLayout]; [cv layoutIfNeeded]; CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false); [cv layoutIfNeeded];
        UICollectionViewCell *cell=[cv cellForItemAtIndexPath:[NSIndexPath indexPathForItem:39 inSection:0]];
        printf("%s: queried during scroll: %s\n",name,[[g_log componentsJoinedByString:@","] UTF8String]);
        { NSMutableString *m=[NSMutableString string]; for(int i=0;i<40;i++){ CGFloat hh=[l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]].size.height; if (hh!=40) [m appendFormat:@"%d:%g ",i,hh]; } printf("%s: items not at estimate: %s\n",name,m.UTF8String); }
        printf("%s: cell39=%s offset=%g contentH=%g\n",name,cell?"visible":"NIL",cv.contentOffset.y,cv.contentSize.height);
    } @catch (NSException *e) { printf("%s: EXCEPTION %s\n",name,e.reason.UTF8String); }
}
int main(){@autoreleasepool{[UIApplication sharedApplication]; probe("fresh-no-warmup",NO); probe("after-3-item-reload",YES);}return 0;}
