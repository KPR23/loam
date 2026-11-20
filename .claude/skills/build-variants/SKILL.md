---
name: build-variants
description: Use when adding or changing a build variant, bundle ID, app icon or display name, setting up TestFlight/Loam RC (App IDs, App Store Connect, Xcode Cloud), configuring staging Apple sign-in or push, debugging why an rc/* build never reaches Loam RC's TestFlight, or debugging why the Dev, RC and App Store apps collide or fail to sign in, push or delete accounts. Covers Loam's three side-by-side iOS apps and how to verify them.
---

# Build variants

README.md → "Xcode Cloud / TestFlight" and "Push notifications" are the source of truth; read them if anything here looks out of date.

Each build type is its own app, so all three install side by side on one iPhone and keep their own sign-in and push token.

| Build | Configuration | Scheme | Bundle ID | Name | Icon | Backend |
|---|---|---|---|---|---|---|
| App Store | `Production` (archive), `Release` | `Loam` | `app.loam.Loam` | Loam | `AppIcon` | production |
| TestFlight | `TestFlight` | `Loam-TestFlight` (archive) | `app.loam.Loam.rc` | Loam RC | `AppIcon-RC` (orange) | staging |
| Xcode | `Debug` | `Loam` (run) | `app.loam.Loam.dev` | Loam Dev | `AppIcon-Dev` (blue) | staging |

Debug builds register **sandbox** APNs tokens (`PushEnvironment.current` in `Loam/Data/NotificationRepository.swift` keys off `#if DEBUG`); TestFlight and App Store builds register **production** tokens. Only App Store builds send analytics (only `Production.xcconfig` sets the PostHog keys).

## Where each value is set

- `Loam/Config/Production.xcconfig` sets `LOAM_BUNDLE_ID`, `LOAM_APP_ICON`, `APP_DISPLAY_NAME`, `LOAM_SIRI_NAME`, `LOAM_SIRI_PRONUNCIATION` for the App Store app. `Release.xcconfig` includes it.
- `Loam/Config/Staging.xcconfig` sets them for TestFlight. `Debug.xcconfig` includes Staging, then overrides them for Loam Dev.
- `project.yml` maps configurations to files (`configFiles`) and sets `PRODUCT_BUNDLE_IDENTIFIER: $(LOAM_BUNDLE_ID)` and `ASSETCATALOG_COMPILER_APPICON_NAME: $(LOAM_APP_ICON)` on the `Loam` target. The `Loam` scheme runs `Debug` and archives `Production`; `Loam-TestFlight` archives `TestFlight`.
- `Loam/Info.plist` reads `$(APP_DISPLAY_NAME)` for `CFBundleDisplayName` and `$(LOAM_SIRI_NAME)` / `$(LOAM_SIRI_PRONUNCIATION)` for the Siri app name. Shortcuts belong to one app, so a shortcut made in one build doesn't run another.
- Icons are Icon Composer bundles in `Loam/Resources/`: `AppIcon.icon`, `AppIcon-RC.icon`, `AppIcon-Dev.icon`. They share `Assets/final.svg`; the variants set a solid white glyph on an `automatic-gradient` background color in `icon.json`.
- `scripts/run-sim.sh` and `scripts/dual-sim.sh` launch `app.loam.Loam.dev`. The unit and UI test targets keep their own fixed bundle IDs.

## Changing an icon or adding a variant

- **Icon:** edit the `.icon` bundle in Icon Composer (or the `fill` color in its `icon.json`). A new icon name must be added to `Loam/Resources/`, referenced in the xcconfig's `LOAM_APP_ICON`, and present in `Loam.xcodeproj` (run `xcodegen generate`; the `.icon` files are in the target's Resources phase).
- **Name or bundle ID:** change the xcconfig only, never `project.yml` or the pbxproj directly. A new bundle ID also needs every external step below, plus `scripts/run-sim.sh` / `dual-sim.sh` if it is the Debug one.
- **New variant:** add a configuration under `configs` and `configFiles` in `project.yml`, an xcconfig that sets all five variant values (include Staging or Production for the backend), a scheme if Xcode Cloud should archive it, and an icon. Then do the external setup.

## External setup (not in the repo)

**Apple Developer → Identifiers.** One explicit App ID per bundle ID (`app.loam.Loam`, `app.loam.Loam.rc`, `app.loam.Loam.dev`), each with:
- Push Notifications.
- Sign in with Apple, with `.rc` and `.dev` set to "Group with an existing primary App ID" → `app.loam.Loam`, so a user's Apple ID maps to the same account across apps.

**App Store Connect.** A separate app record, **Loam RC**, for `app.loam.Loam.rc`. TestFlight builds upload there, not to the Loam record.

**Xcode Cloud** (configured in App Store Connect). Xcode Cloud allows one product per repository, so both workflows live under the **Loam** product (`app.loam.Loam`, ASC app 6809904711) and Loam RC (ASC app 6835553681) has no product.
- **Release candidate**: start condition tags `rc/*`, scheme `Loam-TestFlight` (archives `TestFlight`), Deployment Preparation **None**, no TestFlight post-action. Xcode Cloud can't publish to Loam RC, so `ci_scripts/upload-rc-archive.sh` (run from `ci_post_xcodebuild.sh` after the Sentry upload) exports the archive and uploads it to Loam RC's internal TestFlight with an App Store Connect API key. It skips any archive whose bundle ID isn't exactly `app.loam.Loam.rc`, so production is never uploaded from there.
- **Production**: branches `release/*`, scheme `Loam`, archive `Production`, published by Xcode Cloud.
- Secret env vars: `SENTRY_AUTH_TOKEN` on both. On Release candidate also `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_PRIVATE_KEY_B64` (`base64 -i AuthKey_<id>.p8 | tr -d '\n'`) of a team API key with the **Admin** role; lower roles can't create the distribution signing assets. Missing ones fail the archive.
- Fallback without Xcode Cloud: `scripts/rc-testflight.sh [ref]` builds Loam RC locally and uploads it with the `asc` CLI. It refuses a ref whose `Staging.xcconfig` doesn't set `LOAM_BUNDLE_ID = app.loam.Loam.rc`.

**RevenueCat.** `Staging.xcconfig` leaves `REVENUECAT_API_KEY` empty, so TestFlight has no purchases. The App Store app's key can't sell from `.rc`; to test purchases on TestFlight, add an `app.loam.Loam.rc` app in RevenueCat and put its `appl_…` key there.

## Staging backend for two bundle IDs

The `staging` Supabase project serves both Loam RC and Loam Dev.

**GitHub `staging` environment** (read by the `deploy` job in `.github/workflows/supabase.yml`):
- Secrets `APPLE_CLIENT_ID` = `app.loam.Loam.rc` and `APPLE_CLIENT_SECRET`, a JWT signed for `.rc`: `node scripts/apple-client-secret.mjs "$key" app.loam.Loam.rc | gh secret set APPLE_CLIENT_SECRET --env staging`. The script defaults to `app.loam.Loam` (production). Renewal and expiry: `docs/account-deletion-runbook.md` → "Renewing the Apple client secret".
- **Variables** (not secrets; the workflow reads `vars.*`): `APNS_BUNDLE_ID` = `app.loam.Loam.rc`, `APNS_SANDBOX_BUNDLE_ID` = `app.loam.Loam.dev`. Unset, both fall back to `app.loam.Loam`, which is right for production only.

Because the client secret is for `.rc`, deleting an Apple-linked account from a Loam Dev build on staging is refused at the confirmation step, before anything is deleted. Test account deletion on TestFlight.

**Supabase staging → Authentication → Providers → Apple → Client IDs:** `app.loam.Loam.rc,app.loam.Loam.dev`. Native sign-in checks the ID token's audience against this list, so a missing ID fails sign-in for that app only.

**How `send-push` picks a topic.** `supabase/functions/send-push/index.ts` builds the config with `topic = APNS_BUNDLE_ID` and reads `APNS_SANDBOX_BUNDLE_ID`. `configForDevice` in `supabase/functions/_shared/apns.ts` uses the sandbox topic for devices registered as `sandbox` (Debug builds) when it is set, otherwise `APNS_BUNDLE_ID`. Sandbox tokens go to `api.sandbox.push.apple.com`, production tokens to `api.push.apple.com`. A wrong topic gets `DeviceTokenNotForTopic`, which the function treats as dead and deletes a valid token, so a misconfigured variable silently unregisters devices. Tests: `deno test supabase/functions/send-push`.

## Verification checklist

- `gh variable list --env staging` shows `APNS_BUNDLE_ID app.loam.Loam.rc` and `APNS_SANDBOX_BUNDLE_ID app.loam.Loam.dev` (plus `SUPABASE_PROJECT_REF`, `ANALYTICS_ENABLED=false`).
- `gh secret list --env staging` lists `APPLE_CLIENT_ID` and `APPLE_CLIENT_SECRET`. The latest `Supabase migrations` run on `main` passed the client secret expiry check.
- Build settings per configuration:
  `for c in Debug TestFlight Production; do xcodebuild -scheme Loam -configuration $c -showBuildSettings 2>/dev/null | grep -E ' (PRODUCT_BUNDLE_IDENTIFIER|LOAM_APP_ICON|APP_DISPLAY_NAME) ='; done`
- After `scripts/run-sim.sh`: `plutil -p "$(xcrun simctl get_app_container booted app.loam.Loam.dev)/Info.plist" | grep -E 'CFBundleIdentifier|CFBundleDisplayName|CFBundleIconName|LOAM_ENVIRONMENT'` shows `.dev`, `Loam Dev`, `AppIcon-Dev`, `testing`. The home screen shows the blue icon.
- Loam RC from TestFlight: orange icon, named Loam RC, installs beside Loam; Sign in with Apple works; a push arrives (proves `APNS_BUNDLE_ID`).
- Loam Dev on a device: Sign in with Apple works and a push arrives (proves the Client IDs list and `APNS_SANDBOX_BUNDLE_ID`).
- Apple Developer: all three App IDs have Push and Sign in with Apple, `.rc` and `.dev` grouped under `app.loam.Loam`. App Store Connect has the Loam RC record and the latest `rc/*` build lands there.
