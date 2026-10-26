# PSTCollectionView source runtime

MIT sources from https://github.com/steipete/PSTCollectionView, imported from
UIKitCompatKit commit `0494ee40f0519095522352e2ce4c846b8b20fe16` plus its
uncommitted `PSTCollectionView.h` nullability/kindof changes. That checkout was
read/copied only; its uncommitted change is preserved. `SNAPSHOT.json` records
SHA-256 hashes of every file **as imported**, before the patches below. No
upstream commit is claimed: the source checkout did not record one.

## Compiler-repository changes

* Original modern-SDK receiver cast and Swift-name attributes are preserved.
* Objective-C Foundation subscripting is replaced by iOS 5-safe
  `objectAtIndex:`, `objectForKey:`, `setObject:forKey:` and
  `replaceObjectAtIndex:withObject:`. No Foundation categories or global
  subscript selector implementations are injected.
* Internal index-path operations use the equivalent UIKit `row` methods.
  Client `item` and `indexPathForItem:inSection:` methods are installed using
  `class_addMethod` **only when absent**, never category method replacement.
* `PST_TOOLCHAIN_RUNTIME` disables upstream `class_setSuperclass` forwarding
  entirely. Its constructor returns immediately when native UICollectionView
  already exists. This is the mode selected by the source builder.
* Compiler declarations expose UIKit spelling with direct PST runtime names,
  preserving the real collection/cell/reusable-view/layout inheritance graph.
  PSUI wrappers are NOT the compiler's class identities.

## Build and integration

From `utils/legacy-ios5-mac`, run:

```
bash build-collection-runtime.sh /absolute/SDK /absolute/clang /absolute/ar /absolute/fresh-output
```

Only these vendored sources are compiled, serially, for armv7 iOS 5.0 in ARM
instruction mode (`-marm`) with ARC,
blocks, no Clang modules, and availability errors enabled. Inputs are explicit;
there is no network fetch, SDK discovery, package dependency, prebuilt archive,
installed-toolchain write or whole-toolchain build. Outputs retain commands,
diagnostics and a SHA-256 build manifest. `ZERO_AR_DATE=1`, `-g0` and source path
prefix normalization make the archive deterministic for matching inputs.

Outputs:

* `libswiftLegacyCollectionView.a` — intermediate **toolchain build** archive.
* `legacy-collection/Headers/UIKitLegacyCollection.h` — generated baseline
  declarations for importer fallback when SDK collection declarations are absent.
* `legacy-collection/LICENSE` and `legacy-collection/SNAPSHOT.json`.

The overlay linker force-loads the archive **only into libswiftUIKit.dylib** for
legacy deployment targets. Clients need no bridge, collection module import,
static archive, `-ObjC`, `-all_load` or `-force_load` flag. UIKit's normal overlay
autolinking supplies the runtime. Carry the MIT license in the assembled
resource directory when distributing the dylib.

`test-collection-runtime.sh SDK CLANG AR NM OUT` builds twice, compares archive
bytes and generated headers, checks eight PST class/metaclass definitions,
rejects native UIKit class definitions, iOS 6 subscript selectors, weak stores
and superclass-mutation references, and checks stale-output rejection. A C
SDK-overlay smoke test checks subclass class/metaclass symbols and Darwin C
constant aliases. This is **not runtime/device qualification**.

## iOS 6 coexistence and remaining safety limits

Selection is **compile-time**: target iOS 5 uses PST classes on iOS 5 **and on
newer operating systems**; target iOS 6+ uses native UIKit declarations/classes.
An iOS 5-targeted binary is not silently reparented to native UIKit on iOS 6.
This avoids breaking Swift inheritance and runtime casts: upstream PSUI wrappers
are sibling hierarchies, not a valid replacement for the imported PST hierarchy.

On iOS 5, upstream dynamic registration of missing UIKit collection class names
is retained for old nib compatibility. On iOS 6+ the toolchain constructor is a
no-op and native UIKit classes/methods are never replaced. The guarded NSIndexPath
additions likewise preserve native implementations. Existing upstream PSUI
wrappers remain in the sources but are not used as compiler class identities.

The compatibility surface is the old PST/iOS 6 collection API, not contemporary
collection/diffable/compositional-layout APIs. Retaining modern SDK declarations
does not implement modern selectors in PST. Only backported/supported API may
have availability relaxed by the importer. Formal protocol runtime identities
remain PST-prefixed. Nib decoding, batch updates, custom layouts, subclassing,
Swift casts and mixed native/PST objects still require real iOS 5/iOS 6 device
validation. The copied historical `STATUS.md` describes UIKitCompatKit before
toolchain integration, not the status of this compiler package.
