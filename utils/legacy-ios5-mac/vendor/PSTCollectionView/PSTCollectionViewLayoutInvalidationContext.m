#import "PSTCollectionViewLayout.h"

// Independent path accumulator: a context describes invalidation, it does not execute layout.
@implementation PSTCollectionViewLayoutInvalidationContext {
    NSMutableSet *_items;
    NSMutableDictionary *_supplementary;
    NSMutableDictionary *_decoration;
}
- (BOOL)invalidateEverything { return NO; }
- (BOOL)invalidateDataSourceCounts { return NO; }
- (NSArray *)invalidatedItemIndexPaths { return [_items allObjects]; }
- (NSDictionary *)pstSnapshotOfKinds:(NSDictionary *)kinds {
    if (!kinds) return nil;
    NSMutableDictionary *snapshot=[NSMutableDictionary dictionaryWithCapacity:kinds.count];
    for (NSString *kind in kinds) [snapshot setObject:[[kinds objectForKey:kind] allObjects] forKey:kind];
    return [snapshot copy];
}
- (NSDictionary *)invalidatedSupplementaryIndexPaths { return [self pstSnapshotOfKinds:_supplementary]; }
- (NSDictionary *)invalidatedDecorationIndexPaths { return [self pstSnapshotOfKinds:_decoration]; }
- (void)invalidateItemsAtIndexPaths:(NSArray *)indexPaths {
    if (!_items) _items=[NSMutableSet set];
    [_items addObjectsFromArray:indexPaths];
}
- (void)pstAddPaths:(NSArray *)paths kind:(NSString *)kind toKinds:(NSMutableDictionary *)kinds {
    NSMutableSet *set=[kinds objectForKey:kind];
    if (!set) { set=[NSMutableSet set]; [kinds setObject:set forKey:kind]; }
    [set addObjectsFromArray:paths];
}
- (void)invalidateSupplementaryElementsOfKind:(NSString *)kind atIndexPaths:(NSArray *)indexPaths {
    if (!_supplementary) _supplementary=[NSMutableDictionary dictionary];
    [self pstAddPaths:indexPaths kind:kind toKinds:_supplementary];
}
- (void)invalidateDecorationElementsOfKind:(NSString *)kind atIndexPaths:(NSArray *)indexPaths {
    if (!_decoration) _decoration=[NSMutableDictionary dictionary];
    [self pstAddPaths:indexPaths kind:kind toKinds:_decoration];
}
@end

@implementation PSTCollectionViewFlowLayoutInvalidationContext
- (instancetype)init {
    if ((self=[super init])) { _invalidateFlowLayoutAttributes=YES; _invalidateFlowLayoutDelegateMetrics=YES; }
    return self;
}
@end
