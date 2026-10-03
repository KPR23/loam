# Loam database audit — 23 September 2026

**Assessment:** fix the authorization and integrity issues before inviting real users. The most serious problems are publicly readable spending summaries and write permissions that bypass the app's acceptance rules. Duplicated expense fields are not the main risk.

This was an audit. No migrations, schema fixes, data deletion, or production deployment were performed. Reproduction writes used synthetic users in transactions ending in `ROLLBACK`. Follow-up queries confirmed that the fixtures were absent and the existing expense/share/activity counts were unchanged.

**Scope and evidence**

Inspected both Supabase projects through MCP: project health, migration history, security/performance advisors, schema and table privileges, RLS policies, function definitions and execution grants, constraints, indexes, triggers, storage bucket settings, extensions, role settings, publications, Edge Functions, cron schedules, and account-deletion health. Compared relevant definitions with the Swift repositories and migration files. Also made read-only HTTP requests using the app's publishable keys to verify anonymous view access, exposed API schemas, and public Auth settings.

| Live project | Observed state |
| --- | --- |
| `loam-demo` / `iazyvupjvtuiezugurvo` | 36 applied migrations; 13 public application tables, all with RLS; one public view; four private deletion tables; four deployed Edge Functions. |
| `loam-prod` / `nffogbutnyevhhwnpgip` | No application tables, migrations, buckets, or Edge Functions. Apple sign-in disabled. Its short advisor list reflects an almost empty application backend. |
| Both | Healthy PostgreSQL 17.6.1.166 projects; Data API exposes `public` and `graphql_public`, rejects `private`; anonymous sign-in disabled; email signup enabled and email confirmation required. |

Staging held four expenses, six shares, six households, twelve memberships, thirty-three activity rows, four profiles, and no recurring rules or proposals during the audit. Existing expense totals matched their shares. This is far too little traffic to make reliable decisions from unused-index statistics.

The MCP tools available in this session do not expose all hosted management settings. SSL enforcement, network restrictions, PITR/backup retention, MFA configuration, full Auth rate limits, CAPTCHA, and OAuth redirect allowlists were **not verified**. The local `supabase/config.toml` is not evidence of those hosted settings. The SQL role settings include a JWT-expiry setting of 3,600 seconds, but this is not a verification of the full hosted Auth configuration.

**Confirmed findings, ordered by priority**

1. **P1 — The monthly-spend view is readable without signing in.**

   `public.v_personal_month_spend` is owned by `postgres`, has no `security_invoker` option, has no caller filter, and grants SELECT to `anon`. A read-only query under `SET LOCAL ROLE anon`, with `auth.uid()` null, returned a count of three visible summary rows. A real HTTP HEAD request to the REST view with only the publishable key returned HTTP 206 and `Content-Range: 0-0/3`.

   The exposed fields include user UUID, month, currency, total spending and shared spending. The query aggregates everyone's rows, bypassing the underlying expense/share RLS.

   **Fix:** the Swift app has no reference to this view, so remove it if it is unused. If retained, set `security_invoker = true`, revoke anonymous access, and explicitly restrict `s.user_id = (select auth.uid())` for a personal-only summary. Invoker security alone still allows aggregation of other participants' shares on expenses the caller is allowed to read. Prefer bigint totals and `COALESCE` for empty filtered sums.

   Source: [view definition](/Users/kacperzabludowski/Developer/loam/supabase/migrations/20260910000000_expense_acceptance.sql:530). [Supabase view-security advisor](https://supabase.com/docs/guides/database/database-linter?lint=0010_security_definer_view).

2. **P1 — Users can promote themselves to household owner.**

   `member_insert_owner_or_self_join` allows an inserted membership whenever `auth.uid() = user_id`. It does not require an invitation/connection or restrict the supplied `role`.

   **Reproduced:** an unrelated synthetic authenticated user inserted their own membership into another user's household with `role = 'owner'`; `is_household_owner` then returned true. Knowing a household UUID must not count as authorization. The owner policies allow membership administration and household deletion; the expense foreign key has `ON DELETE CASCADE`, making these owner powers consequential.

   **Fix:** remove direct self-join and client-controlled role assignment. If households remain temporarily, use an authorized RPC for membership creation and role changes. Existing `ensure_split_household` connection validation is bypassable while direct writes remain available.

   Source: [membership policy](/Users/kacperzabludowski/Developer/loam/supabase/migrations/20260909000001_household_member_rls.sql:5).

3. **P1 — Expense creators can accept someone else's debt.**

   `share_update_creator` authorizes updates to every share on the creator's expense. RLS controls which rows can change; the policy name and comments do not restrict which columns can change.

   **Reproduced:** creator A directly changed participant B's pending share to accepted. The share sum was valid, so the constraint did not stop it. The status trigger then generated acceptance activity identifying B as the actor, even though A performed the update.

   **Fix:** enforce the acceptance state machine at the database boundary. Separate structural expense edits from participant consent. Restrict direct DML/column access and use narrowly authorized transactional operations or comprehensive triggers. Revoking table writes requires adapting the current security-invoker RPCs as well; a grant change alone would break them.

   Source: [share update policies](/Users/kacperzabludowski/Developer/loam/supabase/migrations/20260910000002_per_user_share_acceptance.sql:8).

4. **P1 — A “personal” expense can impose accepted debt on another user.**

   Expense insertion validates the creator/payer but share insertion only checks that the caller created the parent expense. It does not enforce that a personal expense contains only the creator, or validate every shared participant against the intended sharing rules. The insert trigger automatically accepts every share when `household_id IS NULL`.

   **Reproduced:** A created a personal expense with their own zero share and a 1,000-minor-unit share assigned to B, with no accepted connection or trust. B's share was automatically accepted. Combined with the previous 500-unit fixture, `balance_snapshot()` reported a 1,500-unit claim by A against B.

   **Fix:** create expense and shares in one authorized transaction; validate payer, participants, allowed connections, personal/shared semantics, totals, and server-assigned acceptance fields. Checks inside the Swift app or update RPC do not protect the direct insert endpoint.

   Source: [expense creation path](/Users/kacperzabludowski/Developer/loam/Loam/Data/SupabaseExpenseRepository.swift:121), live `share_insert_via_expense`, `share_status_for_insert`.

5. **P1 — Expense totals can diverge from their shares.**

   The deferred sum-check trigger runs on `expense_share` changes only. Updating `expense.amount_minor` alone never invokes it.

   **Reproduced:** changed a 1,000-unit expense to 2,000 while its shares remained 1,000. `SET CONSTRAINTS ALL IMMEDIATE` did not reject the inconsistent state.

   Expense creation also uses two separate HTTP transactions: insert expense, then shares, with best-effort cleanup if the second request fails. A crash or failed cleanup can leave an expense without shares. The recurring unique index then makes retry behavior particularly important.

   **Fix:** transactional create/update operations and an invariant covering both expense totals and share changes. Add parent-row locking/concurrency handling and reject empty or invalid share collections. Cover old and new parents if share reparenting is ever allowed.

   Source: [sum trigger](/Users/kacperzabludowski/Developer/loam/supabase/migrations/20260907000000_init.sql:173), [two-request creation](/Users/kacperzabludowski/Developer/loam/Loam/Data/SupabaseExpenseRepository.swift:124).

6. **P2 — Proposal status can be forged; proposal application lacks version checks.**

   `proposal_update_participant_or_creator` permits the proposer to update their own row without limiting columns or transitions.

   **Reproduced:** B inserted a proposal and directly changed its status to accepted, bypassing `respond_to_edit_proposal`. This forges proposal state and activity; it does **not** itself apply the proposed expense changes.

   Separately, the current response RPC reads a proposal and expense without a locking/version precondition. It can apply a stale proposal over later expense edits. Proposed shares use JSONB without comprehensive schema validation; the acceptance path does not repeat the household-member/payer validation present in the ordinary update RPC.

   **Fix:** make proposal identity and payload immutable after submission, expose explicit withdraw/accept/reject operations, validate the full payload, lock affected rows, and require an `expense_version` matching the proposal's `base_version`. Store proposed currency or explicitly reject acceptance after currency changes.

   Sources: [proposal update policy](/Users/kacperzabludowski/Developer/loam/supabase/migrations/20260910000003_fix_proposal_retargeting.sql:6), [proposal RPCs](/Users/kacperzabludowski/Developer/loam/supabase/migrations/20260913173417_expense_location.sql:98).

7. **P2 — Failed connection-code attempts escape rate limiting.**

   The rate helper inserts an attempt in the same transaction as code lookup. Lookup then raises an exception for invalid/unavailable codes, rolling the attempt back.

   **Reproduced:** 12 invalid previews all returned “That code is unavailable”; none reached the nominal 10-attempt rate limit, and zero counter rows remained within the outer test transaction. The test catches each error in a PostgreSQL subtransaction, reproducing the rollback that occurs for a failed RPC.

   **Fix:** persist attempts outside the failing transaction, or return a structured failure result that commits the attempt and map it to an application error outside PostgreSQL. Add cleanup/retention for attempt rows. Use endpoint/IP throttling as an additional layer.

   Source: [rate helper and preview RPC](/Users/kacperzabludowski/Developer/loam/supabase/migrations/20260922100000_connection_codes.sql:49).

**Answers to the seven schema questions**

| Question | Recommendation |
| --- | --- |
| 1. `activity_event` duplicates expense details | Keep a small event-time snapshot plus expense ID. An activity entry describes what happened then; joining only the current expense rewrites history after edits and loses context after deletion. Your table also copies an event for each audience member. Splitting into `activity_event` and `activity_event_audience` is reasonable later, but is not urgent at this scale. |
| 2. Remove `household_id` | Assuming this means `expense.household_id`: it is still used throughout the database and app. It defines `ExpenseRecord.isShared`, participates in validation and acceptance/trust, and is supplied from `ensure_split_household`. Remove it as part of a coordinated model change, not as an isolated column drop. |
| 3. `expense_edit_proposal` duplicates expense fields | Keep the proposed values: they represent an alternative state that must coexist with the current expense. A full typed snapshot is often clearer than a sparse patch. Add a base version and enforce immutability/approval rules. A relational `proposal_share` child table would improve foreign-key/check enforcement; JSONB is viable only with full server-side validation. |
| 4. `expense_share_trust.household_id` | Today trust is scoped to a household, so trusting the same person in another participant combination may not carry over. If the product means “always trust this person,” use a directional unique pair `(user_id, trusted_user_id)`, with self-trust prohibited and explicit revoke behavior. Removing the column changes consent scope. Since the data is disposable, clear old trust rather than silently broadening existing consents. |
| 5. `household` and `household_member` | For the current pairwise-connections product, I recommend removing this hidden grouping layer eventually. The app creates “Splits” households as a creator/participant-set container rather than a user-facing household. Expense participants already exist in `expense_share`. First replace authorization and all dependent functions, Swift models, tests, recurring behavior and deletion logic. |
| 6. `recurring_rule` duplicates expense fields | Keep template fields in the rule. A recurring rule describes future intent; an expense records one actual occurrence. Referencing only one mutable past expense couples future generation to historical edits/deletion. The current implementation already has two competing sources: it usually prefers the latest expense over the rule. Make the rule the authoritative template and add template shares/payer there. |
| 7. `v_personal_month_spend`, view and “unrestricted” | A regular view is a named SELECT query, not a second stored copy of the data. Views do not have ordinary table RLS policies, so the dashboard label alone does not prove either safety or exposure. In this specific project, the default owner privileges and anonymous grant make the view unsafe, confirmed via REST. |

The live `activity_event` table does not have a `household_id` column.

Recurring detail: [generation](/Users/kacperzabludowski/Developer/loam/Loam/Data/ExpenseStore.swift:655) fetches the latest expense; [template selection](/Users/kacperzabludowski/Developer/loam/Loam/Core/Recurring.swift:272) gives it precedence for amount, currency, category and other fields. Deleting the last available occurrence loses the split template and falls back to an owner-only share. Generation runs when the app refreshes, not from a scheduled server worker. That is acceptable if intentional, but balances will not gain missed occurrences until the owner's app runs.

[Supabase documentation on views and RLS](https://supabase.com/docs/guides/database/postgres/row-level-security#views).

**Other correctness and efficiency findings**

- **Activity snapshots can mix old shares with new totals.** The expense UPDATE trigger logs before `update_expense_with_shares` deletes/reinserts shares. Log the completed logical operation after the final share state is known. Suppress meaningless “edited” events when only bookkeeping fields change.
- **Activity pagination can skip rows.** The query orders by timestamp and ID but the next page filters only `occurred_at < cursor`. Events sharing the boundary timestamp are lost; `now()` gives all events in one transaction the same timestamp. Use a composite timestamp/ID cursor, preserving timestamp precision. [Current query](/Users/kacperzabludowski/Developer/loam/Loam/Data/SupabaseActivityRepository.swift:8).
- **Strengthen structural constraints.** Expenses/rules accept arbitrary currency text while repayment creation only permits PLN/EUR/USD. Use one currency definition. Validate recurring date bounds, JSONB shape and size, payer membership, and ownership of referenced recurring rules. Use bigint for aggregates; several sums cast back to integer and can overflow even when individual rows fit.
- **Privileged helper exposure needs cleanup.** Nine security-definer functions are executable by `anon`, and 25 by `authenticated`. These counts are not 34 confirmed vulnerabilities: intended RPCs need execution grants, and trigger-returning functions cannot simply be called as ordinary RPCs. However, `share_status_for_insert(expense_id,user_id)` is an ordinary callable helper that bypasses RLS and lacks a caller authorization check; it reveals acceptance/trust-derived status for supplied IDs. Remove its public execution path. Remove the obsolete `ensure_test_household` endpoint and placeholder helpers if their callers are gone.
- **Three functions lack a pinned search path:** `enforce_expense_share_sum`, `is_placeholder_partner`, `auth_is_placeholder_partner`. Pin paths/qualify objects. This is hardening, not proof of a currently exploitable code-execution path. [Advisor guidance](https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable).
- **Grants are broader than necessary.** Many application tables and defaults still grant anon and authenticated wide privileges. RLS usually blocks anonymous rows, but it does not protect this definer view. Adopt explicit grants for intended operations and explicit function grants. Fix existing objects and defaults; changing defaults does not repair existing grants.
- **Performance advisors:** 16 foreign keys lack covering indexes; 25 policy findings concern repeatedly evaluated Auth calls; `expense_share` has overlapping permissive UPDATE policies. Prioritize `expense.created_by`, `recurring_rule.owner_user_id`, connection and repayment lookups, and foreign keys involved in deletion. Use `(select auth.uid())` where appropriate and inspect plans with realistic data. Do not remove the two “unused” indexes based on this tiny test dataset. [Index advisor](https://supabase.com/docs/guides/database/database-linter?lint=0001_unindexed_foreign_keys), [RLS evaluation advisor](https://supabase.com/docs/guides/database/database-linter?lint=0003_auth_rls_initplan).
- **Rate-limit table:** missing primary key is low priority compared with its rollback bug. An identity key and retention policy would make maintenance clearer.
- **Leaked-password protection is disabled on staging.** Relevant because email auth is enabled for test accounts. Enable it if password auth remains available, or disable unused email auth in production if Apple is the only intended login. [Supabase password security](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).
- **Test coverage gap:** the repository's SQL permission suite covers account deletion, not the central expense/share/household/proposal access matrix. Add role-based allow/deny and business-invariant regression tests for every confirmed issue, plus transaction and concurrent-update tests.

**Controls that are working or are reasonable**

- Every public application table has RLS enabled.
- `activity_event` allows authenticated reads only and filters by audience; clients cannot directly insert/update/delete feed rows.
- The `avatars` bucket is private, limited to JPEG and 1 MiB. Reads are restricted to self/connections; writes and deletes use the caller's folder. No UPDATE policy exists, so uploading with upsert would need a deliberate additional policy.
- Private deletion tables have no client table privileges and the private schema is not exposed through the Data API. Their lack of RLS is not presently a demonstrated public leak; adding RLS is optional defense in depth.
- `connection_code_rate_limit` having RLS with no policies is intentional deny-by-default for clients; do not add permissive policies just to clear the informational advisor.
- Deletion RPCs intended for service use are restricted. All four deployed Edge entrypoints match the local files. Although gateway `verify_jwt` is false, the code implements its own session/receipt or shared-secret checks; the setting alone is not evidence of unauthenticated deletion.
- Deletion worker and notifier cron jobs are active every minute; both heartbeats were recent, with zero pending jobs, terminal failures or email failures at inspection time. This is an operational snapshot, not an end-to-end Apple deletion test.
- Balance calculations separate currencies, require accepted debtor and payer shares, and exclude reversed repayments. Repayment operations have idempotency keys and locking, although the share authorization holes undermine the validity of their input balances.
- The unique recurring occurrence index `(recurring_id, spent_at) WHERE recurring_id IS NOT NULL` is useful protection against duplicate generation.
- No tables are currently in a Realtime publication, and the Swift code has no Realtime subscription path. This matches refresh-based synchronization; Realtime is not providing live updates today.

**Recommended implementation order**

1. Close the view exposure, household self-promotion, direct consent bypasses and personal-expense share injection.
2. Make expense creation/update and proposal acceptance transactional, version-aware, validated operations; repair rate limiting and add regression coverage.
3. Refactor away households if pairwise connections remain the product model; use expense shares as participation, directional user trust, authoritative recurring templates with template shares, and versioned proposals.
4. Correct activity logging/pagination, tighten grants and constraints, then tune indexes using realistic data.
5. Deploy the audited schema to the currently empty production project, configure Apple Auth and verify hosted production settings.

Because all data is pre-production, resetting staging and clearing old trust/proposals after the replacement model is tested is reasonable. A reset alone does not fix these issues: replaying the current migration chain recreates them.

**Reproductions**

[Rollback-only SQL proof](/Users/kacperzabludowski/Developer/loam/docs/database-audit-2026-09-23-repro.sql) contains the synthetic tests used for the confirmed authorization/integrity issues and failed-attempt rate limiter. These are diagnostic reproductions of the current bugs, not passing regression tests. Run only in a disposable development database with an administrator SQL session; the file intentionally exercises operations ordinary clients should eventually be denied.

