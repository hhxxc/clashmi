#!/usr/bin/env bash
# WSL 本地测试车道：装 Flutter（用户态，无需 sudo）→ 跑 Dart 协议测试。
#
#   bash scripts/wsl_flutter_test.sh
#
# 能替代 CI 干的事：秒级跑 VpnServiceConfig 契约测试 / flutter analyze。
# 干不了的事：iOS 模拟器启动（那是 macOS/iPhone 独有运行时，WSL 没有）。
#
# 镜像走 flutter-io.cn（国内直连）。Flutter 版本与 CI 对齐：3.47.9。
set -uo pipefail

FLUTTER_VER="3.47.9"
SDK_DIR="$HOME/flutter-sdk"
MIRROR="https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux"
export PUB_HOSTED_URL="https://pub.flutter-io.cn"
export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"

if [ ! -x "$SDK_DIR/bin/flutter" ]; then
  echo "==> Installing Flutter $FLUTTER_VER (user-space, no sudo) to $SDK_DIR"
  TARBALL="flutter_linux_${FLUTTER_VER}-stable.tar.xz"
  TMPD="$(mktemp -d)"
  if ! curl -fL --retry 3 -o "$TMPD/$TARBALL" "$MIRROR/$TARBALL"; then
    echo "FAIL: cannot download $MIRROR/$TARBALL"
    exit 1
  fi
  mkdir -p "$SDK_DIR"
  tar -xJf "$TMPD/$TARBALL" -C "$SDK_DIR" --strip-components=1
  rm -rf "$TMPD"
fi
export PATH="$SDK_DIR/bin:$PATH"

flutter --version | head -2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/third_party/libclash_vpn_service"

echo "==> flutter pub get (libclash_vpn_service)"
flutter pub get || exit 1

echo "==> flutter test (VpnServiceConfig contract)"
flutter test -r expanded || exit 1

echo "WSL LOCAL TEST PASS"
