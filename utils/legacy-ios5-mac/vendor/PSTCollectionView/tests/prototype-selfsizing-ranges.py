#!/usr/bin/env python3
"""Generate an isolated compact-range prototype. NEVER edits the vendor originals.
Usage: prototype-selfsizing-ranges.py PST_SOURCE NEW_COPY [changed-only|all-reports]
This is a cache-response experiment, not a shipping implementation or parity claim.
The copy supports the simulator sizing probes; sibling backport projects/device packaging
are deliberately not copied or installed.
"""
import pathlib
import shutil
import sys

src, out = (pathlib.Path(p).resolve() for p in sys.argv[1:3])
mode = sys.argv[3] if len(sys.argv) > 3 else 'changed-only'
if mode not in ('changed-only', 'all-reports') or out.exists() or out.is_relative_to(src):
    raise SystemExit('Use a new output outside the vendor source; mode changed-only|all-reports')
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
    if (!_pstPrototypeRunCount) return _pstProposalAtLayout;
    const PSTPrototypeProposalRun *runs = _pstPrototypeRuns.bytes;
    NSInteger section = path.section, item = path.item;
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
replace('    if (_pstMeasuredSizeCount) return _pstProposalAtLayout;',
        '    if (_pstMeasuredSizeCount) return [self pstPrototypeProposalAtIndexPath:indexPath];')
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
p.write_text(text)
print('Generated isolated compact-range prototype:', out, 'report mode:', mode)
