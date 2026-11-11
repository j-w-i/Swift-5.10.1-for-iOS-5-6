#!/bin/bash
# Build-only: persistent test app for Apple-route self-sizing with no delegate. Installs nothing.
# Usage: build-nil-delegate-device.sh RUNTIME_SOURCE.m NAME NEW_ABSOLUTE_OUTPUT_DIR
set -euo pipefail
RT=${1:?runtime .m};NAME=${2:?app name};OUT=${3:?new output}
[[ "$NAME" =~ ^[A-Za-z][A-Za-z0-9]*$ && "$OUT" = /* && ! -e "$OUT" ]] || { echo 'bad arguments' >&2; exit 64; }
D=/Users/jwalr/Applications/Xcode-13.4.1.app/Contents/Developer
SDK="$D/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk";CC="$D/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P);mkdir -p "$OUT/$NAME.app"
"$CC" -target armv7-apple-ios6.0 -marm -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -Wno-unguarded-availability-new \
 -L /Users/jwalr/Developer/Legacy-Build-Inputs "$HERE/nil_delegate_selfsizing.m" "$RT" \
 -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -o "$OUT/$NAME.app/$NAME" >"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log" >&2; exit 1; }
python3 - "$OUT/$NAME.app" "$NAME" <<'PY'
import plistlib,sys,pathlib
app,n=sys.argv[1:]
plistlib.dump(dict(CFBundleExecutable=n,CFBundleIdentifier='org.example.'+n,CFBundleName=n,CFBundlePackageType='APPL',CFBundleVersion='1',MinimumOSVersion='6.0',UIDeviceFamily=[1],CFBundleDevelopmentRegion='en'),open(pathlib.Path(sys.argv[1])/'Info.plist','wb'))
PY
ldid -S "$OUT/$NAME.app/$NAME";tar -czf "$OUT/$NAME.tgz" -C "$OUT" "$NAME.app";echo "built $OUT/$NAME.tgz"
