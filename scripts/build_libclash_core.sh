#!/usr/bin/env bash
# Build Libclash.xcframework (the mihomo core SDK) from the public
# ProjectClash kernel + the libclash facade package in this repo.
#
# Requires: Go >= 1.26, Xcode (macOS runner).
# Output:   bind/apple/Libclash.xcframework
set -euo pipefail

KERNEL_REPO="https://github.com/ProjectClash/Clash.git"
KERNEL_REV="4b7d5f53cff448f01cd5012b5e3f7eddc7d43e33"
GOMOBILE="github.com/sagernet/gomobile/cmd/gomobile@v0.1.13"
GOBIND="github.com/sagernet/gomobile/cmd/gobind@v0.1.13"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.core-build"

echo "==> Cloning kernel @ $KERNEL_REV"
rm -rf "$WORK"
mkdir -p "$WORK"
git clone --filter=blob:none "$KERNEL_REPO" "$WORK/kernel"
git -C "$WORK/kernel" checkout --detach "$KERNEL_REV"

echo "==> Injecting libclash facade"
mkdir -p "$WORK/kernel/bind/clash/libclash"
cp "$ROOT/bind/libclash/"*.go "$WORK/kernel/bind/clash/libclash/"

echo "==> Injecting roothelper (TrollStore root FakeVPN core)"
mkdir -p "$WORK/kernel/bind/clash/cmd/roothelper"
cp "$ROOT/bind/roothelper/main.go" "$WORK/kernel/bind/clash/cmd/roothelper/"

echo "==> Installing gomobile"
export GOBIN="$WORK/bin"
export PATH="$GOBIN:$PATH"
go install "$GOMOBILE"
go install "$GOBIND"

echo "==> gomobile bind (ios)"
rm -rf "$ROOT/bind/apple/Libclash.xcframework"
(
  cd "$WORK/kernel/bind/clash"
  gomobile bind \
    -target=ios,iossimulator \
    -tags="with_gvisor,cmfa,with_quic,with_low_memory,no_easytier" \
    -o "$ROOT/bind/apple/Libclash.xcframework" \
    ./libclash
)

echo "==> build roothelper binary (ios/arm64)"
# Runs as root via TrollStore spawnRoot; user-space utun FakeVPN replacing the
# NetworkExtension path (ldid fake-signed NE providers are rejected by iOS).
# iOS requires external (cgo) linking, so CGO stays enabled on the macOS runner.
(
  cd "$WORK/kernel/bind/clash"
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 go build \
    -tags="with_gvisor,cmfa,with_quic,with_low_memory,no_easytier" \
    -trimpath \
    -o "$ROOT/bind/apple/roothelper" \
    ./cmd/roothelper
)
chmod +x "$ROOT/bind/apple/roothelper"

echo "==> Done: $ROOT/bind/apple/Libclash.xcframework"
ls -la "$ROOT/bind/apple/Libclash.xcframework"
