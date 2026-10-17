#!/bin/sh
# Renders the App Store screenshots (2880×1800, light) and layout checks (light and dark) from
# demo data, using a Debug build's snapshot mode. The app is sandboxed, so it writes into its
# container; the images are then copied to App/build/screenshots.
set -eu

app=$(cd "$(dirname "$0")/.." && pwd)
xcodebuild -quiet -project "$app/Stowaway.xcodeproj" -scheme Stowaway -configuration Debug \
  -derivedDataPath "$app/build/DerivedData" -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
container="$HOME/Library/Containers/com.brooklynspaceport.stowaway/Data/tmp/snapshots"
rm -rf "$container"
STOWAWAY_SNAPSHOTS="$container" "$app/build/DerivedData/Build/Products/Debug/Stowaway.app/Contents/MacOS/Stowaway"
rm -rf "$app/build/screenshots"
cp -R "$container" "$app/build/screenshots"
echo "Wrote $app/build/screenshots (appstore/ is the set to upload)"
