# Shared defaults for the device/CLI test scripts (sourced, not run). Override any of them in the
# environment. Defaults come from the installed Legacy Swift Development Kit environment, so nothing
# depends on a particular user's folders.
#   XCODE_13_4_1_DEVELOPER_DIR  Xcode 13.4.1 .../Contents/Developer
#   LEGACY_CRT_DIR              directory containing crt1.3.1.o (iOS < 6 startup object)
_LSDK_ENVS="$HOME/Library/Application Support/Legacy Swift Development Kit/Environments"
if [ -z "${XCODE_13_4_1_DEVELOPER_DIR:-}" ]; then
  for _x in "$_LSDK_ENVS"/*/Xcode-13.4.1-LSDK.app "$_LSDK_ENVS"/*/Xcode.app; do
    [ -d "$_x/Contents/Developer" ] && { XCODE_13_4_1_DEVELOPER_DIR="$_x/Contents/Developer"; break; }
  done
fi
: "${XCODE_13_4_1_DEVELOPER_DIR:?set XCODE_13_4_1_DEVELOPER_DIR to Xcode 13.4.1.app/Contents/Developer}"
if [ -z "${LEGACY_CRT_DIR:-}" ]; then
  for _c in "$_LSDK_ENVS"/*/Toolchains/5.10.1-ios5.xctoolchain/usr/lib/swift_ios5/iphoneos; do
    [ -f "$_c/crt1.3.1.o" ] && { LEGACY_CRT_DIR="$_c"; break; }
  done
fi
: "${LEGACY_CRT_DIR:?set LEGACY_CRT_DIR to a directory containing crt1.3.1.o}"
export XCODE_13_4_1_DEVELOPER_DIR LEGACY_CRT_DIR
unset _LSDK_ENVS _x _c
