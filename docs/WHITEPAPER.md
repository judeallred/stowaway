# Stowaway and Stowaway Lite: the original design and the Mac App Store variant

**Status:** findings from prototyping, October 2026. Tested on macOS 26.6, Apple M4 Pro, with an
OWC Express 1M2 SSD over PCI-Express.
**Scope:** whether Stowaway can be sold on the Mac App Store, what a sandboxed version can and
can't do, and how the two designs compare.

## 1. Summary

Stowaway keeps re-creatable developer folders (`node_modules`, Cargo `target/`, package caches,
Xcode DerivedData) on an external SSD. It does that by mounting a disk image at each folder's own
path: tools see an ordinary folder, and when the drive is unplugged, work continues locally.

**That design can't ship on the Mac App Store.** Every App Store app runs in the App Sandbox,
and the sandbox refuses to mount anything outside the app's own container. No documented
entitlement or temporary exception lifts that rule. Attaching disk images is blocked too, unless
App Review grants a temporary exception, which it rarely does for new apps.

**A different design, Stowaway Lite, does work inside the sandbox.** It moves folders to the
drive and leaves symlinks. It swaps in local folders when the drive goes away and merges the
offline work back when it returns. For npm projects, whose tools refuse a symlinked
`node_modules`, it keeps every package folder real and links only the files inside them ("deep
links"). A working prototype passes end-to-end tests with every folder kind core handles. On the
same hardware it matches the original's day-to-day speed, including `npm install`, and it's much
faster when adopting small folders and when the drive comes and goes. Its main costs: the app
must keep running, and projects that build with Turbopack need a one-line config change.

**Recommendation:** keep selling the original directly (Developer ID, notarization, license keys).
Use the App Store for a cleaner app that finds and deletes developer dependencies, with Lite's
offloading sold as an in-app purchase. The direct edition can honor that purchase.

In this paper, **core** means the original Stowaway and **Lite** means the sandbox version.

## 2. Background: how core works

Core consists of a Rust engine and command-line tool, a background agent, and a SwiftUI menu bar
app.

1. The agent watches root folders (such as `~/code`) and the caches of known tools. It finds
   re-creatable folders by *kind*: `node`, `cargo-target`, `next`, `venv`, `pnpm-store`,
   `cargo-home`, `xcode-derived-data`, `gradle-home`, `go`, `js-caches`, `npx` and
   `huggingface`.
2. Once a folder is idle (nothing changed recently and `lsof` shows nobody has it open), core
   creates a sparse-bundle APFS image on the drive. It copies the folder in through a staging
   mount, then **mounts the image at the folder's own path**.
3. Unplugging the drive makes the mounts vanish. The empty local folder underneath shows
   through, and tools rebuild into it.
4. When the drive returns, core reattaches the images. Anything built locally while the drive was
   away is moved onto the drive.

Before settling on mounts, the spec tried plain symlinks. Real tools rejected them: npm deletes a
symlinked `node_modules` and reinstalls into a real folder on every run, and pnpm fails with
`ENOTDIR`. Mounting in place is what makes core work with every tool.

## 3. What the App Sandbox allows

A sandboxed probe app tried each of core's mechanisms under four entitlement sets:
1. The plain sandbox.
2. Plus `user-selected.executable`.
3. Plus Apple's documented temporary exceptions.
4. Plus raw SBPL rules, which App Review doesn't accept, to see whether anything beyond the
   exceptions would still block us.

| Core mechanism | In the sandbox | Detail |
|---|---|---|
| Create a disk image (`hdiutil create`) | **Blocked** | The kernel denies the disk-image driver's IOKit clients. `newfs_apfs` is denied `file-ioctl` on `/dev/rdisk*`, which no documented entitlement grants. Copying in a pre-made template image avoids this step. |
| Attach a disk image | **Only with a temporary exception** | It works with `temporary-exception.iokit-user-client-class: IOHDIXControllerUserClient` plus `-noverify -noautofsck`. Apple says it "rarely approves" temporary exceptions. |
| **Mount at the project's own path** | **Blocked, no path** | The sandbox runs a `file-mount` check on the mount point, and it passes only inside the app's own container. This applies to both `hdiutil` and DiskArbitration (`DADiskMount`), whether one folder or the whole disk is granted, and even with a `home-relative-path` exception. Only raw SBPL gets past it. |
| Quarantine | **Solved** | Everything a sandboxed process writes is quarantined, and a quarantined disk image mounts non-executable. With `com.apple.security.files.user-selected.executable`, files written into user-granted folders aren't quarantined, and binaries run. |
| Folder access | Works, with user consent | A folder granted through an open panel or LaunchServices is kept as a security-scoped bookmark, and the grant survives a reboot and the drive being unplugged. Dot folders (`~/.npm`, `~/.cargo`) can be granted. Granting `/` gives only read access, and granting the home folder through LaunchServices is remapped to the app's container. |
| Is a folder in use? (`lsof`) | **Blocked** | `lsof`, `ps` and `pgrep` see no processes. |
| Is a folder tracked by git? (`/usr/bin/git`) | Blocked | It's an `xcrun` shim, and xcrun refuses to run in the sandbox. Fixable by bundling a git library. |
| `diskutil`, DiskArbitration, `ioreg`, `iostat`, `launchctl print`, `osascript` | Work | DiskArbitration can replace `diskutil`. |
| The Rust engine as a helper | Works | Signed with `com.apple.security.inherit`, it runs in the app's sandbox and can reach the granted folders. |
| A sandboxed background agent (`SMAppService.agent`) | Unverified | It registers, but an ad-hoc signed agent is killed for lacking a Team ID. This needs a real certificate. A login-item app can be the engine instead. |

Alternatives that don't restore mounting in place:
- **FSKit's mount API** (`FSClient.mountSingleVolume`) needs macOS 27, and Apple's documentation
  says it mounts "within the `/Volumes/` directory."
- **A sandboxed root daemon** registered with `SMAppService.daemon` has been approved by App
  Review before, but it runs under the same `file-mount` check.
- **Mounting inside the container and symlinking to it** works, but npm and pnpm reject the
  symlink.
- **Mounting APFS volumes from the drive itself:** the sandbox can't mount external disks, can't
  create volumes, and a container allows at most about one volume per 512 MiB, capped at 100.

### App Store policy that applies

- **2.4.5(i):** apps must be sandboxed.
- **2.4.5(iv):** apps may not download or install standalone apps or code. That rules out
  "install the full version" from inside the app.
- **2.4.5(vi):** no license keys.
- **2.4.5(vii):** updates come only through the App Store.
- **3.1.1:** unlocking a full version must use in-app purchase.
- **3.1.3(b):** features bought in the app may be honored on other platforms and on your
  website.
- **Linking out to buy elsewhere** is allowed only on the US storefront today. The Supreme Court
  agreed in July 2026 to hear Apple's appeal of the ruling behind that.
- **Apple's developer support** says temporary exceptions are "rarely" approved, never approves
  raw SBPL, and that App Review "scrutinises" `user-selected.executable` closely.

## 4. How Lite works

Lite uses only what the sandbox allows: folders the user grants, symlinks, ordinary file copies
and volume notifications.

**Whole folders** (caches, pnpm store, Cargo `target/`):
- **Adopt:** copy the folder into `Stowaway Lite.noindex/` on the drive, swap the original for a
  symlink, and delete the local copy.
- **Drive unplugged:** the app gets the unmount notification and replaces each symlink with an
  empty local folder. Tools rebuild there.
- **Drive back:** the app merges the local contents onto the drive and restores the symlink.

**npm projects ("deep links"):**
- `node_modules` and every package folder in it stay real directories; only each package's
  contents (`dist/`, `package.json` and so on) are symlinks into a store on the drive. npm
  therefore sees ordinary installed packages and leaves them alone, so `npm install` with nothing
  to change is as fast as with core.
- **Resolution stays correct.** Node, bundlers and `tsc` resolve a file to its real path on the
  drive and look for dependencies from there. In the store, each package sits in a private
  `node_modules/<name>` folder, so paths still read `…/node_modules/<name>/…`, which tools such
  as Next.js test for. Its parent folders carry `node_modules` links back to the project's local
  ones, so lookups always go through the tree npm maintains. After an upgrade, offloaded packages
  get the new version, never a stale copy from the drive. This was verified by upgrading a
  dependency of an offloaded package.
- **npm's hidden lockfile** (`node_modules/.package-lock.json`) moves to the drive, and Lite
  preserves folder modification times. With the drive connected, npm trusts the lockfile and
  takes its fast path. With the drive gone, npm can't read it, rescans, and repairs every package
  locally, even if Lite isn't running.
- **After an install that adds or upgrades packages**, only those are extracted locally. Once
  `node_modules` has been quiet for 20 s, Lite moves them to the drive, reusing any identical copy
  already there.
- **Replug:** anything installed while the drive was away goes back onto the drive.
- **Refused:** pnpm projects (offload pnpm's store instead), and projects that build with
  Turbopack unless their `turbopack.root` setting is set. Turbopack refuses any file outside the
  project root.

**Build output in JavaScript projects** (`.next`): the folder's slot on the drive gets a
`node_modules` link back to the project's, because Next's compiled server code `require`s
packages at run time from its real path.

**The engine:**
- **Copying:** a parallel copier.
- **Swapping:** copy first, then swap, so a folder is never missing.
- **Deleting:** removes trees with `unlinkat`.
- **Locking:** a lock shared across processes, so the app and the command line can't run
  operations at the same time.
- **Startup:** it reconciles state with whether the drive is there.
- **Bookmarks:** it resolves the drive's bookmark without trying to mount it, so an unplug never
  stalls.

## 5. Architectural diff

### 5.1 Components

```
CORE (Developer ID, unsandboxed)                 LITE (Mac App Store, sandboxed)
┌───────────────────────────┐                    ┌─────────────────────────────────────┐
│ Menu bar app (SwiftUI)    │◀── IPC ──┐         │ One app: menu bar + engine          │
└───────────────────────────┘          │         │ (login item, runs continuously)     │
┌───────────────────────────┐          │         │  ├ LiteEngine (Swift; could reuse   │
│ Launch agent (Rust)       │──────────┘         │  │   the Rust kinds/scan as a       │
│  ├ kinds, scan, registry  │                    │  │   sandbox-inheriting helper)     │
│  ├ hdiutil create/attach  │                    │  ├ security-scoped bookmarks        │
│  ├ lsof idle check        │                    │  ├ symlinks + mirror on the drive   │
│  ├ iostat-paced copies    │                    │  ├ NSWorkspace mount events + timer │
│  └ launchctl, osascript   │                    │  └ quiet-period check (no lsof)     │
└─────────────┬─────────────┘                    └──────────────────┬──────────────────┘
              │ mounts images at                                    │ symlinks point into
              ▼ ~/code/…/node_modules                                ▼ /Volumes/<drive>/…
   /Volumes/<drive>/.stowaway/<machine>.noindex/   /Volumes/<drive>/Stowaway Lite.noindex/
      <entry>.sparsebundle  (one per folder)           <folder>-<id>/  (plain folders)
```

### 5.2 Side by side

| Concern | Core | Lite |
|---|---|---|
| Distribution | Developer ID + notarization, sold direct, license keys | Mac App Store, in-app purchase, App Store updates only |
| Privileges | Unsandboxed user processes | App Sandbox + `files.user-selected.read-write`, `bookmarks.app-scope`, `user-selected.executable` |
| Processes | Agent + app + one disk-image service | One app |
| How a folder lives on the drive | APFS sparse-bundle image, mounted at the folder's path | Plain folder on the drive's own filesystem |
| What tools see | A real directory (a mount point) | A symlink (or, for npm, a real folder of symlinks) |
| Finding the drive's folders | Free access to `~/code` and the cache paths | The user grants each root and cache folder once |
| Idle check | `lsof` | Quiet period of no changes, copy-then-swap, and checking whether IDEs are running |
| Git-tracked check | `git` | Needs a bundled library (gix or libgit2) |
| Drive goes away | The kernel removes the mounts; no process needs to be running | The app must be running to swap in local folders |
| Drive comes back | Clear stale devices, reattach every image (~1.2 s each) | Merge local changes, restore the symlinks |
| Space on the drive | Images grow but never shrink (`hdiutil compact` is unsupported on macOS 26) | Deleting files frees space immediately |
| Ejecting the drive | Images must be detached first; a Finder eject reports the drive in use | No images to detach (inferred: not tested with Finder) |
| Deleting a managed folder | `rm -rf node_modules` and `cargo clean` fail with "Resource busy" | `cargo clean` removes the symlink and Lite adopts again; `rm -rf node_modules` removes the links |
| Spotlight | Images marked never-index | Folder named `*.noindex` |
| Several Macs sharing one drive | Per-machine folders | Not yet designed |

### 5.3 What each design covers

| Kind | Core | Lite |
|---|---|---|
| npm `node_modules` | ✔ Mounted image (but see §8: `npm ci` fails) | ✔ Deep links, as fast as core; Turbopack needs `turbopack.root` |
| pnpm projects | ✔ `node_modules` mounted, store offloaded | ✔ Store offloaded; projects need pnpm's `enableGlobalVirtualStore` |
| Yarn cache, npm cache, `npx` | ✔ | ✔ Tested |
| Cargo `target/` | ✔ Mounts the build folders; built programs stay local | ✔ Symlink (prototype moves the whole `target/`; the same split is possible) |
| Cargo registry, Go (module and build caches), Gradle, DerivedData, Hugging Face | ✔ | ✔ Tested through the full lifecycle, including Go's read-only module cache and running a program built into DerivedData |
| Next.js `.next`, Python `.venv` (uv) | ✔ | ✔ Tested; `.next` needs a `node_modules` link back to the project in its drive slot |

## 6. Performance

Medians of three runs on the OWC SSD. "Core" replays core's `hdiutil` steps exactly, and both
designs use the same copier, so the numbers compare the mechanisms. Full data and method are in
`results/bench.md`.

| Workload | Step | Local disk | Core | Lite |
|---|---|---|---|---|
| Cargo (542 MB, 2,173 files) | clean build | 7.58 s | 7.81 s | 7.61 s |
| | incremental build | 1.56 s | 0.87 s | 0.71 s |
| | no-op build | 0.57 s | 0.54 s | 0.30 s |
| pnpm, global virtual store | offline install | 7.89 s | 2.45 s | 2.33 s |
| | `require` every dependency | 0.95 s | 0.31 s | 0.36 s |
| | `tsc --noEmit` | 2.25 s | 1.82 s | 1.69 s |
| npm (376 MB, 15,128 files)* | `npm install` from the lockfile | 3.83 s | 2.73 s | 3.22 s |
| | **`npm install` with nothing to change** | 0.24 s | 0.24 s | **0.28 s** |
| | `require` every dependency / `tsc` | 0.33 / 1.67 s | 0.31 / 1.62 s | 0.30 / 1.53 s |
| | after a fresh install: move packages to the drive | | | 0.71 s (+2.4 s background cleanup) |
| Adopt a folder | Cargo `target/` | | 3.77 s | **0.83 s** |
| | `node_modules` | | 9.71 s | 8.98 s |
| Drive unplugged (20 folders) | until tools see local folders | | 5.8 s | **0.7 s** |
| Drive plugged back in (20 folders) | until everything is on the drive | | 26.4 s | **5.3 s** |
| Overhead per folder | | | 7–8 MB empty image | one symlink |

\* The npm rows come from a later run on a less busy machine, so compare them only with each
other.

- **Day to day, they're the same.** Builds, installs, module resolution and type-checking run at
  drive speed under both.
- **Lite adopts small folders faster.** It skips about 3 s per folder spent creating, attaching
  and remounting an image.
- **Lite handles the drive coming and going faster, and the gap grows with folder count.** Core
  reattaches about 1.2 s per image, so a Mac with 55 mounted `node_modules` waits over a minute
  after each replug.
- **npm is on par.** With deep links, `npm install` with nothing to change takes 0.28 s, against
  0.24 s for core. The first npm design (see §6.1) took 5.4 s here.
- **The local column is noisy.** On the internal disk, Spotlight indexed every freshly written
  file, while the test folders on the drive were excluded from indexing.

### 6.1 How npm got from 5.4 s to 0.28 s

The first design linked each whole package folder to the drive. Arborist, npm's installer, then
saw every package as a `link:` dependency that didn't match the lockfile, and replaced them all
on every install. Reading Arborist's source showed both why, and how npm decides whether to trust
its hidden lockfile without scanning: no package folder may be newer than it, and every package's
real path must be in it.

| Approach | No-change install | Verdict |
|---|---|---|
| Whole package folders as symlinks | 5.4 s; npm reinstalls everything every run | Replaced |
| **Deep links:** real package folders, linked contents, `node_modules` links back to the Mac from the store, lockfile on the drive, folder times kept | 0.28 s; npm leaves the links alone | **Adopted** |
| Asking users to switch npm to `install-strategy=linked` (pnpm-like layout) | Not measured | Per-project config and still experimental in npm |
| Asking users to move to pnpm with its global virtual store | Already supported | Requires changing package manager |
| A shim around `npm` that restores links | Not built | Lite can't install shims into the user's PATH from the sandbox |

Two details were essential:
- **Each package gets a private `node_modules/<name>` in the store.** Otherwise Next.js's build
  failed: it identifies its own files with path patterns like `next/dist/…`.
- **The lockfile lives on the drive.** Otherwise, unplugging the drive while Lite wasn't running
  left npm trusting a lockfile for packages that were no longer there.

## 7. Tradeoffs

### Core

**Pros**
- Works with every tool, including npm and Turbopack, because tools see a real directory.
- Survives the drive vanishing without any process running: the kernel removes the mounts.
- Built programs stay local by design (Cargo `target/` split, Xcode products).
- Unrestricted access: no setup beyond choosing roots, plus a true in-use check (`lsof`).
- Mature: the full kind catalogue, paced copies and machine identity.

**Cons**
- **Can't be sold on the Mac App Store.**
- Many processes and devices: one image per folder, and reattaching costs about 1.2 s each.
- Images never shrink, and the drive must be ejected through Stowaway.
- `rm -rf node_modules` and `cargo clean` report "Resource busy".
- `npm ci` currently fails on every mounted `node_modules` (§8).
- `hdiutil` sometimes fails under bursts of attaches.

### Lite

**Pros**
- **Can be sold on the Mac App Store,** using only documented, non-exception entitlements.
- Simple: one app, plain folders on the drive, nothing mounted.
- Faster to adopt, unplug and replug, and its cost doesn't grow with the number of folders.
- Space on the drive is freed as soon as things are deleted, and the drive ejects normally.
- Tools that delete their folder (`cargo clean`, `rm -rf`) just work; Lite adopts again later.

**Cons**
- **Relies on `user-selected.executable`.** Its behavior is undocumented and App Review
  scrutinizes it. Without it, Lite is limited to data-only caches.
- **The app must keep running.** If it's quit when the drive is unplugged, the symlinks dangle
  and builds fail until it starts again.
- **npm projects:** newly installed packages sit on the Mac until the project has been quiet for
  20 s, and Turbopack projects need a config change.
- No true in-use check, only heuristics.
- Setup takes several permission grants, unless one home-folder grant through the real open
  panel works (untested).
- Bundlers that refuse paths outside the project would need per-project configuration.

## 8. Defects found along the way

1. **Core: `npm ci` fails with EACCES on every Stowaway-mounted `node_modules`.** macOS creates a
   root-only `.fseventsd` folder at the top of each mounted volume, and `npm ci` dies trying to
   read it. All 55 mounted `node_modules` on the test machine have one. The spec's note that
   `npm ci` works probably predates macOS creating the folder, since it's created lazily.
2. **Core: `hdiutil attach` sometimes fails** under bursts of attaches with "no mountable file
   systems". A retry is advisable.
3. **Lite (fixed):**
   - Resolving the drive's bookmark without `.withoutMounting` could stall on unplug.
   - Linking whole `@scope` folders broke npm, and linking whole package folders made every
     `npm install` reinstall everything (§6.1).
   - `.next` on the drive couldn't find `react` at run time until its slot got a `node_modules`
     link back to the project.
   - Parallel deletes contended on the shared parent directory.
   - The app and the command line could race without a shared lock.

## 9. Distribution recommendation

| Channel | Product | Monetization |
|---|---|---|
| Your website | Stowaway (core) | License keys; the existing `stowaway license` flow |
| Mac App Store | A dependency cleaner (scan, size up, delete) | Free |
| Mac App Store, in-app purchase | Lite offloading | In-app purchase (Apple takes 15% under the Small Business Program) |

Rules to keep the App Store build approvable:
- **Build it from the same codebase, but compile the excluded features out.** No hidden or
  dormant features (2.3.1).
- **Use its own bundle ID and entitlements file.**
- **Ship no launch-agent plist and no mounting helper.**
- **Add a CI check** that inspects the binary for `hdiutil`, `launchctl` and `lsof`, and checks
  its entitlements.
- **Point to the full edition from inside the app only on the US storefront,** and only as a
  link to a web page, never an install button. Say so in the review notes.
- **Let core honor App Store purchases (3.1.3(b))** by validating the App Store receipt locally
  (not yet prototyped).

## 10. Open questions

- **Does one home-folder grant through the real open panel cover every cache?** It would make
  setup a single click (`scripts/panel-home-test.sh`).
- **Does a sandboxed launch agent work** when signed with a real Team ID?
- **Will App Review accept `user-selected.executable` for this use?** Only a submission will
  tell.
- **Do Vite's dev server and Jest work with deep links?** Vite worked with the earlier per-package
  links; deep links haven't been retested with it.
- **What happens when a tool is running during the unplug flip?** Gradle's daemon and a running
  dev server weren't tested.
- **Can core validate an App Store receipt** from the separately installed App Store edition?

## Appendix: evidence

Everything is in `sandbox-probe/` on the `sandbox-prototype` branch.

| What | Where |
|---|---|
| Sandbox probe app, four entitlement sets | `Sources/SandboxProbe`, `entitlements/`, `results/A-*.md`, `results/B-*.md` |
| Lite engine and app | `Sources/LiteEngine`, `Sources/StowawayLite` |
| End-to-end tests | `scripts/lite-e2e.sh` (folders), `scripts/lite-npm-e2e.sh` (npm mode and guards), `scripts/lite-kinds-e2e.sh` (every other kind, with real tools) |
| Benchmark | `scripts/bench.sh`, `Sources/stowbench`, `results/bench.md`, `results/bench-raw.tsv` |
| Sandbox denials | `log show --style compact \| grep 'Sandbox:'`, as described in the README |

Sources:
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Disk Arbitration and App Sandbox](https://developer.apple.com/forums/thread/775835)
- [hdiutil in the sandbox](https://developer.apple.com/forums/thread/780965)
- [Temporary exceptions](https://developer.apple.com/forums/thread/823455)
- [Quarantine and `user-selected.executable`](https://developer.apple.com/forums/thread/811450)
- [`FSClient.mountSingleVolume`](https://developer.apple.com/documentation/fskit/fsclient/mountsinglevolume(resource:bundleid:options:completionhandler:))
- [FSKit performance](https://developer.apple.com/forums/thread/793013)
- [Apple v. Epic (Supreme Court)](https://www.oyez.org/cases/2026/25-1311)
