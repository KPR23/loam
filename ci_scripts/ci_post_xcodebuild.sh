#!/bin/bash
# Xcode Cloud runs this after each xcodebuild action. After an archive it uploads the dSYMs to
# Sentry, so crashes from TestFlight and App Store builds are symbolicated. Both workflows need
# SENTRY_AUTH_TOKEN, a Sentry organization token, as a secret environment variable.
set -euo pipefail

[[ ${CI_XCODEBUILD_ACTION:-} == archive ]] || exit 0

if [[ -z ${SENTRY_AUTH_TOKEN:-} ]]; then
  echo "error: Set SENTRY_AUTH_TOKEN on this Xcode Cloud workflow; without it Sentry can't symbolicate this build's crashes." >&2
  exit 1
fi

# Pinned and checksum-verified, like the Supabase CLI in GitHub Actions.
version=3.8.0
sha256=2c26914636c47ab9bf9e710484ad7b44d371cbec8bd29cafb36b3cf877bf4285
cli="$(mktemp -d)/sentry-cli"
curl --fail --silent --show-error --location --retry 3 --output "$cli" \
  "https://github.com/getsentry/sentry-cli/releases/download/$version/sentry-cli-Darwin-universal"
echo "$sha256  $cli" | shasum -a 256 -c -
chmod +x "$cli"

"$cli" debug-files upload --org kprs-lab --project apple-ios --include-sources "$CI_ARCHIVE_PATH/dSYMs"
