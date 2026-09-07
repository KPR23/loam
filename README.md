# Loam

Native iOS expense tracker for personal + household spending. Home answers **how much I spent this month** — not who owes whom.

## Stack

- SwiftUI, iOS 17+
- Supabase (Postgres + Auth + Realtime + RLS)
- Sign in with Apple
- StoreKit 2 (stub in later phase)

## Phase 0 (current)

- Xcode project + folder architecture
- `Money` as `Int` minor units
- Supabase SQL schema + RLS (incl. empty `recurring_*`)
- Sign in with Apple (+ demo mode when Supabase is not configured)
- Empty Home led by personal month total

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
4. Copy project URL + anon key into `Loam/Config/Secrets.xcconfig` (see example)

Without secrets, the app still runs in **demo mode** (Continue without account) so UI work is unblocked.

### 3. Secrets

```bash
cp Loam/Config/Secrets.xcconfig.example Loam/Config/Secrets.xcconfig
# edit URL + anon key
```

Then in Xcode: Project → Info → Configurations → based on `Secrets.xcconfig`, **or** set env vars `SUPABASE_URL` / `SUPABASE_ANON_KEY` in the Run scheme.

Info.plist keys expected (via build settings):

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

Add to the target build settings if not using xcconfig yet:

```
INFOPLIST_KEY_SUPABASE_URL = $(SUPABASE_URL)
INFOPLIST_KEY_SUPABASE_ANON_KEY = $(SUPABASE_ANON_KEY)
```

## Architecture

```
Loam/
├─ Core/       Money, Category, Formatters, SettlementMode
├─ Data/       Supabase client
├─ Domain/     SplitCalculator, BalanceSimplifier
├─ Features/   Auth, Home  (+ AddExpense, Household, Balances, Paywall later)
└─ System/     Auth
```

## Product rule

Home must read as a tracker:

1. You spent X this month  
2. of which Y is your share of shared expenses  
3. balances only below (ledger mode)

## Next

**Phase 1** — personal expense CRUD + month sum in ~3 taps.
