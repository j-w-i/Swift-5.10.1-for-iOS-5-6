// Source-only bounded Apple-selector backend. Compile without ARC: weak runtime
// slots are explicit so enumeration returns autoreleased +1 weak loads safely.
#import "private/FBPHashTable.h"
#import <objc/runtime.h>

extern id objc_initWeak(id *, id);
extern id objc_loadWeakRetained(id *);
extern void objc_destroyWeak(id *);

static void FBPInvalid(NSString *reason) {
    [NSException raise:NSInvalidArgumentException format:@"FBPHashTable: %@", reason];
}
static void FBPValidate(NSUInteger o) {
    NSUInteger memory = o & 0xff, personality = o & 0xff00;
    if ((o & ~(NSUInteger)0x2ff) || (memory != 0 && memory != 5) ||
        (personality != 0 && personality != 0x200))
        FBPInvalid(@"unsupported memory/personality/options; only strong or ARC zeroing-weak object/object-pointer storage is implemented");
}
static NSUInteger FBPHash(const void *p, NSUInteger (*size)(const void *)) { return [(id)p hash]; }
static NSUInteger FBPPointerHash(const void *p, NSUInteger (*size)(const void *)) { return ((NSUInteger)p) >> 3; }
static BOOL FBPEqual(const void *a, const void *b, NSUInteger (*size)(const void *)) { return [(id)a isEqual:(id)b]; }
static BOOL FBPPointerEqual(const void *a, const void *b, NSUInteger (*size)(const void *)) { return a == b; }
static NSString *FBPDescribe(const void *p) { return [(id)p description]; }
static void *FBPAcquire(const void *p, NSUInteger (*size)(const void *), BOOL copy) { return copy ? [(id)p copy] : [(id)p retain]; }
static void FBPRelinquish(const void *p, NSUInteger (*size)(const void *)) { [(id)p release]; }

@interface FBPPointerFunctions () { @package NSUInteger _options; }
@end
@implementation FBPPointerFunctions
- (instancetype)init { return [self initWithOptions:0]; }
- (instancetype)initWithOptions:(NSPointerFunctionsOptions)o {
    if ((self = [super init])) { @try { FBPValidate(o); _options = o; } @catch (id e) { [self release]; @throw; } } return self;
}
+ (NSPointerFunctions *)pointerFunctionsWithOptions:(NSPointerFunctionsOptions)o { return (id)[[[self alloc] initWithOptions:o] autorelease]; }
- (id)copyWithZone:(NSZone *)z { return [[[self class] allocWithZone:z] initWithOptions:_options]; }
- (NSUInteger (*)(const void *, NSUInteger (*)(const void *)))hashFunction { return (_options & 0x200) ? FBPPointerHash : FBPHash; }
- (BOOL (*)(const void *, const void *, NSUInteger (*)(const void *)))isEqualFunction { return (_options & 0x200) ? FBPPointerEqual : FBPEqual; }
- (NSUInteger (*)(const void *))sizeFunction { return NULL; }
- (NSString *(*)(const void *))descriptionFunction { return FBPDescribe; }
- (void (*)(const void *, NSUInteger (*)(const void *)))relinquishFunction { return (_options & 0xff) == 5 ? NULL : FBPRelinquish; }
- (void *(*)(const void *, NSUInteger (*)(const void *), BOOL))acquireFunction { return (_options & 0xff) == 5 ? NULL : FBPAcquire; }
- (BOOL)usesStrongWriteBarrier { return NO; }
- (BOOL)usesWeakReadAndWriteBarriers { return (_options & 0xff) == 5; }
// Unsupported customization fails immediately, including setters to an unchanged
// function: there is no silent acceptance of a configuration we cannot preserve.
- (void)setHashFunction:(NSUInteger (*)(const void *, NSUInteger (*)(const void *)))f { FBPInvalid(@"custom pointer functions require importer gating"); }
- (void)setIsEqualFunction:(BOOL (*)(const void *, const void *, NSUInteger (*)(const void *)))f { FBPInvalid(@"custom pointer functions require importer gating"); }
- (void)setSizeFunction:(NSUInteger (*)(const void *))f { FBPInvalid(@"custom pointer functions require importer gating"); }
- (void)setDescriptionFunction:(NSString *(*)(const void *))f { FBPInvalid(@"custom pointer functions require importer gating"); }
- (void)setRelinquishFunction:(void (*)(const void *, NSUInteger (*)(const void *)))f { FBPInvalid(@"custom pointer functions require importer gating"); }
- (void)setAcquireFunction:(void *(*)(const void *, NSUInteger (*)(const void *), BOOL))f { FBPInvalid(@"custom pointer functions require importer gating"); }
- (void)setUsesStrongWriteBarrier:(BOOL)b { FBPInvalid(@"custom barriers require importer gating"); }
- (void)setUsesWeakReadAndWriteBarriers:(BOOL)b { FBPInvalid(@"custom barriers require importer gating"); }
@end

@interface FBPHashSlot : NSObject { @public id value; BOOL weak; NSUInteger hash; }
- (id)initWithObject:(id)o options:(NSUInteger)options;
- (id)object;
@end
@implementation FBPHashSlot
- (id)initWithObject:(id)o options:(NSUInteger)options {
    if ((self = [super init])) {
        weak = (options & 0xff) == 5;
        if (weak) objc_initWeak(&value, o);
        else value = (options & 0x10000) ? [o copy] : [o retain];
        id actual = [self object];
        hash = (options & 0x200) ? FBPPointerHash(actual, NULL) : [actual hash];
    } return self;
}
- (id)object { return weak ? [objc_loadWeakRetained(&value) autorelease] : value; }
- (void)dealloc { if (weak) objc_destroyWeak(&value); else [value release]; [super dealloc]; }
@end

@interface FBPHashEnumerator : NSEnumerator { NSArray *_slots; NSUInteger _index; }
- (id)initWithSlots:(NSArray *)slots;
@end
@implementation FBPHashEnumerator
- (id)initWithSlots:(NSArray *)slots { if ((self = [super init])) _slots = [slots copy]; return self; }
- (id)nextObject { while (_index < [_slots count]) { id o = [[_slots objectAtIndex:_index++] object]; if (o) return o; } return nil; }
- (void)dealloc { [_slots release]; [super dealloc]; }
@end
@interface FBPHashTable () { NSMutableArray *_slots; NSUInteger _options; unsigned long _mutation; }
@end
@implementation FBPHashTable
- (instancetype)init { return [self initWithOptions:0 capacity:0]; }
- (instancetype)initWithOptions:(NSPointerFunctionsOptions)o capacity:(NSUInteger)c {
    if ((self = [super init])) { @try { FBPValidate(o); _options = o; _slots = [[NSMutableArray alloc] initWithCapacity:c]; _mutation = 1; } @catch (id e) { [self release]; @throw; } } return self;
}
- (instancetype)initWithPointerFunctions:(NSPointerFunctions *)f capacity:(NSUInteger)c {
    if (![f isMemberOfClass:[FBPPointerFunctions class]]) { [self release]; FBPInvalid(@"only unmodified private-backend pointer functions supported"); return nil; }
    return [self initWithOptions:((FBPPointerFunctions *)(id)f)->_options capacity:c];
}
+ (NSHashTable *)hashTableWithOptions:(NSPointerFunctionsOptions)o { return (id)[[[self alloc] initWithOptions:o capacity:0] autorelease]; }
+ (NSHashTable *)weakObjectsHashTable { return [self hashTableWithOptions:5]; }
- (void)dealloc { [_slots release]; [super dealloc]; }
- (NSPointerFunctions *)pointerFunctions { return (id)[[[FBPPointerFunctions alloc] initWithOptions:_options] autorelease]; }
- (NSUInteger)count { NSUInteger c = 0; for (FBPHashSlot *s in _slots) if ([s object]) ++c; return c; }
- (id)member:(id)o {
    if (!o) return nil;
    NSUInteger h = (_options & 0x200) ? FBPPointerHash(o, NULL) : [o hash];
    for (FBPHashSlot *s in _slots) { id v = [s object]; if (v && s->hash == h && (v == o || (!(_options & 0x200) && [v isEqual:o]))) return v; }
    return nil;
}
- (BOOL)containsObject:(id)o { return [self member:o] != nil; }
- (void)addObject:(id)o {
    if (!o || [self member:o]) return;
    FBPHashSlot *s = [[FBPHashSlot alloc] initWithObject:o options:_options];
    [_slots addObject:s]; [s release]; ++_mutation;
}
- (void)removeObject:(id)o {
    if (!o) return;
    NSUInteger h = (_options & 0x200) ? FBPPointerHash(o, NULL) : [o hash];
    for (NSUInteger i = 0; i < [_slots count]; ++i) {
        FBPHashSlot *s = [_slots objectAtIndex:i]; id v = [s object];
        if (v && s->hash == h && (v == o || (!(_options & 0x200) && [v isEqual:o]))) { [_slots removeObjectAtIndex:i]; ++_mutation; return; }
    }
}
- (void)removeAllObjects { if ([_slots count]) { [_slots removeAllObjects]; ++_mutation; } }
- (NSArray *)allObjects { NSMutableArray *a = [NSMutableArray array]; for (FBPHashSlot *s in _slots) { id o = [s object]; if (o) [a addObject:o]; } return [[a copy] autorelease]; }
- (id)anyObject { for (FBPHashSlot *s in _slots) { id o = [s object]; if (o) return o; } return nil; }
- (NSEnumerator *)objectEnumerator { return [[[FBPHashEnumerator alloc] initWithSlots:_slots] autorelease]; }
- (NSSet *)setRepresentation { return [NSSet setWithArray:[self allObjects]]; }
- (id)copyWithZone:(NSZone *)zone { FBPHashTable *t = [[[self class] allocWithZone:zone] initWithOptions:_options capacity:[self count]]; for (id o in self) [t addObject:o]; return t; }
- (BOOL)intersectsHashTable:(NSHashTable *)t { for (id o in self) if ([t containsObject:o]) return YES; return NO; }
- (BOOL)isSubsetOfHashTable:(NSHashTable *)t { for (id o in self) if (![t containsObject:o]) return NO; return YES; }
- (BOOL)isEqualToHashTable:(NSHashTable *)t { return t && [self count] == [t count] && [self isSubsetOfHashTable:t]; }
- (void)intersectHashTable:(NSHashTable *)t { for (id o in [self allObjects]) if (![t containsObject:o]) [self removeObject:o]; }
- (void)minusHashTable:(NSHashTable *)t { for (id o in [self allObjects]) if ([t containsObject:o]) [self removeObject:o]; }
- (void)unionHashTable:(NSHashTable *)t { for (id o in [t allObjects]) [self addObject:o]; }
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id *)buffer count:(NSUInteger)len {
    state->mutationsPtr = &_mutation; state->itemsPtr = buffer;
    NSUInteger n = 0, i = state->state;
    while (i < [_slots count] && n < len) { id o = [[_slots objectAtIndex:i++] object]; if (o) buffer[n++] = o; }
    state->state = i; return n;
}
@end
