#!/bin/sh
# Builds an unsigned Release of the App Store app into App/build, regenerating the Xcode project
# first if XcodeGen is installed. Signing and uploading happen in Xcode (Product > Archive).
set -eu

app=$(cd "$(dirname "$0")/.." && pwd)
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet --spec "$app/project.yml"
fi
xcodebuild -quiet -project "$app/Stowaway.xcodeproj" -scheme Stowaway -configuration Release \
  -derivedDataPath "$app/build/DerivedData" -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
echo "Built $app/build/DerivedData/Build/Products/Release/Stowaway.app"
