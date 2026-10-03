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

Database migrations are deployed by `.github/workflows/supabase.yml`: pushes to `main` apply pending migrations to staging, and pushes to a `release/**` branch apply them to production. Configure these GitHub Actions secrets before enabling the workflow:

- `SUPABASE_ACCESS_TOKEN`
- `SUPABASE_STAGING_DB_PASSWORD`
- `SUPABASE_PRODUCTION_DB_PASSWORD`

Keep production migration deployment behind a required GitHub `production` environment approval if you want a manual gate. Apply and test migrations on staging before cutting a release branch.

Xcode Cloud sets the build number, so `CURRENT_PROJECT_VERSION` in `project.yml` only applies to local builds. `MARKETING_VERSION` must match the version in App Store Connect.

### 6. Releasing

`main` is the trunk. Every release is a short-lived branch, and tags mark what shipped.

| Ref | Deploys |
|---|---|
| push to `main` | staging migrations and functions, the support site |
| tag `rc/x.y.z-N` | Xcode Cloud archives `Loam-TestFlight` (staging) for internal TestFlight |
| push to `release/x.y.z` | production migrations and functions, then Xcode Cloud archives `Loam` (production) for the App Store |
| tag `vx.y.z` | nothing; marks the build Apple approved |

1. Set `MARKETING_VERSION` to `x.y.z` on `main` and create version `x.y.z` in App Store Connect.
2. Test with `rc/x.y.z-N` tags until the build is ready.
3. Branch `release/x.y.z` from `main` and push it. Wait for the production deploy and the Xcode Cloud build, then submit that build for review.
4. If Apple rejects it, fix on `release/x.y.z` and push again for a new build. Bring the fix to `main` too.
5. Once approved, tag the reviewed commit `vx.y.z`, push the tag and merge `release/x.y.z` into `main`.

Hotfixes branch `release/x.y.(z+1)` from the `vx.y.z` tag.

**Export compliance:** `Info.plist` sets `ITSAppUsesNonExemptEncryption = false` (HTTPS/Supabase only — no custom crypto). That skips the manual “App Encryption Documentation” step in App Store Connect and prevents TestFlight post-actions from hanging while waiting for compliance.

Info.plist keys (via build settings from xcconfig):

- `POSTHOG_PROJECT_TOKEN`
- `POSTHOG_HOST`
- `REVENUECAT_API_KEY`
- `SENTRY_DSN`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

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
