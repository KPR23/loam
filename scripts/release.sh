#!/usr/bin/env bash
# Drives the release flow described in README.md ("Releasing").
#
#   scripts/release.sh rc [ref]        Tag the next rc/x.y.z-N on ref (default origin/main; release/x.y.z works too) for TestFlight
#   scripts/release.sh cut [x.y.z]     With x.y.z: promote patch/x.y.z to release/x.y.z. Without: branch release/x.y.z from the tested rc tag (default: latest rc of main's version), then open a PR bumping main
#   scripts/release.sh pick <commit>…  Cherry-pick commits from main onto the open release branch
#   scripts/release.sh ship [x.y.z]    Tag vx.y.z on the release branch, publish a GitHub release, delete the branch
#   scripts/release.sh hotfix [ref]    Open patch/x.y.(z+1) from ref (default: the latest vx.y.z tag; x.y means the newest x.y.* tag); nothing deploys until cut
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

# The release branch to act on: the current branch if it is one, else an explicit version ($1),
# else the newest one on origin (an older one left over from a shipped release never blocks a newer cut).
release_branch() {
  local current branches
  current="$(git branch --show-current)"
  if [[ -n ${1:-} ]]; then echo "release/$1"; return; fi
  if [[ $current == release/* || $current == patch/* ]]; then echo "$current"; return; fi
  # An open patch branch is where fixes collect, so it wins over a release branch awaiting approval.
  branches="$(git branch --remotes --list 'origin/patch/*' --format='%(refname:lstrip=3)' | sort -V)"
  [[ -n $branches ]] || branches="$(git branch --remotes --list 'origin/release/*' --format='%(refname:lstrip=3)' | sort -V)"
  [[ -n $branches ]] || die "no patch or release branch on origin"
  if [[ $(wc -l <<< "$branches") -gt 1 ]]; then
    echo "release: several release branches ($(tr '\n' ' ' <<< "$branches")), using the newest" >&2
  fi
  tail -n 1 <<< "$branches"
}

git fetch --quiet --prune --tags origin

case "${1:-}" in
  rc)
    ref="${2:-origin/main}"
    # A bare release/x.y.z or patch/x.y.z names the branch on origin, so a patch can be built without touching main.
    if [[ $ref == release/* || $ref == patch/* ]] && ! git rev-parse --verify --quiet "$ref" > /dev/null; then ref="origin/$ref"; fi
    version="$(version_at "$ref")"
    [[ -n $version ]] || die "no MARKETING_VERSION in project.yml at $ref"
    last="$(git tag --list "rc/$version-*" | sed "s|^rc/$version-||" | sort -n | tail -n 1)"
    tag="rc/$version-$(( ${last:-0} + 1 ))"
    git tag --annotate "$tag" --message "$tag" "$ref"
    git push --quiet origin "$tag"
    echo "Pushed $tag ($(git rev-parse --short "$ref")). Xcode Cloud builds it for internal TestFlight."
    ;;

  cut)
    if [[ -n ${2:-} && $2 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && git rev-parse --verify --quiet "origin/patch/$2" > /dev/null; then
      # Promote a patch branch: release exactly its latest tested rc. main is untouched.
      version="$2"
      patch="patch/$version"
      branch="release/$version"
      last="$(git tag --list "rc/$version-*" | sed "s|^rc/$version-||" | sort -n | tail -n 1)"
      [[ -n $last ]] || die "no rc/$version-N tag; run release.sh rc $patch and test it on TestFlight first"
      ref="rc/$version-$last"
      git rev-parse --verify --quiet "origin/$branch" > /dev/null && die "$branch already exists"
      git push --quiet origin "$(git rev-parse "$ref^{commit}"):refs/heads/$branch"
      git push --quiet origin --delete "$patch"
      echo "Pushed $branch from $ref and deleted $patch. $branch deploys production now. Once that run and Xcode Cloud's build finish, submit the build for review."
      exit 0
    fi
    version="$(version_at origin/main)"
    branch="release/$version"
    # Release exactly what was tested: the latest rc tag for this version, unless a ref is given.
    last="$(git tag --list "rc/$version-*" | sed "s|^rc/$version-||" | sort -n | tail -n 1)"
    ref="${2:-${last:+rc/$version-$last}}"
    [[ -n $ref ]] || die "no rc/$version-N tag; run release.sh rc and test it on TestFlight first (or pass a ref)"
    [[ $(version_at "$ref") == "$version" ]] || die "$ref is not version $version"
    git rev-parse --verify --quiet "origin/$branch" > /dev/null && die "$branch already exists"
    git tag --list "v$version" | grep -q . && die "v$version is already tagged; bump MARKETING_VERSION on main first"
    git push --quiet origin "$(git rev-parse "$ref^{commit}"):refs/heads/$branch"
    echo "Pushed $branch from $ref, which deploys production now. Once that run and Xcode Cloud's build finish, submit the build for review."

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
    if [[ $branch == patch/* ]]; then
      echo "Pushed the fix to $branch (no deploy). Tag it for TestFlight with: release.sh rc $branch"
    else
      echo "Pushed the fix to $branch, which deploys production now. Once that run finishes, submit the new build."
    fi
    ;;

  ship)
    branch="$(release_branch "${2:-}")"
    version="${branch#release/}"
    tag="v$version"
    echo "About to: tag $tag on origin/$branch ($(git rev-parse --short "origin/$branch")), publish a public GitHub release, delete origin/$branch."
    if [[ -t 0 ]]; then
      read -r -p "Continue? [y/N] " answer
      [[ $answer == [yY]* ]] || die "aborted"
    fi
    git tag --annotate "$tag" --message "Loam $version" "origin/$branch"
    git push --quiet origin "$tag"
    # Only the highest version is marked Latest, so shipping a patch for an older line doesn't take it over.
    highest="$(git tag --list 'v*' --sort=-version:refname | head -n 1)"
    latest=true
    [[ $highest == "$tag" ]] || latest=false
    gh release create "$tag" --verify-tag --generate-notes --title "Loam $version" --latest="$latest"
    git push --quiet origin --delete "$branch"
    git branch --quiet --delete --force "$branch" 2> /dev/null || true
    echo "Tagged $tag and deleted $branch. Hotfixes start from the tag: release.sh hotfix"
    ;;

  hotfix)
    base="${2:-$(git tag --list 'v*' --sort=-version:refname | head -n 1)}"
    # "hotfix 1.1" starts from the newest vx.y.* tag, so the patch follows the line you name.
    if [[ $base =~ ^[0-9]+\.[0-9]+$ ]]; then
      base="$(git tag --list "v$base.*" --sort=-version:refname | head -n 1)"
      [[ -n $base ]] || die "no v$2.* tag"
    fi
    [[ -n $base ]] || die "no vx.y.z tag to hotfix; pass the ref that matches the live release, e.g. origin/release/1.1.0"
    current="$(version_at "$base")"
    [[ -n $current ]] || die "no MARKETING_VERSION in project.yml at $base"
    version="$(next_patch "$current")"
    branch="patch/$version"
    for existing in "$branch" "release/$version"; do
      git rev-parse --verify --quiet "origin/$existing" > /dev/null && die "$existing already exists"
    done
    commit_version "$base" "$branch" "$version"
    git push --quiet --set-upstream origin "$branch"
    echo "Opened $branch from $base (nothing deploys; main is untouched). Create version $version in App Store Connect."
    echo "Land each fix on main, then: scripts/release.sh pick <commit>   (repeat as needed)"
    echo "Test it:  scripts/release.sh rc $branch"
    echo "Release:  scripts/release.sh cut $version"
    ;;

  *)
    sed -n '2,10s/^# \{0,1\}//p' "$0"
    exit 1
    ;;
esac
