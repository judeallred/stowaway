#!/bin/zsh
# End-to-end check of Stowaway Lite's npm mode (node_modules offloaded package by package), in
# the App Sandbox: adopt a Next.js app's node_modules, build, let `npm install` replace the links
# and check they're re-offloaded, unplug and install offline, replug, release. Also checks the
# guards that refuse pnpm projects and Turbopack projects.
#
# Uses a throwaway APFS image as the drive and ~/stowlite-npm-test as the code folder; needs
# network for the first npm install. Usage: sandbox-probe/scripts/lite-npm-e2e.sh
set -uo pipefail
zmodload zsh/datetime

here=${0:A:h:h}
app="$here/build-AppExecutable/StowawayLite.app"
lite="$app/Contents/MacOS/StowawayLite"
work=$(mktemp -d)
x="$HOME/stowlite-npm-test"
drive=/Volumes/StowLiteNPM
nm="$x/next-app/node_modules"
state="$HOME/Library/Containers/dev.stowaway.lite/Data/Library/Application Support/lite-entries.json"

fail() { print "FAIL: $*"; cleanup; exit 1; }
# Deep links: package folders stay real; their contents link to the drive. These count packages
# whose contents are still real files (not offloaded) and those fully linked.
pkgcount() {
  python3 -I - "$nm" "$1" <<'PY'
import os, sys
nm, want = sys.argv[1], sys.argv[2]
def pkgs(d):
    for n in os.listdir(d):
        if n.startswith(".") : continue
        p = os.path.join(d, n)
        if os.path.islink(p) or not os.path.isdir(p): continue
        if n.startswith("@"):
            for c in os.listdir(p):
                q = os.path.join(p, c)
                if not c.startswith(".") and os.path.isdir(q) and not os.path.islink(q): yield q
        else: yield p
def walk(d):
    for p in pkgs(d):
        yield p
        nested = os.path.join(p, "node_modules")
        if os.path.isdir(nested) and not os.path.islink(nested): yield from walk(nested)
real = linked = 0
for p in walk(nm):
    entries = [e for e in os.listdir(p) if e != "node_modules"]
    if not entries: continue
    if all(os.path.islink(os.path.join(p, e)) for e in entries): linked += 1
    else: real += 1
print(real if want == "real" else linked)
PY
}
reals() { pkgcount real; }
links() { pkgcount linked; }
# Waits up to $2 seconds for a condition; prints how long it took.
await() {
  local start=$EPOCHREALTIME
  while ! eval "$1"; do
    (( EPOCHREALTIME - start > $2 )) && fail "timed out waiting for: $1"
    sleep 0.5
  done
  printf '%.1fs' $(( EPOCHREALTIME - start ))
}
build() { (cd "$x/next-app" && npx next build >>"$work/build.log" 2>&1) || fail "next build $1 (see the build log)"; }

cleanup() {
  pkill -f 'StowawayLite --watch' 2>/dev/null
  hdiutil detach -force $drive >/dev/null 2>&1
  rm -rf "$work" "$x" "$state"
}
trap 'cleanup' INT TERM
cleanup
mkdir -p "$work"

hdiutil create -quiet -type SPARSEBUNDLE -fs APFS -size 4g -volname StowLiteNPM "$work/drive.sparsebundle"
hdiutil attach -quiet -nobrowse "$work/drive.sparsebundle"
mkdir -p "$x/next-app/app" "$x/pnpm-app" "$x/next16-app/node_modules/x"
cat > "$x/next-app/package.json" <<'EOF'
{ "name": "n", "private": true, "dependencies": { "next": "^15.5.0", "react": "^19.1.0", "react-dom": "^19.1.0" } }
EOF
print 'export default function L({ children }) { return <html><body>{children}</body></html>; }' > "$x/next-app/app/layout.js"
print 'export default function P() { return <p>hi</p>; }' > "$x/next-app/app/page.js"
(cd "$x/next-app" && npm install --no-audit --no-fund >/dev/null 2>&1) || fail "first npm install"
print '{ "name": "p" }' > "$x/pnpm-app/package.json"; : > "$x/pnpm-app/pnpm-lock.yaml"; mkdir -p "$x/pnpm-app/node_modules"
print '{ "name": "n16", "dependencies": { "next": "^16.0.0" } }' > "$x/next16-app/package.json"

open -W -a "$app" "$x" $drive --args --grant

# Guards
[[ "$($lite --adopt "$x/pnpm-app/node_modules" 2>&1)" == *"pnpm project"* ]] || fail "a pnpm project wasn't refused"
[[ "$($lite --adopt "$x/next16-app/node_modules" 2>&1)" == *Turbopack* ]] || fail "a Next 16 project wasn't refused"
$lite --adopt "$x/next16-app/node_modules" --allow-turbopack >/dev/null 2>&1 || fail "--allow-turbopack didn't allow it"
$lite --release "$x/next16-app/node_modules" >/dev/null 2>&1
print "ok: refuses pnpm and Turbopack projects (allowed with --allow-turbopack)"

# Adopt and build
local_before=$(du -sh $nm | cut -f1)
$lite --adopt $nm 2>&1 | grep -o 'package by package.*'
(( $(reals) == 0 && $(links) > 0 )) || fail "not every package was linked"
[[ -L $nm/.package-lock.json ]] || fail "npm's hidden lockfile wasn't moved to the drive"
build "with packages on the drive"
print "ok: node_modules $local_before → $(du -sh $nm | cut -f1) on the Mac; next build passes"

# npm install with nothing to change must leave everything alone and be fast
start=$EPOCHREALTIME
out=$(cd "$x/next-app" && npm install --no-audit --no-fund 2>&1 | tail -1)
[[ $out == *"up to date"* ]] || fail "npm install changed things: $out"
(( $(reals) == 0 )) || fail "npm install brought packages back locally"
printf 'ok: npm install with nothing to change: %.2fs (%s), links untouched\n' $(( EPOCHREALTIME - start )) "$out"

# Adding a package: npm installs only it locally; the watcher offloads it once it's quiet
STOWAWAY_LITE_QUIET=3 $lite --watch 600 2>"$work/watch.log" &
start=$EPOCHREALTIME
(cd "$x/next-app" && npm install lodash --no-audit --no-fund >/dev/null 2>&1) || fail "npm install lodash"
printf 'ok: npm install lodash took %.1fs and left %s real packages\n' $(( EPOCHREALTIME - start )) $(reals)
print "ok: offloaded after $(await '(( $(reals) == 0 ))' 120)"
(cd "$x/next-app" && node -e 'require("lodash")') || fail "lodash didn't resolve"

# Unplug: links dangle and npm can't read its lockfile, so an install rebuilds locally
hdiutil detach -force $drive >/dev/null
sleep 2
(cd "$x/next-app" && npm install --prefer-offline --no-audit --no-fund >/dev/null 2>&1) || fail "offline npm install"
build "offline"
print "ok: offline npm install and build work ($(reals) packages local)"

# Replug: what was installed offline goes back onto the drive
hdiutil attach -quiet -nobrowse "$work/drive.sparsebundle"
print "ok: replugged; packages back on the drive after $(await '(( $(reals) == 0 ))' 120)"
build "after replug"

$lite --release $nm >/dev/null 2>&1 || fail "release"
(( $(links) == 0 && $(reals) > 0 )) || fail "release left links"
build "after release"
print "ok: released; node_modules is a plain local folder again"
grep -E 're-offloaded|offline:|online:' "$work/watch.log" | sed 's/^/   /'
cleanup
print PASS
