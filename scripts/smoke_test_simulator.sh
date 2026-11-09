#!/usr/bin/env bash
# iOS Simulator smoke test（发布闸门）：为模拟器构建 app → 装进全新启动的
# 模拟器 → 真实启动 → 截图 + 日志扫描 + 进程存活检查。
# 本脚本不通过就不许打 IPA。
#
# 与旧版的区别：
#   1. 构建改走直接 xcodebuild（flutter build ios --simulator 在 CI 上会以
#      "No Xcode build settings have been found" 失败且吞掉真实错误）；
#      flutter 命令仅作兜底，且带 --verbose。
#   2. 全部输出落 .core-build/smoke/smoke_build.log，失败时证据包也有内容。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.core-build/smoke"
mkdir -p "$OUT"
BUILD_LOG="$OUT/smoke_build.log"
: > "$BUILD_LOG"

log() { echo "$*" | tee -a "$BUILD_LOG"; }
run() { log "==== $* ===="; "$@" 2>&1 | tee -a "$BUILD_LOG"; return "${PIPESTATUS[0]}"; }

BUNDLE_ID="com.nebula.clashmi"
SIM_BUILD_DIR="$ROOT/build/ios/iphonesimulator"

if [ ! -d "$ROOT/bind/apple/Libclash.xcframework" ]; then
  log "FAIL: bind/apple/Libclash.xcframework missing (run scripts/build_libclash_core.sh first)"
  exit 1
fi

log "==> Toolchain"
run xcodebuild -version || true
run flutter --version || true

log "==> flutter pub get + pod install"
run flutter pub get || exit 1
run bash -c "cd ios && pod install" || exit 1

# Xcode 15+ 起模拟器运行时是可下载组件；镜像没预装时 xcodebuild 会以
# "Unable to find a destination matching ... platform:iOS Simulator" 拒绝构建。
log "==> Ensuring iOS Simulator runtime"
xcrun simctl list runtimes 2>&1 | tee -a "$BUILD_LOG" || true
NEED_RUNTIME="$(xcrun simctl list runtimes --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("yes"); raise SystemExit
ok = any(
    ("iOS" in r.get("name", "") or "iOS" in r.get("identifier", ""))
    and r.get("isAvailable", True)
    for r in d.get("runtimes", [])
)
print("no" if ok else "yes")
')"
if [ "$NEED_RUNTIME" = "yes" ]; then
  log "==> Downloading iOS Simulator platform (this can take several minutes)"
  run xcodebuild -downloadPlatform iOS || log "WARN: -downloadPlatform iOS returned non-zero"
  xcrun simctl list runtimes 2>&1 | tee -a "$BUILD_LOG" || true
fi

# 诊断用：把 -showBuildSettings 的完整输出留档（flutter 失败时这正是被吞掉的部分）
log "==> Diagnostic: xcodebuild -showBuildSettings (iphonesimulator)"
run xcodebuild -showBuildSettings \
  -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Debug -sdk iphonesimulator || true

log "==> Building app for iOS Simulator via xcodebuild (debug)"
rm -rf "$SIM_BUILD_DIR"
run xcodebuild build \
  -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CONFIGURATION_BUILD_DIR="$SIM_BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  || log "WARN: xcodebuild build exited non-zero"

APP="$(ls -d "$SIM_BUILD_DIR"/*.app 2>/dev/null | head -1)"
if [ -z "$APP" ]; then
  log "==> Primary build produced no .app — falling back to flutter build --verbose"
  run flutter build ios --simulator --debug --verbose || true
  APP="$(ls -d "$ROOT"/build/ios/iphonesimulator/*.app 2>/dev/null | head -1)"
fi
if [ -z "$APP" ]; then
  log "FAIL: no .app produced in build/ios/iphonesimulator (see smoke_build.log for the real xcodebuild error)"
  exit 1
fi
log "app bundle: $APP"

log "==> Picking an available iPhone simulator"
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
  log "==> No iPhone simulator exists yet — creating one"
  RT="$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
for r in d.get("runtimes", []):
    if ("iOS" in r.get("name", "") or "iOS" in r.get("identifier", "")) and r.get("isAvailable", True):
        print(r["udid"]); break
')"
  DT="$(xcrun simctl list devicetypes --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
for t in d.get("devicetypes", []):
    if "iPhone" in t.get("name", ""):
        print(t["identifier"]); break
')"
  if [ -n "$RT" ] && [ -n "$DT" ]; then
    UDID="$(xcrun simctl create "CI iPhone" "$DT" "$RT")" || true
    log "created: $UDID ($DT @ $RT)"
  fi
fi
if [ -z "$UDID" ]; then
  log "FAIL: no available iPhone simulator and could not create one"
  exit 1
fi
log "simulator: $UDID"
xcrun simctl boot "$UDID" 2>>"$BUILD_LOG" || true
run xcrun simctl bootstatus "$UDID" -b || true

log "==> Installing app"
run xcrun simctl install "$UDID" "$APP" || exit 1

log "==> Launching app (detached)"
xcrun simctl launch "$UDID" "$BUNDLE_ID" 2>&1 | tee -a "$BUILD_LOG" || true
log "waiting 25s for Flutter boot + home screen render..."
sleep 25

log "==> Screenshot"
xcrun simctl io "$UDID" screenshot "$OUT/smoke_screenshot.png" 2>&1 | tee -a "$BUILD_LOG" || true

log "==> Collecting unified log"
xcrun simctl spawn "$UDID" log show --last 2m --style compact 2>/dev/null \
  | grep -iE "runner|clash|flutter|fatal|error|exception|invalidProfile|访问配置" \
  | tee "$OUT/smoke_launch.log" | tail -40 | tee -a "$BUILD_LOG" || true

log "==> Checking process is alive"
RUNNING=0
if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -qi "$BUNDLE_ID"; then
  RUNNING=1
elif xcrun simctl spawn "$UDID" ps -ax 2>/dev/null | grep -qiE "Clash Mi|clashmi"; then
  RUNNING=1
fi

FAIL_MARKERS=""
if grep -qiE "invalidProfile|访问配置文件|Fatal error|Unhandled exception|Cannot find .* in scope" "$OUT/smoke_launch.log" 2>/dev/null; then
  FAIL_MARKERS="error markers in launch log"
fi
if grep -qiE "Terminating app due to uncaught exception|Process crashed" "$OUT/smoke_launch.log" 2>/dev/null; then
  FAIL_MARKERS="${FAIL_MARKERS:+$FAIL_MARKERS; }crash markers in launch log"
fi

SHOT_SIZE=$(wc -c < "$OUT/smoke_screenshot.png" 2>/dev/null || echo 0)
if [ "$SHOT_SIZE" -lt 10000 ]; then
  FAIL_MARKERS="${FAIL_MARKERS:+$FAIL_MARKERS; }screenshot suspiciously small ($SHOT_SIZE bytes)"
fi

log "process alive at check time: $RUNNING"
log "screenshot: $OUT/smoke_screenshot.png ($SHOT_SIZE bytes)"

if [ -n "$FAIL_MARKERS" ]; then
  log "FAIL: $FAIL_MARKERS"
  exit 1
fi
if [ "$RUNNING" -ne 1 ]; then
  log "FAIL: app process is not running after launch (crashed on startup?)"
  exit 1
fi

log "SMOKE TEST PASS: app booted to a running state"
