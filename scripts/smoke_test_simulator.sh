#!/usr/bin/env bash
# iOS Simulator smoke test: build the app for the simulator, install it into a
# freshly booted simulator, launch it and verify it reaches a running state
# (home screen) without crashing. Artifacts: smoke_screenshot.png + smoke_launch.log.
#
# The IPA build step must NOT run unless this passes — that is the whole point.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.core-build/smoke"
mkdir -p "$OUT"

BUNDLE_ID="com.nebula.clashmi"

if [ ! -d "$ROOT/bind/apple/Libclash.xcframework" ]; then
  echo "FAIL: bind/apple/Libclash.xcframework missing (run scripts/build_libclash_core.sh first)"
  exit 1
fi

echo "==> Building app for iOS Simulator (debug: the only mode Flutter allows on simulators)"
flutter pub get
(cd ios && pod install)
flutter build ios --simulator --debug

APP="$(ls -d "$ROOT"/build/ios/iphonesimulator/*.app 2>/dev/null | head -1)"
if [ -z "$APP" ]; then
  echo "FAIL: no .app produced in build/ios/iphonesimulator"
  exit 1
fi
echo "app bundle: $APP"

echo "==> Picking an available iPhone simulator"
UDID="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
for runtime, devs in d["devices"].items():
    if "iOS" not in runtime and "iphoneos" not in runtime.lower():
        continue
    for x in devs:
        if x.get("isAvailable") and "iPhone" in x["name"]:
            print(x["udid"])
            sys.exit(0)
')"
if [ -z "$UDID" ]; then
  echo "FAIL: no available iPhone simulator"
  exit 1
fi
echo "simulator: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

echo "==> Installing app"
xcrun simctl install "$UDID" "$APP"

echo "==> Launching app (detached)"
xcrun simctl launch "$UDID" "$BUNDLE_ID" || true
echo "waiting 25s for Flutter boot + home screen render..."
sleep 25

echo "==> Screenshot"
xcrun simctl io "$UDID" screenshot "$OUT/smoke_screenshot.png" || true

echo "==> Collecting unified log"
xcrun simctl spawn "$UDID" log show --last 2m --style compact 2>/dev/null \
  | grep -iE "runner|clash|flutter|fatal|error|exception|invalidProfile|访问配置" \
  > "$OUT/smoke_launch.log" || true

echo "==> Checking process is alive"
RUNNING=0
if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -qi "$BUNDLE_ID"; then
  RUNNING=1
elif xcrun simctl spawn "$UDID" ps -ax 2>/dev/null | grep -qiE "Clash Mi|clashmi"; then
  RUNNING=1
fi

echo "==> Log scan"
FAIL_MARKERS=""
if grep -qiE "invalidProfile|访问配置文件|Fatal error|Unhandled exception|Cannot find .* in scope" "$OUT/smoke_launch.log"; then
  FAIL_MARKERS="error markers in launch log"
fi
if grep -qiE "Terminating app due to uncaught exception|Process crashed" "$OUT/smoke_launch.log"; then
  FAIL_MARKERS="${FAIL_MARKERS:+$FAIL_MARKERS; }crash markers in launch log"
fi

SHOT_SIZE=$(wc -c < "$OUT/smoke_screenshot.png" 2>/dev/null || echo 0)
if [ "$SHOT_SIZE" -lt 10000 ]; then
  FAIL_MARKERS="${FAIL_MARKERS:+$FAIL_MARKERS; }screenshot suspiciously small ($SHOT_SIZE bytes)"
fi

echo "---- smoke_launch.log (tail) ----"
tail -30 "$OUT/smoke_launch.log" || true
echo "---------------------------------"
echo "process alive at check time: $RUNNING"
echo "screenshot: $OUT/smoke_screenshot.png ($SHOT_SIZE bytes)"

if [ -n "$FAIL_MARKERS" ]; then
  echo "FAIL: $FAIL_MARKERS"
  exit 1
fi
if [ "$RUNNING" -ne 1 ]; then
  echo "FAIL: app process is not running after launch (crashed on startup?)"
  exit 1
fi

echo "SMOKE TEST PASS: app booted to a running state"
