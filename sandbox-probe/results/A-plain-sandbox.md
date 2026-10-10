# Stowaway sandbox probe

Run 10/10/2026, 1:08 AM on macOS Version 26.6.2 (Build 25G83)


## Sandbox

| | Probe | Detail |
|---|---|---|
| PASS | App Sandbox is on | container=dev.stowaway.sandbox-probe, NSHomeDirectory=/Users/judeallred/Library/Containers/dev.stowaway.sandbox-probe/Data |

## Files without asking

| | Probe | Detail |
|---|---|---|
| FAIL | List ~/code | denied |
| FAIL | Read global caches | ~/.npm: denied; ~/.cargo/registry: denied; ~/Library/Developer/Xcode/DerivedData: denied; ~/Library/pnpm/store: denied; ~/.gradle/caches: denied; ~/go/pkg/mod: missing; ~/.cache/huggingface/hub: missing |
| PASS | List /Volumes | readable (5 entries) |
| FAIL | List an external volume's root | /Volumes/<some mounted volume>: denied |

## Chosen folders (security-scoped bookmarks)

| | Probe | Detail |
|---|---|---|
| SKIP | Code folder: resolve bookmark | not chosen yet |
| SKIP | External drive: resolve bookmark | not chosen yet |

## Disk images (the core mechanism, §4.1)

| | Probe | Detail |
|---|---|---|
| FAIL | in the container: hdiutil create | exit 1: hdiutil: create failed - Device not configured |
| FAIL | in the container, mounted by DiskArbitration: hdiutil create | exit 1: hdiutil: create failed - Device not configured |
| SKIP | Real layout: image on drive, mounted in code folder | choose both a code folder and a drive |

## Drive identity

| | Probe | Detail |
|---|---|---|
| PASS | DiskArbitration describe / | VolumeKind=apfs, VolumeUUID=<redacted>, DeviceInternal=1, DeviceProtocol=Apple Fabric, MediaRemovable=0 |
| PASS | diskutil info / | exit 0: <?xml version="1.0" encoding="UTF-8"?> ⏎ <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"> ⏎ <plist version="1.0"> |

## Command-line tools the engine runs

| | Probe | Detail |
|---|---|---|
| PASS | id -u | exit 0: 501 |
| PASS | sw_vers | exit 0: 26.6.2 |
| PASS | ioreg IOPlatformUUID | found: true |
| PASS | iostat -Id disk0 | exit 0: disk0  ⏎     KB/t xfrs   MB  ⏎    22.08 411242917 8865551.41 |
| FAIL | lsof sees other processes | 0 processes visible (exit 1) |
| PASS | launchctl print gui/<uid> | exit 0: gui/501/com.apple.Finder = { ⏎ 	active count = 8 ⏎ 	path = /System/Library/LaunchAgents/com.apple.Finder.plist |
| PASS | osascript | exit 0: 1 |
| FAIL | git --version | exit 1: xcrun: error: cannot be used within an App Sandbox. |
| PASS | Embedded stowaway --version | exit 0: stowaway 0.1.0 |
| INFO | Embedded stowaway status | exit 1: stowaway: Stowaway isn't set up yet. Run `stowaway init --volume <drive> --root <folder>`. |

## Running in the background

| | Probe | Detail |
|---|---|---|
| INFO | Login item status (SMAppService.mainApp) | not registered |
| INFO | Launch agent status (SMAppService.agent) | not registered; agent's heartbeat isn't readable from the app (separate containers): read it from Terminal |

