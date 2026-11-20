#!/bin/bash
# Called from ci_post_xcodebuild.sh after an archive. Xcode Cloud has one product for this repository,
# the App Store app (app.loam.Loam), so it can't publish the TestFlight app (app.loam.Loam.rc, "Loam RC")
# by itself. This exports a Loam RC archive and uploads it straight to App Store Connect, where it lands in
# the Loam RC app's TestFlight. Every other archive, including production, is left to Xcode Cloud.
#
# The "Release candidate" workflow therefore needs Deployment Preparation set to None and no TestFlight
# post-action; besides SENTRY_AUTH_TOKEN it needs these secret environment variables:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_B64 (the base64 of the App Store Connect API key's .p8 file)
# The key must be allowed to create distribution signing assets (Admin role) and upload builds.
set -euo pipefail

rc_bundle_id=app.loam.Loam.rc

archive_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$CI_ARCHIVE_PATH/Info.plist")"

if [[ $archive_bundle_id != "$rc_bundle_id" ]]; then
  echo "Archive is $archive_bundle_id, not $rc_bundle_id; Xcode Cloud publishes it, nothing to upload here."
  exit 0
fi

# If Loam RC ever gets its own Xcode Cloud product, Xcode Cloud publishes it and an upload here would collide.
if [[ ${CI_BUNDLE_ID:-} == "$rc_bundle_id" ]]; then
  echo "This workflow's product is $rc_bundle_id; Xcode Cloud publishes it, nothing to upload here."
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
umask 077

key_error() {
  echo "error: ASC_PRIVATE_KEY_B64 $1. Set it to the output of: base64 -i AuthKey_$ASC_KEY_ID.p8 | tr -d '\\n'" >&2
  exit 1
}

# Pasted values pick up line breaks, spaces, quotes or literal "\n"; none of them is valid base64.
# A raw .p8 (PEM) is accepted too, even with its line breaks flattened.
value="$ASC_PRIVATE_KEY_B64"
pem_begin='-----BEGIN PRIVATE KEY-----'
pem_end='-----END PRIVATE KEY-----'
if [[ $value == *"$pem_begin"* ]]; then
  [[ $value == *"$pem_end"* ]] || key_error "starts a PEM key but has no '$pem_end' line"
  body="${value#*"$pem_begin"}"
  body="${body%%"$pem_end"*}"
else
  body="$value"
fi
body="$(printf '%s' "$body" | sed 's/\\[nr]//g' | tr -d " \t\r\n\"'")"
[[ -n $body ]] || key_error "is empty after removing whitespace and quotes"
printf '%s' "$body" | base64 --decode > "$work/decoded" 2> /dev/null || key_error "isn't valid base64"

if [[ $value == *"$pem_begin"* ]]; then
  { echo "$pem_begin"; printf '%s' "$body" | fold -w 64; echo; echo "$pem_end"; } > "$key"
elif grep -q -- "$pem_begin" "$work/decoded"; then
  mv "$work/decoded" "$key"
else
  key_error "decodes, but not to a .p8 private key"
fi

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
