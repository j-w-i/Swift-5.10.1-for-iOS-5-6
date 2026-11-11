// Prints every item frame and the content size for a sweep of fixed-size flow layouts, so two builds of
// PST can be compared byte for byte (the output must not change when the layout code is optimised).
#import <UIKit/UIKit.h>
#import "PSTCollectionView.h"
@interface Src : NSObject<PSTCollectionViewDataSource> @property(nonatomic) NSInteger sections, items; @end
@implementation Src
- (NSInteger)numberOfSectionsInCollectionView:(PSTCollectionView *)cv { return self.sections; }
- (NSInteger)collectionView:(PSTCollectionView *)cv numberOfItemsInSection:(NSInteger)s { return self.items + s * 3; }
- (PSTCollectionViewCell *)collectionView:(PSTCollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
@end
int main(void) { @autoreleasepool { [UIApplication sharedApplication];
    NSArray *widths = @[@320, @317, @300, @250, @97, @45];
    int configs = 0;
    for (int horizontal = 0; horizontal < 2; horizontal++)
    for (NSNumber *w in widths)
    for (int itemW = 20; itemW <= 130; itemW += 37)
    for (int spacing = 0; spacing <= 9; spacing += 4)
    for (int items = 0; items <= 41; items += (items < 3 ? 1 : 19)) {
        Src *src = [Src new]; src.sections = 2; src.items = items;
        PSTCollectionViewFlowLayout *l = [PSTCollectionViewFlowLayout new];
        l.scrollDirection = horizontal ? PSTCollectionViewScrollDirectionHorizontal : PSTCollectionViewScrollDirectionVertical;
        l.itemSize = CGSizeMake(itemW, 31 + itemW % 7); l.minimumInteritemSpacing = spacing; l.minimumLineSpacing = spacing + 1;
        l.sectionInset = UIEdgeInsetsMake(3, 5 + spacing, 4, 6);
        CGFloat e = [w floatValue];
        PSTCollectionView *cv = [[PSTCollectionView alloc] initWithFrame:horizontal ? CGRectMake(0,0,200,e) : CGRectMake(0,0,e,300) collectionViewLayout:l];
        [cv registerClass:[PSTCollectionViewCell class] forCellWithReuseIdentifier:@"c"]; cv.dataSource = src; [cv layoutIfNeeded];
        printf("cfg h=%d dim=%g item=%dx%g sp=%d n=%d content=%s\n", horizontal, e, itemW, (double)(31 + itemW % 7), spacing, items, [NSStringFromCGSize(l.collectionViewContentSize) UTF8String]);
        for (NSInteger sec = 0; sec < 2; sec++) for (NSInteger i = 0; i < items + sec * 3; i++)
            printf("%ld.%ld %s\n", (long)sec, (long)i, [NSStringFromCGRect([l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForRow:i inSection:sec]].frame) UTF8String]);
        configs++;
    }
    fprintf(stderr, "%d configurations\n", configs); } return 0; }
