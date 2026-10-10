#!/bin/sh
# Builds SandboxProbe.app: a sandboxed app that tries Stowaway's mechanisms from inside the App
# Sandbox. Embeds a sandboxed launch agent and the real Rust `stowaway` binary as a helper that
# inherits the app's sandbox.
#
# Usage: [APP_ENTITLEMENTS=App|AppExecutable|AppDocumented|AppExceptions] sandbox-probe/scripts/bundle.sh [output-dir]
# Signing: ad-hoc unless CODESIGN_IDENTITY is set. The sandbox applies either way.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/.." && pwd)
out=${1:-"$here/build"}
app="$out/SandboxProbe.app"
ent="$here/entitlements"

cargo build --release --locked -p stowaway --manifest-path "$root/Cargo.toml"
swift build -c release --package-path "$here"
bin=$(swift build -c release --package-path "$here" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Library/LaunchAgents"
cp "$bin/SandboxProbe" "$app/Contents/MacOS/SandboxProbe"
cp "$bin/ProbeAgent" "$app/Contents/Helpers/ProbeAgent"
cp "$root/target/release/stowaway" "$app/Contents/Helpers/stowaway"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.stowaway.sandbox-probe</string>
  <key>CFBundleName</key><string>SandboxProbe</string>
  <key>CFBundleExecutable</key><string>SandboxProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSFileQuarantineEnabled</key><${QUARANTINE:-true}/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string><string>public.volume</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

cat > "$app/Contents/Library/LaunchAgents/dev.stowaway.sandbox-probe.agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.stowaway.sandbox-probe.agent</string>
  <key>BundleProgram</key><string>Contents/Helpers/ProbeAgent</string>
  <key>AssociatedBundleIdentifiers</key><array><string>dev.stowaway.sandbox-probe</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

identity=${CODESIGN_IDENTITY:--}
sign() { codesign --force --options runtime --timestamp=none --sign "$identity" "$@"; }
sign --identifier dev.stowaway.sandbox-probe.stowaway --entitlements "$ent/Helper.entitlements" \
  "$app/Contents/Helpers/stowaway"
sign --identifier dev.stowaway.sandbox-probe.agent --entitlements "$ent/Agent.entitlements" \
  "$app/Contents/Helpers/ProbeAgent"
# APP_ENTITLEMENTS=AppExceptions builds variant B, with temporary exceptions.
sign --entitlements "$ent/${APP_ENTITLEMENTS:-App}.entitlements" "$app"
echo "Built $app"
