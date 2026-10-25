#!/bin/bash
# Fetch every source dependency of the dual iOS 5/6 Swift 5.10.1 toolchain into $LEGACY_BUILD_ROOT/src
# at pinned upstream tags and apply this repo's patches. Idempotent; never deletes anything.
set -euo pipefail
ROOT="${LEGACY_BUILD_ROOT:?set LEGACY_BUILD_ROOT to an empty build directory}"
HERE="$(cd "$(dirname "$0")/../.." && pwd -P)"          # this repo's root (the swift 5.10.1 fork)
TAG=swift-5.10.1-RELEASE
SRC="$ROOT/src"; mkdir -p "$SRC"
clone() { # name url ref
  [ -d "$SRC/$1/.git" ] || git clone -q --depth 1 --branch "$3" "$2" "$SRC/$1"
}
[ -e "$SRC/swift" ] || ln -s "$HERE" "$SRC/swift"        # the fork itself IS the swift source
clone llvm-project  https://github.com/swiftlang/llvm-project.git  "$TAG"
clone cmark         https://github.com/swiftlang/swift-cmark.git   "$TAG"
clone swift-syntax  https://github.com/swiftlang/swift-syntax.git  "$TAG"
clone string-processing https://github.com/swiftlang/swift-experimental-string-processing.git "$TAG"
clone swift-driver  https://github.com/swiftlang/swift-driver.git  "$TAG"
apply() { # repo patchfile
  if git -C "$SRC/$1" apply --check "$2" 2>/dev/null; then git -C "$SRC/$1" apply "$2"; echo "applied $(basename "$2") to $1"
  elif git -C "$SRC/$1" apply --reverse --check "$2" 2>/dev/null; then echo "$(basename "$2") already applied to $1"
  else echo "PATCH DOES NOT APPLY: $2 -> $1" >&2; exit 1; fi
}
apply llvm-project "$HERE/patches/llvm-project-legacy-ios5-atomics.patch"
apply swift-driver "$HERE/patches/swift-driver-legacy-ios5.patch"
echo "Sources ready in $SRC"
