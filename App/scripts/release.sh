#!/bin/sh
# Builds Stowaway for a GitHub release and, with PUBLISH=1, publishes it (CI does this; see
# .github/workflows). Without PUBLISH it only builds, into App/build/release, to try it out.
#
#   App/scripts/release.sh main      the "latest-main" pre-release, replaced on every green push
#   App/scripts/release.sh nightly   "nightly-<version>", from the newest main commit CI passed;
#                                    nothing if that commit already has one
#
# Versions are <MARKETING_VERSION>.<N>, N being the number of commits on main up to the one
# built: always increasing, and the same for the same commit wherever it's built. N is the build
# number (CFBundleVersion) too.
#
# The app is signed ad hoc (no Developer ID), as install.sh signs it: macOS asks before the first
# launch. It can't make purchases (that's the App Store's build), so stowing stops at the free
# limit.
set -eu

channel=${1:?usage: release.sh main|nightly}
case $channel in main | nightly) ;; *) echo "release.sh: unknown channel $channel" >&2 && exit 2 ;; esac
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
keep_nightlies=14

# The newest commit on main whose CI passed (core and app). Nightlies come from it, so a broken
# main never ships; pushes that only touch documentation don't run CI, so it may be an older one.
green_commit() {
  for sha in $(git rev-list --first-parent --max-count=50 HEAD); do
    passed=$(gh api "repos/$GITHUB_REPOSITORY/commits/$sha/check-runs" \
      --jq '[.check_runs[] | select(.name == "core" or .name == "app") | select(.conclusion == "success") | .name] | unique | length')
    if [ "$passed" = 2 ]; then
      echo "$sha"
      return
    fi
  done
  echo "release.sh: no commit among the last 50 on main passed CI" >&2
  exit 1
}

if [ "$channel" = nightly ] && [ "${PUBLISH:-}" = 1 ]; then
  sha=$(green_commit)
  git checkout --quiet "$sha"
fi
sha=$(git rev-parse HEAD)
build=$(git rev-list --count HEAD)
marketing=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' App/project.yml)
version="$marketing.$build"
case $channel in
  main) tag=latest-main ;;
  nightly) tag="nightly-$version" ;;
esac

if [ "$channel" = nightly ] && [ "${PUBLISH:-}" = 1 ] && gh release view "$tag" >/dev/null 2>&1; then
  echo "release.sh: $tag already exists; nothing new on main since"
  exit 0
fi

out="$root/App/build/release"
rm -rf "$out"
mkdir -p "$out/dist"
xcodebuild -quiet -project App/Stowaway.xcodeproj -scheme Stowaway -configuration Release \
  -derivedDataPath "$out/DerivedData" -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build
app="$out/DerivedData/Build/Products/Release/Stowaway.app"
App/scripts/check-release.sh "$app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" ] ||
  { echo "release.sh: the app doesn't say it's $version" >&2 && exit 1; }

zip="Stowaway-$version.zip"
ditto -c -k --keepParent "$app" "$out/dist/$zip"
(cd "$out/dist" && shasum -a 256 "$zip" >SHA256SUMS)
echo "Built $out/dist/$zip ($version, $(git log -1 --format=%h))"
[ "${PUBLISH:-}" = 1 ] || exit 0

date=$(git log -1 --format=%cs)
case $channel in
  main) title="Stowaway $version (latest main)" ;;
  nightly) title="Stowaway $version (nightly, $date)" ;;
esac
notes="$out/notes.md"
cat >"$notes" <<EOF
**Pre-release**, built from \`main\` at $(git log -1 --format=%h) ($date): $(git log -1 --format=%s)

macOS 14 or later, Apple silicon or Intel. Stowaway moves folders on your disk; keep backups of
anything you can't rebuild.

### Install

Unzip, move **Stowaway.app** to Applications and open it. It isn't signed with a Developer ID,
so macOS blocks the first launch: open **System Settings → Privacy & Security** and click
**Open Anyway**, or run \`xattr -dr com.apple.quarantine /Applications/Stowaway.app\`.

This build can't make purchases (that's the App Store's), so stowing stops at the free limit.
EOF

if [ "$channel" = main ]; then
  # One release that always holds the latest main: replaced, tag and all.
  gh release delete "$tag" --cleanup-tag --yes >/dev/null 2>&1 || true
fi
gh release create "$tag" --target "$sha" --title "$title" --notes-file "$notes" --prerelease \
  --latest=false "$out/dist/$zip" "$out/dist/SHA256SUMS"
echo "Published $tag"

if [ "$channel" = nightly ]; then
  # The newest nightlies only.
  gh release list --limit 200 --json tagName,createdAt \
    --jq "[.[] | select(.tagName | startswith(\"nightly-\"))] | sort_by(.createdAt) | reverse | .[$keep_nightlies:] | .[].tagName" |
    while read -r old; do
      gh release delete "$old" --cleanup-tag --yes
    done
fi
