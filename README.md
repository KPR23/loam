# Loam

Native iOS expense tracker for personal spending and pairwise shared balances. Spending answers **how much I spent this month**; balances answer **who owes whom**.

## Stack

- SwiftUI, iOS 17+
- Supabase (Postgres + Auth + Realtime + RLS)
- Sign in with Apple
- RevenueCat (StoreKit purchases, paywall, Customer Center)

## Phase status

**Phase 0** — project, schema+RLS, Apple auth / demo, empty Home  
**Phase 1 (done)** — personal expense CRUD, month sum, Supabase sync when secrets are set (local fallback otherwise)

- Xcode project + folder architecture
- `Money` as `Int` minor units
- Supabase SQL schema + RLS (incl. empty `recurring_*`)
- Sign in with Apple (+ demo mode when Supabase is not configured)
- Home led by personal month total + expense list
- `SupabaseExpenseRepository` when configured; `LocalExpenseRepository` demo fallback
- Backend URL + anon key in committed `Loam/Config/Config.xcconfig` (shipped via Info.plist)

## Setup

### 1. Generate / open the Xcode project

```bash
xcodegen generate
open Loam.xcodeproj
```

The Development Team is configured in `project.yml`. Enable **Sign in with Apple** capability (the entitlement is already present).

### 2. Supabase

1. Create a project at [supabase.com](https://supabase.com)
2. Apply the complete, ordered `supabase/migrations/` chain (for example, `supabase db push`). Do not run only the initial migration: connections, approvals, and repayments are introduced by later migrations.
3. Auth → Providers → enable **Apple** (Services ID, key, etc.)
4. Put the project URL + **anon / publishable** key in `Loam/Config/Config.xcconfig`

Without a real anon key, the app runs in **demo mode** (Continue without account).

### 3. Environment configuration

Use the environment-specific files:

- `Loam/Config/Staging.xcconfig` for Debug and TestFlight.
- `Loam/Config/Production.xcconfig` for App Store distribution.

Each file contains the corresponding project's URL and publishable key:

```
SUPABASE_URL = https:/$()/abcdxyz.supabase.co
SUPABASE_ANON_KEY = eyJhbGciOi...   # or sb_publishable_…
```

**xcconfig gotcha:** `//` starts a comment, so never write `https://…` literally — use `https:/$()/…`.

Use the anon / publishable key only. Never commit `service_role` / `sb_secret_…` (RLS protects data; the anon key is meant to live in the client).

`Debug.xcconfig` and `TestFlight` deliberately use the staging Supabase project. `Release.xcconfig` and the `Production` configuration use the production project. The staging and production URLs and publishable keys are kept in the committed `Staging.xcconfig` and `Production.xcconfig` files; never put a service-role or secret key there.

### Real test-account switching (non-production only)

The debug account switcher uses real Supabase Auth users and real RLS-protected rows. It never routes test-persona expenses, households, proposals, or balances through `UserDefaults`. Each persona has a separate Supabase auth storage key, which is equivalent to keeping Julia, Philip, and the main account signed in on separate devices.

Keep this away from production with a separate Supabase project:

1. Create a dedicated staging/test Supabase project and apply the same ordered migrations.
2. Create confirmed email/password users for Julia and Philip in that project's Auth dashboard. Never create these users in production.
3. Add accepted `user_connection` rows between the identities that should split expenses. `ensure_split_household` rejects unknown or unconnected UUIDs.
4. Copy `Loam/Config/Secrets.example.xcconfig` to gitignored `Loam/Config/Secrets.xcconfig`, then put only the local persona credentials there:

   ```text
   LOAM_TEST_JULIA_USER_ID=<Julia auth.users UUID>
   LOAM_TEST_JULIA_EMAIL=<Julia email>
   LOAM_TEST_JULIA_PASSWORD=<Julia password>
   LOAM_TEST_PHILIP_USER_ID=<Philip auth.users UUID>
   LOAM_TEST_PHILIP_EMAIL=<Philip email>
   LOAM_TEST_PHILIP_PASSWORD=<Philip password>
   ```

`Debug.xcconfig` contains the non-secret project allowlist. The switcher is hidden unless all of the following are true: the app is compiled with `DEBUG`, `LOAM_ENVIRONMENT` is exactly `testing`, the active Supabase URL exactly matches `LOAM_TEST_SUPABASE_URL`, and the persona has a complete ID/email/password configuration. `Release.xcconfig` does not include local secrets, and Release builds compile the test-account code out.

Only publishable keys belong in the app. Use a secret/service-role key only in a trusted provisioning script or the Supabase dashboard; never add it to an Xcode setting, plist, scheme, or repository.

### 4. Loam Pro (RevenueCat)

Apple processes payments; RevenueCat validates receipts and owns the `loam_pro` entitlement. Loam Free covers personal tracking and one connection. Pro unlocks inviting more connections, recurring expenses and notes. Only the person creating an invite needs Pro: redeeming a code is always free.

- `REVENUECAT_API_KEY`: Debug uses the RevenueCat Test Store key. `Staging.xcconfig` (TestFlight) and `Production.xcconfig` need the public Apple key (`appl_…`). The SDK crashes Release builds that use a `test_` key. With no key, purchases are off and everyone stays on Free.
- Dashboard: products `monthly`, `yearly` (two-week trial) and `lifetime`, all attached to `loam_pro`, in the current offering as the monthly, annual and lifetime packages. Customer Center is designed there too; the paywall is built in `ProPaywall.swift` and reads prices and trials from the offering. It hides the lifetime package for now.
- Backend: the app logs customers in with the lowercase Supabase user ID. `create_connection_invitation` checks `private.pro_entitlement`, which the `revenuecat-webhook` and `sync-pro-entitlement` functions fill from RevenueCat's REST API. Set the GitHub secrets `REVENUECAT_SECRET_API_KEY` (a v1 secret key) and `REVENUECAT_WEBHOOK_AUTH`. Point the RevenueCat webhook at `<project>/functions/v1/revenuecat-webhook` and set its Authorization header to the exact `REVENUECAT_WEBHOOK_AUTH` value.

### 5. Xcode Cloud / TestFlight

The shared `Loam` scheme archives with the `Production` configuration. The `Loam-TestFlight` scheme archives with the `TestFlight` configuration, so TestFlight builds use staging while App Store distribution builds use production.

Database migrations and edge functions are deployed by `.github/workflows/supabase.yml`: pushes to `main` deploy staging, and pushes to a `release/**` branch deploy production. Each GitHub environment (`staging`, `production`) needs:

- the `SUPABASE_PROJECT_REF` variable, naming its Supabase project
- in `staging` only, the `ANALYTICS_ENABLED` variable set to `false`, because only App Store builds send analytics; `production` then needs the PostHog secrets and staging doesn't
- its DB password secret (`SUPABASE_STAGING_DB_PASSWORD` or `SUPABASE_PRODUCTION_DB_PASSWORD`) and the function secrets the deploy job validates
- `SUPABASE_ACCESS_TOKEN`, which can live at the repository level

Every function under `supabase/functions` deploys automatically, so a new function needs no workflow change.

Xcode Cloud sets the build number, so `CURRENT_PROJECT_VERSION` in `project.yml` only applies to local builds. `MARKETING_VERSION` must match the version in App Store Connect.

Xcode Cloud workflows are configured in App Store Connect, not in this repo. Keep them matching the table below: `Loam-TestFlight` starts on tags matching `rc/*`, and `Loam` starts on branches matching `release/*`.

After each archive, `ci_scripts/ci_post_xcodebuild.sh` uploads the dSYMs to Sentry, so both workflows need a secret `SENTRY_AUTH_TOKEN` environment variable holding a Sentry organization token. Without it the archive fails rather than shipping a build Sentry can't symbolicate. Debug builds don't report to Sentry.

### 6. Releasing

`main` is the trunk. Every release is a short-lived branch, and tags mark what shipped. `scripts/release.sh` runs each step.

| Ref | Deploys |
|---|---|
| push to `main` | staging migrations and functions, the support site |
| tag `rc/x.y.z-N` | Xcode Cloud archives `Loam-TestFlight` (staging) for internal TestFlight |
| push to `release/x.y.z` | production migrations and functions, then Xcode Cloud archives `Loam` (production) for the App Store |
| tag `vx.y.z` | a GitHub release with generated notes; marks the build Apple approved |

1. Create version `x.y.z` in App Store Connect. `main` already carries it in `MARKETING_VERSION`.
2. `scripts/release.sh rc` tags the next `rc/x.y.z-N` on `origin/main`. Repeat until the TestFlight build is ready.
3. `scripts/release.sh cut` pushes `release/x.y.z`, which deploys production, and opens a PR moving `main` to the next minor version. Wait for the deploy and the Xcode Cloud build, then submit that build for review.
4. If Apple rejects it, merge the fix into `main` first, then `scripts/release.sh pick <commit>` cherry-picks it onto the release branch for a new build. Fixes never land on the release branch alone, so it never merges back.
5. Once approved, `scripts/release.sh ship` tags `vx.y.z`, publishes the GitHub release and deletes the branch.

Hotfixes: `scripts/release.sh hotfix` branches `release/x.y.(z+1)` from the latest `vx.y.z` tag and sets its version. Merge the fix into `main`, `pick` it, submit, then `ship`.

Every push to a release branch migrates production at once. GitHub only offers required reviewers on environments with a paid plan for private repos, so there is no approval gate: push to release branches through the script. Production migrates before Apple approves the build, while the App Store version still runs against it, so migrations must be backward compatible. Add columns, tables and functions in one release and remove the old ones in a later release.

`main` accepts changes through pull requests that pass `verify-database` and `test-functions`. Merges rebase or squash, so history stays linear, and merged branches are deleted. Release branches reject force pushes.

**Export compliance:** `Info.plist` sets `ITSAppUsesNonExemptEncryption = false` (HTTPS/Supabase only — no custom crypto). That skips the manual “App Encryption Documentation” step in App Store Connect and prevents TestFlight post-actions from hanging while waiting for compliance.

Info.plist keys (via build settings from xcconfig):

- `POSTHOG_PROJECT_TOKEN`
- `POSTHOG_HOST`
- `REVENUECAT_API_KEY`
- `SENTRY_DSN`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

Only `Production.xcconfig` sets the PostHog keys, so Debug and TestFlight builds send no analytics and the PostHog project (216307) holds App Store users only. The `POSTHOG_PROJECT_ID` secret in the `production` environment must name that project, or account deletion erases nothing.

## Architecture

```
Loam/
├─ Core/       Money, Category, Formatters, SettlementMode
├─ Data/       Models, ExpenseStore, LocalExpenseRepository, Supabase client
├─ Domain/     SplitCalculator, BalanceSimplifier
├─ Features/   Auth, Home, AddExpense, Balances, Root (+ Profile)
└─ System/     Auth, DeepLinks, Subscriptions, Telemetry

Design/        App icon source (.icon bundle + exports → AppIcon.appiconset)
supabase/      SQL migrations + local config
```

## Product rule

Home must read as a tracker:

1. You spent X this month  
2. of which Y is your share of shared expenses  
3. balances are independent pairwise debts; repayments never change spending

## Next

**Phase 2** — connections, split approvals, balances, and repayment history.
