// Reuse hiding, native UIKit vs PST. Compiled twice by run-reuse-hidden-test.sh (native, and -DTEST_PST=1).
//
// UIKit 6.1 (ios61-ref/ghidra/collection-scroll-output): a queued view is hidden for reuse at the layer, with its own
// flag (-[UIView _setHiddenForReuse:]); -setHidden:NO does not reveal it; its -layoutSubviews is held back and
// replayed once when it is shown; -[UICollectionView _addControlledSubview:atZIndex:] shows it when it joins the
// visible set, after the data source configured it. The base -applyLayoutAttributes: is empty: geometry is applied
// by the private -_setLayoutAttributes:, so a subclass that does not call super is still positioned.
#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#endif

static NSMutableArray *LOG;

@interface RC : UICollectionViewCell @property int row; @property int layouts; @end
@implementation RC
- (void)layoutSubviews { [super layoutSubviews]; self.layouts++; }
// Deliberately no super: UIKit's base implementation is empty.
- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)attributes { }
@end

@interface D : NSObject <UICollectionViewDataSource> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 60; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p {
    RC *c = (RC *)[cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];
    [LOG addObject:[NSString stringWithFormat:@"cfi %ld hidden=%d attached=%d", (long)p.row, c.isHidden, c.superview == cv]];
    c.row = (int)p.row % 100; c.tag = 1000 + p.row;
    if (p.row == 13) c.hidden = YES;  // the app hides one cell itself
    return c;
}
@end

static NSArray *sortedVisible(UICollectionView *cv) {
    return [cv.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) { return a.tag < b.tag ? NSOrderedAscending : a.tag > b.tag ? NSOrderedDescending : NSOrderedSame; }];
}

int main(void) { @autoreleasepool {
    [UIApplication sharedApplication];
    LOG = [NSMutableArray array];
    UICollectionViewFlowLayout *l = [UICollectionViewFlowLayout new];
    l.itemSize = CGSizeMake(200, 50); l.minimumLineSpacing = 0;
    UICollectionView *cv = [[UICollectionView alloc] initWithFrame:CGRectMake(0, 0, 200, 200) collectionViewLayout:l];
    UIWindow *w = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 320, 480)]; [w addSubview:cv]; w.hidden = NO;
    [cv registerClass:[RC class] forCellWithReuseIdentifier:@"c"];
    D *d = [D new]; cv.dataSource = d; [cv layoutIfNeeded];

    for (UICollectionViewCell *c in sortedVisible(cv))
        printf("initial cell %ld frame=%s hidden=%d\n", (long)c.tag - 1000, NSStringFromCGRect(c.frame).UTF8String, c.isHidden);

    // Scroll far enough that the first cells are queued.
    cv.contentOffset = CGPointMake(0, 300); [cv layoutIfNeeded];
    NSMutableArray *queued = [NSMutableArray array];
    for (UIView *v in cv.subviews) if ([v isKindOfClass:[RC class]] && ![cv.visibleCells containsObject:v]) [queued addObject:v];
    [queued sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) { return a.tag < b.tag ? NSOrderedAscending : NSOrderedDescending; }];
    for (RC *q in queued) printf("queued cell %ld hidden=%d attached=%d\n", (long)q.tag - 1000, q.isHidden, q.superview == cv);

    // A queued cell asked to lay out: UIKit holds the pass back while it is queued.
    // Every queued cell is probed: the queue hands out its most recently queued one, which is not knowable here.
    for (RC *q in queued) { q.layouts = 0; [q setNeedsLayout]; [q layoutIfNeeded]; }
    [cv layoutIfNeeded];
    int whileQueued = 0; for (RC *q in queued) whileQueued += q.layouts;
    printf("queued cells: layoutSubviews while queued=%d\n", whileQueued);
    RC *probe = queued.firstObject;
    probe.hidden = NO;
    printf("queued probe after setHidden:NO hidden=%d\n", probe.isHidden);

    // Reuse it.
    [LOG removeAllObjects];
    cv.contentOffset = CGPointMake(0, 500); [cv layoutIfNeeded];
    for (NSString *line in LOG) printf("%s\n", line.UTF8String);
    for (UICollectionViewCell *c in sortedVisible(cv))
        printf("visible cell %ld frame=%s hidden=%d\n", (long)c.tag - 1000, NSStringFromCGRect(c.frame).UTF8String, c.isHidden);
    for (RC *q in queued) if ([cv.visibleCells containsObject:q])
        printf("reused cell now row %ld: layoutSubviews after it was shown=%d\n", (long)q.tag - 1000, q.layouts);
}}
