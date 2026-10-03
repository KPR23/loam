#!/usr/bin/env bash
# Drives the release flow described in README.md ("Releasing").
#
#   scripts/release.sh rc [ref]        Tag the next rc/x.y.z-N on ref (default origin/main) for TestFlight
#   scripts/release.sh cut             Branch release/x.y.z from origin/main, then open a PR bumping main
#   scripts/release.sh pick <commit>…  Cherry-pick commits from main onto the open release branch
#   scripts/release.sh ship            Tag vx.y.z on the release branch, publish a GitHub release, delete the branch
#   scripts/release.sh hotfix          Branch release/x.y.(z+1) from the latest vx.y.z tag
#
# Version bumps happen in a temporary worktree, so your checkout is never switched.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

die() { echo "release: $*" >&2; exit 1; }

version_at() {
  git show "$1:project.yml" | sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}$/\1/p' | head -n 1
}

next_minor() { IFS=. read -r major minor _ <<< "$1"; echo "$major.$((minor + 1)).0"; }
next_patch() { IFS=. read -r major minor patch <<< "$1"; echo "$major.$minor.$((patch + 1))"; }

# Commits a MARKETING_VERSION change on top of start_ref as a new branch, without touching the checkout.
commit_version() {
  local start_ref=$1 branch=$2 version=$3 dir
  dir="$(mktemp -d)"
  git worktree add --quiet -b "$branch" "$dir" "$start_ref"
  perl -pi -e "s/^(\s*MARKETING_VERSION:\s*)\"?[0-9.]+\"?/\${1}\"$version\"/" "$dir/project.yml"
  perl -pi -e "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $version;/" "$dir/Loam.xcodeproj/project.pbxproj"
  git -C "$dir" commit --quiet --all --message "Set the app version to $version"
  git worktree remove "$dir"
}

# The release branch to act on: the current branch if it is one, otherwise the only one on origin.
release_branch() {
  local current branches
  current="$(git branch --show-current)"
  if [[ $current == release/* ]]; then echo "$current"; return; fi
  branches="$(git branch --remotes --list 'origin/release/*' --format='%(refname:lstrip=3)')"
  [[ -n $branches ]] || die "no release branch on origin"
  [[ $(wc -l <<< "$branches") -eq 1 ]] || die "several release branches; check one out first: $(tr '\n' ' ' <<< "$branches")"
  echo "$branches"
}

git fetch --quiet --prune --tags origin

case "${1:-}" in
  rc)
    ref="${2:-origin/main}"
    version="$(version_at "$ref")"
    [[ -n $version ]] || die "no MARKETING_VERSION in project.yml at $ref"
    last="$(git tag --list "rc/$version-*" | sed "s|^rc/$version-||" | sort -n | tail -n 1)"
    tag="rc/$version-$(( ${last:-0} + 1 ))"
    git tag --annotate "$tag" --message "$tag" "$ref"
    git push --quiet origin "$tag"
    echo "Pushed $tag ($(git rev-parse --short "$ref")). Xcode Cloud builds it for internal TestFlight."
    ;;

  cut)
    version="$(version_at origin/main)"
    branch="release/$version"
    git rev-parse --verify --quiet "origin/$branch" > /dev/null && die "$branch already exists"
    git tag --list "v$version" | grep -q . && die "v$version is already tagged; bump MARKETING_VERSION on main first"
    git push --quiet origin "origin/main:refs/heads/$branch"
    echo "Pushed $branch, which deploys production now. Once that run and Xcode Cloud's build finish, submit the build for review."

    next="$(next_minor "$version")"
    bump="chore/version-$next"
    commit_version origin/main "$bump" "$next"
    git push --quiet --set-upstream origin "$bump"
    gh pr create --base main --head "$bump" --title "Set the app version to $next" \
      --body "Starts $next on main now that \`$branch\` is cut. Create version $next in App Store Connect before tagging an rc."
    git branch --quiet --delete --force "$bump"
    ;;

  pick)
    shift
    [[ $# -gt 0 ]] || die "usage: release.sh pick <commit>…"
    branch="$(release_branch)"
    # A detached checkout (e.g. a tag) has no branch name, so fall back to its commit.
    previous="$(git branch --show-current)"
    previous_commit="$(git rev-parse HEAD)"
    git diff --quiet && git diff --cached --quiet || die "commit or stash your changes first"
    git switch --quiet "$branch" 2> /dev/null || git switch --quiet --track "origin/$branch"
    git pull --quiet --ff-only
    git cherry-pick -x "$@"
    git push --quiet origin "$branch"
    if [[ -n $previous ]]; then git switch --quiet "$previous"; else git switch --quiet --detach "$previous_commit"; fi
    echo "Pushed the fix to $branch, which deploys production now. Once that run finishes, submit the new build."
    ;;

  ship)
    branch="$(release_branch)"
    version="${branch#release/}"
    tag="v$version"
    git tag --annotate "$tag" --message "Loam $version" "origin/$branch"
    git push --quiet origin "$tag"
    gh release create "$tag" --verify-tag --generate-notes --title "Loam $version"
    git push --quiet origin --delete "$branch"
    git branch --quiet --delete --force "$branch" 2> /dev/null || true
    echo "Tagged $tag and deleted $branch. Hotfixes start from the tag: release.sh hotfix"
    ;;

  hotfix)
    latest="$(git tag --list 'v*' --sort=-version:refname | head -n 1)"
    [[ -n $latest ]] || die "no vx.y.z tag to hotfix"
    version="$(next_patch "${latest#v}")"
    branch="release/$version"
    git rev-parse --verify --quiet "origin/$branch" > /dev/null && die "$branch already exists"
    commit_version "$latest" "$branch" "$version"
    git push --quiet --set-upstream origin "$branch"
    echo "Pushed $branch from $latest. Create version $version in App Store Connect, land the fix on main,"
    echo "then: git switch $branch && scripts/release.sh pick <commit>"
    ;;

  *)
    sed -n '2,10s/^# \{0,1\}//p' "$0"
    exit 1
    ;;
esac
