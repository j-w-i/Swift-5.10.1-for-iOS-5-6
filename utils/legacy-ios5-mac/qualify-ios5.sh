#!/bin/bash
# qualify-ios5.sh - one command that turns a freshly built iOS 5 toolchain into a
# qualified environment, so a new user never assembles qualification evidence by hand.
#
#   LEGACY_BUILD_ROOT=/path/to/build ./qualify-ios5.sh
#   LEGACY_BUILD_ROOT=/path/to/build ./qualify-ios5.sh --environment-root "<env>"   # + publish profile
#
# What it does:
#   1. installs out/swift-5.10.1-ios5.xctoolchain into <env>/Toolchains/5.10.1-ios5.xctoolchain
#   2. runs the five qualification checks against that toolchain and preserves log + artifact evidence:
#        staticBuild        the build products are the assembled ones (compiler/driver hashes bound)
#        abiClassMarking    check-class-marking.sh: legacy marker only with the iOS 5 flags
#        ios5Archive        armv7 iOS 5.0 executable: LC_VERSION_MIN 5.0, LC_UNIXTHREAD, no LC_MAIN
#        defaultIOS6Archive armv7 iOS 7.0 executable from the default resource tree: LC_MAIN
#        imports            the iOS 5 executable's Swift imports are all @rpath and resolvable from swift_ios5
#   3. writes qualification-evidence.json (schema pinned by publish-ios5-profile.py) and publishes
#      <env>/ios5-profile.json with publish-ios5-profile.py, which re-verifies every hash.
#   4. always reports deviceExecution as "pending": static qualification is not a device test.
#
# Options:
#   --environment-root DIR   kit environment root (default: the single installed environment)
#   --toolchain PATH         assembled toolchain (default: $LEGACY_BUILD_ROOT/out/swift-5.10.1-ios5.xctoolchain)
#   --sdk PATH               iPhoneOS SDK (default: the environment's Xcode, else $XCODE_13_4_1_DEVELOPER_DIR)
#   --output DIR             evidence directory (default: $LEGACY_BUILD_ROOT/out/ios5-qualification)
#   --check-only             run the checks and write evidence, do not install/publish
#   --force                  re-run the checks even if the environment already has a profile
set -euo pipefail

die() { echo "qualify-ios5: $*" >&2; exit 1; }
need_value() { [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "missing value for $1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TOOLCHAIN=""
ENVROOT=""
SDK=""
OUTPUT=""
CHECK_ONLY=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --environment-root) need_value "$@"; ENVROOT="$2"; shift 2 ;;
    --toolchain) need_value "$@"; TOOLCHAIN="$2"; shift 2 ;;
    --sdk) need_value "$@"; SDK="$2"; shift 2 ;;
    --output) need_value "$@"; OUTPUT="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Defaults: the build root this script ships with, and the single installed environment.
if [ -z "$TOOLCHAIN" ]; then
  [ -n "${LEGACY_BUILD_ROOT:-}" ] || die "set LEGACY_BUILD_ROOT or pass --toolchain"
  TOOLCHAIN="$LEGACY_BUILD_ROOT/out/swift-5.10.1-ios5.xctoolchain"
fi
[ -d "$TOOLCHAIN" ] || die "toolchain not found: $TOOLCHAIN"
if [ -z "$ENVROOT" ]; then
  CANDIDATES=("$HOME/Library/Application Support/Legacy Swift Development Kit/Environments"/*)
  FOUND=()
  for c in "${CANDIDATES[@]}"; do [ -f "$c/receipt.json" ] && FOUND+=("$c"); done
  if [ "${#FOUND[@]}" -eq 1 ]; then ENVROOT="${FOUND[0]}"; else CHECK_ONLY=1; fi
fi
if [ -n "$ENVROOT" ]; then
  ENVROOT="$(cd "$ENVROOT" && pwd -P)" || die "environment root not found: $ENVROOT"
  [ -f "$ENVROOT/receipt.json" ] || die "not a kit environment (no receipt.json): $ENVROOT"
  if [ "$CHECK_ONLY" -eq 0 ] && [ -f "$ENVROOT/ios5-profile.json" ] && [ "$FORCE" -eq 0 ]; then
    echo "iOS 5 is already qualified in $ENVROOT (ios5-profile.json). Use --force to redo it."
    exit 0
  fi
fi

# iPhoneOS SDK: the kit environment's Xcode first, then the build's Xcode 13.4.1.
if [ -z "$SDK" ]; then
  for dev in "${ENVROOT:+$ENVROOT/Xcode.app/Contents/Developer}" "${XCODE_13_4_1_DEVELOPER_DIR:-}"; do
    [ -n "$dev" ] && [ -d "$dev/Platforms/iPhoneOS.platform/Developer/SDKs" ] || continue
    SDK="$(ls -d "$dev/Platforms/iPhoneOS.platform/Developer/SDKs"/iPhoneOS*.sdk 2>/dev/null | sort -V | tail -1)"
    [ -n "$SDK" ] && break
  done
fi
[ -n "$SDK" ] && [ -d "$SDK" ] || die "no iPhoneOS SDK found; pass --sdk or set XCODE_13_4_1_DEVELOPER_DIR"
HOST_XCODE_DEV="${ENVROOT:+$ENVROOT/Xcode.app/Contents/Developer}"
HOST_XCODE_DEV="${HOST_XCODE_DEV:-${XCODE_13_4_1_DEVELOPER_DIR:-}}"
HOST_CLANG="$HOST_XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
[ -x "$HOST_CLANG" ] || HOST_CLANG="$TOOLCHAIN/usr/bin/clang"
[ -x "$HOST_CLANG" ] || die "no linker clang found (looked in the environment Xcode and the toolchain)"

if [ -z "$OUTPUT" ]; then
  [ -n "${LEGACY_BUILD_ROOT:-}" ] || die "set LEGACY_BUILD_ROOT or pass --output"
  OUTPUT="$LEGACY_BUILD_ROOT/out/ios5-qualification"
fi
[ ! -e "$OUTPUT" ] || die "refusing to overwrite evidence directory: $OUTPUT (choose --output or remove it)"

# 1. Install the assembled toolchain where the profile expects it.
INSTALLED=0
if [ -n "$ENVROOT" ] && [ "$CHECK_ONLY" -eq 0 ]; then
  DEST="$ENVROOT/Toolchains/5.10.1-ios5.xctoolchain"
  if [ -d "$DEST" ]; then
    [ "$DEST" -ef "$TOOLCHAIN" ] || die "$DEST already exists and is not this toolchain; remove it or pass --toolchain"
  elif [ "$(basename "$(dirname "$TOOLCHAIN")")" = "Toolchains" ]; then
    : # already an installed toolchain; the profile can bind it where it is
  else
    echo "Installing $TOOLCHAIN -> $DEST"
    /bin/cp -R "$TOOLCHAIN" "$DEST"
    INSTALLED=1
    TOOLCHAIN="$DEST"
  fi
fi
TC="$TOOLCHAIN"
RES="$TC/usr/lib/swift_ios5"
[ -d "$RES/iphoneos" ] || die "toolchain has no usr/lib/swift_ios5/iphoneos (not an isolated iOS 5 assembly): $TC"

# Clang builtin resource directory: highest installed version that ships stdarg.h.
CLANG_RES=""
shopt -s nullglob
for candidate in "$TC"/usr/lib/clang/*/; do
  [ -f "${candidate}include/stdarg.h" ] && CLANG_RES="${candidate%/}"
done
[ -n "$CLANG_RES" ] || die "toolchain has no usr/lib/clang/<version>/include/stdarg.h"

BUILDLOG=""
if [ -n "${LEGACY_BUILD_ROOT:-}" ] && [ -s "$LEGACY_BUILD_ROOT/logs/compiler-515.log" ]; then
  BUILDLOG="$LEGACY_BUILD_ROOT/logs/compiler-515.log"
fi
# The profile publisher requires every provenance log to be non-empty. Successful commands are often silent,
# so record an explicit pass line when a log produced no diagnostics.
ensure_log() { # file message
  [ -s "$1" ] || printf '%s\n' "$2" > "$1"
}

mkdir -p "$OUTPUT/logs"
echo "== 1/5 static build products"
"$TC/usr/bin/swift-frontend" --version > "$OUTPUT/logs/static-build.txt" 2>&1 || die "swift-frontend --version failed"
if [ -n "$BUILDLOG" ]; then cp "$BUILDLOG" "$OUTPUT/logs/compiler-515.log"; else cp "$OUTPUT/logs/static-build.txt" "$OUTPUT/logs/compiler-515.log"; fi
echo "   $(head -1 "$OUTPUT/logs/static-build.txt")"
/usr/bin/python3 "$HERE/check-macho-initializers.py" "$RES/iphoneos/libswiftUIKit.dylib" \
  > "$OUTPUT/logs/arm-initializers.log" 2>&1 \
  || { tail -30 "$OUTPUT/logs/arm-initializers.log" >&2; die "unsafe ARM/Thumb runtime initializer"; }
for name in Dispatch CoreGraphics Foundation Metal QuartzCore CoreImage UIKit; do
  /usr/bin/python3 "$HERE/check-thumb-pointers.py" "$RES/iphoneos/libswift$name.dylib" \
    >> "$OUTPUT/logs/arm-initializers.log" 2>&1 \
    || { tail -20 "$OUTPUT/logs/arm-initializers.log" >&2; die "unsafe ARM/Thumb pointer in libswift$name"; }
done

echo "== 2/5 ABI class marking"
bash "$HERE/check-class-marking.sh" "$TC/usr/bin/swiftc" "$OUTPUT/class-marking" "$TC/usr/lib/swift" \
  > "$OUTPUT/logs/class-marking.log" 2>&1 || { tail -20 "$OUTPUT/logs/class-marking.log" >&2; die "class-marking check failed"; }
ensure_log "$OUTPUT/logs/class-marking.log" "PASS: class-marking check completed without diagnostics"

echo "== 3/5 iOS 5 armv7 link (LC_VERSION_MIN 5.0, LC_UNIXTHREAD, no LC_MAIN)"
mkdir -p "$OUTPUT/ios5-app"
cat > "$OUTPUT/ios5-app/main.swift" <<'SW'
// Keep the SDK's transitive os/log import covered: this failed at an iOS 5
// deployment target even though Foundation/UIKit alone could compile.
import Foundation
import UIKit
import Dispatch
import Accelerate
final class QualificationMarker { var value = 41; func bump() -> Int { value + 1 } }
let marker = QualificationMarker()
print("ios5-qualification \(marker.bump()) \(String(describing: Date.init(timeIntervalSince1970: 0)))")
SW
SDKROOT_ARGS=(-sdk "$SDK")
"$TC/usr/bin/swiftc" -c "$OUTPUT/ios5-app/main.swift" -target armv7-apple-ios5.0 "${SDKROOT_ARGS[@]}" \
  -enable-legacy-ios5-runtime -resource-dir "$RES" \
  -Xcc -resource-dir -Xcc "$CLANG_RES" -Xcc -I"$RES/legacy-overlay-shims" \
  -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements \
  -Xfrontend -disable-autolink-library -Xfrontend swiftFileProvider \
  -o "$OUTPUT/ios5-app/main.o" > "$OUTPUT/logs/ios5-compile.log" 2>&1 \
  || { tail -20 "$OUTPUT/logs/ios5-compile.log" >&2; die "iOS 5 compile failed"; }
ensure_log "$OUTPUT/logs/ios5-compile.log" "PASS: iOS 5 compile completed without diagnostics"
"$HOST_CLANG" -target armv7-apple-ios5.0 -isysroot "$SDK" -nostartfiles -Wl,-no_new_main \
  -L "$RES/iphoneos" "$OUTPUT/ios5-app/main.o" \
  "$RES/iphoneos/crt1.3.1.o" "$RES/iphoneos/libswiftLegacyIOS5Backports.a" \
  -lobjc -lSystem -Wl,-rpath,@executable_path/Frameworks -o "$OUTPUT/ios5-app/App" \
  > "$OUTPUT/logs/ios5-link.log" 2>&1 \
  || { tail -20 "$OUTPUT/logs/ios5-link.log" >&2; die "iOS 5 link failed"; }
ensure_log "$OUTPUT/logs/ios5-link.log" "PASS: iOS 5 link completed without linker diagnostics"
OTOOL="$HOST_XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/otool"; [ -x "$OTOOL" ] || OTOOL=/usr/bin/otool
"$OTOOL" -l "$OUTPUT/ios5-app/App" > "$OUTPUT/ios5-app/load-commands.txt"
grep -q "cmd LC_UNIXTHREAD" "$OUTPUT/ios5-app/load-commands.txt" || die "iOS 5 executable has no LC_UNIXTHREAD"
if grep -q "cmd LC_MAIN" "$OUTPUT/ios5-app/load-commands.txt"; then die "iOS 5 executable has a modern LC_MAIN entry"; fi
MIN_VERSION="$(awk '/cmd LC_VERSION_MIN_IPHONEOS/ { seen=1; next } seen && $1 == "version" { print $2; exit }' "$OUTPUT/ios5-app/load-commands.txt")"
case "$MIN_VERSION" in 5|5.*) ;; *) die "iOS 5 executable minimum version is $MIN_VERSION, expected 5.x" ;; esac
echo "   min iOS $MIN_VERSION, LC_UNIXTHREAD, no LC_MAIN"

# Ordinary UIKit source must work in independent dependency modules, and only
# iOS 5 compilation may reference the implementation built into libswiftUIKit.
bash "$HERE/check-collection-api.sh" "$TC" "$SDK" "$OUTPUT/collection-api" \
  > "$OUTPUT/logs/collection-api.log" 2>&1 \
  || { tail -30 "$OUTPUT/logs/collection-api.log" >&2; die "compiler-native collection API check failed"; }

# Backported UIKit APIs must be SDK surfaces at an iOS 5 target and correctly
# version-gated for later targets and for members the backports do not implement.
bash "$HERE/check-backports-api.sh" "$TC" "$SDK" "$OUTPUT/backports-api" \
  > "$OUTPUT/logs/backports-api.log" 2>&1 \
  || { tail -40 "$OUTPUT/logs/backports-api.log" >&2; die "UIKit backport API check failed"; }

echo "== 4/5 default resource tree still builds iOS 7.0 (LC_MAIN)"
mkdir -p "$OUTPUT/default-ios6-app"
printf 'let values = [1, 2, 3]\nprint("default-route \\(values.reduce(0, +))")\n' > "$OUTPUT/default-ios6-app/main.swift"
"$TC/usr/bin/swiftc" -c "$OUTPUT/default-ios6-app/main.swift" -target armv7-apple-ios7.0 "${SDKROOT_ARGS[@]}" \
  -resource-dir "$TC/usr/lib/swift" -o "$OUTPUT/default-ios6-app/main.o" > "$OUTPUT/logs/default-ios6-compile.log" 2>&1 \
  || { tail -20 "$OUTPUT/logs/default-ios6-compile.log" >&2; die "default-route compile failed"; }
ensure_log "$OUTPUT/logs/default-ios6-compile.log" "PASS: default-route compile completed without diagnostics"
"$HOST_CLANG" -target armv7-apple-ios7.0 -isysroot "$SDK" -L "$TC/usr/lib/swift/iphoneos" \
  "$OUTPUT/default-ios6-app/main.o" -lobjc -lSystem -o "$OUTPUT/default-ios6-app/App" \
  > "$OUTPUT/logs/default-ios6-link.log" 2>&1 \
  || { tail -20 "$OUTPUT/logs/default-ios6-link.log" >&2; die "default-route link failed"; }
ensure_log "$OUTPUT/logs/default-ios6-link.log" "PASS: default-route link completed without linker diagnostics"
"$OTOOL" -l "$OUTPUT/default-ios6-app/App" > "$OUTPUT/default-ios6-app/load-commands.txt"
grep -q "cmd LC_MAIN" "$OUTPUT/default-ios6-app/load-commands.txt" || die "default-route executable has no LC_MAIN"
grep -q "cmd LC_UNIXTHREAD" "$OUTPUT/default-ios6-app/load-commands.txt" && die "default-route executable wrongly uses LC_UNIXTHREAD"

echo "== 5/5 imports and host signatures"
/usr/bin/python3 - "$RES" "$OUTPUT/ios5-app/App" "$OUTPUT/imports.txt" <<'PY'
import subprocess, sys, pathlib
res, app, report = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
def run(*cmd):
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False).stdout
lines, problems = [], []
deps = [line.split(" (compatibility")[0].strip() for line in run("/usr/bin/otool", "-L", str(app)).splitlines()[1:]]
for dep in deps:
    if not dep: continue
    lines.append("dependency " + dep)
    if "/usr/lib/swift/" in dep: problems.append("system Swift dependency: " + dep)
    if dep.startswith("@rpath/libswift"):
        if not (res / "iphoneos" / dep.split("/")[-1]).is_file():
            problems.append("missing runtime dylib for " + dep)
provided = set()
for dylib in sorted((res / "iphoneos").glob("*.dylib")):
    for line in run("/usr/bin/nm", "-arch", "armv7", "-gU", str(dylib)).splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] in ("T", "D", "S", "B"): provided.add(parts[2])
missing = []
for line in run("/usr/bin/nm", "-arch", "armv7", "-u", str(app)).splitlines():
    parts = line.split()
    if len(parts) >= 2 and parts[-1].startswith("_$") and parts[-1] not in provided:
        missing.append(parts[-1])
lines.append("swift references missing from swift_ios5: " + str(len(missing)))
lines += ["missing " + name for name in missing]
report.write_text("\n".join(lines) + "\n")
if problems or missing:
    print("\n".join(problems + ["missing " + name for name in missing]), file=sys.stderr)
    raise SystemExit(1)
print("   imports resolve against swift_ios5; no system Swift dylib")
PY
[ -s "$OUTPUT/imports.txt" ] || die "import report missing"

for name in swift-frontend swift-driver swiftc swift; do
  [ -x "$TC/usr/bin/$name" ] || die "toolchain is missing usr/bin/$name"
  codesign --verify --strict "$TC/usr/bin/$name" > "$OUTPUT/logs/codesign-$name.log" 2>&1 \
    || { cat "$OUTPUT/logs/codesign-$name.log" >&2; die "ad-hoc signature verification failed for $name"; }
done
echo "   host binaries verify"

# 3. Evidence bound to this exact toolchain build, then the profile publisher re-verifies it.
/usr/bin/python3 - "$TC" "$RES" "$OUTPUT" "$BUILDLOG" <<'PY'
import hashlib, json, pathlib, sys
tc, res, out, buildlog = (pathlib.Path(p) for p in sys.argv[1:5])
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
fixed = ["Info.plist", "usr/lib/swift/iphoneos/libswiftCore.dylib"] + [
    "usr/lib/swift_ios5/iphoneos/" + name for name in
    ("crt1.3.1.o", "libswiftLegacyIOS5Backports.a") + tuple(
        "libswift" + overlay + ".dylib" for overlay in
        ("Core", "Darwin", "ObjectiveC", "CoreFoundation") + ("Dispatch", "CoreGraphics",
         "Foundation", "Metal", "QuartzCore", "CoreImage", "UIKit"))]
fixed += ["usr/lib/swift_ios5/legacy-collection/" + name for name in
          ("Headers/UIKitLegacyCollection.h", "LICENSE", "SNAPSHOT.json")]
fixed += ["usr/lib/swift_ios5/legacy-backports/INVENTORY.json"]
groups = []
for module in ("Swift", "Darwin", "Dispatch", "CoreGraphics", "Foundation", "Metal",
               "QuartzCore", "CoreImage", "UIKit"):
    available = [f"usr/lib/swift_ios5/iphoneos/{module}.swiftmodule/{spelling}"
                 for spelling in ("armv7.swiftmodule", "armv7-apple-ios.swiftmodule")
                 if (tc / f"usr/lib/swift_ios5/iphoneos/{module}.swiftmodule/{spelling}").is_file()]
    if not available:
        raise SystemExit("missing rebuilt armv7 module: " + module)
    groups.append(available)
resource_sha = {relative: digest(tc / relative) for relative in fixed + [n for g in groups for n in g]}
provenance = {
    "staticBuild": {"logPath": str(out / "logs/compiler-515.log"), "artifactPath": str(tc / "usr/bin/swift-frontend")},
    "abiClassMarking": {"logPath": str(out / "logs/class-marking.log"), "artifactPath": str(out / "class-marking")},
    "ios5Archive": {"logPath": str(out / "logs/ios5-link.log"), "artifactPath": str(out / "ios5-app")},
    "defaultIOS6Archive": {"logPath": str(out / "logs/default-ios6-link.log"), "artifactPath": str(out / "default-ios6-app")},
    "imports": {"logPath": str(out / "imports.txt"), "artifactPath": str(out / "ios5-app")},
}
evidence = {
    "schemaVersion": 1,
    "staticBuildVerified": True, "abiClassMarkingVerified": True, "ios5ArchiveVerified": True,
    "defaultIOS6ArchiveVerified": True, "importsVerified": True, "hostSignaturesVerified": True,
    "compilerSHA256": digest(tc / "usr/bin/swift-frontend"),
    "driverSHA256": digest(tc / "usr/bin/swift-driver"),
    "assemblyReceiptSHA256": digest(tc / "ios5-assembly-receipt.json"),
    "resourceSHA256": resource_sha,
    "deviceExecution": "pending",
    "provenance": provenance,
}
(out / "qualification-evidence.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
print("   evidence: " + str(out / "qualification-evidence.json"))
PY

if [ "$CHECK_ONLY" -eq 1 ] || [ -z "$ENVROOT" ]; then
  echo
  echo "Checks passed; evidence written to $OUTPUT/qualification-evidence.json."
  echo "No environment was qualified. Publish with:"
  echo "  ./qualify-ios5.sh --environment-root \"<env>\" --toolchain \"$TC\" --output \"$OUTPUT\""
  exit 0
fi

/usr/bin/python3 "$HERE/publish-ios5-profile.py" --environment-root "$ENVROOT" --toolchain "$TC" \
  --evidence "$OUTPUT/qualification-evidence.json"
echo
echo "iOS 5 is now available in the kit for that environment (device execution: pending, static checks only)."
if [ "$INSTALLED" -eq 1 ]; then echo "Toolchain installed at $TC"; fi
