# Loam

Native iOS expense tracker for personal + household spending. Home answers **how much I spent this month** — not who owes whom.

## Stack

- SwiftUI, iOS 17+
- Supabase (Postgres + Auth + Realtime + RLS)
- Sign in with Apple
- StoreKit 2 (stub in later phase)

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

Set your **Development Team** in the Loam target signing settings. Enable **Sign in with Apple** capability (entitlement is already present).

### 2. Supabase

1. Create a project at [supabase.com](https://supabase.com)
2. Run `supabase/migrations/20260907000000_init.sql` in the SQL editor
3. Auth → Providers → enable **Apple** (Services ID, key, etc.)
4. Put the project URL + **anon / publishable** key in `Loam/Config/Config.xcconfig`

Without a real anon key, the app runs in **demo mode** (Continue without account).

### 3. Config.xcconfig

Edit `Loam/Config/Config.xcconfig`:

```
SUPABASE_URL = https:/$()/abcdxyz.supabase.co
SUPABASE_ANON_KEY = eyJhbGciOi...   # or sb_publishable_…
```

**xcconfig gotcha:** `//` starts a comment, so never write `https://…` literally — use `https:/$()/…`.

Use the anon / publishable key only. Never commit `service_role` / `sb_secret_…` (RLS protects data; the anon key is meant to live in the client).

Optional: set `SUPABASE_URL` / `SUPABASE_ANON_KEY` in the Xcode Run scheme to override Info.plist while debugging.

### 4. Xcode Cloud / TestFlight

Supabase URL + publishable key come from committed `Config.xcconfig` — no ASC env vars required for the backend.

Local builds use the committed `CURRENT_PROJECT_VERSION` in `project.yml`.

**Export compliance:** `Info.plist` sets `ITSAppUsesNonExemptEncryption = false` (HTTPS/Supabase only — no custom crypto). That skips the manual “App Encryption Documentation” step in App Store Connect and prevents TestFlight post-actions from hanging while waiting for compliance.

Info.plist keys (via build settings from xcconfig):

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

## Architecture

```
Loam/
├─ Core/       Money, Category, Formatters, SettlementMode
├─ Data/       Models, ExpenseStore, LocalExpenseRepository, Supabase client
├─ Domain/     SplitCalculator, BalanceSimplifier
├─ Features/   Auth, Home, AddExpense, Root (+ Household, Profile)
└─ System/     Auth, DeepLinks, StoreKit stub

Design/        App icon source (.icon bundle + exports → AppIcon.appiconset)
supabase/      SQL migrations + local config
```

## Product rule

Home must read as a tracker:

1. You spent X this month  
2. of which Y is your share of shared expenses  
3. balances only below (ledger mode)

## Next

**Phase 2** — household + invite + split in Add expense.
