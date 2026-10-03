---
name: release
description: Runs Loam's release cycle with scripts/release.sh. Use when asked to tag an rc or TestFlight build, cut a release branch, ship to the App Store, cherry-pick a fix onto a release, start a hotfix, bump the app version, or explain where a build or deploy comes from.
---

# Releasing Loam

README.md → "Releasing" is the source of truth; read it if anything here looks out of date.

`main` is the trunk. A release is a short-lived `release/x.y.z` branch, and tags mark builds.

| Ref | What happens |
|---|---|
| push to `main` (via PR) | staging migrations and functions, the support site |
| tag `rc/x.y.z-N` | Xcode Cloud builds `Loam-TestFlight` (staging) for internal TestFlight |
| push to `release/x.y.z` | **production** migrations and functions at once, then Xcode Cloud builds `Loam` (production) |
| tag `vx.y.z` | GitHub release with generated notes; marks what Apple approved |

## Commands

Always go through the script. Never create rc/v tags, release branches or version bumps by hand.

- `scripts/release.sh rc [ref]`: tags the next `rc/x.y.z-N` on `origin/main` (or `ref`).
- `scripts/release.sh cut`: pushes `release/x.y.z` from `origin/main` and opens a PR moving `main` to the next minor version.
- `scripts/release.sh pick <commit>…`: cherry-picks commits that are already on `main` onto the open release branch and pushes.
- `scripts/release.sh ship`: tags `vx.y.z` on the release branch, publishes the GitHub release, deletes the branch.
- `scripts/release.sh hotfix`: branches `release/x.y.(z+1)` from the latest `vx.y.z` tag with the version set.

## Rules

- **Confirm with the user before `cut`, `pick`, `ship` or `hotfix`.** Each one pushes a release branch or tag. A release branch push migrates production immediately, and there is no approval gate.
- **Fixes land on `main` first**, through a PR, then go onto the release branch with `pick`. Never commit a fix only on a release branch, and never merge a release branch back into `main`.
- **Migrations must be backward compatible.** Production migrates before Apple approves the build, while the current App Store version still runs against it. Add columns, tables and functions in one release; remove the old ones in a later release. Flag any migration that drops, renames or tightens something the shipped app uses.
- `MARKETING_VERSION` (in `project.yml` and `Loam.xcodeproj/project.pbxproj`) must match the version in App Store Connect. The user creates that version in App Store Connect; remind them after `cut` and `hotfix`. Xcode Cloud sets the build number.
- `main` only accepts PRs that pass `verify-database` and `test-functions`. Merge with rebase to keep atomic commits.

## Typical flows

**New release:** `rc` until TestFlight looks good → confirm → `cut` → wait for the production deploy run and the Xcode Cloud build → the user submits for review → after approval, confirm → `ship`.

**Rejected by Apple:** fix via PR to `main` → merge → confirm → `pick <sha>` → the user submits the new build.

**Hotfix:** confirm → `hotfix` → fix via PR to `main` → `pick <sha>` → submit → `ship`.

## Checking status

- Deploys: `gh run list --workflow "Supabase migrations" --limit 5`
- Open release branch: `git ls-remote --heads origin 'release/*'`
- Latest tags: `git tag --list 'rc/*' 'v*' --sort=-creatordate | head`
