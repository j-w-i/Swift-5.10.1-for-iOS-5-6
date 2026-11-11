#!/usr/bin/env python3
"""Generate an isolated compact-range prototype. NEVER edits the vendor originals.
Usage: prototype-selfsizing-ranges.py PST_SOURCE NEW_COPY [changed-only|all-reports]
       [none|one|two|half] [frame|estimate] [top|center] [raw|pixel] [distance|index|column]
This is a cache-response experiment, not a shipping implementation or parity claim.
The copy supports the simulator sizing probes; sibling backport projects/device packaging
are deliberately not copied or installed.
"""
import pathlib
import shutil
import sys

src, out = (pathlib.Path(p).resolve() for p in sys.argv[1:3])
mode = sys.argv[3] if len(sys.argv) > 3 else 'changed-only'
schedule = sys.argv[4] if len(sys.argv) > 4 else 'none'
stability = sys.argv[5] if len(sys.argv) > 5 else 'frame'
row_alignment = sys.argv[6] if len(sys.argv) > 6 else 'top'
rounding = sys.argv[7] if len(sys.argv) > 7 else 'raw'
order = sys.argv[8] if len(sys.argv) > 8 else 'distance'
if (mode not in ('changed-only', 'all-reports') or schedule not in ('none', 'one', 'two', 'half')
        or stability not in ('frame', 'estimate') or row_alignment not in ('top', 'center') or rounding not in ('raw', 'pixel') or order not in ('distance', 'index', 'column')
        or out.exists() or out.is_relative_to(src)):
    raise SystemExit('Use a new output outside the vendor source and documented experiment modes')
out.mkdir()
for path in src.iterdir():
    if path.is_file() and path.suffix in ('.h', '.m'):
        shutil.copy2(path, out / path.name)
shutil.copytree(src / 'tests', out / 'tests')
p = out / 'PSTCollectionViewFlowLayout.m'
text = p.read_text()
def replace(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit('Source changed; expected exactly one: ' + old)
    text = text.replace(old, new, 1)

replace('@implementation PSTCollectionViewFlowLayout {', '''
// EXPERIMENT ONLY: contiguous breakpoints, not one object per unmeasured item.
typedef struct { NSInteger section, item; CGSize size; } PSTPrototypeProposalRun;
static BOOL PSTPrototypeRunBefore(PSTPrototypeProposalRun r, NSInteger section, NSInteger item) {
    return r.section < section || (r.section == section && r.item < item);
}
@interface PSTCollectionViewFlowLayout (PrototypeRanges)
- (CGSize)pstPrototypeProposalAtIndexPath:(NSIndexPath *)path;
- (CGSize)pstPrototypeProposalAtSection:(NSInteger)section item:(NSInteger)item;
- (void)pstPrototypeApplyPending;
- (NSUInteger)pstPrototypeRangeCount;
@end
@implementation PSTCollectionViewFlowLayout {
    NSMutableData *_pstPrototypeRuns;
    NSUInteger _pstPrototypeRunCount;
    NSIndexPath *_pstPrototypePending;''')
replace('    if (!_pstPreservingStableMeasurements) [_pstStableMeasuredFrames removeAllObjects];', '''    if (!_pstPreservingStableMeasurements) {
        [_pstStableMeasuredFrames removeAllObjects];
        [_pstPrototypeRuns setLength:0]; _pstPrototypeRunCount = 0; _pstPrototypePending = nil;
    }''')
replace('    _pstMeasuredSizeSum = CGSizeZero; _pstMeasuredSizeCount = 0;', '''    _pstMeasuredSizeSum = CGSizeZero; _pstMeasuredSizeCount = 0;
    [_pstPrototypeRuns setLength:0]; _pstPrototypeRunCount = 0; _pstPrototypePending = nil;''')
replace("/// The layout's current size for an item: what its cell last reported, else the estimate.", '''
- (NSUInteger)pstPrototypeRangeCount { return _pstPrototypeRunCount; }

- (CGSize)pstPrototypeProposalAtIndexPath:(NSIndexPath *)path {
    return [self pstPrototypeProposalAtSection:path.section item:path.item];
}
- (CGSize)pstPrototypeProposalAtSection:(NSInteger)section item:(NSInteger)item {
    if (!_pstPrototypeRunCount) return _pstProposalAtLayout;
    const PSTPrototypeProposalRun *runs = _pstPrototypeRuns.bytes;
    NSUInteger lo = 0, hi = _pstPrototypeRunCount;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        BOOL atOrBefore = PSTPrototypeRunBefore(runs[mid], section, item) ||
            (runs[mid].section == section && runs[mid].item == item);
        if (atOrBefore) lo = mid + 1; else hi = mid;
    }
    return lo ? runs[lo - 1].size : _pstProposalAtLayout;
}

- (void)pstPrototypeApplyPending {
    NSIndexPath *path = _pstPrototypePending; _pstPrototypePending = nil;
    if (!path || !_pstMeasuredSizeCount || [self pstDelegateProvidesSizes]) return;
    NSInteger section = path.section, item = path.item, first = 0;
    if (section >= 0 && section < (NSInteger)_data.sections.count) {
        PSTGridLayoutSection *s = [_data.sections objectAtIndex:(NSUInteger)section];
        if (item >= 0 && item < (NSInteger)s.items.count) {
            PSTGridLayoutItem *i = [s.items objectAtIndex:(NSUInteger)item];
            PSTGridLayoutRow *row = i.rowObject;
            NSInteger previous = MAX(0, row.index - 1);
            if (row && previous < [s rowCount]) first = [s rowAtIndex:previous].firstItemIndex;
        }
    }
    if (!_pstPrototypeRuns) _pstPrototypeRuns = [NSMutableData data];
    if (!_pstPrototypeRunCount) {
        PSTPrototypeProposalRun seed = {0, 0, _pstProposalAtLayout};
        [_pstPrototypeRuns appendBytes:&seed length:sizeof seed]; _pstPrototypeRunCount = 1;
    }
    CGSize mean = CGSizeMake(_pstMeasuredSizeSum.width / (CGFloat)_pstMeasuredSizeCount,
                             _pstMeasuredSizeSum.height / (CGFloat)_pstMeasuredSizeCount);
    const PSTPrototypeProposalRun *runs = _pstPrototypeRuns.bytes;
    NSUInteger keep = 0;
    while (keep < _pstPrototypeRunCount && PSTPrototypeRunBefore(runs[keep], section, first)) keep++;
    BOOL coalesce = keep && CGSizeEqualToSize(runs[keep - 1].size, mean);
    [_pstPrototypeRuns setLength:keep * sizeof(PSTPrototypeProposalRun)];
    _pstPrototypeRunCount = keep;
    if (!coalesce) {
        PSTPrototypeProposalRun next = {section, first, mean};
        [_pstPrototypeRuns appendBytes:&next length:sizeof next]; _pstPrototypeRunCount++;
    }
}

/// The layout's current size for an item: what its cell last reported, else the estimate.''')
# The per-item proposal now lives in the seed loop; pstUnmeasuredProposal stays the frozen mean for first layout.
replace('    return [self pstUnmeasuredProposal];\n}\n\n/// The size proposed',
        '    if (_pstMeasuredSizeCount) return [self pstPrototypeProposalAtIndexPath:indexPath];\n    return [self pstUnmeasuredProposal];\n}\n\n/// The size proposed')
replace('                for (NSInteger item = 0; item < numberOfItems; item++)\n                    [layoutSection addItem].itemFrame = (CGRect){.size=proposal};',
        '                const BOOL prototypeRanges = _pstMeasuredSizeCount && _pstPrototypeRunCount;\n                for (NSInteger item = 0; item < numberOfItems; item++)\n                    [layoutSection addItem].itemFrame = (CGRect){.size=prototypeRanges ? [self pstPrototypeProposalAtSection:(NSInteger)section item:item] : proposal};')
replace('    [self pstAccumulateMeasuredSize:size replacing:wasMeasured ? &old : NULL];\n    return YES;', '''    [self pstAccumulateMeasuredSize:size replacing:wasMeasured ? &old : NULL];
    if (!_pstPrototypePending || [indexPath compare:_pstPrototypePending] == NSOrderedAscending)
        _pstPrototypePending = indexPath;
    return YES;''')
replace('- (void)pstInvalidateForPreferredSizeChanges {\n    BOOL previous',
        '- (void)pstInvalidateForPreferredSizeChanges {\n    [self pstPrototypeApplyPending];\n    BOOL previous')
replace('    if (_pstMeasuredSizeCount) _pstProposalAtLayout = CGSizeMake(_pstMeasuredSizeSum.width / (CGFloat)_pstMeasuredSizeCount, _pstMeasuredSizeSum.height / (CGFloat)_pstMeasuredSizeCount);', '''    if (_pstMeasuredSizeCount) _pstProposalAtLayout = CGSizeMake(_pstMeasuredSizeSum.width / (CGFloat)_pstMeasuredSizeCount, _pstMeasuredSizeSum.height / (CGFloat)_pstMeasuredSizeCount);
    else _pstProposalAtLayout = CGSizeEqualToSize(_estimatedItemSize, CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)) ? CGSizeMake(50, 50) : _estimatedItemSize;''')
if mode == 'changed-only':
    replace('''        [_pstMeasuredItemSizes setObject:[NSValue valueWithCGSize:size] forKey:indexPath];
        // A delegate seed is stored as a measurement but is not a cell report.
        if (![self pstDelegateProvidesSizes]) [self pstAccumulateMeasuredSize:size replacing:wasMeasured3 ? &old3 : NULL];''', '''        // A new unchanged proposal remains an estimate in this prototype.
        if (wasMeasured3 || [self pstDelegateProvidesSizes]) {
            [_pstMeasuredItemSizes setObject:[NSValue valueWithCGSize:size] forKey:indexPath];
            if (![self pstDelegateProvidesSizes]) [self pstAccumulateMeasuredSize:size replacing:&old3];
        }''')
if stability == 'estimate':
    replace('    return confirmed && CGRectEqualToRect([confirmed CGRectValue], frame);',
            '    return confirmed && (![_pstMeasuredItemSizes objectForKey:indexPath] || CGRectEqualToRect([confirmed CGRectValue], frame));')
p.write_text(text)
if schedule != 'none':
    p = out / 'PSTCollectionView.m'
    text = p.read_text()
    replace('    int _pstSelfSizingRounds;', '''    int _pstSelfSizingRounds;
    BOOL _pstPrototypeMeasuring, _pstPrototypeScheduleBudgetHit;
    NSUInteger _pstPrototypeSchedulePasses;''')
    start = text.index('- (void)pstMeasureSelfSizingCells {')
    end = text.index('// fetches a cell from the dataSource', start)
    body = '''- (NSUInteger)pstPrototypeSchedulePasses { return _pstPrototypeSchedulePasses; }
- (BOOL)pstPrototypeScheduleBudgetHit { return _pstPrototypeScheduleBudgetHit; }
- (void)pstMeasureSelfSizingCells {
    if (_pstPrototypeMeasuring || ![_layout isKindOfClass:[PSTCollectionViewFlowLayout class]]) return;
    PSTCollectionViewFlowLayout *flow = (id)_layout;
    if (![flow pstUsesSelfSizing]) return;
    _pstPrototypeMeasuring = YES;
    NSMutableDictionary *attempts = [NSMutableDictionary dictionary];
    BOOL settled = NO;
    @try {
        for (NSUInteger pass = 0; pass < 256; pass++) {
            _pstPrototypeSchedulePasses++;
            NSMutableArray *fresh = [NSMutableArray array], *confirm = [NSMutableArray array];
            for (PSTCollectionViewItemKey *key in [_allVisibleViewsDict allKeys]) {
                if (key.type != PSTCollectionViewItemTypeCell) continue;
                PSTCollectionReusableView *cell = [_allVisibleViewsDict objectForKey:key];
                PSTCollectionViewLayoutAttributes *a = cell.layoutAttributes;
                if (!a || [flow pstHasStableMeasuredSizeForItemAtIndexPath:key.indexPath proposedFrame:a.frame]) continue;
                NSUInteger count = [[attempts objectForKey:key.indexPath] unsignedIntegerValue];
                if (count >= 6) { _pstPrototypeScheduleBudgetHit = YES; continue; }
                [(count ? confirm : fresh) addObject:key];
            }
            if (!fresh.count && !confirm.count) { settled = YES; break; }
            CGPoint origin = self.bounds.origin;
            [fresh sortUsingComparator:^NSComparisonResult(PSTCollectionViewItemKey *a, PSTCollectionViewItemKey *b) {
                CGPoint x = ((PSTCollectionReusableView *)[_allVisibleViewsDict objectForKey:a]).layoutAttributes.frame.origin;
                CGPoint y = ((PSTCollectionReusableView *)[_allVisibleViewsDict objectForKey:b]).layoutAttributes.frame.origin;
                CGFloat dx=x.x-origin.x,dy=x.y-origin.y,ex=y.x-origin.x,ey=y.y-origin.y;
                CGFloat da=dx*dx+dy*dy,db=ex*ex+ey*ey;
                return da<db?NSOrderedAscending:da>db?NSOrderedDescending:[a.indexPath compare:b.indexPath];
            }];
            [confirm sortUsingComparator:^NSComparisonResult(PSTCollectionViewItemKey *a, PSTCollectionViewItemKey *b) { return [a.indexPath compare:b.indexPath]; }];
            NSArray *chosen = fresh.count ? fresh : confirm;
            NSUInteger limit = chosen.count;
            if (fresh.count) limit = PROTOTYPE_LIMIT;
            BOOL changed = NO;
            for (NSUInteger index = 0; index < limit; index++) {
                PSTCollectionViewItemKey *key = [chosen objectAtIndex:index];
                PSTCollectionReusableView *cell = [_allVisibleViewsDict objectForKey:key];
                PSTCollectionViewLayoutAttributes *proposed = cell.layoutAttributes;
                if (!cell || !proposed) continue;
                NSUInteger count = [[attempts objectForKey:key.indexPath] unsignedIntegerValue];
                [attempts setObject:@(count+1) forKey:key.indexPath];
                PSTCollectionViewLayoutAttributes *preferred = [cell preferredLayoutAttributesFittingAttributes:proposed];
                if ([flow pstRecordPreferredSize:preferred?preferred.size:proposed.size forItemAtIndexPath:key.indexPath proposedFrame:proposed.frame]) changed = YES;
            }
            if (changed) {
                [flow pstInvalidateForPreferredSizeChanges];
                [_collectionViewData validateLayoutInRect:self.bounds];
                [self updateVisibleCellsNow:YES]; // reentrant measurement is suppressed by the scoped guard
                CGSize size = [_collectionViewData collectionViewContentRect].size;
                if (!CGSizeEqualToSize(self.contentSize,size)) self.contentSize=size;
            }
        }
        if (!settled) _pstPrototypeScheduleBudgetHit=YES;
    } @finally { _pstPrototypeMeasuring=NO; }
}

'''
    limit = {'one': '1', 'two': 'MIN((NSUInteger)2,fresh.count)', 'half': 'MAX((NSUInteger)1,fresh.count/2)'}[schedule]
    body = body.replace('PROTOTYPE_LIMIT', limit)
    if order == 'column':
        a = body.index('[fresh sortUsingComparator:')
        b = body.index('[confirm sortUsingComparator:')
        body = body[:a] + '''[fresh sortUsingComparator:^NSComparisonResult(PSTCollectionViewItemKey *a, PSTCollectionViewItemKey *b) {
                CGPoint x = ((PSTCollectionReusableView *)[_allVisibleViewsDict objectForKey:a]).layoutAttributes.frame.origin;
                CGPoint y = ((PSTCollectionReusableView *)[_allVisibleViewsDict objectForKey:b]).layoutAttributes.frame.origin;
                if (x.x != y.x) return x.x < y.x ? NSOrderedAscending : NSOrderedDescending;
                if (x.y != y.y) return x.y < y.y ? NSOrderedAscending : NSOrderedDescending;
                return [a.indexPath compare:b.indexPath];
            }];
            ''' + body[b:]
    if order == 'index':
        a = body.index('[fresh sortUsingComparator:')
        b = body.index('[confirm sortUsingComparator:')
        body = body[:a] + '[fresh sortUsingComparator:^NSComparisonResult(PSTCollectionViewItemKey *a, PSTCollectionViewItemKey *b) { return [a.indexPath compare:b.indexPath]; }];\n            ' + body[b:]
    text = text[:start] + body + text[end:]
    p.write_text(text)
if row_alignment == 'center':
    p = out / 'PSTGridLayoutRow.m'
    text = p.read_text()
    replace('        // calculate row frame as union of all items', '''        CGFloat prototypeCrossMax = isHorizontal ? self.section.itemSize.width : self.section.itemSize.height;
        if (!self.fixedItemSize) {
            prototypeCrossMax = 0;
            for (PSTGridLayoutItem *i in self.items)
                prototypeCrossMax = MAX(prototypeCrossMax, isHorizontal ? i.itemFrame.size.width : i.itemFrame.size.height);
        }
        // calculate row frame as union of all items''')
    replace('                itemFrame.origin.y = itemOffset.y;',
            '                itemFrame.origin.x = (prototypeCrossMax - itemFrame.size.width) / 2;\n                itemFrame.origin.y = itemOffset.y;')
    replace('                itemFrame.origin.x = itemOffset.x;',
            '                itemFrame.origin.y = (prototypeCrossMax - itemFrame.size.height) / 2;\n                itemFrame.origin.x = itemOffset.x;')
    p.write_text(text)
if rounding == 'pixel':
    p = out / 'PSTCollectionViewFlowLayout.m'
    text = p.read_text()
    replace('// EXPERIMENT ONLY: contiguous breakpoints, not one object per unmeasured item.', '''#include <math.h>
static CGRect PSTPrototypePixelOrigin(CGRect r, CGFloat scale) {
    r.origin.x = round(r.origin.x * scale) / scale;
    r.origin.y = round(r.origin.y * scale) / scale;
    return r; // preferred sizes remain fractional; only origins are quantised
}
// EXPERIMENT ONLY: contiguous breakpoints, not one object per unmeasured item.''')
    replace('    NSMutableArray *layoutAttributesArray = [NSMutableArray array];', '''    BOOL prototypePixel = [self pstUsesSelfSizing];
    CGFloat prototypeScale = [UIScreen mainScreen].scale;
    CGRect prototypeBroad = prototypePixel ? CGRectInset(rect, -1/prototypeScale, -1/prototypeScale) : rect;
    NSMutableArray *layoutAttributesArray = [NSMutableArray array];''')
    replace('CGRectIntersectsRect(section.frame, rect)', 'CGRectIntersectsRect(section.frame, prototypeBroad)')
    replace('CGFloat pstRectMin = pstHorizontal ? CGRectGetMinX(rect) : CGRectGetMinY(rect);',
            'CGFloat pstRectMin = pstHorizontal ? CGRectGetMinX(prototypeBroad) : CGRectGetMinY(prototypeBroad);')
    replace('CGFloat pstRectMax = pstHorizontal ? CGRectGetMaxX(rect) : CGRectGetMaxY(rect);',
            'CGFloat pstRectMax = pstHorizontal ? CGRectGetMaxX(prototypeBroad) : CGRectGetMaxY(prototypeBroad);')
    replace('CGRectIntersectsRect(normalizedRowFrame, rect)', 'CGRectIntersectsRect(normalizedRowFrame, prototypeBroad)')
    replace('                        if (CGRectIntersectsRect(normalisedItemFrame, rect)) {', '''                        if (prototypePixel) normalisedItemFrame = PSTPrototypePixelOrigin(normalisedItemFrame, prototypeScale);
                        if (CGRectIntersectsRect(normalisedItemFrame, rect)) {''')
    replace('    layoutAttributes.frame = CGRectMake(normalizedRowFrame.origin.x + itemFrame.origin.x, normalizedRowFrame.origin.y + itemFrame.origin.y, itemFrame.size.width, itemFrame.size.height);', '''    CGRect prototypeFrame = CGRectMake(normalizedRowFrame.origin.x + itemFrame.origin.x, normalizedRowFrame.origin.y + itemFrame.origin.y, itemFrame.size.width, itemFrame.size.height);
    if ([self pstUsesSelfSizing]) prototypeFrame = PSTPrototypePixelOrigin(prototypeFrame, [UIScreen mainScreen].scale);
    layoutAttributes.frame = prototypeFrame;''')
    replace('    return _data.contentSize;', '''    CGSize result = _data.contentSize;
    return [self pstUsesSelfSizing] ? CGSizeMake(round(result.width), round(result.height)) : result;''')
    p.write_text(text)
print('Generated isolated compact-range prototype:', out, 'report mode:', mode, 'schedule:', schedule, 'stability:', stability, 'row alignment:', row_alignment, 'rounding:', rounding)
