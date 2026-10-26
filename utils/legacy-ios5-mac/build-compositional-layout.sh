#!/bin/bash
# Source-only armv7 iOS 5 compositional-layout runtime; no network, no writes to
# installed toolchains, no xcrun/global SDK lookup.
#
# Usage: build-compositional-layout.sh SDK CLANG AR OUT
# OUT must not exist. Outputs, below OUT:
#   libswiftLegacyCompositionalLayout.a   deterministic ObjC archive (armv7, ARM mode)
#   legacy-compositional-layout/          contract + licensing + capability report
#     compositional-layout-mapping.json   public -> runtime name mapping (importer input)
#     SNAPSHOT.json LICENSE THIRD-PARTY-NOTICES.md STATUS.md
#   overlay/                              private PST-mapped SDK declarations (compile only)
#   sources/ objects/ logs/ build-manifest.json
#
# The archive references PSTCollectionView rather than native UIKit collection
# classes, because a legacy iOS 5 binary uses the toolchain's PST graph on every
# OS it can run on. The final libswiftUIKit link force-loads this archive and the
# PST archive together for a 5.x deployment target; see link-overlay-stage.sh.
set -euo pipefail
umask 022
fail() { printf 'build-compositional-layout: %s\n' "$*" >&2; exit 1; }
[ "$#" = 4 ] || fail 'Usage: build-compositional-layout.sh SDK CLANG AR OUT'
SDK=$1; CLANG=$2; AR=$3; OUT=$4
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$HERE/vendor/CompositionalLayout"
PY=${PYTHON:-$(command -v python3 || command -v python || true)}
PATCH_TOOL=${PATCH:-$(command -v patch || true)}
for path in "$SDK" "$CLANG" "$AR" "$OUT"; do
  [[ "$path" = /* ]] || fail "Use absolute paths: $path"
done
[ -d "$SDK" ] && [ -x "$CLANG" ] && [ -x "$AR" ] || fail 'Missing SDK, clang or archive tool.'
[ -x "$PATCH_TOOL" ] || fail 'Missing patch tool (set PATCH to an absolute patch executable).'
[ -x "$PY" ] || fail 'Missing python3 (set PYTHON to an absolute interpreter).'
[ -d "$SRC/upstream" ] && [ -d "$SRC/shims" ] && [ -d "$SRC/patches" ] || fail "Incomplete vendor snapshot: $SRC"
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail "Refusing existing output: $OUT"
# Deterministic archive metadata; also required by the rest of the pipeline.
export ZERO_AR_DATE=1
# Atomic claim; parent must exist and failures retain all diagnostic evidence.
mkdir "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
mkdir "$OUT/objects" "$OUT/logs" "$OUT/sources" "$OUT/overlay" "$OUT/legacy-compositional-layout"
NM=${NM:-}
if [ -z "$NM" ]; then
  for candidate in "$(dirname -- "$CLANG")/llvm-nm" "$(dirname -- "$CLANG")/nm" /usr/bin/nm; do
    if [ -x "$candidate" ]; then NM=$candidate; break; fi
  done
fi
[[ "$NM" = /* && -x "$NM" ]] || fail 'Set NM to an absolute nm executable.'

# Refuse a modified vendor tree: SNAPSHOT.json hash-binds the verbatim upstream
# files, the patches, and the authored/shims files. Drift is a build error, never
# a silently different runtime.
"$PY" - "$SRC" <<'PY'
import hashlib, json, pathlib, sys
src = pathlib.Path(sys.argv[1])
snapshot = json.loads((src / 'SNAPSHOT.json').read_text())

def verify(group):
    for relative, digest in sorted(group.items()):
        path = src / relative
        if not path.is_file():
            raise SystemExit('Vendor snapshot file missing: ' + relative)
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise SystemExit('Vendor snapshot hash mismatch: ' + relative)

verify({('upstream/' + name): digest
        for name, digest in snapshot['verbatimUpstream'].items()})
verify({('patches/' + name): digest for name, digest in snapshot['patches'].items()})
verify({('shims/' + name): digest for name, digest in snapshot['authored']['shims'].items()})
verify({('authored/' + name): digest
        for name, digest in snapshot['authored']['protocolExports'].items()})
for name, digest in snapshot['records'].items():
    path = src / name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit('Vendor record hash mismatch: ' + name)
PY

# Stage the verbatim MIT snapshot, then apply the documented legacy-toolchain
# patch. The vendored upstream/ tree itself is never edited.
cp -R "$SRC/upstream/." "$OUT/sources/"
for patch in "$SRC"/patches/*.patch; do
  [ -s "$patch" ] || fail "Empty patch: $patch"
  printf 'Applying %s\n' "$(basename -- "$patch")"
  ( cd "$OUT/sources" && "$PATCH_TOOL" -p1 --batch --forward < "$patch" ) > "$OUT/logs/patch.log" 2>&1 \
    || { tail -20 "$OUT/logs/patch.log" >&2; fail "Patch failed: $(basename -- "$patch")"; }
done
# Reconstructed declaration shims for the omitted unlicensed component, and the
# authored protocol-identity TU. Neither file is upstream text.
cp "$SRC"/shims/*.h "$OUT/sources/"
cp "$SRC"/authored/*.m "$OUT/sources/"
# A patch that silently stops applying must fail the build, not map a different
# runtime. Guard on the exact behaviour the contract assumes.
if grep -R -q '@available(iOS 13' "$OUT/sources"; then
  fail 'Patched sources still delegate to the native iOS 13 API'
fi
if grep -R -q 'NSClassFromString(@"NSCollectionLayout\|NSClassFromString(@"UICollectionViewCompositionalLayout' "$OUT/sources"; then
  fail 'Patched sources still look up native compositional classes'
fi

# Private PST-mapped declarations so the same sources compile for the toolchain's
# collection runtime instead of the SDK's native collection classes.
"$PY" "$SRC/generate-runtime-overlay.py" "$SDK" "$OUT/overlay"

OBJECTS=()
for source in "$OUT"/sources/*.m; do
  name=$(basename -- "$source" .m)
  # This LLVM/ld64 combination drops Thumb bits on local data relocations; the
  # old dyld then executes Thumb code in ARM mode. Build every method, block and
  # constructor in ARM mode, exactly like the collection runtime. Never patch
  # pointers after the fact.
  command=("$CLANG" -target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -g0
    -fobjc-arc -fblocks -fno-modules -fvisibility=default
    -Wno-unguarded-availability -Wno-unguarded-availability-new
    "-ffile-prefix-map=$OUT=/legacy-compositional-layout"
    "-ffile-prefix-map=$HERE=utils/legacy-ios5-mac"
    -ivfsoverlay "$OUT/overlay/overlay.json"
    -I "$OUT/sources/include" -I "$OUT/sources"
    -c "$source" -o "$OUT/objects/$name.o")
  # The unguarded-availability diagnostics are suppressed deliberately: the SDK
  # annotations describe the native OS, while this runtime intentionally provides
  # the collection family through PST and uses an iOS 6 typed identifier that is
  # nil on iOS 5. Availability gating for Swift lives in the Clang importer.
  (printf '%q ' "${command[@]}"; printf '\n') > "$OUT/logs/$name.command"
  if ! /usr/bin/nice -n 15 "${command[@]}" > "$OUT/logs/$name.log" 2>&1; then
    tail -40 "$OUT/logs/$name.log" >&2
    fail "Compilation failed: $name (see $OUT/logs)"
  fi
  OBJECTS+=("$OUT/objects/$name.o")
done
[ "${#OBJECTS[@]}" -gt 0 ] || fail 'No sources compiled.'
(printf '%q ' "$AR" rcs "$OUT/libswiftLegacyCompositionalLayout.a" "${OBJECTS[@]}"; printf '\n') \
  > "$OUT/logs/archive.command"
"$AR" rcs "$OUT/libswiftLegacyCompositionalLayout.a" "${OBJECTS[@]}" > "$OUT/logs/archive.log" 2>&1

# Verify the mapped runtime identities exist and write the importer contract.
"$PY" "$SRC/emit-runtime-mapping.py" "$NM" "$OUT/libswiftLegacyCompositionalLayout.a" \
  "$OUT/legacy-compositional-layout/compositional-layout-mapping.json"
cp "$SRC/LICENSE" "$SRC/THIRD-PARTY-NOTICES.md" "$SRC/SNAPSHOT.json" "$SRC/STATUS.md" \
  "$OUT/legacy-compositional-layout/"

"$PY" - "$SRC" "$SDK" "$CLANG" "$AR" "$OUT" <<'PY'
import hashlib, json, pathlib, subprocess, sys
src, sdk, clang, ar, out = map(pathlib.Path, sys.argv[1:])
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

def tree(root):
    return {str(p.relative_to(root)): sha(p)
            for p in sorted(root.rglob('*')) if p.is_file()}

manifest = {
    'target': 'armv7-apple-ios5.0', 'instructionSet': 'ARM', 'arc': True, 'blocks': True,
    'sdk': str(sdk.resolve()), 'clang': str(clang.resolve()), 'ar': str(ar.resolve()),
    'clangVersion': subprocess.check_output([str(clang), '--version'], text=True),
    # Apple's ar has no version query (it prints usage for --version). The exact
    # tool is recorded by path, and the resulting archive is hash-bound below.
    'patches': tree(src / 'patches'),
    'vendorSnapshotSHA256': tree(src / 'upstream'),
    'shimsSHA256': tree(src / 'shims'),
    'authoredSHA256': tree(src / 'authored'),
    # The overlay JSON necessarily contains build-local absolute paths for the
    # VFS roots, so only the generated declaration text is hash-bound.
    'overlayHeadersSHA256': {p.name: sha(p) for p in sorted((out / 'overlay').glob('gen-*.h'))},
    'archiveSHA256': sha(out / 'libswiftLegacyCompositionalLayout.a'),
    'mappingSHA256': sha(out / 'legacy-compositional-layout/compositional-layout-mapping.json'),
    'qualification': 'Source compilation and symbol verification only; not device/runtime qualification.',
}
(out / 'build-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
printf 'Built armv7 iOS 5 compositional-layout runtime: %s\n' "$OUT"
printf '  archive: %s\n' "$OUT/libswiftLegacyCompositionalLayout.a"
printf '  importer contract: %s\n' "$OUT/legacy-compositional-layout/compositional-layout-mapping.json"
