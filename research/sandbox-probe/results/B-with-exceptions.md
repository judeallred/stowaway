# Stowaway sandbox probe

Run 10/10/2026, 1:08 AM on macOS Version 26.6.2 (Build 25G83)


## Sandbox

| | Probe | Detail |
|---|---|---|
| PASS | App Sandbox is on | container=dev.stowaway.sandbox-probe, NSHomeDirectory=/Users/judeallred/Library/Containers/dev.stowaway.sandbox-probe/Data |

## Files without asking

| | Probe | Detail |
|---|---|---|
| PASS | List ~/code | readable (71 entries) |
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
| PASS | in the container: hdiutil create | exit 0: created: /Users/judeallred/Library/Containers/dev.stowaway.sandbox-probe/Data/tmp/probe-3C78D2BF/probe-50073ADE.sparsebundle |
| PASS | in the container: hdiutil attach -mountpoint | exit 0: <?xml version="1.0" encoding="UTF-8"?> ⏎ <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"> ⏎ <plist version="1.0"> |
| PASS | in the container: mounted in place | statfs mount-on=/Users/judeallred/Library/Containers/dev.stowaway.sandbox-probe/Data/tmp/probe-3C78D2BF/project-5EE183E0/node_modules, fs=apfs, device differs from parent: true |
| FAIL | in the container: mount is executable | mount quarantine flag: true, image has com.apple.quarantine: true |
| PASS | in the container: write through the mount | wrote and read index.js |
| PASS | in the container: hdiutil info sees it | 31 attached images listed |
| PASS | in the container: hdiutil detach | exit 0:  |
| PASS | in the container, mounted by DiskArbitration: hdiutil create | exit 0: created: /Users/judeallred/Library/Containers/dev.stowaway.sandbox-probe/Data/tmp/probe-3C78D2BF/probe-1C61B49F.sparsebundle |
| PASS | in the container, mounted by DiskArbitration: hdiutil attach -nomount | exit 0: <?xml version="1.0" encoding="UTF-8"?> ⏎ <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"> ⏎ <plist version="1.0"> |
| PASS | in the container, mounted by DiskArbitration: DADiskMount at path | mounted /dev/disk63s1 at /Users/judeallred/Library/Containers/dev.stowaway.sandbox-probe/Data/tmp/probe-3C78D2BF/project-32C9D3C5/node_modules |
| PASS | in the container, mounted by DiskArbitration: mounted in place | statfs mount-on=/Users/judeallred/Library/Containers/dev.stowaway.sandbox-probe/Data/tmp/probe-3C78D2BF/project-32C9D3C5/node_modules, fs=apfs, device differs from parent: true |
| FAIL | in the container, mounted by DiskArbitration: mount is executable | mount quarantine flag: true, image has com.apple.quarantine: true |
| PASS | in the container, mounted by DiskArbitration: write through the mount | wrote and read index.js |
| FAIL | in the container, mounted by DiskArbitration: hdiutil info sees it | 31 attached images listed |
| PASS | in the container, mounted by DiskArbitration: hdiutil detach | exit 0:  |
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
| PASS | iostat -Id disk0 | exit 0: disk0  ⏎     KB/t xfrs   MB  ⏎    22.08 411252948 8865736.98 |
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

