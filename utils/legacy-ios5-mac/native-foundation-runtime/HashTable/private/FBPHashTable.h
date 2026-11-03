// Private backend declarations only. Never install this header in an SDK.
// Clients retain Apple's original NSHashTable/NSPointerFunctions declarations.
#import <Foundation/Foundation.h>
// Only type spellings from the SDK are used, never the iOS6 class objects.
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

@interface FBPPointerFunctions : NSObject <NSCopying>
- (instancetype)initWithOptions:(NSPointerFunctionsOptions)options;
+ (NSPointerFunctions *)pointerFunctionsWithOptions:(NSPointerFunctionsOptions)options;
@property NSUInteger (*hashFunction)(const void *, NSUInteger (*)(const void *));
@property BOOL (*isEqualFunction)(const void *, const void *, NSUInteger (*)(const void *));
@property NSUInteger (*sizeFunction)(const void *);
@property NSString *(*descriptionFunction)(const void *);
@property void (*relinquishFunction)(const void *, NSUInteger (*)(const void *));
@property void *(*acquireFunction)(const void *, NSUInteger (*)(const void *), BOOL);
@property BOOL usesStrongWriteBarrier;
@property BOOL usesWeakReadAndWriteBarriers;
@end

@interface FBPHashTable : NSObject <NSCopying, NSFastEnumeration>
- (instancetype)initWithOptions:(NSPointerFunctionsOptions)options capacity:(NSUInteger)initialCapacity;
- (instancetype)initWithPointerFunctions:(NSPointerFunctions *)functions capacity:(NSUInteger)initialCapacity;
+ (NSHashTable *)hashTableWithOptions:(NSPointerFunctionsOptions)options;
+ (NSHashTable *)weakObjectsHashTable;
@property (readonly, copy) NSPointerFunctions *pointerFunctions;
@property (readonly) NSUInteger count;
- (id)member:(id)object;
- (NSEnumerator *)objectEnumerator;
- (void)addObject:(id)object;
- (void)removeObject:(id)object;
- (void)removeAllObjects;
@property (readonly, copy) NSArray *allObjects;
@property (readonly) id anyObject;
- (BOOL)containsObject:(id)object;
- (BOOL)intersectsHashTable:(NSHashTable *)other;
- (BOOL)isEqualToHashTable:(NSHashTable *)other;
- (BOOL)isSubsetOfHashTable:(NSHashTable *)other;
- (void)intersectHashTable:(NSHashTable *)other;
- (void)unionHashTable:(NSHashTable *)other;
- (void)minusHashTable:(NSHashTable *)other;
@property (readonly, copy) NSSet *setRepresentation;
@end
