#!/bin/bash
# Called from ci_post_xcodebuild.sh after an archive. Xcode Cloud has one product for this repository,
# the App Store app (app.loam.Loam), so it can't publish the staging app (app.loam.Loam.rc, "Loam RC")
# by itself. When the archive carries a different bundle ID than the product, this exports it and uploads
# it straight to App Store Connect, where it lands in the Loam RC app's TestFlight.
#
# The "Release candidate - TestFlight publish" workflow therefore needs Deployment Preparation set to None
# and no TestFlight post-action; it needs these secret environment variables:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_B64 (the base64 of the App Store Connect API key's .p8 file)
# The key must be allowed to create distribution signing assets (Admin role) and upload builds.
set -euo pipefail

archive_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$CI_ARCHIVE_PATH/Info.plist")"

# Builds of the product's own app (the production workflow) are published by Xcode Cloud itself.
if [[ $archive_bundle_id == "${CI_BUNDLE_ID:-}" ]]; then
  exit 0
fi

for name in ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_B64; do
  if [[ -z ${!name:-} ]]; then
    echo "error: Set $name as a secret environment variable on this Xcode Cloud workflow; without it $archive_bundle_id can't be uploaded." >&2
    exit 1
  fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
key="$work/AuthKey_$ASC_KEY_ID.p8"
printf '%s' "$ASC_PRIVATE_KEY_B64" | base64 --decode > "$key"
chmod 600 "$key"

# destination "upload" sends the build to App Store Connect instead of writing an .ipa.
cat > "$work/export-options.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>XXJA67J9AN</string>
  <key>signingStyle</key><string>automatic</string>
  <key>testFlightInternalTestingOnly</key><true/>
</dict>
</plist>
PLIST

echo "Uploading $archive_bundle_id to App Store Connect ..."
xcodebuild -exportArchive \
  -archivePath "$CI_ARCHIVE_PATH" \
  -exportOptionsPlist "$work/export-options.plist" \
  -exportPath "$work/export" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$key" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
