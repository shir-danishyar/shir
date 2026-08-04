#!/bin/bash
# Compiles the whole app for the iOS simulator SDK without needing a simulator
# runtime installed.
#
# Xcode 26 requires the iOS platform component (a multi-GB download) before
# xcodebuild will accept any iOS destination. Until that is installed, this
# script is the way to prove the app actually compiles: it builds ShirKit as a
# module for the iOS triple, then typechecks every app source file against it.
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
TRIPLE="${ARCH}-apple-ios17.0-simulator"
BUILD_DIR=".build/ios-typecheck"

mkdir -p "$BUILD_DIR"

echo "==> Building ShirKit for $TRIPLE"
# shellcheck disable=SC2046
swiftc \
  -sdk "$SDK" \
  -target "$TRIPLE" \
  -module-name ShirKit \
  -emit-module \
  -emit-module-path "$BUILD_DIR/ShirKit.swiftmodule" \
  $(find ShirKit/Sources/ShirKit -name '*.swift')

echo "==> Typechecking the app"
# shellcheck disable=SC2046
swiftc \
  -sdk "$SDK" \
  -target "$TRIPLE" \
  -typecheck \
  -I "$BUILD_DIR" \
  $(find Shir -name '*.swift')

echo "==> OK: app and ShirKit compile for iOS 17 simulator"
