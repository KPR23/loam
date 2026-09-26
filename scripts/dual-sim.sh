#!/bin/bash
# Boots two simulators and installs the same Debug build on both, so you can
# sign in as Julia on one and Philip on the other for real two-device testing.
#
# No Apple ID needed: the debug auth screen's test-account buttons (added
# alongside this script) sign personas in directly against Supabase.
#
# Prerequisite: Loam/Config/Secrets.xcconfig must have real Julia/Philip
# credentials. Run scripts/create-test-personas.sh once if it doesn't.
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
SECRETS_FILE="Loam/Config/Secrets.xcconfig"

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

# Prints "<udid> <deviceTypeIdentifier>" for a device named "$1" that is
# actually usable (present and available), or nothing if none exists.
find_available_device() {
  local name="$1"
  xcrun simctl list devices --json | python3 -c "
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
for devices in data['devices'].values():
    for d in devices:
        if d['name'] == name and d.get('isAvailable'):
            print(d['udid'], d['deviceTypeIdentifier'])
            sys.exit(0)
" "$name"
}

# Removes a stale/unavailable device named "$1", if one is registered.
delete_device_named() {
  local name="$1"
  local udid
  udid=$(xcrun simctl list devices --json | python3 -c "
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
for devices in data['devices'].values():
    for d in devices:
        if d['name'] == name:
            print(d['udid'])
            sys.exit(0)
" "$name")
  if [ -n "$udid" ]; then
    echo "Removing stale simulator '$name' ($udid)..." >&2
    xcrun simctl delete "$udid" 2>/dev/null || true
  fi
}

ensure_simulator() {
  local name="$1"
  local dtype rtime found udid found_type

  dtype=$(device_type_id)
  if [ -z "$dtype" ]; then
    echo "No simulator device type matching '$DEVICE_TYPE' found." >&2
    exit 1
  fi
  rtime=$(runtime_id)
  if [ -z "$rtime" ]; then
    echo "No iOS simulator runtime found." >&2
    exit 1
  fi

  found=$(find_available_device "$name")
  if [ -n "$found" ]; then
    udid="${found%% *}"
    found_type="${found#* }"
    if [ "$found_type" != "$dtype" ]; then
      echo "Warning: existing simulator '$name' is $found_type, not the requested $DEVICE_TYPE. Reusing it as-is; delete it manually (xcrun simctl delete $udid) to change its type." >&2
    fi
    echo "$udid"
    return
  fi

  # No available device with this name — it may not exist, or it may be
  # registered but unavailable (e.g. its runtime was removed). Either way,
  # clear the name and create fresh so we don't silently reuse a broken device.
  delete_device_named "$name"
  echo "Creating simulator '$name' ($DEVICE_TYPE)..." >&2
  udid=$(xcrun simctl create "$name" "$dtype" "$rtime")
  if [ -z "$udid" ]; then
    echo "Failed to create simulator '$name'." >&2
    exit 1
  fi
  echo "$udid"
}

echo "== Resolving simulators =="
UDID_A=$(ensure_simulator "$SIM_A")
UDID_B=$(ensure_simulator "$SIM_B")
echo "$SIM_A -> $UDID_A"
echo "$SIM_B -> $UDID_B"

echo "== Booting (waiting for full boot) =="
# bootstatus boots if needed and blocks until the device can actually accept
# installs/launches — a bare `boot` returns immediately and installing into a
# half-booted simulator fails.
xcrun simctl bootstatus "$UDID_A" -b
xcrun simctl bootstatus "$UDID_B" -b
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

echo
echo "Both simulators are running the same Debug build against staging."
echo

if [ ! -f "$SECRETS_FILE" ] || ! grep -q '[^[:space:]]' <(grep 'LOAM_TEST_JULIA_PASSWORD' "$SECRETS_FILE" | cut -d= -f2-); then
  cat <<EOF
Julia/Philip credentials aren't set up yet (missing or empty in $SECRETS_FILE),
so the test-account buttons on the sign-in screen won't have anyone to sign
in as. Run this first, then re-run this script:

  SUPABASE_SERVICE_ROLE_KEY=<from Supabase Dashboard> scripts/create-test-personas.sh
EOF
else
  cat <<EOF
Next (one-time per simulator, until data is erased):
  1. On "$SIM_A": tap "Continue as Julia" on the sign-in screen
  2. On "$SIM_B": tap "Continue as Philip" on the sign-in screen

No Apple ID needed — those buttons sign in directly with the Supabase
email/password credentials from $SECRETS_FILE.
EOF
fi
