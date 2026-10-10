#!/bin/sh
# Needs you at the screen: shows the sandboxed app's real open panel at your home folder. Click
# Grant. Prints whether one home-folder grant lets the app read ~/.npm and create symlinks under
# it, which would make Stowaway Lite a one-click setup. (Opening the home folder through
# LaunchServices instead gets remapped to the app's container, so only the real panel can
# answer this.)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
log=$(mktemp)
mkdir -p "$HOME/stowprobe-code"
open -W --stderr "$log" -a "$here/build-AppExecutable/SandboxProbe.app" --args --panel "$HOME"
grep -E 'panel' "$log"
rmdir "$HOME/stowprobe-code" 2>/dev/null || true
