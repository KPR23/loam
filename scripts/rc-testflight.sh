#!/usr/bin/env bash
# Builds the TestFlight app ("Loam RC", app.loam.Loam.rc) on this Mac and uploads it to TestFlight.
#
#   scripts/rc-testflight.sh [ref]     ref defaults to origin/main
#
# Fallback for when Xcode Cloud can't do it: the "Release candidate" workflow builds the RC app on rc/*
# tags and uploads it from ci_scripts/upload-rc-archive.sh. Xcode Cloud has only one product for this
# repository (the App Store app), so the RC app has no product of its own.
#
# The build comes from a clean worktree at ref, so uncommitted changes never end up in it. The
# version is MARKETING_VERSION at ref; App Store Connect picks the next build number.
#
# Needs: the `asc` CLI with API authentication (ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH), and
# Xcode signed in with the team's Apple ID for automatic signing. The upload goes to the internal
# "Admin" group of the Loam RC app, so add yourself to that group in App Store Connect once.
set -euo pipefail

RC_APP_ID="6835553681" # App Store Connect app "Loam RC" (app.loam.Loam.rc)
GROUP="Admin"

die() { echo "rc-testflight: $*" >&2; exit 1; }

command -v asc > /dev/null || die "asc is not installed (brew install asc)"

cd "$(git rev-parse --show-toplevel)"
git fetch --quiet --prune origin

ref="${1:-origin/main}"
git rev-parse --verify --quiet "$ref^{commit}" > /dev/null || die "unknown ref: $ref"

version="$(git show "$ref:project.yml" | sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}$/\1/p' | head -n 1)"
[[ -n $version ]] || die "no MARKETING_VERSION in project.yml at $ref"

# The build must carry the RC bundle ID, or App Store Connect rejects it for this app. The TestFlight
# configuration reads it from Staging.xcconfig.
git show "$ref:project.yml" | grep -Eq '^ *TestFlight: *Loam/Config/Staging\.xcconfig *$' ||
  die "project.yml at $ref doesn't map the TestFlight configuration to Loam/Config/Staging.xcconfig"
git show "$ref:Loam/Config/Staging.xcconfig" 2> /dev/null | grep -Eq '^ *LOAM_BUNDLE_ID *= *app\.loam\.Loam\.rc *$' ||
  die "Loam/Config/Staging.xcconfig at $ref doesn't set LOAM_BUNDLE_ID = app.loam.Loam.rc"

dir="$(mktemp -d)"
trap 'git worktree remove --force "$dir" 2> /dev/null || true' EXIT
git worktree add --quiet --detach "$dir" "$ref"

echo "Building Loam RC $version from $(git rev-parse --short "$ref") ..."
cd "$dir"
asc publish testflight \
  --app "$RC_APP_ID" \
  --project Loam.xcodeproj \
  --scheme Loam-TestFlight \
  --configuration TestFlight \
  --version "$version" \
  --group "$GROUP" \
  --wait

echo "Uploaded Loam RC $version. It shows up in TestFlight for the $GROUP group once processing finishes."
