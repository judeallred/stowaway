#!/bin/sh
# Assembles Stowaway.app: the SwiftUI menu bar app, with the Rust `stowaway` binary embedded as a
# helper and registered as a launch agent through SMAppService (spec §9.1).
#
# Usage: macos-app/scripts/bundle.sh [output-dir]   (default: macos-app/build)
# Signing: set CODESIGN_IDENTITY to sign with a Developer ID; otherwise the bundle is ad-hoc signed.
# Architectures: set UNIVERSAL=1 to build for both Apple silicon and Intel; otherwise this Mac's
# only.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-"$root/macos-app/build"}
app="$out/Stowaway.app"
version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/Cargo.toml" | head -1)

if [ "${UNIVERSAL:-}" = 1 ]; then
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  for triple in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build --release --locked -p stowaway --target "$triple" \
      --manifest-path "$root/Cargo.toml"
  done
  rust_bin="$root/target/universal/stowaway"
  mkdir -p "$(dirname "$rust_bin")"
  lipo -create -output "$rust_bin" \
    "$root/target/aarch64-apple-darwin/release/stowaway" \
    "$root/target/x86_64-apple-darwin/release/stowaway"
  set -- --arch arm64 --arch x86_64
else
  cargo build --release --locked -p stowaway --manifest-path "$root/Cargo.toml"
  rust_bin="$root/target/release/stowaway"
  set --
fi
swift build -c release --package-path "$root/macos-app" "$@" -Xswiftc -warnings-as-errors
swift_bin=$(swift build -c release --package-path "$root/macos-app" "$@" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Library/LaunchAgents" \
  "$app/Contents/Resources"
cp "$swift_bin/Stowaway" "$app/Contents/MacOS/Stowaway"
cp "$rust_bin" "$app/Contents/Helpers/stowaway"
cp "$root/LICENSE" "$app/Contents/Resources/LICENSE"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.stowaway.app</string>
  <key>CFBundleName</key><string>Stowaway</string>
  <key>CFBundleDisplayName</key><string>Stowaway</string>
  <key>CFBundleExecutable</key><string>Stowaway</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>Source-available under the Prosperity Public License 3.0.0</string>
</dict>
</plist>
EOF

cat > "$app/Contents/Library/LaunchAgents/dev.stowaway.agent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.stowaway.agent</string>
  <key>BundleProgram</key><string>Contents/Helpers/stowaway</string>
  <key>ProgramArguments</key><array><string>stowaway</string><string>agent</string></array>
  <key>AssociatedBundleIdentifiers</key><array><string>dev.stowaway.app</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>
  </dict>
</dict>
</plist>
EOF

identity=${CODESIGN_IDENTITY:--}
# Notarization needs a secure timestamp; an ad-hoc signature can't have one.
if [ "$identity" = - ]; then timestamp=--timestamp=none; else timestamp=--timestamp; fi
codesign --force --options runtime "$timestamp" --sign "$identity" "$app/Contents/Helpers/stowaway"
codesign --force --options runtime "$timestamp" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
