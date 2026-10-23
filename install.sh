#!/bin/sh
# Builds a Release of the app, signed to run on this Mac only (no developer team needed), and
# installs it in /Applications, replacing and relaunching any copy that's running. App Store
# builds are signed and uploaded from Xcode instead (Product > Archive).
set -eu

root=$(cd "$(dirname "$0")" && pwd)
app="$root/App"
built="$app/build/DerivedData/Build/Products/Release/Stowaway.app"
installed=/Applications/Stowaway.app

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet --spec "$app/project.yml"
fi
xcodebuild -quiet -project "$app/Stowaway.xcodeproj" -scheme Stowaway -configuration Release \
  -derivedDataPath "$app/build/DerivedData" -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build

# Quit the running copy as its Quit menu item does.
if pgrep -xq Stowaway; then
  echo "Quitting Stowaway…"
  osascript -e 'tell application id "com.brooklynspaceport.stowaway" to quit' >/dev/null 2>&1 || true
  waited=0
  while pgrep -xq Stowaway; do
    if [ "$waited" -ge 60 ]; then
      echo "install.sh: Stowaway didn't quit within a minute; quit it from its menu and run this again." >&2
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
fi

rm -rf "$installed"
ditto "$built" "$installed"
open "$installed"
echo "Installed $installed ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$installed/Contents/Info.plist"))"
