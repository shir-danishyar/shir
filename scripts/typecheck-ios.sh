#!/bin/bash
# Compiles the whole app for the iOS simulator SDK without needing a simulator
# runtime installed.
#
# Xcode 26 requires the iOS platform component (a multi-GB download) before
# xcodebuild will accept any iOS destination. Until that is installed, this
# script is the way to prove the app actually compiles: it builds RiffKit as a
# module for the iOS triple, then typechecks every app source file against it.
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
TRIPLE="${ARCH}-apple-ios17.0-simulator"
BUILD_DIR=".build/ios-typecheck"

mkdir -p "$BUILD_DIR"

echo "==> Building RiffKit for $TRIPLE"
# shellcheck disable=SC2046
swiftc \
  -sdk "$SDK" \
  -target "$TRIPLE" \
  -module-name RiffKit \
  -emit-module \
  -emit-module-path "$BUILD_DIR/RiffKit.swiftmodule" \
  $(find RiffKit/Sources/RiffKit -name '*.swift')

echo "==> Typechecking the app"
# shellcheck disable=SC2046
swiftc \
  -sdk "$SDK" \
  -target "$TRIPLE" \
  -typecheck \
  -I "$BUILD_DIR" \
  $(find Riff -name '*.swift')

echo "==> OK: app and RiffKit compile for iOS 17 simulator"
