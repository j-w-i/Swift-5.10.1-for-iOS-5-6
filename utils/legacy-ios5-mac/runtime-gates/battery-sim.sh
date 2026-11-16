#!/bin/bash
# battery-sim.sh APP_DIR BUNDLE_ID SIM_UDID  : crash battery on a modern simulator. Fails on any crash report.
APP=${1:?}; BID=${2:?}; SIM=${3:?}; FAIL=0
pass(){ echo "PASS  $*"; }; fail(){ echo "FAIL  $*"; FAIL=1; }
before=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -ic "$(basename "$APP" .app)")
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null 2>&1
xcrun simctl uninstall $SIM $BID 2>/dev/null; xcrun simctl install $SIM "$APP" || { fail install; exit 1; }
[ -n "$DISCORD_TOKEN" ] && xcrun simctl spawn $SIM defaults write $BID discordToken "$DISCORD_TOKEN"
alive(){ xcrun simctl spawn $SIM launchctl list 2>/dev/null | grep -c "UIKitApplication:$BID"; }
# 1 cold launch x12 (kill between)
ok=0; for i in $(seq 12); do xcrun simctl terminate $SIM $BID 2>/dev/null; xcrun simctl launch $SIM $BID >/dev/null 2>&1; sleep 2; [ "$(alive)" = 1 ] && ok=$((ok+1)); done
[ $ok = 12 ] && pass "12/12 cold launches stayed up" || fail "cold launches: $ok/12"
# 2 soak
xcrun simctl launch $SIM $BID >/dev/null 2>&1; sleep ${SOAK:-60}; [ "$(alive)" = 1 ] && pass "${SOAK:-60}s soak" || fail soak
# 3 memory warnings x20
for i in $(seq 20); do xcrun simctl spawn $SIM notifyutil -p UIApplicationDidReceiveMemoryWarningNotification >/dev/null 2>&1; xcrun simctl ui $SIM appearance dark >/dev/null 2>&1; sleep 0.3; xcrun simctl ui $SIM appearance light >/dev/null 2>&1; done; sleep 2
[ "$(alive)" = 1 ] && pass "appearance toggles x20" || fail "appearance toggles"
# 4 background / foreground x10
for i in $(seq 10); do xcrun simctl launch $SIM com.apple.Preferences >/dev/null 2>&1; sleep 1.2; xcrun simctl launch $SIM $BID >/dev/null 2>&1; sleep 1.2; done
[ "$(alive)" = 1 ] && pass "background/foreground x10" || fail "bg/fg"
# 5 text-size (dynamic type) change
for s in extra-small large accessibility-extra-extra-extra-large medium; do xcrun simctl ui $SIM content_size $s >/dev/null 2>&1; sleep 1.5; done
[ "$(alive)" = 1 ] && pass "content-size changes" || fail "content size"
# 6 malloc debugging launch
xcrun simctl terminate $SIM $BID 2>/dev/null; SIMCTL_CHILD_MallocScribble=1 SIMCTL_CHILD_MallocGuardEdges=1 SIMCTL_CHILD_MallocPreScribble=1 xcrun simctl launch $SIM $BID >/dev/null 2>&1; sleep 25
[ "$(alive)" = 1 ] && pass "malloc scribble + guard edges" || fail "malloc debug"
after=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -ic "$(basename "$APP" .app)")
[ "$after" = "$before" ] && pass "no new crash reports" || fail "$((after-before)) new crash report(s)"
xcrun simctl terminate $SIM $BID 2>/dev/null; xcrun simctl uninstall $SIM $BID 2>/dev/null
[ $FAIL = 0 ] && echo "BATTERY PASS" || echo "BATTERY FAIL"; exit $FAIL
