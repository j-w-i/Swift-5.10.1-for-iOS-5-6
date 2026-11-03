#import "../private/FBPHashTable.h"
static NSUInteger checks;
#define CHECK(x) do { ++checks; if (!(x)) { NSLog(@"FAIL line %d: %s", __LINE__, #x); abort(); } } while (0)
@interface Value : NSObject <NSCopying> { @public int key; }
@end
@implementation Value
- (NSUInteger)hash { return 7; } // deliberately colliding unequal values
- (BOOL)isEqual:(id)o { return [o isKindOfClass:[Value class]] && ((Value *)o)->key == key; }
- (id)copyWithZone:(NSZone *)z { Value *v = [[Value allocWithZone:z] init]; v->key = key; return v; }
@end
static Value *value(int k) { Value *v = [[[Value alloc] init] autorelease]; v->key = k; return v; }
static void exercise(Class cls, NSUInteger options) {
    id t = [[cls alloc] initWithOptions:options capacity:2];
    Value *a = value(1), *equal = value(1), *b = value(2);
    [t addObject:a]; [t addObject:equal]; [t addObject:b];
    BOOL pointer = (options & 0x200) != 0;
    CHECK([t count] == (pointer ? 3u : 2u)); CHECK([t containsObject:a]); CHECK([t containsObject:b]);
    CHECK([t member:a] != nil); CHECK([[t allObjects] count] == [t count]);
    NSUInteger n = 0; for (id x in t) { CHECK([t containsObject:x]); ++n; } CHECK(n == [t count]);
    id c = [t copy]; CHECK([c count] == [t count]); CHECK([c isEqualToHashTable:t]);
    CHECK([t intersectsHashTable:c]); CHECK([t isSubsetOfHashTable:c]);
    [c removeObject:b]; CHECK(![c containsObject:b]); CHECK([t containsObject:b]);
    [c unionHashTable:t]; CHECK([c count] == [t count]);
    [c minusHashTable:t]; CHECK([c count] == 0);
    [c unionHashTable:t]; [c intersectHashTable:t]; CHECK([c count] == [t count]);
    [t removeAllObjects]; CHECK([t count] == 0); CHECK([t anyObject] == nil);
    [c release]; [t release];
}
static void enumeratorLifetime(Class cls) {
    id t = [[cls alloc] initWithOptions:5 capacity:0];
    NSEnumerator *enumerator;
    @autoreleasepool { Value *v = [[Value alloc] init]; [t addObject:v]; enumerator = [[t objectEnumerator] retain]; [v release]; }
    CHECK([enumerator nextObject] == nil);
    [enumerator release]; [t release];
}
static void mutation(Class cls) {
    id t = [[cls alloc] initWithOptions:0 capacity:0]; [t addObject:value(1)]; [t addObject:value(2)];
    BOOL raised = NO; @try { for (id o in t) { (void)o; [t addObject:value(3)]; } } @catch (NSException *e) { raised = YES; }
    CHECK(raised); [t release];
}
static void lifetimes(Class cls, BOOL weak) {
    id t = [[cls alloc] initWithOptions:weak ? 5 : 0 capacity:0];
    id copy;
    @autoreleasepool {
        Value *v = [[Value alloc] init]; v->key = 42;
        [t addObject:v]; copy = [t copy]; [v release];
        CHECK([t count] == 1); CHECK([copy count] == 1);
    }
    // Apple explicitly permits delayed purging: native count can remain stale.
    CHECK([[t allObjects] count] == (weak ? 0u : 1u)); CHECK([[copy allObjects] count] == (weak ? 0u : 1u));
    CHECK(([t anyObject] == nil) == weak);
    [copy release]; [t release];
}
int main(void) { @autoreleasepool {
    for (NSUInteger i = 0; i < 20; ++i) {
        for (NSUInteger p = 0; p <= 0x200; p += 0x200) {
            exercise([NSHashTable class], p); exercise([FBPHashTable class], p);
            exercise([NSHashTable class], p | 5); exercise([FBPHashTable class], p | 5);
        }
        lifetimes([NSHashTable class], YES); lifetimes([FBPHashTable class], YES);
        lifetimes([NSHashTable class], NO); lifetimes([FBPHashTable class], NO);
        enumeratorLifetime([NSHashTable class]); enumeratorLifetime([FBPHashTable class]);
        mutation([NSHashTable class]); mutation([FBPHashTable class]);
    }
    for (NSUInteger o = 0; o <= 0x205; o += (o == 0 ? 5 : (o == 5 ? 0x1fb : 5))) {
        NSPointerFunctions *n = [[NSPointerFunctions alloc] initWithOptions:o];
        NSPointerFunctions *f = (id)[[FBPPointerFunctions alloc] initWithOptions:o];
        NSLog(@"options %lu native barriers %d/%d backend %d/%d callbacks hash %d/%d equal %d/%d size %d/%d acquire %d/%d relinquish %d/%d", (unsigned long)o, [n usesStrongWriteBarrier], [n usesWeakReadAndWriteBarriers], [f usesStrongWriteBarrier], [f usesWeakReadAndWriteBarriers], n.hashFunction != NULL, f.hashFunction != NULL, n.isEqualFunction != NULL, f.isEqualFunction != NULL, n.sizeFunction != NULL, f.sizeFunction != NULL, n.acquireFunction != NULL, f.acquireFunction != NULL, n.relinquishFunction != NULL, f.relinquishFunction != NULL);
        CHECK(n.usesStrongWriteBarrier == f.usesStrongWriteBarrier); CHECK(n.usesWeakReadAndWriteBarriers == f.usesWeakReadAndWriteBarriers);
        Value *a = value(99), *b = value(99), *c = value(100);
        CHECK(n.hashFunction(a, NULL) == f.hashFunction(a, NULL));
        CHECK(n.isEqualFunction(a, b, NULL) == f.isEqualFunction(a, b, NULL));
        CHECK(n.isEqualFunction(a, c, NULL) == f.isEqualFunction(a, c, NULL));
        CHECK((n.sizeFunction == NULL) == (f.sizeFunction == NULL));
        id table = [[FBPHashTable alloc] initWithPointerFunctions:f capacity:0]; [table addObject:a]; CHECK([table member:a] == a);
        NSPointerFunctions *out = [table pointerFunctions]; CHECK(out != f); CHECK(out.hashFunction(a, NULL) == f.hashFunction(a, NULL)); [table release];
        [n release]; [f release];
    }
    NSUInteger masks[] = {1,2,3,4,6,0x100,0x300,0x400,0x500,0x10000,0x10005,0x80000000};
    for (NSUInteger i = 0; i < sizeof(masks)/sizeof(*masks); ++i) {
        BOOL raised = NO; @try { id t = [[FBPHashTable alloc] initWithOptions:masks[i] capacity:0]; [t release]; } @catch (NSException *e) { raised = [e.name isEqual:NSInvalidArgumentException]; } CHECK(raised);
    }
    NSLog(@"PASS %lu host native/fallback checks (not device qualification)", (unsigned long)checks);
} return 0; }
