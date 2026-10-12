#!/bin/bash
# Builds the Debug app and runs it on one simulator, booting it first if needed.
#
# Usage: scripts/run-sim.sh [device name]
#   scripts/run-sim.sh                    # defaults to "iPhone 18 Pro"
#   scripts/run-sim.sh "iPhone 18 Pro Max"

set -euo pipefail

DEVICE_NAME="${1:-iPhone 18 Pro}"
SCHEME="Loam"
BUNDLE_ID="app.loam.Loam"
DERIVED_DATA="build/run-sim"

# Prints the UDID of the available device named "$1" on the newest iOS runtime.
find_device() {
  xcrun simctl list devices available --json | python3 -c "
import json, re, sys
name = sys.argv[1]
data = json.load(sys.stdin)
def version(runtime):
    return [int(n) for n in re.findall(r'\d+', runtime.rsplit('.', 1)[-1])]
for runtime in sorted(data['devices'], key=version, reverse=True):
    if '.iOS-' not in runtime:
        continue
    for d in data['devices'][runtime]:
        if d['name'] == name:
            print(d['udid'])
            sys.exit(0)
" "$1"
}

UDID=$(find_device "$DEVICE_NAME")
if [ -z "$UDID" ]; then
  echo "No available simulator named '$DEVICE_NAME'. Pick one from: xcrun simctl list devices available" >&2
  exit 1
fi
echo "== $DEVICE_NAME -> $UDID =="

echo "== Booting (waiting for full boot) =="
# bootstatus boots if needed and blocks until the device accepts installs.
xcrun simctl bootstatus "$UDID" -b
open -a Simulator 2>/dev/null \
  || echo "Could not open the Simulator UI automatically — open it manually to view the device." >&2

echo "== Building Debug ($SCHEME) =="
build() {
  xcodebuild build \
    -project Loam.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "id=$UDID" \
    -derivedDataPath "$DERIVED_DATA"
}
if command -v xcpretty >/dev/null 2>&1; then
  build | xcpretty
else
  build
fi

APP_PATH=$(find "$DERIVED_DATA/Build/Products" -maxdepth 2 -iname "Loam.app" -print -quit)
if [ -z "$APP_PATH" ]; then
  echo "Could not find built Loam.app under $DERIVED_DATA" >&2
  exit 1
fi

echo "== Installing and launching =="
xcrun simctl install "$UDID" "$APP_PATH"
# Relaunch so a running copy picks up the new build.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"
