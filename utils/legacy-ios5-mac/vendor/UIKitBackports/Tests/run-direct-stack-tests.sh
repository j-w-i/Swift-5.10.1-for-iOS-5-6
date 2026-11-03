#!/bin/bash
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
V=$(dirname "$HERE")
W=$(mktemp -d /tmp/direct-stack-parity.XXXXXX)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
DEVICE=${1:-0827B93D-F8C3-49C4-9ACF-4A5064843B45}
TARGET=$(uname -m)-apple-ios15.0-simulator
clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -fblocks -Wno-deprecated-declarations \
  -I "$V/OAStackView" "$V"/OAStackView/*.m "$HERE/direct_stack_test.m" \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -o "$W/test"
xcrun simctl spawn "$DEVICE" "$W/test"
printf 'Test artifacts: %s\n' "$W"
