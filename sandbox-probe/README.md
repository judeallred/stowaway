# Can Stowaway ship on the Mac App Store?

**Short answer:** Stowaway as designed, with disk images mounted in place over `node_modules`,
can't ship there. A reduced edition, **Stowaway Lite**, can. It moves global caches, Cargo
`target/` folders and the pnpm store to the drive behind symlinks, and it works end to end in
the App Sandbox with no temporary exceptions.

This folder is the sandboxed probe app and the experiments behind that answer. It was tested on
macOS 26.6.2 and ad-hoc signed. App Sandbox applies the same way to ad-hoc signed apps; anything
that depends on a Team ID is marked as such below.

## Why full Stowaway can't ship

To work, Stowaway has to attach an image and then mount it at the project's own path. The App
Sandbox blocks both steps. I tried every way around each one:

| Step | What happens in the sandbox | What it would take |
|---|---|---|
| **Mount at `~/code/…/node_modules`** | The sandbox runs a `file-mount` check on the mount point. It allows mounts only inside the app's own container. A user-granted folder carries read/write rights, but not mount rights. This applies whether hdiutil or DiskArbitration (`DADiskMount`) does the mounting, with the folder or the whole disk granted, and even with a documented `home-relative-path` temporary exception. | Only undocumented raw SBPL (`temporary-exception.sbpl`), which App Review doesn't accept ([DTS](https://developer.apple.com/forums/thread/775835), [Quinn](https://developer.apple.com/forums/thread/823455)). **No path.** |
| Attach a disk image | The kernel denies `iokit-open-user-client IOHDIXControllerUserClient`. | One documented temporary exception, plus `hdiutil attach -noverify -noautofsck`. That worked here. But App Review "rarely approves" temporary exceptions ([Quinn, 2026](https://developer.apple.com/forums/thread/823455)), and Quinn says hdiutil "was never really intended to be used from within App Sandbox" ([thread](https://developer.apple.com/forums/thread/780965)). |
| Create a disk image | `newfs_apfs` is denied `file-ioctl` on `/dev/rdisk*`. | Avoidable: copy in a pre-formatted template image instead of running `newfs`. |
| Quarantine | Every file the sandbox writes is quarantined, a quarantined image mounts with `MNT_QUARANTINE`, and binaries on it won't run. | **Solved**: see `user-selected.executable` below. |

Other routes I checked, which don't help:

- **Mount inside the container, then symlink to it.** The mount works from the plain sandbox. But
  npm deletes a symlinked `node_modules` and reinstalls into a real folder, and pnpm fails with
  `ENOTDIR`. I rechecked this with npm 11.13; it matches what SPEC §4.0 found.
- **FSKit.** The in-app mount API, `FSClient.mountSingleVolume`, needs macOS 27, and per Apple's
  docs "the system mounts the volume within the `/Volumes/` directory"
  ([docs](https://developer.apple.com/documentation/fskit/fsclient/mountsinglevolume(resource:bundleid:options:completionhandler:))).
  That leaves a symlink again, so it has the same npm problem. FSKit is also slow for
  metadata-heavy trees ([forum](https://developer.apple.com/forums/thread/793013)).
- **A sandboxed root daemon (`SMAppService.daemon`).** App Review approved one for remounting
  disks ([thread](https://developer.apple.com/forums/thread/775835)). But it runs under the same
  sandbox, including the `file-mount` check.
- **Volumes on the drive itself instead of images.** DiskArbitration refuses to mount external
  disks from the sandbox (`system.volume.external.mount`), and creating APFS volumes needs
  `diskutil`, which the sandbox denies. Each container also allows only about one volume per
  512 MiB, at most 100.

## What does work: Stowaway Lite

`scripts/lite-e2e.sh` proves this end to end, using a real `cargo build` in the plain App Sandbox
plus one non-exception entitlement:

1. **Adopt:** move a folder to the drive and leave a symlink. Cargo builds and runs through it.
2. **Unplug:** the app sees `NSWorkspace.didUnmount` and replaces the symlink with an empty local
   folder. The offline build works.
3. **Plug back in:** the drive's bookmark resolves again, the local build is merged onto the
   drive, and the symlink is restored.

What it rests on, all tested:

- **`com.apple.security.files.user-selected.executable` stops quarantine.** Files the app copies
  into folders the user granted, including binaries, come out unquarantined and run. Without this
  entitlement they're quarantined, and running one blocks on Gatekeeper. This is a normal
  entitlement, not a temporary exception, but its behaviour is undocumented and App Review
  scrutinises it ([Quinn](https://developer.apple.com/forums/thread/811450)). Our justification
  would be: "a developer tool that moves build outputs and package caches; quarantining them
  breaks the user's toolchain."
- **Folder grants:** an open panel plus security-scoped bookmarks. This works for hidden
  dot-folders (`~/.npm`, `~/.cargo`, DerivedData) and for the drive, and the drive's bookmark
  survives an unplug. Inside a granted folder the app can create symlinks, rename and delete.
  DevCleaner for Xcode ships on the App Store with this pattern. Granting `/` gives read-only
  access, so it's no use.
- **Tools that accept symlinked folders.** Verified: npm cache, pnpm store, Yarn cache and Cargo
  `target/` (`cargo clean` deletes the symlink, after which the app adopts again). Commonly done
  but not re-tested here: DerivedData, Go, Gradle and Hugging Face.
- **Node.** npm projects aren't covered. pnpm projects are, if they use pnpm's
  `enableGlobalVirtualStore`: then `node_modules` is a 20 KB tree of symlinks into the store,
  verified with React, lodash and TypeScript. The links go through the store path, so the
  unplug flip works.

**Lite's costs compared with full Stowaway:**

- **No npm `node_modules`.** That's the biggest per-project folder.
- **No idle check.** `lsof`, `ps` and `pgrep` all see nothing in the sandbox. Replace it with a
  quiet period of filesystem events, renaming before copying, and checking whether Xcode or
  Android Studio are running (`NSWorkspace.runningApplications`).
- **The app has to keep running.** If it isn't running when the drive vanishes, the symlink
  dangles and builds fail ("Not a directory"). It runs as a login item and reconciles at launch.
- **Slower pnpm installs.** With the store on another volume, pnpm copies files instead of
  cloning them.
- **Setup takes a few clicks.** The user grants each cache's parent folder once, in a panel
  already open at that folder.

## How to sell it

- **Recommended:** sell full Stowaway directly (Developer ID, notarization, license keys), which
  is what the current design and `stowaway license` already support. Ship Stowaway Lite on the
  App Store for discovery, with an in-app pointer to the full edition.
- **Lite's review risks, in order:**
  1. `user-selected.executable`. Have a fallback: without it, Lite can still move data-only caches
     (npm cache, Cargo registry, Go modules, Gradle, Hugging Face), where quarantine does no harm.
  2. A login item that's always running. Allowed with consent under 2.4.5(iii).
  3. The symlink flip touching the user's folders. Explain it in the review notes.

## Still open (each needs something I don't have)

- **A one-click home grant:** run `scripts/panel-home-test.sh` while at the screen and click
  Grant. The screen was locked at the time. Opening the home folder through LaunchServices gets
  remapped to the app's container, so only the real panel can answer this.
- **A sandboxed launch agent:** launchd killed the ad-hoc agent with `OS_REASON_CODESIGNING`
  ("doesn't have a Team ID"). Retest with a real certificate (`CODESIGN_IDENTITY=… bundle.sh`).
  Lite doesn't need it: the login-item app can be the engine.
- **A first TestFlight/App Review submission of Lite** is the only definitive test of the
  entitlement policy.

## The probe app

```sh
cd sandbox-probe
APP_ENTITLEMENTS=App           scripts/bundle.sh "$PWD/build-App"            # plain sandbox
APP_ENTITLEMENTS=AppExecutable scripts/bundle.sh "$PWD/build-AppExecutable"  # + user-selected.executable (Lite)
APP_ENTITLEMENTS=AppDocumented scripts/bundle.sh "$PWD/build-AppDocumented"  # + documented temporary exceptions
APP_ENTITLEMENTS=AppExceptions scripts/bundle.sh "$PWD/build-AppExceptions"  # + raw SBPL (never shippable)
scripts/lite-e2e.sh
```

`SandboxProbe` takes these modes. The sandbox comes from the code signature, so all of them run
sandboxed even when started from Terminal:

| Mode | What it does |
|---|---|
| (none) | Window: choose folders, run probes, copy the report |
| `--headless` | Runs every probe and prints the report (`results/` has the first runs) |
| `--grant` (via `open -a App <folders…> --args --grant`) | Saves the folders as bookmarks; paths under `/Volumes` become the drive |
| `--panel <dir>` | Shows the real open panel at `<dir>` |
| `--exec <tool> [args…]` | Runs one command inside the sandbox with the bookmarks in scope |
| `--da-mount <bsd> <path>`, `--da-unmount <bsd>` | Mounts or unmounts through DiskArbitration |
| `--lite-adopt <folder>`, `--lite-watch <seconds>` | The Lite engine |
| `--register-agent`, `--unregister-agent` | The sandboxed launch agent |

To see what the sandbox denied: `/usr/bin/log show --last 2m --style compact | grep 'Sandbox:'`.
