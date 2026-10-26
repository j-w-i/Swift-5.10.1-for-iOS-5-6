//
//  PSTCollectionViewData.m
//  PSPDFKit
//
//  Copyright (c) 2012-2013 Peter Steinberger. All rights reserved.
//

#import "PSTCollectionViewData.h"
#import "PSTCollectionView.h"
#import "PSTCollectionViewStats.h"

@interface PSTCollectionViewData () {
    CGRect _validLayoutRect;

    NSInteger _numItems;
    NSInteger _numSections;
    NSInteger *_sectionItemCounts;
    // Prefix sums of _sectionItemCounts: _sectionItemOffsets[i] is the global
    // index of the first item of section i, _sectionItemOffsets[_numSections] is
    // _numItems.  Replaces the O(section) linear scans that ran for every
    // globalIndexForItemAtIndexPath / numberOfItemsBeforeSection query.
    NSInteger *_sectionItemOffsets;
    // Reused backing store for the filtered per-pass attribute array; avoids
    // allocating and growing a fresh NSMutableArray on every scroll pass.
    NSMutableArray *_filteredLayoutAttributesStorage;
    NSUInteger _layoutAttributesGeneration;
//    id __strong* _globalItems; ///< _globalItems appears to be cached layoutAttributes. But adding that work in opens a can of worms, so deferring until later.

/*
 // At this point, I've no idea how _screenPageDict is structured. Looks like some optimization for layoutAttributesForElementsInRect.
 And why UICGPointKey? Isn't that doable with NSValue?

 "<UICGPointKey: 0x11432d40>" = "<NSMutableIndexSet: 0x11432c60>[number of indexes: 9 (in 1 ranges), indexes: (0-8)]";
 "<UICGPointKey: 0xb94bf60>" = "<NSMutableIndexSet: 0x18dea7e0>[number of indexes: 11 (in 2 ranges), indexes: (6-15 17)]";

 (lldb) p (CGPoint)[[[[[collectionView valueForKey:@"_collectionViewData"] valueForKey:@"_screenPageDict"] allKeys] objectAtIndex:0] point]
 (CGPoint) $11 = (x=15, y=159)
 (lldb) p (CGPoint)[[[[[collectionView valueForKey:@"_collectionViewData"] valueForKey:@"_screenPageDict"] allKeys] objectAtIndex:1] point]
 (CGPoint) $12 = (x=15, y=1128)

 // https://github.com/steipete/iOS6-Runtime-Headers/blob/master/UICGPointKey.h

 NSMutableDictionary *_screenPageDict;
 */

    // @steipete

    CGSize _contentSize;
    struct {
        unsigned int contentSizeIsValid:1;
        unsigned int itemCountsAreValid:1;
        unsigned int layoutIsPrepared:1;
    }_collectionViewDataFlags;
}
@property (nonatomic, unsafe_unretained) PSTCollectionView *collectionView;
@property (nonatomic, unsafe_unretained) PSTCollectionViewLayout *layout;
@property (nonatomic, strong) NSArray *cachedLayoutAttributes;

@end

@implementation PSTCollectionViewData

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSObject

- (id)initWithCollectionView:(PSTCollectionView *)collectionView layout:(PSTCollectionViewLayout *)layout {
    if ((self = [super init])) {
        _collectionView = collectionView;
        _layout = layout;
    }
    return self;
}

- (void)dealloc {
    free(_sectionItemCounts);
    free(_sectionItemOffsets);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p numItems:%ld numSections:%ld>", NSStringFromClass(self.class), self, (long)self.numberOfItems, (long)self.numberOfSections];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public

- (void)invalidate {
    _collectionViewDataFlags.itemCountsAreValid = NO;
    _collectionViewDataFlags.layoutIsPrepared = NO;
    _validLayoutRect = CGRectNull;  // don't set CGRectZero in case of _contentSize=CGSizeZero
}

- (CGRect)collectionViewContentRect {
    return (CGRect){.size=_contentSize};
}

- (void)validateLayoutInRect:(CGRect)rect {
    PSTCollectionViewStatsCountersStorage[PSTStatDataValidations]++;
    [self validateItemCounts];
    [self prepareToLoadData];

    // TODO: check if we need to fetch data from layout
    if (!CGRectEqualToRect(_validLayoutRect, rect)) {
        _validLayoutRect = rect;
        _layoutAttributesGeneration++;
        PSTCollectionViewStatsCountersStorage[PSTStatDataRefilters]++;
        PSTCollectionViewStatsCountersStorage[PSTStatElementScans]++;
        // we only want cell layoutAttributes & supplementaryView layoutAttributes
        // Filter with a loop: this runs on every layout-rect change (scroll, resize), and
        // allocating an NSPredicate plus a filtered copy each time is measurable on iOS 5 hardware.
        NSArray *allAttributes = [self.layout layoutAttributesForElementsInRect:rect];
        if (!_filteredLayoutAttributesStorage) {
            _filteredLayoutAttributesStorage = [NSMutableArray arrayWithCapacity:allAttributes.count];
        } else {
            [_filteredLayoutAttributesStorage removeAllObjects];
        }
        for (PSTCollectionViewLayoutAttributes *attributes in allAttributes) {
            if ([attributes isKindOfClass:PSTCollectionViewLayoutAttributes.class] &&
                ([attributes isCell] || [attributes isSupplementaryView] || [attributes isDecorationView])) {
                [_filteredLayoutAttributesStorage addObject:attributes];
            }
        }
        self.cachedLayoutAttributes = (NSArray *)_filteredLayoutAttributesStorage;
    }
}

- (NSInteger)numberOfItems {
    [self validateItemCounts];
    return _numItems;
}

- (NSInteger)numberOfItemsBeforeSection:(NSInteger)section {
    [self validateItemCounts];

    NSAssert(section < _numSections, @"request for number of items in section %ld when there are only %ld sections in the collection view", (long)section, (long)_numSections);

    if (section <= 0) {
        // Matches the old loop's behaviour for section 0 and for the
        // NS_BLOCK_ASSERTIONS case where a negative section was tolerated.
        return 0;
    }
    // Constant-time lookup instead of the previous per-section linear scan.
    return _sectionItemOffsets[section];
}

- (NSInteger)numberOfItemsInSection:(NSInteger)section {
    [self validateItemCounts];
    if (section >= _numSections || section < 0) {
        // In case of inconsistency returns the 'less harmful' amount of items. Throwing an exception here potentially
        // causes exceptions when data is consistent. Deleting sections is one of the parts sensitive to this.
        // All checks via assertions are done on CollectionView animation methods, specially 'endAnimations'.
        return 0;
        //@throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"Section %d out of range: 0...%d", section, _numSections] userInfo:nil];
    }

    NSInteger numberOfItemsInSection = 0;
    if (_sectionItemCounts) {
        numberOfItemsInSection = _sectionItemCounts[section];
    }
    return numberOfItemsInSection;
}

- (NSInteger)numberOfSections {
    [self validateItemCounts];
    return _numSections;
}

- (CGRect)rectForItemAtIndexPath:(NSIndexPath *)indexPath {
    return CGRectZero;
}

- (NSIndexPath *)indexPathForItemAtGlobalIndex:(NSInteger)index {
    [self validateItemCounts];

    NSAssert(index < _numItems, @"request for index path for global index %ld when there are only %ld items in the collection view", (long)index, (long)_numItems);

    // Binary search the prefix sums instead of walking every section.  We want
    // the last section whose first global index is <= index.
    NSInteger low = 0;
    NSInteger high = _numSections - 1;
    NSInteger section = 0;
    while (low <= high) {
        NSInteger mid = low + (high - low) / 2;
        if (_sectionItemOffsets[mid] <= index) {
            section = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }

    NSInteger item = index - _sectionItemOffsets[section];

    return [NSIndexPath indexPathForRow:item inSection:section];
}

- (NSUInteger)globalIndexForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger offset = [self numberOfItemsBeforeSection:indexPath.section] + indexPath.row;
    return (NSUInteger)offset;
}

- (BOOL)layoutIsPrepared {
    return _collectionViewDataFlags.layoutIsPrepared;
}

- (void)setLayoutIsPrepared:(BOOL)layoutIsPrepared {
    _collectionViewDataFlags.layoutIsPrepared = (unsigned int)layoutIsPrepared;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Fetch Layout Attributes

- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect {
    [self validateLayoutInRect:rect];
    return self.cachedLayoutAttributes;
}

- (NSUInteger)layoutAttributesGeneration {
    return _layoutAttributesGeneration;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private

// ensure item count is valid and loaded
- (void)validateItemCounts {
    if (!_collectionViewDataFlags.itemCountsAreValid) {
        [self updateItemCounts];
    }
}

// query dataSource for new data
- (void)updateItemCounts {
    // query how many sections there will be
    _numSections = 1;
    if ([self.collectionView.dataSource respondsToSelector:@selector(numberOfSectionsInCollectionView:)]) {
        _numSections = [self.collectionView.dataSource numberOfSectionsInCollectionView:self.collectionView];
    }
    if (_numSections <= 0) { // early bail-out
        _numItems = 0;
        free(_sectionItemCounts);
        _sectionItemCounts = 0;
        free(_sectionItemOffsets);
        _sectionItemOffsets = 0;
        _collectionViewDataFlags.itemCountsAreValid = YES;
        return;
    }
    // allocate space
    if (!_sectionItemCounts) {
        _sectionItemCounts = malloc((size_t)_numSections * sizeof(NSInteger));
    }else {
        _sectionItemCounts = realloc(_sectionItemCounts, (size_t)_numSections * sizeof(NSInteger));
    }
    if (!_sectionItemOffsets) {
        _sectionItemOffsets = malloc((size_t)(_numSections + 1) * sizeof(NSInteger));
    }else {
        _sectionItemOffsets = realloc(_sectionItemOffsets, (size_t)(_numSections + 1) * sizeof(NSInteger));
    }

    // query cells per section, building the prefix sums in the same pass
    _numItems = 0;
    _sectionItemOffsets[0] = 0;
    for (NSInteger i = 0; i < _numSections; i++) {
        NSInteger cellCount = [self.collectionView.dataSource collectionView:self.collectionView numberOfItemsInSection:i];
        _sectionItemCounts[i] = cellCount;
        _numItems += cellCount;
        _sectionItemOffsets[i + 1] = _numItems;
    }

    _collectionViewDataFlags.itemCountsAreValid = YES;
}

- (void)prepareToLoadData {
    if (!self.layoutIsPrepared) {
        [self.layout prepareLayout];
        _contentSize = self.layout.collectionViewContentSize;
        self.layoutIsPrepared = YES;
    }
}

@end
