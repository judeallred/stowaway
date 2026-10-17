#!/bin/zsh
# Compares Stowaway Lite (symlinks, sandboxed) with the core design (a sparse-bundle image on the
# drive, mounted in place) and with plain local folders, on real workloads.
#
# Core is replayed by stowbench with the same hdiutil flags and staging flow as the engine; both
# designs move data with the same parallel copier, so the numbers compare the mechanisms. The
# real engine's adoption is also paced around other disk activity, which this leaves out.
#
# Usage: sandbox-probe/scripts/bench.sh "/Volumes/<external SSD>" [reps]
# Writes only to <drive>/stowaway-bench and ~/stowbench-work, and removes both at the end.
# Needs network once (npm and pnpm downloads), then installs run from warm caches.
set -uo pipefail
zmodload zsh/datetime

drive=${1:?usage: bench.sh /Volumes/<drive> [reps]}
reps=${2:-3}
only=${BENCH_ONLY:-}               # cargo|npm|pnpm|adopt|flip: rerun one section, keep the rest
here=${0:A:h:h}
src=${here:h}                      # this repository: the Rust workload
lite_app="$here/build-AppExecutable/StowawayLite.app"
lite="$lite_app/Contents/MacOS/StowawayLite"
sb="$here/build-AppExecutable/stowbench"
bench="$drive/stowaway-bench"
work="$HOME/stowbench-work"
raw="$here/results/bench-raw.tsv"
log="$here/results/bench-log.txt"
lite_state="$HOME/Library/Containers/dev.stowaway.lite/Data/Library/Application Support/lite-entries.json"

[[ -x $lite && -x $sb ]] || { echo "build first: APP_ENTITLEMENTS=AppExecutable scripts/bundle.sh \"\$PWD/build-AppExecutable\""; exit 1; }
[[ -d $drive ]] || { echo "no drive at $drive"; exit 1; }

say() { print -- "$*" | tee -a $log; }
record() { print -r -- "$1"$'\t'"$2"$'\t'"$3"$'\t'"$4" >> $raw; }   # section variant metric seconds

# Runs a command and records its wall time.
measure() {
  local section=$1 variant=$2 metric=$3; shift 3
  local start=$EPOCHREALTIME
  "$@" >>$log 2>&1 || { say "FAILED: $section/$variant/$metric: $*"; return 0; }
  local secs=$(( EPOCHREALTIME - start ))
  record $section $variant $metric $secs
  printf '  %-8s %-10s %-26s %8.3fs\n' $section $variant $metric $secs | tee -a $log
}

detach_under() {   # detaches every image mounted under a folder
  mount | awk -v p="$1" 'index($0, " on " p) {print $1}' | sort -r | while read -r dev; do
    hdiutil detach -force "$dev" >/dev/null 2>&1 || true
  done
}

cleanup() {
  pkill -f 'StowawayLite --watch' 2>/dev/null || true
  detach_under "$work"
  hdiutil detach -force /Volumes/StowBenchFake >/dev/null 2>&1 || true
  rm -rf "$work" "$bench" "$lite_state"
}
trap 'cleanup; exit 130' INT TERM

main() {
mkdir -p "$work" "$bench/images" "${raw:h}"
if [[ -n $only ]]; then
  grep -v "^$only"$'\t' $raw > $raw.tmp 2>/dev/null || true; mv $raw.tmp $raw
else
  : > $raw
fi
: > $log
say "# Stowaway Lite vs core — $(date '+%Y-%m-%d %H:%M'), $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)"
say "drive: $drive ($(diskutil info "$drive" | awk -F': *' '/Protocol/{print $2; exit}')), reps: $reps"
open -W -a "$lite_app" "$work" "$bench" --args --grant

# Puts an empty folder under each design: local (plain), core (image mounted), lite (symlink).
place() {
  local variant=$1 dir=$2
  mkdir -p "$dir"
  case $variant in
    core) $sb core-adopt "$dir" "$bench/images" >>$log ;;
    lite) $lite --adopt "$dir" 2>>$log ;;
  esac
}

# Empties a folder, leaving a mounted volume's own metadata alone.
empty_dir() {
  find "$1/" -mindepth 1 -maxdepth 1 ! -name .metadata_never_index ! -name .fseventsd \
    ! -name .Spotlight-V100 ! -name .Trashes ! -name .TemporaryItems -exec rm -rf {} + || true
}

want() { [[ -z $only || $only == $1 ]]; }

if want cargo; then
### 1. Cargo: this workspace (clean, no-op, incremental builds)
say "\n## Cargo build of the stowaway crate"
for v in local core lite; do place $v "$work/rust-$v/target"; done
for i in $(seq $reps); do
  for v in local core lite; do
    empty_dir "$work/rust-$v/target"
    measure cargo $v clean-build env CARGO_TARGET_DIR="$work/rust-$v/target" cargo build -q -p stowaway --manifest-path "$src/Cargo.toml"
    measure cargo $v noop-build env CARGO_TARGET_DIR="$work/rust-$v/target" cargo build -q -p stowaway --manifest-path "$src/Cargo.toml"
    touch "$src/crates/stowaway/src/lib.rs"
    measure cargo $v incremental env CARGO_TARGET_DIR="$work/rust-$v/target" cargo build -q -p stowaway --manifest-path "$src/Cargo.toml"
  done
done

fi

### 2. npm: node_modules (Lite links each package; core mounts the folder)
if want npm || want pnpm || want adopt; then
say "\n## npm: node_modules (Lite links each package; core mounts the whole folder)"
proj="$work/node-template"
mkdir -p "$proj/src"
cat > "$proj/package.json" <<'EOF'
{ "name": "bench", "version": "1.0.0", "private": true,
  "dependencies": { "next": "^15.5.0", "react": "^19.1.0", "react-dom": "^19.1.0", "lodash": "^4.17.21",
    "typescript": "~5.9.0", "@types/react": "^19.1.0", "@types/react-dom": "^19.1.0", "@types/lodash": "^4.17.0",
    "@types/node": "^24.0.0", "eslint": "^9.30.0",
    "webpack": "^5.100.0", "@babel/core": "^7.28.0" } }
EOF
cat > "$proj/tsconfig.json" <<'EOF'
{ "compilerOptions": { "strict": true, "jsx": "react-jsx", "module": "esnext", "moduleResolution": "bundler", "noEmit": true, "skipLibCheck": false, "lib": ["dom", "dom.iterable", "esnext"], "types": ["node"] }, "include": ["src"] }
EOF
cat > "$proj/src/index.tsx" <<'EOF'
import type { NextConfig } from "next";
import { useState } from "react";
import _ from "lodash";
import { Configuration } from "webpack";
export const config: NextConfig = {}; export const w: Configuration = {};
export function App() { const [n] = useState(_.sum([1, 2])); return <div>{n}</div>; }
EOF
cat > "$proj/require-all.js" <<'EOF'
const deps = Object.keys(require("./package.json").dependencies).filter(d => !d.startsWith("@types/"));
for (const d of deps) { try { require(d); } catch (e) { if (e.code !== "ERR_REQUIRE_ESM") require.resolve(d); } }
EOF
(cd "$proj" && npm install --no-audit --no-fund --package-lock-only >>$log 2>&1 && npm ci --no-audit --no-fund >>$log 2>&1 && rm -rf node_modules)
fi
if want npm || want adopt; then
for v in local core lite; do
  cp -R "$proj" "$work/npm-$v"
  mkdir -p "$work/npm-$v/node_modules"
  [[ $v == lite ]] || place $v "$work/npm-$v/node_modules"
done
(cd "$work/npm-lite" && npm install --prefer-offline --no-audit --no-fund >>$log 2>&1)
$lite --adopt "$work/npm-lite/node_modules" 2>>$log
fi
if want npm; then
# Lite re-offloads after an install once node_modules is quiet; here that's run right away.
# Records the two parts separately: relinking (what tools wait for) and deleting the replaced
# local copies (which the app does in the background).
reoffload() {
  local metric=$1 out
  out=$(env STOWAWAY_LITE_QUIET=0 STOWAWAY_LITE_TRACE=1 "$lite" --reconcile 2>&1)
  print -r -- "$out" >> $log
  local trace=$(print -r -- "$out" | grep -m1 '^trace:')
  if [[ -z $trace ]]; then   # nothing was brought back locally: nothing to do
    record npm lite "$metric: relink" 0; record npm lite "$metric: cleanup (background)" 0
    printf '  %-8s %-10s %-26s %8.3fs (nothing to re-offload)\n' npm lite "$metric" 0 | tee -a $log
    return 0
  fi
  local compare=${${trace#*compare }%%s,*} swap=${${trace#*swap }%%s,*} delete=${${trace#*delete }%%s*}
  record npm lite "$metric: relink" $(( compare + swap ))
  record npm lite "$metric: cleanup (background)" $delete
  printf '  %-8s %-10s %-26s %8.3fs (+ %.2fs cleanup in the background)\n' npm lite "$metric" $(( compare + swap )) $delete | tee -a $log
}
for i in $(seq $reps); do
  for v in local core lite; do
    empty_dir "$work/npm-$v/node_modules"
    # npm ci, not install: see the .fseventsd check below.
    measure npm $v "npm install (lockfile)" sh -c "cd '$work/npm-$v' && npm install --prefer-offline --no-audit --no-fund"
    [[ $v == lite ]] && reoffload "re-offload after install"
    measure npm $v "npm install (no changes)" sh -c "cd '$work/npm-$v' && npm install --prefer-offline --no-audit --no-fund"
    [[ $v == lite ]] && reoffload "re-offload, unchanged"
    measure npm $v "walk (find -L)" sh -c "find -L '$work/npm-$v/node_modules' -type f | wc -l"
    measure npm $v "require all" sh -c "cd '$work/npm-$v' && node require-all.js"
    measure npm $v "tsc --noEmit" sh -c "cd '$work/npm-$v' && (node_modules/.bin/tsc -p . || true)"
  done
done

fi
if want npm; then
# npm ci scans node_modules before emptying it. On a mounted volume that includes the root-only
# .fseventsd folder macOS creates, which npm can't read.
if (cd "$work/npm-core" && npm ci --prefer-offline --no-audit --no-fund >>$log 2>&1); then
  say "  npm ci on a mounted node_modules: works"
else
  say "  npm ci on a mounted node_modules: FAILS (EACCES on .fseventsd, owned by root)"
fi

fi

if want pnpm; then
### 3. pnpm with the global virtual store: node_modules is links; the store holds everything
say "\n## pnpm (global virtual store), store on each design"
for v in local core lite; do
  cp -R "$proj" "$work/pnpm-$v"
  rm -f "$work/pnpm-$v/package-lock.json"
  place $v "$work/store-$v"
  # The first install fills the store from the network: recorded, but noisy.
  measure pnpm $v "first install (network)" sh -c "cd '$work/pnpm-$v' && pnpm install --store-dir '$work/store-$v' --config.enable-global-virtual-store=true --reporter=silent"
done
for i in $(seq $reps); do
  for v in local core lite; do
    rm -rf "$work/pnpm-$v/node_modules"
    measure pnpm $v "install (offline)" sh -c "cd '$work/pnpm-$v' && pnpm install --offline --store-dir '$work/store-$v' --config.enable-global-virtual-store=true --reporter=silent"
    measure pnpm $v "walk store (find)" sh -c "find '$work/store-$v/' -type f | wc -l"
    measure pnpm $v "require all" sh -c "cd '$work/pnpm-$v' && node require-all.js"
    measure pnpm $v "tsc --noEmit" sh -c "cd '$work/pnpm-$v' && (node_modules/.bin/tsc -p . || true)"
  done
done

fi

if want adopt; then
### 4. Adopting folders that already exist (moving data onto the drive)
say "\n## Adopt: move an existing folder onto the drive"
for i in $(seq $reps); do
  for kind in target node_modules; do
    case $kind in
      target) from="$work/rust-local/target" ;;
      node_modules) from="$work/npm-local/node_modules" ;;
    esac
    for v in core lite; do
      d="$work/adopt-$v-$kind-$i"
      mkdir -p "$d" && cp -cR "$from" "$d/$kind"     # APFS clone: instant, identical tree
      measure adopt $v "adopt $kind" sh -c "case $v in core) '$sb' core-adopt '$d/$kind' '$bench/images' ;; lite) '$lite' --adopt '$d/$kind' ;; esac"
    done
  done
done
say "  sizes: target $(du -sh "$work/rust-local/target" | cut -f1) / $(find "$work/rust-local/target" -type f | wc -l | tr -d ' ') files; node_modules $(du -sh "$work/npm-local/node_modules" | cut -f1) / $(find "$work/npm-local/node_modules" -type f | wc -l | tr -d ' ') files"

fi

if want flip; then
### 5. Drive unplugged and plugged back, with 20 managed folders
# Uses a throwaway image as the drive: this measures how fast each design reacts, not I/O.
say "\n## Unplug and replug with 20 managed folders"
for d in "$work/rust-lite/target" "$work/store-lite"; do
  [[ -L $d ]] && measure release lite "bring ${d:t} back" $lite --release "$d"
done
rm -f "$lite_state"      # forget the adopt-test entries; their data is deleted at the end anyway
pkill -f 'StowawayLite --watch' 2>/dev/null || true
fake="$work/fake-drive.sparsebundle"
hdiutil create -quiet -type SPARSEBUNDLE -fs APFS -size 20g -volname StowBenchFake "$fake"
hdiutil attach -quiet -nobrowse "$fake"
open -W -a "$lite_app" /Volumes/StowBenchFake --args --grant      # Lite's drive is now the fake one
for i in $(seq -w 1 20); do
  for v in core lite; do mkdir -p "$work/flip-$v/e$i" && echo x > "$work/flip-$v/e$i/f"; done
  $sb core-adopt "$work/flip-core/e$i" /Volumes/StowBenchFake/images >>$log
  $lite --adopt "$work/flip-lite/e$i" 2>>$log
done
"$lite" --watch 900 2>>$log &
watcher=$!
sleep 2
for i in $(seq $reps); do
  # Unplug: core's mounts vanish with the drive; Lite must notice and swap 20 symlinks.
  $sb wait-unmounted "$work/flip-core/e20" 30 > "$work/core-yank.ms" & pc=$!
  $sb wait-real-dir "$work/flip-lite/e20" 30 > "$work/lite-yank.ms" & pl=$!
  sleep 0.2
  hdiutil detach -force /Volumes/StowBenchFake >/dev/null
  wait $pc $pl || true
  record flip core "unplug → local (ms)" "$(cat "$work/core-yank.ms")"
  record flip lite "unplug → local (ms)" "$(cat "$work/lite-yank.ms")"
  say "  unplug: core $(cat "$work/core-yank.ms") ms, lite $(cat "$work/lite-yank.ms") ms (after detach started)"
  for e in "$work"/flip-lite/e*(N); do echo built-offline > "$e/offline-$i" 2>/dev/null || say "  $e wasn't writable offline"; done

  # Replug: core clears the stale devices the yank left and reattaches 20 images (as the engine
  # does); Lite merges 20 folders and restores 20 symlinks.
  $sb wait-symlink "$work/flip-lite/e20" 60 > "$work/lite-plug.ms" & pl=$!
  start=$EPOCHREALTIME
  hdiutil attach -quiet -nobrowse "$fake"
  hdiutil info | awk '/^image-path/ && /StowBenchFake\/images/ {f=1} f && /^\/dev\/disk[0-9]+[ \t]/ {print $1; f=0}' |
    while read -r dev; do hdiutil detach -force "$dev" >/dev/null 2>&1 || true; done
  for img in /Volumes/StowBenchFake/images/e*.sparsebundle; do
    n=${${img:t}%%-*}
    $sb core-attach "$img" "$work/flip-core/$n" >>$log
  done
  core_ms=$(( (EPOCHREALTIME - start) * 1000 ))
  wait $pl || true
  record flip core "replug → on drive (ms)" "$core_ms"
  record flip lite "replug → on drive (ms)" "$(cat "$work/lite-plug.ms")"
  say "  replug: core $(printf %.0f $core_ms) ms (attach drive, clear stale devices, 20 images), lite $(cat "$work/lite-plug.ms") ms (attach drive → 20 merged, symlinks back)"
done

fi

### 6. Overhead per managed folder (uses the images section 5 made)
if want flip; then
say "\n## Overhead"
img=$(ls -d /Volumes/StowBenchFake/images/e01*.sparsebundle | head -1)
say "  empty core image on disk: $(du -sh "$img" | cut -f1)"
say "  diskimagesiod processes: $(pgrep -x diskimagesiod | wc -l | tr -d ' '), total RSS $(ps -o rss= -p $(pgrep -x diskimagesiod | tr '\n' ',' | sed 's/,$//') | awk '{s+=$1} END {printf "%.0f MB", s/1024}')"
say "  Lite per folder: one symlink, no processes"
fi

python3 - "$raw" >> $log 2>&1 <<'EOF'
import csv, statistics, sys
rows = list(csv.reader(open(sys.argv[1]), delimiter="\t"))
groups = {}
for section, variant, metric, value in rows:
    groups.setdefault((section, metric), {}).setdefault(variant, []).append(float(value))
print("\n## Medians\n\n| Workload | Step | local | core (image) | lite (symlink) | lite vs core |\n|---|---|---|---|---|---|")
for (section, metric), by in groups.items():
    unit = "ms" if "(ms)" in metric else "s"
    med = {v: statistics.median(xs) for v, xs in by.items()}
    cell = lambda v: (f"{med[v]:.0f} ms" if unit == "ms" else f"{med[v]:.2f}s") if v in med else "—"
    ratio = f"{med['lite']/med['core']:.2f}×" if "lite" in med and "core" in med and med["core"] > 0 else "—"
    print(f"| {section} | {metric.replace(' (ms)', '')} | {cell('local')} | {cell('core')} | {cell('lite')} | {ratio} |")
EOF
sed -n '/## Medians/,$p' $log
say "\nraw: $raw"
}

cleanup
# zsh skips EXIT traps when errexit fires, so run the body in a subshell and always clean up.
( set -e; main )
result=$?
cleanup
exit $result
