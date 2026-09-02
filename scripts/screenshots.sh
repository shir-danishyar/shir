#!/bin/bash
# Runs the screenshot tour on a simulator and copies the PNGs into screenshots/.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone 17 Pro}"
RUNNER_BUNDLE_ID="com.shirhussain.shir.uitests.xctrunner"
OUT_DIR="screenshots"

echo "==> Running the screenshot tour on $DEVICE"
xcodebuild \
  -project Shir.xcodeproj \
  -scheme Shir \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -configuration Debug \
  test -only-testing:ShirUITests/ScreenshotTour \
  >/dev/null

SIM_ID="$(xcrun simctl list devices | grep -m1 "$DEVICE (" | sed -E 's/.*\(([A-F0-9-]{36})\).*/\1/')"

# xcodebuild shuts the simulator down when the run ends, and get_app_container
# refuses on a Shutdown device ("Unable to lookup in current state: Shutdown").
# Without this the tour succeeds and the copy fails, which reads like the
# screenshots were never taken. Boot it back up before the lookup.
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_ID" >/dev/null 2>&1 || true

CONTAINER="$(xcrun simctl get_app_container "$SIM_ID" "$RUNNER_BUNDLE_ID" data)"

mkdir -p "$OUT_DIR"
cp "$CONTAINER"/Documents/*.png "$OUT_DIR"/

echo "==> Wrote $(ls -1 "$OUT_DIR"/*.png | wc -l | tr -d ' ') screenshots to $OUT_DIR/"
ls -1 "$OUT_DIR"
