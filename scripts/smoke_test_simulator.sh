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

log "==> Building app for iOS Simulator via xcodebuild (debug)"
rm -rf "$SIM_BUILD_DIR"
# ARCHS=arm64：destination 会同时匹配 Rosetta 的 x86_64 变体，而 Flutter.framework
# 拷贝产物只有 arm64 切片，x86_64 链接必挂。宿主/模拟器都是 arm64，锁死即可。
run xcodebuild build \
  -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Debug -sdk iphonesimulator \
  -destination "id=$UDID" \
  CONFIGURATION_BUILD_DIR="$SIM_BUILD_DIR" \
  SUPPORTED_PLATFORMS="iphoneos iphonesimulator" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  || log "WARN: xcodebuild build exited non-zero"

# .app 必须含有效 Info.plist（上一轮 BUILD FAILED 的半成品 .app 缺 bundle id，
# 会被 simctl install 以 "Missing bundle ID" 拒收）
app_valid() {
  python3 -c "
import plistlib, sys
try:
    d = plistlib.load(open(sys.argv[1] + '/Info.plist', 'rb'))
    ok = bool(d.get('CFBundleIdentifier'))
except Exception:
    ok = False
sys.exit(0 if ok else 1)
" "$1" 2>/dev/null
}

APP=""
for cand in "$SIM_BUILD_DIR"/*.app; do
  [ -d "$cand" ] || continue
  if app_valid "$cand"; then APP="$cand"; break; fi
  log "ignoring incomplete app bundle: $cand"
done
if [ -z "$APP" ]; then
  log "==> Primary build produced no valid .app — retrying with generic destination"
  run xcodebuild build \
    -workspace ios/Runner.xcworkspace -scheme Runner \
    -configuration Debug -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    CONFIGURATION_BUILD_DIR="$SIM_BUILD_DIR" \
    SUPPORTED_PLATFORMS="iphoneos iphonesimulator" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    || log "WARN: generic retry exited non-zero"
  for cand in "$SIM_BUILD_DIR"/*.app; do
    [ -d "$cand" ] || continue
    if app_valid "$cand"; then APP="$cand"; break; fi
    log "ignoring incomplete app bundle: $cand"
  done
fi
if [ -z "$APP" ]; then
  log "==> Still no valid .app — falling back to flutter build --verbose"
  run flutter build ios --simulator --debug --verbose || true
  for cand in "$ROOT"/build/ios/iphonesimulator/*.app; do
    [ -d "$cand" ] || continue
    if app_valid "$cand"; then APP="$cand"; break; fi
    log "ignoring incomplete app bundle: $cand"
  done
fi
if [ -z "$APP" ]; then
  log "FAIL: no .app produced in build/ios/iphonesimulator (see smoke_build.log for the real xcodebuild error)"
  exit 1
fi
log "app bundle: $APP"

xcrun simctl boot "$UDID" 2>>"$BUILD_LOG" || true
run xcrun simctl bootstatus "$UDID" -b || true

log "==> Installing app"
run xcrun simctl install "$UDID" "$APP" || exit 1

# 预写同意标记（LocalStorage 的 storage.json 在 App Group 容器），跳过欢迎页直达主界面，
# 这样能验证「访问配置文件」路径（profileDir -> getAppGroupDirectory -> native_helper）。
# 容器要等 app 跑过一次才会创建，所以先短启一次再写。
log "==> Pre-seeding storage.json in App Group container (skip onboarding)"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 8
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 2
GROUP_DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" groups 2>/dev/null | grep -i 'group.com.nebula' | head -1)"
if [ -z "$GROUP_DIR" ]; then
  # fallback: any line that is an existing directory
  GROUP_DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" groups 2>/dev/null | while read -r p; do [ -d "$p" ] && echo "$p" && break; done)"
fi
if [ -n "$GROUP_DIR" ] && [ -d "$GROUP_DIR" ]; then
  printf '{"userAgreementAgreedKey": "true"}\n' > "$GROUP_DIR/storage.json"
  log "app group container: $GROUP_DIR (storage.json seeded)"
else
  log "WARN: could not resolve app group container — onboarding screen will show (non-fatal)"
  xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" groups 2>&1 | head -5 | tee -a "$BUILD_LOG" || true
fi

log "==> Launching app (detached)"
xcrun simctl launch "$UDID" "$BUNDLE_ID" 2>&1 | tee -a "$BUILD_LOG" || true
log "waiting 25s for Flutter boot + home screen render..."
sleep 25

log "==> Screenshot"
xcrun simctl io "$UDID" screenshot "$OUT/smoke_screenshot.png" 2>&1 | tee -a "$BUILD_LOG" || true

log "==> Collecting unified log"
xcrun simctl spawn "$UDID" log show --last 2m --style compact 2>/dev/null \
  | grep -iE "runner|clash|flutter|fatal|error|exception|invalidProfile|访问配置" \
  | grep -viE "sharingd|replicatord|rapportd|apsd|SpringBoard|runningboardd|cloudd|passd|sleepd|chronod|assistantd|businessservicesd|UserNotifications|IDS:Registration|gamecenter|memorystatus" \
  | tee "$OUT/smoke_launch.log" | tail -40 | tee -a "$BUILD_LOG" || true

log "==> Checking process is alive"
RUNNING=0
# ps 的默认 COMMAND 列会截断长路径，必须用 args= 全量输出才能匹配到 "Clash Mi"
PS_OUT="$(xcrun simctl spawn "$UDID" ps -ax -o pid=,args= 2>/dev/null || true)"
echo "$PS_OUT" | grep -iF "Clash Mi" | head -3 | tee -a "$BUILD_LOG" || true
if echo "$PS_OUT" | grep -qiF "Clash Mi.app/"; then
  RUNNING=1
elif xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -qi "nebula"; then
  RUNNING=1
fi

# 崩溃标记只对主 app 进程（Clash Mi / Runner）的日志行判定——
# 小组件扩展（clashmiWidgetExtension）是独立进程，系统服务（sharingd 等）
# 满嘴 "fatal error" 噪音，都不该判主 app 的生死。
APP_CRASH_LINES="$(grep -E "\] (Clash Mi|Runner)\[|Flutter|nebula\.clashmi" "$OUT/smoke_launch.log" 2>/dev/null \
  | grep -viE "widget|securityd|SecError" \
  | grep -iE "invalidProfile|访问配置文件|Fatal error|Unhandled exception|Cannot find .* in scope|Terminating app|Process crashed|Fatal signal|EXC_BREAKPOINT|EXC_BAD_ACCESS" || true)"

FAIL_MARKERS=""
if [ -n "$APP_CRASH_LINES" ]; then
  FAIL_MARKERS="app crash/error markers in launch log"
  log "matched crash lines:"
  echo "$APP_CRASH_LINES" | head -10 | tee -a "$BUILD_LOG"
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
