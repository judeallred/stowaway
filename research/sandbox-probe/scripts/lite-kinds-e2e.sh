#!/bin/zsh
# Runs every remaining folder kind through Stowaway Lite (sandboxed) with the real tool: adopt,
# use from the drive (offline where the tool allows, to prove the data comes from there), unplug
# and use locally, replug and use the merged data offline, release.
#
# Every cache lives under ~/stowlite-kinds through the tool's own setting (CARGO_HOME,
# GOMODCACHE, GRADLE_USER_HOME, HF_HOME, -derivedDataPath, npm_config_cache), so real caches are
# never touched. Uses a throwaway APFS image as the drive. Needs network.
#
# Usage: sandbox-probe/scripts/lite-kinds-e2e.sh <tools-dir>
#   <tools-dir> holds go/go, uv/*/uv, jdk/*/Contents/Home and gradle/*/bin/gradle when they
#   aren't installed.
set -uo pipefail
zmodload zsh/datetime

here=${0:A:h:h}
tools=${1:?usage: lite-kinds-e2e.sh <tools-dir>}
app="$here/build-AppExecutable/StowawayLite.app"
lite="$app/Contents/MacOS/StowawayLite"
work=$(mktemp -d)
root="$HOME/stowlite-kinds"
drive=/Volumes/StowLiteKinds
state="$HOME/Library/Containers/dev.stowaway.lite/Data/Library/Application Support/lite-entries.json"
log="$here/results/lite-kinds-log.txt"
results=()

export PATH="$tools/go/go/bin:${$(print $tools/uv/*(N[1])):-/nonexistent}:$PATH"
export JAVA_HOME=$(print $tools/jdk/*/Contents/Home(N[1]))
gradle=$(print $tools/gradle/*/bin/gradle(N[1]))
export CARGO_HOME="$root/cargo-home" GOPATH="$root/go" GOMODCACHE="$root/go/pkg/mod" GOCACHE="$root/go/cache"
export GRADLE_USER_HOME="$root/gradle-home" HF_HOME="$root/hf" npm_config_cache="$root/npm-cache"
export GOTOOLCHAIN=local UV_CACHE_DIR="$work/uv-cache" UV_PYTHON_INSTALL_DIR="$work/uv-python"
dd="$root/DerivedData"

: > $log
say() { print -r -- "$*" | tee -a $log; }
cleanup() {
  pkill -f 'StowawayLite --watch' 2>/dev/null
  hdiutil detach -force $drive >/dev/null 2>&1
  chmod -R u+w "$root" "$work" 2>/dev/null
  rm -rf "$root" "$work" "$state"
}

# Runs a check and records PASS/FAIL. Output goes to the log.
check() {
  local kind=$1 step=$2; shift 2
  print -r -- "--- $kind / $step: $*" >> $log
  if perl -e 'alarm shift; exec @ARGV' 600 zsh -c "$*" >>$log 2>&1; then
    results+=("$kind|$step|PASS"); printf '  %-14s %-30s PASS\n' $kind $step
  else
    results+=("$kind|$step|FAIL"); printf '  %-14s %-30s FAIL (see %s)\n' $kind $step ${log:t}
  fi
}
is_link() { [[ -L $1 ]]; }
await_status() {   # waits until every entry reports $1 ("on drive" or "local")
  local start=$EPOCHREALTIME
  until [[ -z $($lite --status 2>/dev/null | grep -E '^(on drive|local   )' | grep -v "^$1") ]]; do
    (( EPOCHREALTIME - start > 180 )) && { say "  timed out waiting for every entry to be $1"; return 1; }
    sleep 1
  done
}

cleanup
mkdir -p "$work" "$root"
hdiutil create -quiet -type SPARSEBUNDLE -fs APFS -size 20g -volname StowLiteKinds "$work/drive.sparsebundle"
hdiutil attach -quiet -nobrowse "$work/drive.sparsebundle"

say "## Setting up projects and filling caches"
# Cargo: a crate with registry dependencies
mkdir -p $root/rs/src
cat > $root/rs/Cargo.toml <<'EOF'
[package]
name = "rs"
version = "0.1.0"
edition = "2021"
[dependencies]
serde = { version = "1", features = ["derive"] }
itoa = "1"
EOF
print 'fn main() { println!("{}", itoa::Buffer::new().format(42)); }' > $root/rs/src/main.rs
(cd $root/rs && cargo fetch -q) >>$log 2>&1 || say "  cargo fetch failed"

# Go: a module with a dependency (the module cache is read-only by default, the hard case)
mkdir -p $root/gomod
cat > $root/gomod/main.go <<'EOF'
package main
import ("fmt"; "github.com/google/uuid")
func main() { fmt.Println(uuid.NewSHA1(uuid.NameSpaceURL, []byte("x"))) }
EOF
(cd $root/gomod && go mod init example.com/gomod && go mod tidy && go build -o $work/gobin .) >>$log 2>&1 || say "  go setup failed"

# Gradle: a Java project with a Maven Central dependency
mkdir -p $root/gr/src/main/java
print "rootProject.name = 'gr'" > $root/gr/settings.gradle
cat > $root/gr/build.gradle <<'EOF'
plugins { id 'java' }
repositories { mavenCentral() }
dependencies { implementation 'com.google.guava:guava:33.4.0-jre' }
EOF
print 'public class App { public static void main(String[] a) { System.out.println(com.google.common.base.Joiner.on(",").join("a","b")); } }' > $root/gr/src/main/java/App.java
(cd $root/gr && $gradle build --no-daemon -q) >>$log 2>&1 || say "  gradle setup failed"

# Xcode: a Swift package built with xcodebuild into its own DerivedData
mkdir -p $root/xc/Sources/Hello
cat > $root/xc/Package.swift <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Hello", targets: [.executableTarget(name: "Hello")])
EOF
print 'print("hello from DerivedData")' > $root/xc/Sources/Hello/main.swift
xcbuild="cd $root/xc && xcodebuild -scheme Hello -destination 'platform=macOS' -derivedDataPath $dd build -quiet"
zsh -c "$xcbuild" >>$log 2>&1 || say "  xcodebuild setup failed"

# Hugging Face: a small model repo, via huggingface_hub in a scratch venv
python3 -m venv $work/hfenv >>$log 2>&1 && $work/hfenv/bin/pip install -q huggingface_hub >>$log 2>&1 || say "  huggingface_hub install failed"
hf="$work/hfenv/bin/python -c 'from huggingface_hub import hf_hub_download as d; p=d(\"hf-internal-testing/tiny-random-bert\", \"config.json\"); print(open(p).read()[:20])'"
zsh -c "$hf" >>$log 2>&1 || say "  hf download failed"

# Next.js: .next from a webpack build (node_modules stays local here)
mkdir -p $root/nx/app
print '{ "name": "nx", "private": true, "dependencies": { "next": "^15.5.0", "react": "^19.1.0", "react-dom": "^19.1.0" } }' > $root/nx/package.json
print 'export default function L({ children }) { return <html><body>{children}</body></html>; }' > $root/nx/app/layout.js
print 'export default function P() { return <p>hi</p>; }' > $root/nx/app/page.js
(cd $root/nx && npm install --no-audit --no-fund && npx next build) >>$log 2>&1 || say "  next setup failed"

# Python: a uv project's .venv
mkdir -p $root/py
(cd $root/py && uv init -q --app --name py . && uv add -q six && uv run python -c 'import six') >>$log 2>&1 || say "  uv setup failed"

# npx: packages npx installed to run
npx -y cowsay@1.6.0 moo >>$log 2>&1 || say "  npx setup failed"

open -W -a "$app" "$root" $drive --args --grant

say "\n## Adopt"
targets=(
  "cargo-registry:$CARGO_HOME/registry"
  "go-modcache:$GOMODCACHE"
  "go-buildcache:$GOCACHE"
  "gradle:$GRADLE_USER_HOME/caches"
  "deriveddata:$dd"
  "huggingface:$HF_HOME/hub"
  "next:$root/nx/.next"
  "venv:$root/py/.venv"
  "npx:$npm_config_cache/_npx"
)
for t in $targets; do
  kind=${t%%:*} dir=${t#*:}
  check $kind "adopt ($(du -sh $dir 2>/dev/null | cut -f1))" "$lite --adopt '$dir' && [[ -L '$dir' ]]"
done

# The commands each kind is checked with: offline variants prove the data is on the drive.
cargo_off="cd $root/rs && CARGO_TARGET_DIR=$work/rt-\$RANDOM cargo build -q --offline && echo ok"
cargo_on="cd $root/rs && CARGO_TARGET_DIR=$work/rt-\$RANDOM cargo build -q"
go_off="cd $root/gomod && GOPROXY=off GOFLAGS=-mod=mod go build -o $work/gobin . && $work/gobin"
go_on="cd $root/gomod && go build -o $work/gobin . && $work/gobin"
gradle_off="cd $root/gr && $gradle build --no-daemon -q --offline"
gradle_on="cd $root/gr && $gradle build --no-daemon -q"
xc_run="$xcbuild && $dd/Build/Products/Debug/Hello"
hf_off="HF_HUB_OFFLINE=1 $hf"
next_build="cd $root/nx && npx next build"
venv_off="cd $root/py && uv run --offline python -c 'import six; print(six.__version__)'"
venv_on="cd $root/py && uv run python -c 'import six; print(six.__version__)'"
npx_off="npx --offline -y cowsay@1.6.0 moo"
npx_on="npx -y cowsay@1.6.0 moo"

run_all() {   # $1: step name; $2: "off" to use offline variants where the tool has them
  local step=$1 mode=$2
  check cargo-registry "$step" "${${mode:#off}:+$cargo_on}${${(M)mode:#off}:+$cargo_off}"
  check go "$step" "${${mode:#off}:+$go_on}${${(M)mode:#off}:+$go_off}"
  check gradle "$step" "${${mode:#off}:+$gradle_on}${${(M)mode:#off}:+$gradle_off}"
  check deriveddata "$step" "$xc_run"
  check huggingface "$step" "${${mode:#off}:+$hf}${${(M)mode:#off}:+$hf_off}"
  check next "$step" "$next_build"
  check venv "$step" "${${mode:#off}:+$venv_on}${${(M)mode:#off}:+$venv_off}"
  check npx "$step" "${${mode:#off}:+$npx_on}${${(M)mode:#off}:+$npx_off}"
}

say "\n## Using everything from the drive (offline, so data must come from the drive)"
run_all "from drive" off
for t in $targets; do
  dir=${t#*:}
  [[ -L $dir ]] || say "  note: ${t%%:*} is no longer a symlink after use (a tool replaced it)"
done

say "\n## Unplugged: tools must work locally (online, refilling local folders)"
STOWAWAY_LITE_QUIET=3 $lite --watch 1800 2>>$log &
sleep 2
$lite --reconcile 2>>$log   # adopt anything a tool replaced during the last step
hdiutil detach -force $drive >/dev/null
await_status "local" && say "  every entry flipped to a local folder"
run_all "drive away" on

say "\n## Replugged: local work merged onto the drive; offline use proves it"
hdiutil attach -quiet -nobrowse "$work/drive.sparsebundle"
await_status "on drive" && say "  every entry is back on the drive"
sleep 2
run_all "after replug" off

say "\n## Release"
pkill -f 'StowawayLite --watch'
for t in $targets; do
  kind=${t%%:*} dir=${t#*:}
  check $kind release "$lite --release '$dir' && [[ -d '$dir' && ! -L '$dir' ]]"
done
check go "after release" "$go_off"
check deriveddata "after release" "$xc_run"

say "\n## Results"
print "| Kind | adopt | from drive | drive away | after replug | release |" | tee -a $log
print "|---|---|---|---|---|---|" | tee -a $log
for kind in cargo-registry go gradle deriveddata huggingface next venv npx; do
  row="| $kind"
  for step in adopt "from drive" "drive away" "after replug" release; do
    r=$(print -l $results | grep "^$kind|$step" | cut -d'|' -f3 | sort -u | tr '\n' ' ')
    [[ $kind == go && $step == adopt ]] && r=$(print -l $results | grep -E '^go-(modcache|buildcache)\|adopt' | cut -d'|' -f3 | sort -u | tr '\n' ' ')
    [[ $kind == go && $step == release ]] && r=$(print -l $results | grep -E '^go-(modcache|buildcache)\|release' | cut -d'|' -f3 | sort -u | tr '\n' ' ')
    row+=" | ${r:-—}"
  done
  print "$row |" | tee -a $log
done
cleanup
