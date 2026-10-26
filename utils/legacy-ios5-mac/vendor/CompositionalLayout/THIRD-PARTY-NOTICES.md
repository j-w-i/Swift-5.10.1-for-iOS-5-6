# Third-party notices for the legacy iOS 5 compositional-layout runtime

This vendor package is **not** wholly MIT-licensed. It combines three kinds of
material, recorded separately below:

1. literal upstream source text (MIT), preserved verbatim;
2. an upstream component that is **not redistributed** because its licence could
   not be established;
3. declarations and build helpers authored for this toolchain.

## 1. IBPCollectionViewCompositionalLayout — MIT, redistributed verbatim

- Component: IBPCollectionViewCompositionalLayout (backport of the iOS 13
  compositional-layout API).
- Upstream: <https://github.com/j-w-i/IBPCollectionViewCompositionalLayout>
  (fork of <https://github.com/kishikawakatsumi/IBPCollectionViewCompositionalLayout>),
  commit `9e5348623ec2119e9dbe845a0f7d8f5fb0672729`
  ("Do not crash during +load below iOS 6").
- Licence: MIT, Copyright (c) 2019 Kishikawa Katsumi. The complete licence text
  is redistributed verbatim as `LICENSE` in this directory.
- Redistributed files: every file under `upstream/`, copied byte-for-byte from
  `Sources/IBPCollectionViewCompositionalLayout/` at that commit (the eight known
  files of the unlicensed component described in section 2 are excluded).
  `SNAPSHOT.json` records the SHA-256 of each file, and `patches/` records the
  only changes made to this text (applied to a build copy, never to `upstream/`).

## 2. DDTraitCollection — NOT redistributed, licence not established

- Component: DDTraitCollection / `DDTraitCollectionObserver`, `UIView+DDTraitCollection`,
  `UIViewController+DDTraitCollection` (bundled by the upstream project and used
  by it to approximate `UITraitCollection` below iOS 8).
- Copyright notices: "Copyright (c) 2015 Delta Dog. All rights reserved." in
  every file. No licence grant appears in those files, in the upstream `LICENSE`
  (which names only Kishikawa Katsumi and MIT), or in the upstream README.
  The licence therefore could not be established; per the toolchain's licensing
  policy this component is omitted rather than guessed at.
- Omitted files (relative to upstream's `Sources/IBPCollectionViewCompositionalLayout/`):
  `DDTraitCollection.h`, `DDTraitCollection.m`, `DDTraitCollectionObserver.h`,
  `DDTraitCollectionObserver.m`, `UIView+DDTraitCollection.h`,
  `UIView+DDTraitCollection.m`, `UIViewController+DDTraitCollection.h`,
  `UIViewController+DDTraitCollection.m`.
- Consequence: `NSCollectionLayoutEnvironment.traitCollection` is a recorded
  capability gap. The compiler-side availability gating keeps it unavailable for
  a legacy iOS 5 target, and the runtime never calls a `traitCollection`
  selector below iOS 8. `shims/` contains three reconstructed forward
  declarations so that the MIT headers still compile without the omitted text.

## 3. Files authored for this toolchain (not upstream, not MIT/BSD)

These files are new work for the legacy-ios5 toolchain and are author-owned; no
separate licence grant is asserted here. They contain no upstream or third-party
text:

- `shims/DDTraitCollection.h`, `shims/UIView+DDTraitCollection.h`,
  `shims/UIViewController+DDTraitCollection.h` — reconstructed opaque
  declarations that stand in for the omitted component (section 2).
- `authored/IBPCompositionalLayoutProtocolExports.m` — emits the Objective-C
  protocol identities the importer maps; the upstream sources never reference
  the visible-item protocol in a conformance.
- `generate-runtime-overlay.py`, `emit-runtime-mapping.py`,
  `../../build-compositional-layout.sh`,
  `../../test-compositional-layout.sh` — build, contract and test helpers.
- `THIRD-PARTY-NOTICES.md`, `STATUS.md`, `SNAPSHOT.json`, `patches/` — provenance
  and patch records.

## 4. Dependencies that are not part of this package

- PSTCollectionView (MIT, Copyright (c) 2012-2013 Peter Steinberger) is vendored
  separately at `../PSTCollectionView` and supplies the collection-view runtime
  that this archive links against. No PST text is present in this package; its
  licence and snapshot manifest live in that sibling directory.
- The SDK's UIKit headers are **not** redistributed in this package. At build
  time the build script makes private, compiler-only copies of six collection
  headers with linkage attributes added (the same mapping the Clang importer
  performs in memory) into the build output directory. That derived text is
  build output on the machine that owns the SDK, not part of this repository or
  of any distributed archive.
