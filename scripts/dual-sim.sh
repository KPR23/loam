#!/bin/bash
# Boots two simulators and installs the same Debug build on both, so you can
# sign in as Julia on one and Philip on the other for real two-device testing.
#
# No Apple ID needed: the debug test-account switcher (Profile tab) signs
# personas in directly against Supabase, bypassing Sign in with Apple.
#
# Usage: scripts/dual-sim.sh [device type]
#   scripts/dual-sim.sh                # defaults to "iPhone 16 Pro"
#   scripts/dual-sim.sh "iPhone 17"

set -euo pipefail

DEVICE_TYPE="${1:-iPhone 16 Pro}"
SCHEME="Loam"
BUNDLE_ID="app.loam.Loam"
SIM_A="Loam - Julia"
SIM_B="Loam - Philip"
DERIVED_DATA="build/dual-sim"

runtime_id() {
  # e.g. "iOS 27.0 (27.0 - 24A434) - com.apple.CoreSimulator.SimRuntime.iOS-27-0"
  xcrun simctl list runtimes \
    | grep -E '^iOS ' \
    | tail -1 \
    | grep -o 'com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9-]*'
}

device_type_id() {
  # e.g. "iPhone 16 Pro (com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro)"
  xcrun simctl list devicetypes | grep -F "$DEVICE_TYPE (" | grep -o 'com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9-]*' | head -1
}

ensure_simulator() {
  local name="$1"
  local udid
  udid=$(xcrun simctl list devices | grep -F "    $name (" | grep -o '[0-9A-F-]\{36\}' | head -1)
  if [ -z "$udid" ]; then
    local dtype rtime
    dtype=$(device_type_id)
    rtime=$(runtime_id)
    if [ -z "$dtype" ]; then
      echo "No simulator device type matching '$DEVICE_TYPE' found." >&2
      exit 1
    fi
    if [ -z "$rtime" ]; then
      echo "No iOS simulator runtime found." >&2
      exit 1
    fi
    echo "Creating simulator '$name' ($DEVICE_TYPE)..." >&2
    udid=$(xcrun simctl create "$name" "$dtype" "$rtime")
  fi
  if [ -z "$udid" ]; then
    echo "Failed to resolve or create simulator '$name'." >&2
    exit 1
  fi
  echo "$udid"
}

echo "== Resolving simulators =="
UDID_A=$(ensure_simulator "$SIM_A")
UDID_B=$(ensure_simulator "$SIM_B")
echo "$SIM_A -> $UDID_A"
echo "$SIM_B -> $UDID_B"

echo "== Booting =="
xcrun simctl boot "$UDID_A" 2>/dev/null || true
xcrun simctl boot "$UDID_B" 2>/dev/null || true
open -a Simulator 2>/dev/null \
  || open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null \
  || open -b com.apple.dt.Devices 2>/dev/null \
  || echo "Could not open the Simulator UI automatically — open it manually to view the devices." >&2

echo "== Building Debug ($SCHEME) =="
if command -v xcpretty >/dev/null 2>&1; then
  xcodebuild build \
    -project Loam.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA" \
    | xcpretty
else
  xcodebuild build \
    -project Loam.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED_DATA"
fi

APP_PATH=$(find "$DERIVED_DATA/Build/Products" -maxdepth 2 -iname "Loam.app" -print -quit)
if [ -z "$APP_PATH" ]; then
  echo "Could not find built Loam.app under $DERIVED_DATA" >&2
  exit 1
fi

echo "== Installing on both simulators =="
xcrun simctl install "$UDID_A" "$APP_PATH"
xcrun simctl install "$UDID_B" "$APP_PATH"

echo "== Launching =="
xcrun simctl launch "$UDID_A" "$BUNDLE_ID"
xcrun simctl launch "$UDID_B" "$BUNDLE_ID"

cat <<EOF

Both simulators are running the same Debug build against staging.

Next (one-time per simulator, until data is erased):
  1. On "$SIM_A": tap "Continue without account (demo)" -> Profile tab -> Julia
  2. On "$SIM_B": tap "Continue without account (demo)" -> Profile tab -> Philip

No Apple ID needed — the test-account switcher signs in directly with
Supabase email/password credentials from Loam/Config/Secrets.xcconfig.
EOF
