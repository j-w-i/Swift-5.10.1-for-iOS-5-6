// Differential check of PSTCollectionViewFlowLayout layoutAttributesForElementsInRect: against a
// brute-force reference computed from layoutAttributesForItemAtIndexPath: and the supplementary accessors.
#import <UIKit/UIKit.h>
#import "PSTCollectionView.h"
@interface Src : NSObject<PSTCollectionViewDataSource, PSTCollectionViewDelegateFlowLayout>
@property(nonatomic) NSInteger sections; @property(nonatomic) NSInteger items; @property(nonatomic) BOOL variable;
@end
@implementation Src
- (NSInteger)numberOfSectionsInCollectionView:(PSTCollectionView *)cv { return self.sections; }
- (NSInteger)collectionView:(PSTCollectionView *)cv numberOfItemsInSection:(NSInteger)s { return self.items + s; }
- (PSTCollectionViewCell *)collectionView:(PSTCollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
- (CGSize)collectionView:(PSTCollectionView *)cv layout:(PSTCollectionViewLayout *)l sizeForItemAtIndexPath:(NSIndexPath *)p {
    return self.variable ? CGSizeMake(40 + (p.row * 7) % 50, 20 + (p.row * 13) % 45) : CGSizeMake(60, 40); }
@end
@interface FixedSource : Src @end
@implementation FixedSource
- (BOOL)respondsToSelector:(SEL)a { if (a == @selector(collectionView:layout:sizeForItemAtIndexPath:)) return NO; return [super respondsToSelector:a]; }
@end
static NSString *key(PSTCollectionViewLayoutAttributes *a) { return [NSString stringWithFormat:@"%ld|%@|%ld.%ld|%@", (long)a.representedElementCategory, a.representedElementKind ?: @"", (long)a.indexPath.section, (long)a.indexPath.row, NSStringFromCGRect(a.frame)]; }
static int failures, checks;
static void run(const char *name, BOOL horizontal, BOOL variable, NSInteger sections, NSInteger items, BOOL supplementary) {
    Src *src = variable ? [Src new] : [FixedSource new]; src.sections = sections; src.items = items; src.variable = variable;
    PSTCollectionViewFlowLayout *l = [PSTCollectionViewFlowLayout new];
    l.scrollDirection = horizontal ? PSTCollectionViewScrollDirectionHorizontal : PSTCollectionViewScrollDirectionVertical;
    l.itemSize = CGSizeMake(60, 40); l.minimumLineSpacing = 3; l.minimumInteritemSpacing = 4; l.sectionInset = UIEdgeInsetsMake(5, 6, 7, 8);
    if (supplementary) { l.headerReferenceSize = CGSizeMake(50, 22); l.footerReferenceSize = CGSizeMake(50, 18); }
    PSTCollectionView *cv = [[PSTCollectionView alloc] initWithFrame:CGRectMake(0, 0, 320, 480) collectionViewLayout:l];
    [cv registerClass:[PSTCollectionViewCell class] forCellWithReuseIdentifier:@"c"]; cv.dataSource = src; cv.delegate = src; [cv layoutIfNeeded];
    CGSize content = l.collectionViewContentSize; int bad = 0, n = 0;
    // reference: every item and every supplementary view, filtered by intersection
    NSMutableDictionary *all = [NSMutableDictionary dictionary];
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger count = items + s;
        for (NSInteger i = 0; i < count; i++) { PSTCollectionViewLayoutAttributes *a = [l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForRow:i inSection:s]]; [all setObject:a forKey:key(a)]; }
        if (supplementary) for (NSString *k in @[PSTCollectionElementKindSectionHeader, PSTCollectionElementKindSectionFooter]) {
            PSTCollectionViewLayoutAttributes *a = [l layoutAttributesForSupplementaryViewOfKind:k atIndexPath:[NSIndexPath indexPathForRow:0 inSection:s]]; if (a) [all setObject:a forKey:key(a)]; }
    }
    CGFloat span = horizontal ? content.width : content.height;
    for (CGFloat pos = -100; pos < span + 100; pos += 37.3) {
        for (CGFloat extent = 1; extent <= 700; extent = extent < 50 ? extent * 7 : extent * 2.7) {
            CGRect rect = horizontal ? CGRectMake(pos, 0, extent, 480) : CGRectMake(0, pos, 320, extent);
            NSMutableSet *want = [NSMutableSet set];
            for (NSString *k in all) { PSTCollectionViewLayoutAttributes *a = [all objectForKey:k]; if (CGRectIntersectsRect(a.frame, rect)) [want addObject:k]; }
            NSMutableSet *got = [NSMutableSet set]; for (PSTCollectionViewLayoutAttributes *a in [l layoutAttributesForElementsInRect:rect]) [got addObject:key(a)];
            n++; if (![got isEqualToSet:want]) { if (bad++ < 3) { NSMutableSet *miss = [want mutableCopy]; [miss minusSet:got]; NSMutableSet *extra = [got mutableCopy]; [extra minusSet:want]; fprintf(stderr, "  MISMATCH %s rect=%s missing=%lu extra=%lu e.g. %s\n", name, [NSStringFromCGRect(rect) UTF8String], (unsigned long)miss.count, (unsigned long)extra.count, [[(miss.anyObject ?: extra.anyObject) description] UTF8String]); } }
        }
    }
    checks += n; failures += bad; printf("%-44s %5d rects, %d mismatches\n", name, n, bad);
}
int main(void) { @autoreleasepool { [UIApplication sharedApplication];
    for (int h = 0; h < 2; h++) for (int v = 0; v < 2; v++) for (int sup = 0; sup < 2; sup++) {
        char nm[96]; snprintf(nm, sizeof nm, "%s %s sections=3 %s", h ? "horizontal" : "vertical", v ? "variable" : "fixed", sup ? "+header/footer" : "");
        run(nm, h, v, 3, 90, sup); }
    run("vertical fixed 1 section 1 item", NO, NO, 1, 1, NO); run("vertical variable 1 section 7 items", NO, YES, 1, 7, YES); run("vertical fixed 6 sections 40 items +hf", NO, NO, 6, 40, YES);
    printf("%d checks, %d failures\n", checks, failures); return failures ? 1 : 0; } }
