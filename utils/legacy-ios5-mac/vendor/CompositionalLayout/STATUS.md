# Legacy iOS 5 compositional-layout runtime

Source-built implementation of the iOS 13 compositional-layout API
(`UICollectionViewCompositionalLayout` and the `NSCollectionLayout*` family) for
the legacy iOS 5 toolchain. It is the runtime half of the importer mapping: the
Clang importer exposes the public UIKit declarations and renames them to the
`IBP*` Objective-C identities built here, exactly as it already does for
`PSTCollectionView`.

## Build

```
bash utils/legacy-ios5-mac/build-compositional-layout.sh SDK CLANG AR OUT
```

- armv7-apple-ios5.0, `-marm` (mandatory: the pinned older linker loses ARM/Thumb
  interworking bits on local relocations), ARC + blocks, `-O2 -g0`, deterministic
  archive (`ZERO_AR_DATE=1`, `-ffile-prefix-map`), no network.
- `OUT` must not exist; the directory itself is the atomic claim. Logs, objects,
  the staged sources, the private SDK declaration overlay, the mapping contract
  and a hash manifest are retained under `OUT`.
- Outputs: `libswiftLegacyCompositionalLayout.a` (link it with the PST archive
  and force-load both for a 5.x deployment target) and
  `legacy-compositional-layout/` (mapping contract, licence, snapshot, notices,
  this file).

`test-compositional-layout.sh` rebuilds twice, compares the archives and the
mapping contract, audits every symbol and class hierarchy, rejects a public-named
runtime class, and (when given the CRT archive and the PST archive) performs the
integrated link and initializer/Thumb-pointer audits.

## Pipeline integration (hooks this package needs, not edited here)

The reproducible build stage and the final link are owned by the pipeline; this
package deliberately does not edit `build-all.sh` or `link-overlay-stage.sh`.
Two hooks are required:

```
# overlays stage, next to build-collection-runtime.sh:
bash "$HERE/build-compositional-layout.sh" "$SDK" "$CLANG" "$AR" \
  "$ROOT/bootstrap/probes/compositional-layout-runtime"

# link-overlay-stage.sh, only in the existing 5.x branch for the UIKit dylib,
# alongside the collection archive:
EXTRA+=(-Xlinker -force_load \
  -Xlinker "$STAGE/probes/compositional-layout-runtime/libswiftLegacyCompositionalLayout.a")
```

The compiler side consumes
`compositional-layout-runtime/legacy-compositional-layout/compositional-layout-mapping.json`
(or the same table duplicated in the importer) to map the public SDK
declarations; no declaration resource header is shipped, because the SDK of
record (Xcode 13.4.1 / iPhoneOS15.5) already declares the whole iOS 13 family and
the importer overrides that header in place exactly like the collection mapping.
For an SDK older than iOS 13 there is no fallback declaration resource: that path
is out of scope and must stay unavailable rather than silently absent.

## Recorded limitations

- No device execution has been observed; the archive and link are static
  evidence only. The qualification profile's `deviceExecution` stays pending.
- `NSCollectionLayoutEnvironment.traitCollection` is unavailable (capability
  gap, see above); `visibleItemsInvalidationHandler` is stored but never called;
  `visualDescription` is an empty stub.
- Estimated (self-sizing) dimensions work through `-sizeThatFits:` on iOS 5-7
  instead of `systemLayoutSizeFittingSize:`; cells should override
  `sizeThatFits:` for best results on those systems.
- Orthogonal scrolling and decoration items are implemented but unverified on a
  device; upstream only tests them against the native iOS 13 collection view.
- The internal per-item `NSUUID` identifier is nil below iOS 6; it only affects
  debug descriptions.


## Deviations from upstream (all in `patches/`)

1. **No native delegation.** Upstream's factories return the *native* iOS 13
   objects when `@available(iOS 13, *)`. A binary compiled for iOS 5 uses the
   PST graph at runtime even on newer OS versions, so mixing native layouts and
   attributes into PSTCollectionView crashes. The patch always constructs the
   backport's own objects. Native classes are never allocated, replaced,
   mutated or subclassed by name.
2. **Decoration item inheritance.** iOS 13's `NSCollectionLayoutDecorationItem`
   is declared as a subclass of `NSCollectionLayoutItem`. Upstream's pre-13
   fallback class is `NSObject`-rooted because it was only ever used through
   `@compatibility_alias`. The class is reparented so the public declaration's
   inheritance graph and casts are real.
3. **iOS 5 guards.** `traitCollection` is only read on iOS 8+ (there is no
   `UITraitCollection` on iOS 5, and the component that approximated it is
   omitted for licensing); the self-sizing path uses `-sizeThatFits:` below
   iOS 8 because `systemLayoutSizeFittingSize:`/`UILayoutFittingCompressedSize`
   do not exist there.

## Implemented / not implemented

Implemented: all 14 public classes and the three protocols at their iOS 13.0
member set, the struct/inline/enum helpers, `NSDirectionalEdgeInsetsZero` and
`NSStringFromDirectionalEdgeInsets`; orthogonal scrolling, boundary
supplementary items (including pinning), decoration items, custom groups,
estimated sizes.

Not implemented (the importer must keep these unavailable for a legacy iOS 5
target): `NSCollectionLayoutEnvironment.traitCollection`;
`NSCollectionLayoutSection.visibleItemsInvalidationHandler` (stored, never
invoked); `NSCollectionLayoutGroup.visualDescription` (empty stub);
`NSDirectionalEdgeInsetsFromString`, the `NSValue`/`NSCoder` directional
extensions; and every declaration introduced after iOS 13.0. See
`legacy-compositional-layout/compositional-layout-mapping.json` for the
machine-readable list.

## Verification status

Compilation, deterministic archive, symbol/class-hierarchy verification and an
integrated link probe (with the PST archive and the toolchain's compiler-rt
archive) pass. This is static evidence only: no iOS 5 device execution has been
observed, so runtime qualification remains pending. The project must be built
with the same SDK used for qualification; the build script fails closed if the
SDK lacks the collection declarations it must map.
