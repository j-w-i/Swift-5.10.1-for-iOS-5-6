# Experimental NSHashTable private backend — NOT integration-ready

Source-only; nothing is installed. No public Swift module/helper is emitted. Apple SDK declarations are not edited. The private Objective-C class names are FBPHashTable and FBPPointerFunctions. The private header must never become an SDK public header. The separate builder emits an ARMv7 static archive and manifest only.

## Bounded scope

Implemented masks are **0, 5, 0x200, 0x205**: strong or runtime zeroing-weak memory with object equality/hash or object-pointer identity. All unknown bits, GC zeroing-weak (1), opaque/malloc/Mach memory, C-string/struct/integer personalities, CopyIn, and custom pointer-function setters raise NSInvalidArgumentException. This is intentionally **not full NSPointerFunctions compatibility**. An unchanged custom callback assignment also raises, rather than pretending customization works. initWithPointerFunctions accepts only an unmodified exact FBPPointerFunctions instance (no subclass or native Apple object).

Slots own strong objects with retain/release. Weak slots use objc_initWeak/objc_loadWeakRetained/objc_destroyWeak; reads are retained by the runtime before being autoreleased, so a concurrent final release cannot produce a dangling object between weak load and use. Weak slots are separately allocated Objective-C objects and never relocated. Enumeration snapshots slots, not their referents. allObjects/setRepresentation intentionally return strong snapshots. Copy preserves options and adds referents into new independent slots. Fast enumeration checks explicit mutations, skipping zeroed slots. Tables are not safe for concurrent mutation, like native mutable Foundation collections. Dead slots currently remain allocated until removal-all/deallocation; count skips them.

Selectors include options/pointer-functions initializers, factories, pointerFunctions, count/member/contains/add/remove/removeAll, anyObject/allObjects/objectEnumerator/setRepresentation, copy, fast enumeration, and hash-table set operations. NSCoder/NSSecureCoding, native class identity, arbitrary void-pointer C APIs, and public inherited isEqual:/hash behavior are not claimed.

## Evidence and limitations

Host differential tests run the same fixtures against genuine NSHashTable and forced FBPHashTable. 3,648 checks pass on this host: equal-but-distinct objects, intentional hash collisions, both supported personalities and memory modes, copied tables and independent mutation, strong retention, nested autorelease pools and weak release, enumeration-held weak lifetime, fast-enumeration mutation exceptions, set operations, pointer-function default hashes/equality/barrier flags and copied accessors, and rejection of unsupported masks. Native weak count may remain stale after reclamation; tests use live allObjects/anyObject, as Apple's header explicitly allows delayed purging. Enumeration order is unspecified.

The old C NSHashTable retain/release callbacks and CFSet callbacks do not provide a stable zeroing-weak slot: directly storing object pointers cannot be made safely weak by merely omitting retains. No NSMapTable/NSPointerArray substitute is used because these also require newer iOS class APIs.

Apple objc4-493.9 source explicitly declares objc_initWeak, objc_loadWeakRetained and objc_destroyWeak with __IPHONE_5_0 availability: https://github.com/apple-oss-distributions/objc4/blob/objc4-493.9/runtime/objc-internal.h . This is source ABI evidence, **not an inspection of a particular iOS5 device binary**. The ARM object compiles for armv7-apple-ios5.0 and imports only old Foundation classes plus the listed weak runtime functions; no NSHashTable/NSPointerFunctions/NSMapTable/NSPointerArray class import. No device execution or TSan claim.

**Importer gating/remapping is still required for both NSHashTable and NSPointerFunctions**, whose actual selected SDK headers mark them iOS6. Do not simply lower availability and claim complete Apple APIs. Both class references need coherent private backend mapping; exposing this header as an alternative public API or shipping a Swift helper is not an acceptable integration. Native iOS6 identity/delegation and secure coding remain unresolved. This source must not be installed/committed as a qualified full API backport until those limitations are resolved or explicitly accepted with configuration gating.

## Reproduce (all outputs under Work/sdk-build/hashtable)

```
bash utils/legacy-ios5-mac/build-native-hashtable-runtime.sh SDK CLANG AR /absolute/Work/sdk-build/hashtable/new-arm-output
clang -fno-objc-arc -Wno-deprecated-declarations -framework Foundation \
  utils/legacy-ios5-mac/native-foundation-runtime/HashTable/FBPHashTable.m \
  utils/legacy-ios5-mac/native-foundation-runtime/HashTable/tests/differential.m \
  -o /absolute/Work/sdk-build/hashtable/differential
/absolute/Work/sdk-build/hashtable/differential
```
