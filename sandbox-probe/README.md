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
- **Tools that accept symlinked folders.** Verified with each real tool through adopt, use from
  the drive, unplug, replug and release (`scripts/lite-kinds-e2e.sh`): npm cache, `npx`, pnpm
  store, Yarn cache, Cargo `target/` and registry, Go's module and build caches, Gradle's caches,
  Xcode DerivedData, Hugging Face, uv's `.venv` and Next.js's `.next`. `cargo clean` deletes the
  symlink, after which the app adopts again.
- **Node.**
  - **npm projects** are covered with deep links (see the prototype section below). Next.js
    (webpack), `tsc` and `require` work, and `npm install` is as fast as with core. Projects that
    build with Turbopack need `turbopack.root` set first.
  - **pnpm projects** are covered if they use pnpm's `enableGlobalVirtualStore`: then
    `node_modules` is a 20 KB tree of symlinks into the store, verified with React, lodash and
    TypeScript. The links go through the store path, so the unplug flip works.

**Lite's costs compared with full Stowaway:**

- **Newly installed npm packages sit on the Mac briefly.** An install that adds or upgrades
  packages extracts them locally; Lite moves them to the drive once the project has been quiet
  for 20 s.
- **No idle check.** `lsof`, `ps` and `pgrep` all see nothing in the sandbox. Replace it with a
  quiet period of filesystem events, renaming before copying, and checking whether Xcode or
  Android Studio are running (`NSWorkspace.runningApplications`).
- **The app has to keep running.** If it isn't running when the drive vanishes, the symlink
  dangles and builds fail ("Not a directory"). It runs as a login item and reconciles at launch.
- **Slower pnpm installs.** With the store on another volume, pnpm copies files instead of
  cloning them.
- **Setup takes a few clicks.** The user grants each cache's parent folder once, in a panel
  already open at that folder.

## The Lite prototype and how it performs

`StowawayLite.app` is a sandboxed prototype of the Lite edition. It's built by `bundle.sh`
alongside the probe, from `Sources/LiteEngine` and `Sources/StowawayLite`:

- **Window:** choose the drive, grant folders, offload a folder, bring it back, and watch status
  live.
- **Command-line modes, for scripting:** `--grant` (through `open -a`), `--adopt`, `--release`,
  `--status`, `--reconcile` and `--watch`.
- **npm projects (deep links):**
  - `node_modules` and every package folder in it stay real; only each package's contents link
    to a store on the drive. npm sees ordinary installed packages, so `npm install` with nothing
    to change leaves everything alone.
  - In the store, each package sits in its own `node_modules/<name>` under folders whose
    `node_modules` entries link back to the project's local ones. Resolving from a file's real
    path still goes through the tree npm maintains, so an upgraded dependency is never shadowed
    by an old copy on the drive.
  - npm's hidden lockfile moves to the drive too, and folder times are preserved. With the drive
    connected, npm trusts it; without the drive, it can't read it and repairs everything locally,
    even if Lite isn't running.
  - It refuses pnpm projects (offload pnpm's store instead) and projects that build with
    Turbopack unless `turbopack.root` is set, because Turbopack refuses packages outside the
    project.
  - `scripts/lite-npm-e2e.sh` checks all of it, including unplugging and installing offline.
- **Build output in a JavaScript project** (`.next`) gets a `node_modules` link next to it on the
  drive, back to the project's, because Next's compiled server code requires packages at run time.
- **Engine:** a parallel copier, so adoption is never stuck on per-file latency. It copies
  first and then swaps, so a folder stays usable until its symlink appears. At launch it
  reconciles with whether the drive is there, and it re-adopts a folder a tool replaced (as
  `cargo clean` does). Its folder on the drive is `Stowaway Lite.noindex`, so Spotlight skips it.

[`results/bench.md`](results/bench.md) compares Lite with core's mounted images on your OWC
SSD:

- **Daily work:** day-to-day speed is the same. Cargo builds, pnpm installs, module resolution
  and `tsc` all run at drive speed under both designs.
- **Adopting:** Lite is up to 4.5× faster for small folders, because it skips creating,
  attaching and remounting an image.
- **npm projects:** as fast as core. `npm install` with nothing to change took 0.28 s, against
  0.24 s for core; resolution and `tsc` are on par.
- **The drive coming and going:** with 20 folders, Lite is about 8× faster on unplug (0.7 s vs
  5.8 s) and about 5× faster when the drive returns (5 s vs 26 s). Core's time grows by about
  1.2 s per image.

The benchmark also turned up a **core bug**: `npm ci` fails with EACCES on the root-only
`.fseventsd` folder in every mounted `node_modules`. All 55 of yours have it.

## How to sell it

- **Recommended:** sell full Stowaway directly (Developer ID, notarization, license keys), which
  is what the current design and `stowaway license` already support. Ship the cleaner on the App
  Store, with Lite offload as an in-app purchase. The full edition can honor App Store purchases
  (3.1.3(b)). Linking out from inside the app is allowed only on the US storefront.
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
scripts/lite-e2e.sh                              # the probe's Lite flow, end to end
scripts/bench.sh "/Volumes/<drive>" 3            # Lite vs core vs local (BENCH_ONLY=flip: unplug only)
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
