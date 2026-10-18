#!/bin/sh
# Checks a Release build for what App Review cares about and the source can't show by itself:
# no test hooks or retired engine tools in the binary, exactly the expected entitlements, and a
# privacy manifest. Run after build.sh.
set -eu

app=$(cd "$(dirname "$0")/.." && pwd)
bundle=${1:-"$app/build/DerivedData/Build/Products/Release/Stowaway.app"}
binary="$bundle/Contents/MacOS/Stowaway"
fail() { echo "check-release: $*" >&2; exit 1; }

[ -x "$binary" ] || fail "no app at $bundle; run App/scripts/build.sh first"
[ -f "$bundle/Contents/Resources/PrivacyInfo.xcprivacy" ] || fail "the privacy manifest isn't in the bundle"
plutil -lint -s "$bundle/Contents/Resources/PrivacyInfo.xcprivacy" || fail "the privacy manifest doesn't parse"

# Strings that mean a hidden feature or a tool the sandbox forbids (App Review 2.3.1, 2.4.5).
for word in hdiutil launchctl lsof /usr/sbin/diskutil -- --adopt --grant --bench STOWAWAY_ Snapshots samplePrices loadDemo; do
  [ "$word" = "--" ] && continue
  if strings -a "$binary" | grep -qF -- "$word"; then fail "the binary contains '$word'"; fi
done

info="$bundle/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" = com.brooklynspaceport.stowaway ] ||
  fail "unexpected bundle identifier"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$info")" = public.app-category.developer-tools ] ||
  fail "unexpected category"
/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$info" >/dev/null || fail "no export compliance key"

# The entitlements file must hold exactly these keys (no temporary exceptions).
expected="com.apple.security.app-sandbox com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.executable com.apple.security.files.user-selected.read-write"
actual=$(plutil -convert json -o - "$app/Stowaway/Stowaway.entitlements" | /usr/bin/python3 -I -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))')
[ "$actual" = "$expected" ] || fail "unexpected entitlements: $actual"
echo "check-release: OK"
