#!/bin/sh
# End-to-end check of "Stowaway Lite" inside the App Sandbox, with no temporary exceptions: adopt a
# Cargo target/ onto a drive as a symlink, yank the drive, build offline, plug it back in, and
# check the offline build merged back onto the drive.
#
# Uses a throwaway APFS image as the "drive" and ~/stowprobe-code as the code folder. Folder
# access is granted the way Finder does it (`open -a App <folder>`), so it needs no clicks.
#
# Usage: sandbox-probe/scripts/lite-e2e.sh   (after: APP_ENTITLEMENTS=AppExecutable bundle.sh "$PWD/sandbox-probe/build-AppExecutable")
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
app="$here/build-AppExecutable/SandboxProbe.app"
probe="$app/Contents/MacOS/SandboxProbe"
work=$(mktemp -d)
code="$HOME/stowprobe-code"
drive=/Volumes/StowLiteDrive

fail() { echo "FAIL: $*"; exit 1; }
cleanup() {
  pkill -f -- '--lite-watch' 2>/dev/null || true
  hdiutil detach -force "$drive" >/dev/null 2>&1 || true
  rm -rf "$work" "$code"
}
trap cleanup EXIT

hdiutil create -quiet -type SPARSEBUNDLE -fs APFS -size 2g -volname StowLiteDrive "$work/drive.sparsebundle"
hdiutil attach -quiet -nobrowse "$work/drive.sparsebundle"
rm -rf "$code" && mkdir -p "$code"
rm -f "$HOME/Library/Containers/dev.stowaway.sandbox-probe/Data/lite-state.json"
(cd "$code" && cargo new -q rs && cd rs && cargo build -q)

open -W -a "$app" "$code" "$drive" --args --grant
"$probe" --lite-adopt "$code/rs/target" 2>&1 | grep adopted
[ -L "$code/rs/target" ] || fail "target isn't a symlink after adopting"
[ -z "$(xattr -r "$drive" 2>/dev/null | grep quarantine)" ] || fail "moved files are quarantined"
(cd "$code/rs" && touch src/main.rs && cargo build -q && ./target/debug/rs >/dev/null) || fail "build on drive"
echo "ok: builds and runs from the drive, nothing quarantined"

"$probe" --lite-watch 60 >"$work/watch.log" 2>&1 &
sleep 2
hdiutil detach -force "$drive" >/dev/null
sleep 2
[ -d "$code/rs/target" ] && [ ! -L "$code/rs/target" ] || fail "target wasn't flipped to a local folder"
(cd "$code/rs" && sed -i '' 's/Hello, world!/Hello, offline!/' src/main.rs && cargo build -q) || fail "offline build"
echo "ok: drive yanked, target flipped to a local folder, offline build works"

hdiutil attach -quiet -nobrowse "$work/drive.sparsebundle"
sleep 5
[ -L "$code/rs/target" ] || fail "target wasn't restored to a symlink"
[ "$(cd "$code/rs" && ./target/debug/rs)" = "Hello, offline!" ] || fail "offline build wasn't merged"
(cd "$code/rs" && cargo build -q) || fail "build after reconnect"
echo "ok: drive back, offline build merged onto it, symlink restored"
grep -v 'in scope' "$work/watch.log"
echo PASS
