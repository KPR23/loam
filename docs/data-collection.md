# Data collection

What Loam's analytics and crash tools receive. Keep this in sync with `Telemetry.swift`,
`site/privacy/index.html` and the App Store privacy label.

## Identity

PostHog gets only the Supabase account ID: a random UUID. Sentry gets no user identity. No email, name, phone or other
person properties are ever sent. It is *pseudonymous*, not anonymous: the same ID ties one
account's events together (needed for funnels and retention), and it can be matched to an
account in our database. Deleting the account erases the PostHog person
(`supabase/functions/_shared/posthog_delete.ts`).

## PostHog (usage analytics)

Opt-in per account, App Store builds only, nothing sent before consent. No session replay, no
autocapture, no screen views.

| Event | Properties | Why |
| --- | --- | --- |
| Application Installed / Opened / Updated / Backgrounded (SDK lifecycle) | app version, build | Activity and retention |
| `onboarding finished` | `furthest_page`, `skipped`, `notifications_allowed` | How onboarding went |
| `expense created` | `shared`, `recurring`, `participant_count` | Core action; first one is activation |
| `repayment recorded` | none | Uses the split feature |
| `friend connected` | none | Uses the split feature |

PostHog also attaches standard device properties (model, OS and app version, locale). Onboarding runs
before sign-in, so its progress is saved on the device and sent once, after the user opts in.
People who leave before sign-in or decline analytics are not counted.

## Sentry (crashes and errors)

Every TestFlight and App Store user who has not turned crash reports off. Crash diagnostics (device model, iOS and app version, stack
traces), not tied to an account (no `setUser`). Settings > "Send crash reports" turns them off (stored as `loam.crashReports.enabled`, on by default). No PII, no session replay.

## Dashboard

PostHog dashboard "Loam health": new users per week, funnel (onboarding finished, expense
created, friend connected), where onboarding ended, weekly retention, expenses per week.
