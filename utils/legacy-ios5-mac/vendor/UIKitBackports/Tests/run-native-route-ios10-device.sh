#!/bin/bash
# Native-route gate on an iOS 10 device (iPhone 6, iOS 10.3.3).
#
# Builds the arm64 command-line probe (the backport hook runtime plus
# native_route_ios10_cli_test.m), uploads it over SSH and runs it there. The probe asserts that the hook runtime
# loads and stays inert for everything iOS 10 already provides, and that Apple's own collection view lays out and
# self-sizes normally.
#
# Usage: run-native-route-ios10-device.sh SSH_PORT [DEVICE_PASSWORD]
#   The device must be jailbroken with SSH (root). Default password is the common jailbreak default; override
#   with the second argument or DEVICE_PASSWORD. Requires iproxy PORT:22 -u <UDID> on the host.
set -euo pipefail
PORT=${1:?usage: run-native-route-ios10-device.sh SSH_PORT [DEVICE_PASSWORD]}
export DEVICE_PASSWORD=${2:-${DEVICE_PASSWORD:-alpine}}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
RT="$HERE/../Runtime"
CLANG=${CLANG:-/Users/jwalr/Applications/Xcode-13.4.1.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang}
SDK=${SDK:-/Users/jwalr/Applications/Xcode-13.4.1.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/native-ios10.XXXXXX")
FLAGS=(-target arm64-apple-ios10.0 -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules
       -Wno-nullability-completeness -Wno-incompatible-pointer-types
       -L /Users/jwalr/Developer/Legacy-Build-Inputs)
"$CLANG" "${FLAGS[@]}" -I "$RT" -c "$RT/UICCollectionViewDisplay.m" -o "$OUT/display.o"
"$CLANG" "${FLAGS[@]}" "$HERE/native_route_ios10_cli_test.m" "$OUT/display.o" \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -o "$OUT/probe10"
cat > "$OUT/ent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>platform-application</key><true/><key>com.apple.private.security.no-container</key><true/><key>get-task-allow</key><true/></dict></plist>
PLIST
ldid -S"$OUT/ent.plist" "$OUT/probe10"
python3 - "$OUT" "$PORT" <<'PY'
import os, sys, pexpect
out, port = sys.argv[1], sys.argv[2]
pw = os.environ["DEVICE_PASSWORD"].encode()
opts = ("-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no "
        "-o PreferredAuthentications=password -o ConnectTimeout=10")
def expect_pw(child, timeout):
    if child.expect([b"[Pp]assword:", pexpect.EOF, pexpect.TIMEOUT], timeout=timeout) == 0:
        child.sendline(pw)
    child.expect(pexpect.EOF, timeout=timeout)
    return (child.before or b"").decode("utf-8", "replace")
up = pexpect.spawn(f"scp -O -P {port} {opts} {out}/probe10 root@127.0.0.1:/tmp/probe10", timeout=120, encoding=None)
expect_pw(up, 120)
run = pexpect.spawn(f"ssh -p {port} {opts} root@127.0.0.1 'chmod 755 /tmp/probe10; /tmp/probe10; rc=$?; rm -f /tmp/probe10; echo EXIT=$rc'", timeout=180, encoding=None)
text = expect_pw(run, 180)
sys.stdout.write(text)
sys.exit(0 if "RESULT: PASS" in text and "EXIT=0" in text else 1)
PY
echo "PASS: native route on the iOS 10 device (hooks inert, native layout intact)"
