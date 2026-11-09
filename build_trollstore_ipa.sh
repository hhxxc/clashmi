#!/usr/bin/env bash
# clashmi -> TrollStore IPA 一键打包脚本
#
# 环境要求 (macOS):
#   - Xcode 15+ (含 Command Line Tools)
#   - Flutter >= 3.44.0
#   - CocoaPods
#   - ldid (brew install ldid)
#
# 不需要 Apple 开发者账号 / 证书 / 描述文件。
# 产物: clashmi-trollstore.ipa，用 TrollStore 安装。
# 注意: 设备需 iOS 15.0-16.6.1 (A12+ 可至 17.0)，工程 Podfile 下限 iOS 15.0。

set -euo pipefail
cd "$(dirname "$0")"

command -v ldid >/dev/null || { echo "缺少 ldid，请先: brew install ldid"; exit 1; }

if [ ! -d "bind/apple/Libclash.xcframework" ]; then
  echo "缺少 bind/apple/Libclash.xcframework（VPN 核心 SDK）"
  echo "请先运行: bash scripts/build_libclash_core.sh"
  exit 1
fi

# lib/generated/build_time.dart 由 build_runner 生成且被上游 gitignore，现场生成
mkdir -p lib/generated
NOW=$(date +"%Y, %-m, %-d, %-H, %-M, %-S")
printf '// GENERATED CODE - DO NOT MODIFY BY HAND\n// This file is generated during build process\n\n/// Build timestamp - automatically generated at build time\nfinal DateTime buildDateTime = DateTime(%s);\n' "$NOW" > lib/generated/build_time.dart

echo "==> flutter pub get"
flutter pub get

echo "==> pod install"
(cd ios && pod install)

echo "==> flutter build ios --release --no-codesign"
flutter build ios --release --no-codesign

APP="build/ios/iphoneos/Clash Mi.app"
[ -d "$APP" ] || { echo "找不到构建产物: $APP"; exit 1; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# keychain-access-groups 里的 $(AppIdentifierPrefix) 是构建期变量，
# ldid 不会替换，去掉前缀即可（自用场景无影响）。
sed 's/\$(AppIdentifierPrefix)//g' ios/Runner/Runner.entitlements > "$WORKDIR/runner.plist"
cp ios/clashmiService/clashmiService.entitlements "$WORKDIR/service.plist"
cp ios/clashmiWidgetExtension.entitlements "$WORKDIR/widget.plist"

sign() {
  local ent="$1" dir="$2"
  local bin
  bin=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$dir/Info.plist")
  echo "==> ldid 假签: $dir/$bin"
  ldid -S"$ent" "$dir/$bin"
}

sign "$WORKDIR/runner.plist" "$APP"
for appex in "$APP"/PlugIns/*.appex; do
  case "$appex" in
    *clashmiService*) sign "$WORKDIR/service.plist" "$appex" ;;
    *)                sign "$WORKDIR/widget.plist"  "$appex" ;;
  esac
done

echo "==> 打包 IPA"
rm -rf Payload
mkdir Payload
ditto "$APP" "Payload/$(basename "$APP")"
rm -f clashmi-trollstore.ipa
zip -qry clashmi-trollstore.ipa Payload
rm -rf Payload

echo "完成: $(pwd)/clashmi-trollstore.ipa"
