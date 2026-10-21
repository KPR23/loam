---
name: pr-screenshots
description: Gets simulator screenshots for a Loam UI PR from CI. Use when a PR changes a screen, when asked for PR screenshots, or when adding a screen to the screenshot flow.
---

# PR screenshots

Add the `screenshots` label to a same-repo PR. The **Screenshots** workflow then builds the app on a macOS runner, runs the screenshot flows against a throwaway local Supabase stack (the PR's own migrations plus `scripts/screenshots/seed.sql`), and posts one comment on the PR with every screen in light and dark. Each push to the PR refreshes the comment while the label stays; remove the label to stop. The images are uploaded with `gh pr comment --attach`, so no branch holds them.

## Merging does not wait

The workflow is not a required check. Small PRs can merge without it, and a red Screenshots run never blocks a merge. Request screenshots when the change is visual enough that a reviewer should see it.

## What it needs

- Fork PRs are skipped. The workflow runs the PR's code, so it only runs for branches in this repo.
- No secrets: the sample users (Julia, Philip) and their passwords are fake and only exist in the runner's database.
- The backend runs on Linux and the simulator on macOS (macOS runners have no Docker), joined by a temporary Cloudflare quick tunnel. If the run fails at "Open a tunnel" or "Wait for the backend", re-run it.

## Which screens get captured

- **Always:** the standard set in `StandardScreenshots.swift` (Expenses, Add expense, Balances, Activity, Profile), light and dark.
- **Extra, by name:** put a line in the PR description, for example `Screenshots: profile-bottom, expense-menu`. The workflow reads the first `Screenshots:` line (lowercase names, comma or space separated) and `RequestedScreenshots` runs each name after the standard set. An unknown name fails the run and lists the known ones.
- **A screen that needs setup** (open sheet, pull-down search, long-press menu, scrolling): add an entry to `RequestedScreens.steps` in `LoamUITests/RequestedScreenshots.swift` in the same PR. The closure starts on the Expenses tab, does the taps and gestures the screen needs, and calls `try test.capture("name")`. `expense-menu` (long-press) and `profile-bottom` (scrolling) are examples. For a whole new flow, subclass `ScreenshotTestCase` instead.
- Each capture saves `<name>-light.png` and `<name>-dark.png`. Screenshot classes skip themselves outside the workflow, so normal `Build & Test` runs are unaffected. New files must be added to `Loam.xcodeproj` (run `xcodegen generate`).

Seed data changes go in `scripts/screenshots/seed.sql`. It goes through `save_expense` like the database tests, so it follows the PR's migrations.

## Debugging a run

A failed capture uploads its `.xcresult` as an artifact. To try the backend locally: `supabase start`, then `scripts/screenshots/seed-backend.sh`.
