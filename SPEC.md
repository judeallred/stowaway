# Stowaway — Specification (v0.1)

**Status:** Draft
**Platform:** macOS only (Apple Silicon and Intel, macOS 14+)
**License:** source-available (Prosperity 3.0.0). Free for personal and noncommercial use; work use needs a license after a 30-day trial (§13).

## 1. Problem

Internal storage on a Mac costs a lot. A developer with many repositories checked out piles up gigabytes of *re-creatable* data in each one, mostly `node_modules/` and Rust `target/` directories. That data can be regenerated from the network or by rebuilding, but it's slow to regenerate, so people keep it on disk.

A fast external SSD is a good place for this data. A plain symlink to the external drive is fragile, though. Unplug the drive and every symlink dangles, so `npm install` and `cargo build` fail with confusing errors.

## 2. Goal

Stowaway is a background agent that watches a root folder (e.g. `~/code`) and moves re-creatable dependency and build directories onto an external drive.

- **Drive connected:** dependencies and build artifacts live on the external drive and are used at full speed. Local disk use is close to zero.
- **Drive disconnected:** everything keeps working without any action from the user. The next `npm install` or `cargo build` fills a *local* fallback directory from the network or by recompiling.
- **Drive reconnected:** projects switch back to the external drive, and anything built locally while offline is moved over so the internal disk is freed again.

The user should never have to think about whether the drive is plugged in.

## 3. Scope

### In scope for v1

| Kind | Detected as | Notes |
|---|---|---|
| `node` | a `node_modules/` directory whose parent folder contains `package.json` | npm, yarn (classic and berry `node-modules` linker), pnpm, bun |
| `cargo-target` | a `target/` directory whose parent folder contains `Cargo.toml`, ideally confirmed by the `CACHEDIR.TAG` file Cargo writes | Only workspace roots normally have one |

There are also two **global** kinds. Each one is a single machine-wide cache rather than one directory per project (§4.8):

| Kind | Location | Notes |
|---|---|---|
| `pnpm-store` | the directory reported by `pnpm store path`; on macOS the default is under `~/Library/pnpm/store` | Content-addressable package store |
| `cargo-home` | `$CARGO_HOME/registry/` and `$CARGO_HOME/git/` (default `~/.cargo`) | Two entries. `~/.cargo/bin`, `config.toml` and credentials are never moved |

**Other global caches in v1.** Each of these is a well-known disk hog for its users. Each is a single machine-wide folder that can be fully rebuilt, so the same mechanism works with no per-project scanning. A kind is enabled only if its folder exists on the machine.

| Kind | Location (resolved at `init`, re-checked by `doctor`) | Typical size | Notes |
|---|---|---|---|
| `xcode-derived-data` | `~/Library/Developer/Xcode/DerivedData`, or a custom location if `defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation` sets one | 10–100+ GB | Xcode writes to it constantly while a project is open, so moving it waits until Xcode quits. `Archives/`, `CoreSimulator/Devices` and `iOS DeviceSupport` are never moved: archives hold the symbol files for shipped builds, and simulators hold app data. |
| `gradle-home` | `$GRADLE_USER_HOME/caches` and `.../wrapper/dists` (default `~/.gradle`) | 5–50 GB | A running Gradle daemon holds locks, so the idle check looks for open files. `gradle.properties` and init scripts stay local. |
| `go` | `go env GOMODCACHE` and `go env GOCACHE` | 2–30 GB | The module cache's files are read-only, so moving and deleting them have to make them writable first. |
| `js-caches` | `~/.npm/_cacache`, the yarn classic and berry global caches, `~/.bun/install/cache` | 1–20 GB | bun installs by copy-on-write cloning from its cache, so it has the same same-volume requirement as pnpm (§4.8). |
| `huggingface` | `$HF_HOME/hub` (default `~/.cache/huggingface/hub`) | 10–500 GB | Downloaded models: the biggest single disk hog for ML developers. Files are stored by content hash, and the links inside the cache are relative and stay inside it. |

**Candidates for v1.1.** They're worth doing, but each needs more care:

- **Python:** a project's `.venv` together with the `uv` cache (`~/.cache/uv`). Like pnpm, uv installs by cloning or hard-linking from its cache, so the two have to switch together. Venvs also contain absolute paths, which need testing. ML venvs (torch, CUDA wheels) are often several GB each.
- **Ollama / LM Studio model folders:** very large and re-downloadable, but the server keeps loaded models memory-mapped, so it needs a "stop the server, then switch" step.
- **SwiftPM:** each package's `.build/` folder. It's similar to `cargo-target` but much less common outside Xcode.

**Deliberately excluded:**

- **Docker Desktop's disk image:** it holds containers and volumes that can't be rebuilt, and Docker breaks completely if the image disappears.
- **rustup toolchains:** if the drive is gone, `cargo` itself is gone, and recent rustup versions no longer reinstall a toolchain automatically.
- **CocoaPods `Pods/`:** often committed to the repo.

### Out of scope for v1

- Ecosystems and caches not listed above. The design must make adding a new kind a small, contained change (§4.8).
- Keeping two copies in sync (local and external). Data lives in exactly one place at a time.
- Windows and Linux.
- Network drives (SMB/NFS/NAS). Only locally attached APFS volumes are supported. §4.9 explains why, and describes a narrow version that could come later.

## 4. Core design

### 4.1 Two levels of symlinks

The naive approach links `project/node_modules → /Volumes/Drive/...` directly. That would mean rewriting thousands of symlinks inside working trees every time the drive comes or goes, which is slow and not atomic.

Stowaway instead uses a **stable symlink in the project** that points to a **switchable symlink owned by Stowaway**:

```
~/code/my-app/node_modules
    → ~/.stowaway/links/<entry-id>                      (never changes)

~/.stowaway/links/<entry-id>
    → /Volumes/FastSSD/.stowaway/<machine-id>/store/<entry-id>   (drive online)
    → ~/.stowaway/local/<entry-id>                               (drive offline)
```

- The symlink in the project is created once, when the directory is adopted, and isn't touched again.
- Switching an entry between external and local is one atomic `rename(2)` of a freshly created symlink over `links/<entry-id>`. No process ever sees a missing path.
- The entry ID is embedded in the project symlink. If a repository is moved or renamed, it keeps working, and Stowaway can rebuild its registry by reading the link.

### 4.2 Entry lifecycle

```
            adopt                     drive unmounts
 [real dir] ─────► [external] ◄────────────────────► [local]
     ▲                  │       drive mounts (+ migrate)
     │ release          │
     └──────────────────┘
```

- **Adopt:** move an existing real directory into the store, or create an empty store entry. Then replace the directory with the project symlink.
- **Go offline** (drive removed): point every `links/<id>` at `local/<id>`, creating it empty if needed. This must finish in under a second for hundreds of entries.
- **Go online** (drive mounted), for each entry:
  - If `local/<id>` is empty or missing, point the link back at the external store right away.
  - If `local/<id>` has content, it is newer than the external copy because the user worked offline. **Local wins.** Copy it to `store/<id>.incoming` on the external drive. Once the copy is complete, swap it in place of the stale `store/<id>` and switch the link. Then delete `local/<id>` and the stale copy in the background. While the migration runs, the entry keeps pointing at local, so the project is never in a half-copied state.
- **Release:** turn the entry back into a real local directory. The default is to recreate it empty, because the data can be regenerated; `--copy` brings the contents back. Then remove the store entry.

### 4.3 Detecting the drive

- The volume is identified by **volume UUID**, not by name or mount path. This guards against "FastSSD 1" style renames and against impostor volumes.
- Use DiskArbitration callbacks for appear, disappear and unmount-approval events.
  - On a **normal eject** (the unmount-approval callback fires), switch every entry to local *before* approving the unmount. The agent must not hold any files open on the volume.
  - On a **surprise removal** (the disappeared callback fires), switch to local immediately. Builds that are running at that moment will fail with I/O errors. That's expected; the user re-runs them.
- As a fallback, poll the mount state every few seconds in case a callback is missed. The same handling applies around sleep and wake, when macOS sometimes unmounts external drives.
- **At startup**, reconcile everything: work out whether the drive is present and correct every link to match.

### 4.4 Discovery and auto-adoption

- Use FSEvents to watch the configured roots, and run a full scan at startup and on `stowaway scan`.
- **Pre-adopt new projects.** When a project root appears that has a manifest but no `node_modules`/`target` yet, create the symlink right away. That way the first install writes straight to the store and never touches the local disk.
  - Node: a directory with `package.json` and a lockfile (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`/`bun.lockb`). A `node_modules` that appears later in a workspace member is adopted when it shows up.
  - Cargo: a `Cargo.toml` that isn't a member of a workspace in a parent directory. Workspace members don't get a `target/`.
- **Adopt existing real directories only when they're idle.** Wait until there have been no FSEvents under the directory for a set period (default 2 minutes) and no process has files open in it (check with `lsof +D` or equivalent). Moving a `node_modules` in the middle of `npm install` is never acceptable.
- **Skip:**
  - anything matched by `exclude` globs in the config
  - directories that contain a `.stowaway-ignore` file
  - nested `node_modules` inside another `node_modules`
  - Cargo projects where `CARGO_TARGET_DIR` or `build.target-dir` is set

### 4.5 Tools that delete the symlink

`rm -rf node_modules`, `cargo clean`, and some `npm ci` / package-manager versions remove the **symlink itself**, not its contents, and then create a fresh real directory. This is the most common way the system will drift from its intended state, so it's handled as a normal event, not an error:

1. FSEvents reports that a managed project symlink was removed.
2. The user meant to "clean". The agent moves the backing store entry into a trash area and deletes it asynchronously.
3. If a real directory appears in the same place, the agent re-adopts it once it is idle (§4.4). Until then it takes up local space temporarily.
4. If nothing appears within the idle window, the agent recreates the symlink pointing to an empty entry (pre-adoption).

The agent does **not** try to win a race by recreating the symlink while a tool is running.

The exact behavior of `cargo clean`, `npm ci`, `pnpm install` and `yarn install` on a symlinked directory needs to be checked and recorded in tests (open question §11).

### 4.6 Store layout

```
/Volumes/<Drive>/.stowaway/
  volume.json                 # format version, volume UUID it was initialized for
  <machine-id>/
    store/<entry-id>/         # the actual node_modules / target contents
    trash/                    # pending async deletion
    manifest.json             # entry-id → {kind, last-known project path, sizes, timestamps}

~/.stowaway/
  links/<entry-id>            # switchable symlinks (§4.1)
  local/<entry-id>/           # offline fallback contents
  trash/
  state.db                    # registry (SQLite): entries, kinds, paths, status
  agent.log
```

- Storage is namespaced by `machine-id` so one drive can safely serve more than one Mac.
- The store and local directories are excluded from Spotlight (`.metadata_never_index`) and Time Machine (`tmutil addexclusion`).
- `entry-id` is a random ID (e.g. a ULID), not a hash of the path. This is what makes repository moves work (§4.1).

### 4.7 Copied repositories

If a repository containing managed symlinks is copied (`cp -R`, Finder duplicate), two projects end up pointing at the same entry. When the scanner finds two project symlinks resolving to the same `entry-id`, it keeps the one at the registered path. It gives the other a new, empty entry and re-points that project's symlink.

### 4.8 Global caches

**Each kind is a small declarative description**, so adding an ecosystem doesn't touch the switching, migration or IPC code. A description specifies:

- **how to find the folder:** for project kinds, a scan pattern plus a manifest or lockfile check; for global kinds, a tool command or environment variable plus a default path
- **how to tell when it's idle:** a lock file to hold, process names to check with `lsof`, or "wait for the owning app to quit"
- **what to do on reconnect:** `local-wins-if-complete` (node), `external-wins` (cargo target, DerivedData, Go build cache), or `merge-no-clobber` (content-addressed caches)
- **companion kinds** that must stay on the same volume as this one (pnpm and `node`, bun and `node`, uv and `.venv`)
- **file-handling quirks**, such as read-only files (Go)

The global kinds use the same two-level symlink and the same online/offline switching as per-project entries. For example, `~/.cargo/registry → ~/.stowaway/links/<id> → store/<id>` when the drive is online, or `→ local/<id>` when it is offline. They differ from per-project entries in a few ways:

- **Discovery:** global caches are found from configuration and tool queries, not by scanning the roots: `pnpm store path`, plus `$CARGO_HOME`, falling back to `~/.cargo`. If a cache directory doesn't exist yet, it is pre-adopted (§4.4).
- **Adoption** still waits until the cache is idle. For Cargo, the agent holds Cargo's own package-cache lock (`$CARGO_HOME/.package-cache`, an `flock`) while it adopts, switches or migrates. That keeps a running `cargo fetch`/`build` from seeing the cache change underneath it. pnpm has no equivalent global lock, so for pnpm the agent relies on the idle check and on `lsof`.
- **Reconnecting after offline work:** these are caches, not something the user worked on, so "local wins" (§4.2) is replaced by a **no-clobber merge**. Files that exist in `local/<id>` but not in the external store are copied over, and then the local copy is discarded. This is safe because both stores are effectively immutable once written: pnpm files are addressed by content hash, and Cargo `.crate` files and extracted sources are addressed by name and version. Cargo's registry index cache is the exception, since it can be stale; Cargo refreshes it on its own. The external store is never overwritten.
- **Deleting the cache** (`rm -rf ~/.cargo/registry`): handled the same way as §4.5.

**Why pnpm needs this:** pnpm installs by hard-linking or cloning files from its store into `node_modules/.pnpm`. Neither works across volumes. If only `node_modules` were on the external drive, every pnpm install would fall back to a full copy. With both the store and `node_modules` managed, their real paths are always on the *same* volume: both on the drive when online, both local when offline. pnpm gets its usual hard links in both states.

Consequences of the pnpm design:

- A pnpm project that is *not* managed (excluded, or outside the roots) installs on the internal disk from a store that lives on the external drive. That falls back to copying, so it is slower and uses more space, but it still works. `status` points this out.
- When a pnpm project's offline `node_modules` is migrated back (§4.2), it becomes plain copies on the drive and is no longer hard-linked to the store. Everything still works, but it is duplicated until the next `pnpm install` relinks it (§11).

### 4.9 Network drives (not in v1)

Supporting an SMB or NFS share looks like a small change, since it's "just a different mount point". It isn't, for these reasons:

| Problem | Why it matters here |
|---|---|
| **Latency on per-file operations** | `node_modules` holds 50k–300k small files, and Node, bundlers and package managers check each one. Over SMB every check is a network round trip, so installs and dev-server startup get *slower* than rebuilding locally. That defeats the "fast cache" goal. |
| **Symlinks and hard links** | macOS's SMB client only supports symlinks when the server is set up for them, and hard links and copy-on-write clones are effectively unavailable. That breaks `node_modules/.bin`, pnpm's symlink layout, and the same-volume linking for pnpm, bun and uv (§4.8). |
| **File locking** | Cargo, Gradle and the agent itself (§4.8) depend on `flock`, which isn't reliable on network filesystems. Cargo warns about this on NFS. |
| **Hung mounts** | When a server or Wi-Fi drops out, calls on the mount can block for minutes instead of failing. Builds hang rather than erroring, and the agent's own checks could hang too. Every filesystem call to the volume would need a timeout in a separate thread. |
| **Frequent disconnects** | Wi-Fi roaming and sleep make the drive come and go often. Each flip back to local leaves partial local copies, so migrations and merges would happen constantly. |
| **Identity** | Network volumes have no volume UUID. Identity would have to come from the server URL and share name plus a marker file. |
| **Memory-mapped files** | Native Node modules, Rust proc-macro libraries and models are memory-mapped. A network dropout crashes the processes using them, and that would happen far more often than with a local drive. |

**Verdict:** this is not a small addition, and per-project kinds (`node`, `cargo-target`, `.venv`) should never be supported on network drives.

**A narrow version that might work later:** allow a network share as a second, read-mostly target, only for global kinds made of large files that are stored by content hash: `huggingface`, Ollama models, the Go module cache, the Gradle cache. These are mostly big files written once, which is the access pattern network storage handles well, and keeping models on a NAS is already common. That would still need the identity, timeout and hung-mount work described above, so it's worth considering only after v1 is stable.

## 5. Ecosystem compatibility notes

- **Node module resolution:** Node resolves symlinks to their real path by default, so dependencies resolve each other correctly inside the store. Code inside `node_modules` that walks up looking for project files (some config loaders) could resolve from the store path instead. The store directories must never contain a stray parent `node_modules` or `package.json`.
- **`.gitignore`:** a `node_modules/` pattern with a trailing slash matches directories only, so **git does not ignore a symlink named `node_modules`**. On adoption, Stowaway adds the name to the repo's `.git/info/exclude`. It never edits the tracked `.gitignore`. Cargo's default `/target` pattern already works.
- **pnpm:** the store is managed together with `node_modules` so that hard links keep working (§4.8). Stowaway never edits `.npmrc` or `store-dir`. It moves the existing store location instead, so pnpm's configuration stays untouched.
- **Cargo** follows a symlinked `target/` without problems. Switching between local and external means a full rebuild the first time, which is expected and acceptable.
- **Docker bind mounts** of a project won't follow the symlink into `/Volumes` unless that path is shared too. This is a documented limitation.
- **Filesystem requirement:** the external volume must be **APFS** with the same case-sensitivity as the internal disk. exFAT and HFS+ are rejected at `init`. exFAT can't store the symlinks and permissions that `node_modules` relies on.

## 6. Safety principles

1. Only directories that are **re-creatable by construction** are managed (§3). Source files are never moved or deleted.
2. Every move is copy-then-swap or a same-volume rename. No step leaves an entry partly moved. An interrupted operation is either resumed or rolled back at the next startup.
3. Deletion only ever happens inside Stowaway's own `store/`, `local/` and `trash/` directories.
4. When in doubt, use local. Local disk is wasted rather than ever leaving a dangling link.
5. `stowaway uninstall` must restore every project to plain real directories and remove all symlinks.

## 7. Failure modes

| Situation | Behavior |
|---|---|
| Drive unplugged with no warning | Links switch to local within about 1 second. Builds running at that moment fail and need a re-run. |
| Agent not running and drive missing | Links dangle. `stowaway doctor` detects and fixes this. launchd `KeepAlive` restarts the agent. A future shell-prompt hook could warn about it. |
| Drive mounted but full | Writes fail with ENOSPC. v1 reports this in `status` and in a notification. Automatically falling back to local when free space is low is a future feature. |
| A different drive with the same name | Ignored, because the volume UUID doesn't match. |
| Project deleted | Its entry becomes an orphan. `gc` removes entries that no symlink has referenced for N days (default 14). |
| macOS blocks access to removable volumes (TCC) | `init` explains how to grant the agent "Removable Volumes" / Full Disk Access permission. |

## 8. Interface

### CLI

```
stowaway init --volume /Volumes/FastSSD --root ~/code   # set up config and store, install the LaunchAgent
stowaway status            # drive state, entries, bytes on external vs local, pending migrations, drive performance (§8.1)
stowaway bench [--json]    # run the drive speed test against the internal disk and the external drive (§8.1)
stowaway scan [--dry-run]  # discover and adopt now; dry-run lists what would happen
stowaway adopt <path>      # adopt a specific directory
stowaway release <path> [--copy]
stowaway doctor [--fix]    # check links, registry, store; repair
stowaway gc [--dry-run]
stowaway roots list | add <path> | remove <path> [--copy]   # watched folders (same as the menu bar's Configure Folders)
stowaway eject             # switch to local, list processes holding files on the drive, then eject
stowaway pause | resume    # stop or resume auto-adoption (drive switching keeps working)
stowaway agent             # run the background agent in the foreground (used by launchd)
stowaway uninstall [--copy]
```

### Config — `~/.config/stowaway/config.toml`

```toml
volume_uuid = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
roots = ["~/code"]
kinds = ["node", "cargo-target", "pnpm-store", "cargo-home",
         "xcode-derived-data", "gradle-home", "go", "js-caches", "huggingface"]
exclude = ["~/code/scratch/**"]
idle_seconds = 120
gc_orphan_days = 14
drive_low_space_percent = 10       # "nearly full" warning threshold
```

Only the agent writes this file. The CLI and the menu bar app ask the agent to make changes over IPC (§9.1). If the user edits the file by hand, the agent notices and reloads it. If the agent isn't running, the CLI edits the file directly and the agent picks up the change when it starts.

### Menu bar app

The CLI can do everything. The menu bar app is an optional, friendlier view onto the same agent, and it adds no features of its own. Quitting the menu bar app never stops the agent.

**Icon**

- A monochrome template image, so it fits light mode, dark mode and tinted menu bars.
- Variants for each state:

| State | Icon |
|---|---|
| Drive connected, idle | Normal glyph |
| Transfer in progress (adopting, migrating, merging) | A slight animation, e.g. the glyph's arrow drifting toward the drive, at a few frames per second. It only runs while bytes are moving. If Reduce Motion is on, a static "transferring" glyph is shown instead. |
| Drive disconnected (working locally) | Glyph with a slash or outline |
| Drive nearly full or full | Glyph with a warning badge |
| Agent not running, permissions missing, links dangling, or another error | Glyph with an error badge |
| Paused | Glyph with a pause badge |

**Popover** (opens when the icon is clicked)

1. **Headline:** "Stowaway is offloading **182.4 GB**". This is the space that managed entries take up on the drive for this machine, i.e. space your internal disk isn't using.
   - When the drive is disconnected, the headline becomes: "Drive disconnected — working locally. 182.4 GB is waiting on FastSSD." Below it: "3.1 GB is being used locally until the drive comes back."
2. **Drive row:** the volume name, connected or disconnected, and a free-space bar.
   - A "nearly full" warning appears below `drive_low_space_percent`, and a "full" error when writes are failing with ENOSPC.
   - The row also flags a drive that is connected but isn't APFS or has the wrong UUID.
3. **Activity:** shown only while transfers are running, e.g. "Moving my-app/node_modules to FastSSD — 1.2 of 3.4 GB · 410 MB/s · 8,200 files/s · about 6 s left", plus "and 4 more queued".
4. **Drive performance** (§8.1), e.g. "Thunderbolt 3 (40 Gb/s) · read 2.6 GB/s · write 2.1 GB/s · small files 0.8× internal". When a bottleneck is detected, a hint line appears below it. A "Run speed test" button sits next to the date of the last test.
5. **Problems:** one row per problem the agent knows about: dangling links, missing permissions (with a button that opens the right System Settings pane), a pnpm store that isn't usable, the agent not running (with a Start button), and so on. Clicking a row shows the matching `doctor` details.
6. **Actions:**
   - Configure Folders…
   - Eject Drive: runs the same flow as `stowaway eject`. If programs are still holding files on the drive, it lists them by name.
   - Pause / Resume
   - Open Log
   - Quit Menu Bar App

**Configure Folders window**

- A list of watched roots. Each row shows the path, how many entries are managed under it, and how much of it is offloaded.
- **Add (+)** opens the standard folder picker. Before confirming, the window previews what will happen, e.g. "Found 23 projects, 41.2 GB can be offloaded."
  - A folder is rejected if it is inside or contains an existing root, or is inside `~/.stowaway`, on the external drive itself, or in a system location.
  - A folder on a different disk than your home folder gets a warning, because the local fallback directory needs to live on the same disk as the folder.
- **Remove (−)** asks what to do with the entries under that folder:
  - **Release (default):** links are replaced with empty real folders, and dependencies download again the next time they're needed. This frees the drive copies immediately.
  - **Bring back to this Mac:** copies the contents back to the internal disk. This is only offered when the drive is connected and the internal disk has enough free space; the window shows the amount needed.
  - Any queued transfers under the removed folder are cancelled.

**Notifications** are kept to a minimum: the drive went offline while transfers were running, a migration finished (with the amount of space freed), the drive is full, and agent errors. Each one can be turned off in the menu bar app.

**How sizes are measured:** sizes count the space actually allocated on disk (`st_blocks`), with hard-linked files counted once. They're formatted the way Finder does it, in decimal units. The agent stores sizes in `state.db` and updates them after each transfer, plus a low-priority rescan every few hours. The popover never walks directories itself, so it opens instantly.

### 8.1 Drive performance and bottleneck diagnosis

The point is to answer two questions: "would a faster drive, cable or port speed up my builds?" and "is something slowing my transfers down?" There are three sources of information, from least to most intrusive.

**1. Connection details** (no cost, read whenever the drive mounts). Read from the IORegistry:

- the transport and the speed the connection actually negotiated: USB 2 (480 Mb/s), USB 3.x at 5/10/20 Gb/s, Thunderbolt 3/4/5 or USB4 at 40/80/120 Gb/s
- the drive's protocol (NVMe or SATA)
- whether the volume is encrypted

The negotiated speed is the useful part. It catches the common case of a fast drive running slowly because of the wrong cable, a hub or a slow port.

**2. Measurements during normal use** (always on, low overhead):

- **Transfer throughput:** every migration and adoption records bytes/s and files/s, kept as a rolling history in `state.db`. node_modules transfers are limited by file count, not bytes, so both numbers are shown.
- **Activity during builds:** the agent periodically samples the drive's cumulative I/O counters from the IORegistry (bytes, operations, time spent in I/O) and turns them into current read/write MB/s and a "busy %". If the drive sits near 100% busy during builds, the drive is limiting build speed.

**3. Speed test** (`stowaway bench` or the "Run speed test" button). It runs once automatically the first time a drive is set up, and after that only on request, to avoid wearing out the SSD. It runs on both the external drive and the internal disk so the results can be compared. It creates its test files in the store's `trash/` directory, and they are always deleted afterwards. It uses the `F_NOCACHE` file option so results reflect the drive rather than RAM.

| Test | What it measures | Why |
|---|---|---|
| Sequential write and read (about 1 GB) | Peak bandwidth in MB/s | The ceiling for migrations and large build outputs (`target/`, model files) |
| Small files: create, stat, read and delete about 20k files of 4 KB, in nested folders | Operations per second, and p50/p99 latency | Mirrors `npm install`, Node module loading and Cargo's fingerprint checks. This is the number that matters most for the `node` kind. |
| Random 4 KB reads | IOPS | How incremental builds and indexing will feel |

**Diagnosis.** The agent compares the measurements with the connection's negotiated speed and with the internal disk, and shows at most one plain-language hint:

| What the measurements show | Hint |
|---|---|
| Sequential speed is close to the connection's maximum, and the connection is slow (USB 2, or 5 Gb/s) | "Your connection is the limit. A 10 Gb/s USB or Thunderbolt port, or a better cable, could make this about N× faster." |
| Sequential speed is far below the connection's maximum | "The drive itself is the limit. An NVMe drive in a matching enclosure would be faster." This can also be heat-related throttling, if speed drops over the course of the test. |
| Sequential speed is fine but small-file speed is much worse than the internal disk | "Small-file performance is the limit (common with cheaper SSDs and some enclosures). Installs will be slower than on your internal disk." |
| Transfer throughput is far below the test results | "Transfers are slower than this drive can handle", together with the likely cause the agent can see: transfers being run at low priority by design, other heavy disk activity, or Spotlight indexing. |
| The external drive is at least as fast as the internal disk in all tests | No hint. The status line shows "Faster than or equal to internal". |

- **Where it appears:** the popover's Drive performance row (§8), the "Drive performance" block in `stowaway status`, and the full table in `stowaway bench`.
- **Formats:** `--json` returns the raw numbers. Results are tied to the volume UUID and the connection path, so moving the drive to a different port or cable is recognized as a new setup that may need a fresh test.

## 9. Implementation

### 9.1 Architecture

- **Language:** Rust, built as a single binary. It fits the target audience and ecosystem.
- **macOS APIs:** DiskArbitration (volume events) and FSEvents (watching the roots), both through `objc2` / `core-foundation` bindings or small FFI shims.
- **Workspace layout:**
  - `stowaway`: the binary and all application logic. `unsafe` code is forbidden here.
  - `stowaway-macos`: thin, safe wrappers around DiskArbitration, FSEvents and `copyfile`. This is the only crate allowed to contain `unsafe` code.
  - `xtask`: developer tasks (`cargo xtask ci`, `cargo xtask install-hooks`).
  - `macos-app/`: the menu bar app, written in Swift (see below).
- **Menu bar app:** a SwiftUI `MenuBarExtra` app using the window style, with `LSUIElement` set so it has no Dock icon.
  - **Why Swift for this part:** a native popover, folder picker, Reduce Motion support and `SMAppService` are straightforward in SwiftUI and awkward through Rust's AppKit bindings.
  - **Thin client:** the app contains no logic for moving files or switching links. It only displays what the agent reports and sends it requests.
  - **The Rust-only alternative:** a status item and `NSMenu` built with `objc2-app-kit`, plus a raw AppKit window. That's possible, but it means much more code for a worse result.
- **IPC:** the agent listens on a Unix domain socket at `~/.stowaway/agent.sock`, which only your user account can access.
  - **Protocol:** versioned, newline-delimited JSON.
  - **Requests:** `status`, `roots.list`, `roots.add` (with a dry-run preview), `roots.remove`, `eject`, `pause`, `resume`, `scan`, `doctor`, `bench`.
  - **Events:** `subscribe` returns a stream of state changes, transfer progress, size updates and problems. The menu bar icon and popover are driven entirely by this stream.
  - **The CLI** uses the same socket for commands that need the live agent.
  - **Message types** are defined once in Rust and exported as a JSON Schema. A test in CI checks that the Swift side decodes them.
- **Distribution:**
  - Both are published from the project's own Homebrew tap. `homebrew-core` only accepts open-source licenses, and this project's license isn't one (§13).
  - **Homebrew formula (CLI only):** installs the binary, and `init` installs a plain launchd plist.
  - **Homebrew cask (`.app`):** bundles the Rust binary inside the app and registers the agent with `SMAppService.agent(plistName:)`. The agent then shows up under the app's name in System Settings → Login Items, and permission prompts name the app rather than a bare binary.
- **Process model:** a per-user launchd agent (`~/Library/LaunchAgents/dev.stowaway.agent.plist`) with `RunAtLoad` and `KeepAlive`. No root access and no kernel extension are needed.
- **State:** SQLite in `~/.stowaway/state.db`. A journal of in-flight operations supports crash recovery (§6.2).
- **Copies across volumes:** `clonefile`/`copyfile(3)` with metadata and symlinks preserved. Copies are throttled to low I/O priority so they don't hurt interactive work.

### 9.2 Engineering standards

This tool moves and deletes directories inside people's working trees, so the codebase is held to the strictest settings the Rust toolchain offers from the first commit. Every rule below is enforced by tooling, not by convention.

**Toolchain**

- `rust-toolchain.toml` pins an exact stable version, plus the `rustfmt` and `clippy` components. Upgrades happen in their own commits.
- Rust edition 2024 with dependency resolver 3.
- `Cargo.lock` is committed.

**Compiler and Clippy lints**, set once in the workspace's `[workspace.lints]` and inherited by every crate:

```toml
[workspace.lints.rust]
unsafe_code = "forbid"            # overridden to "deny" + per-module allow only in stowaway-macos
unsafe_op_in_unsafe_fn = "deny"
missing_docs = "warn"
unreachable_pub = "warn"
rust_2018_idioms = { level = "warn", priority = -1 }
unused_qualifications = "warn"

[workspace.lints.clippy]
all = { level = "warn", priority = -1 }
pedantic = { level = "warn", priority = -1 }
nursery = { level = "warn", priority = -1 }
cargo = { level = "warn", priority = -1 }
# Selected `restriction` lints (the whole group contradicts itself, so it is never enabled wholesale):
unwrap_used = "warn"
expect_used = "warn"
panic = "warn"
todo = "warn"
unimplemented = "warn"
dbg_macro = "warn"
print_stdout = "warn"             # output goes through one reporting module, which allows it locally
print_stderr = "warn"
undocumented_unsafe_blocks = "warn"
multiple_unsafe_ops_per_block = "warn"
indexing_slicing = "warn"
as_conversions = "warn"
let_underscore_must_use = "warn"
create_dir = "warn"
exit = "warn"
```

- CI promotes every warning to an error (`-D warnings`). Locally they stay warnings, so work-in-progress code still compiles.
- `clippy.toml` sets `allow-unwrap-in-tests`, `allow-expect-in-tests`, `allow-panic-in-tests` and `allow-indexing-slicing-in-tests`.
- `#[allow(...)]` is never used. Exceptions use `#[expect(lint, reason = "...")]`, so each one carries a written reason and triggers a warning once it is no longer needed. Exceptions apply to the smallest possible scope; crate-wide exceptions need a PR discussion.
- Every `unsafe` block has a `// SAFETY:` comment.
- `rustdoc` is built with `-D warnings`, so broken intra-doc links fail the build.

**Formatting**

- `rustfmt.toml` is committed. `cargo fmt --check` must pass.
- Non-Rust files (TOML, Markdown, YAML) are formatted with `taplo` and `prettier --check`, or left unformatted rather than half-enforced. Decide this before the first PR.

**Swift (menu bar app)** follows the same rules:

- Swift 6 language mode with complete strict concurrency checking.
- `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in CI.
- `swift-format lint --strict`, using a committed `.swift-format` configuration.
- SwiftLint with `--strict` and opt-in rules enabled, including `force_unwrapping`, `force_cast` and `force_try`.
- Exceptions follow the same rule as Rust: one rule per comment, the smallest possible scope, and a reason written in the comment.

**Dependency hygiene**

- `cargo-deny` enforces:
  - known security advisories are an error (RustSec)
  - a license allow-list of permissive licenses only (MIT, Apache-2.0, BSD-2/3-Clause, ISC, Zlib, Unicode-3.0, MPL-2.0). GPL, LGPL and AGPL dependencies are rejected because they can't be combined with the Prosperity license (§13).
  - no duplicate major versions without an explicit exception
  - crates come only from crates.io; git sources are not allowed
- `cargo-machete` flags unused dependencies.

**Pre-commit hooks**

- Hooks live in a tracked `.githooks/` directory. They are enabled with `cargo xtask install-hooks`, which sets `git config core.hooksPath .githooks`. That avoids needing Python or Node just to run hooks.
- `pre-commit` runs `cargo fmt --check`, plus `swift-format lint` on any staged Swift files. It rejects a commit that isn't formatted. It doesn't reformat silently, so the commit always matches what was reviewed. It must finish in about a second.
- `pre-push` runs `cargo clippy --all-targets --all-features -- -D warnings` and the unit tests. These are slower, but this catches failures before CI does.
- The hooks are a convenience. CI is the actual gate: `--no-verify` must never be able to get anything merged.

**Continuous integration** (GitHub Actions)

- Runs on every PR and every push to `main`. Branch protection on `main` requires all jobs to pass and doesn't allow direct pushes.
- Runs on macOS: an Apple Silicon runner, plus an Intel runner for as long as GitHub offers one.
- Each job is a single command that `cargo xtask ci` also runs locally, so local and CI checks can't drift apart:

| Job | Command |
|---|---|
| fmt | `cargo fmt --all --check` |
| clippy | `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings` |
| test | `cargo nextest run --workspace --all-features --locked`, plus `cargo test --doc` |
| integration | the disk-image end-to-end suite (§10), which attaches and force-detaches real APFS images |
| docs | `RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps` |
| deny | `cargo deny check` |
| unused-deps | `cargo machete` |
| app-lint | `swift-format lint --strict --recursive macos-app` and `swiftlint --strict` |
| app-build | `xcodebuild build test` for the menu bar app, with warnings treated as errors, including the IPC decode test against the schema exported from Rust |

- Third-party actions are pinned to commit SHAs. Build caching uses `Swatinem/rust-cache`.
- Coverage (`cargo-llvm-cov`) is reported but doesn't block merging at first. Once M2 is done, the safety-critical modules (switching, migration, the crash-recovery journal) get a coverage floor.

## 10. Testing

- **Simulated drive:** create APFS disk images with `hdiutil create`, then use `hdiutil attach` / `hdiutil detach -force` to simulate plugging in, ejecting and surprise removal. This needs no hardware and can run in CI on macOS runners.
- **End-to-end scenarios:**
  - `npm install`, `pnpm install`, `cargo build` with the drive online, offline, and across an unplug–work–replug cycle
  - `rm -rf node_modules`, `cargo clean`, `npm ci`
  - moving and copying repositories
  - killing the agent in the middle of a migration
- **Property:** after any sequence of events, once the agent has reconciled, no managed link dangles and every entry exists in exactly one location.

## 11. Open questions

1. Confirm exactly how `cargo clean`, `npm ci`, `pnpm`, `yarn berry` and `bun` behave on a symlinked `node_modules`/`target` (§4.5).
2. Should pre-adoption (§4.4) be on by default, or opt-in per root?
3. When an offline local copy is migrated back, should it be skipped if the external copy turns out to be newer? (This could happen if a second Mac used the same entry. That can't happen in v1 because storage is namespaced per machine.)
4. Is a shell-prompt hook worth adding to warn about dangling links while the agent is down?
5. Should we cap local fallback size and evict the least recently used entries while offline?
6. Check that pnpm really does hard-link when the store and `node_modules` are both symlinks that resolve to the same volume. pnpm decides where its store lives based on which disk the project is on, so the result could depend on whether it compares the symlink path or the real path.
7. For pnpm projects, should migrating an offline `node_modules` back be replaced by discarding it and running `pnpm install --offline` from the store? That would restore the hard links instead of keeping duplicated copies (§4.8).

## 12. Milestones

1. **M0 — manual:** The repository setup from §9.2 comes first: toolchain, lints, hooks and CI, all in place and passing before any feature code lands. Then `init`, `adopt`, `release`, `status`, and manual `online`/`offline` switching. Two-level symlinks proven with disk-image tests.
2. **M1 — agent:** launchd agent with DiskArbitration handling, automatic switching, reconcile at startup, and `doctor`. Global caches: `pnpm-store` and `cargo-home`, including Cargo lock handling.
3. **M2 — automatic:** FSEvents discovery, idle-gated adoption, pre-adoption, handling of deleted symlinks, and migrating offline work back to the drive.
4. **M3 — menu bar app:** the IPC socket and event stream, the icon and its states, the popover, the Configure Folders window, eject, drive performance and speed test (§8.1), `SMAppService` registration, and the App Store feasibility prototype (§13.8).
5. **M4 — release:** `gc`, `uninstall`, notifications, `.git/info/exclude` handling, docs, Homebrew tap with the formula and cask, license and contributor agreement in place (§13), public source release.

## 13. Licensing and sales

**Goal:** developers who build it themselves use it free for personal work. Anyone using it for work, with a company that can pay, is strongly encouraged to buy a license, which is a small expense for them and funds independent development. People who aren't developers buy a ready-made app.

**Decisions so far:**

- **License:** Prosperity Public License 3.0.0.
- **Contributor License Agreement:** required, and enforced by a CI check.
- **Enforcement:** honor system, to be reviewed later.

**This isn't "open source" in the formal sense.** The Open Source Definition doesn't allow limiting commercial use, so the project calls itself **source-available** everywhere and never "open source".

*This section is an engineering and product plan, not legal advice. Have a lawyer review the license notice, the CLA and the commercial terms before the public release.*

### 13.1 License: Prosperity 3.0.0

- [Prosperity 3.0.0](https://prosperitylicense.com) allows any noncommercial use without limits. It also allows commercial use for a **30-day trial**, after which the user must buy a private (commercial) license or stop using the software.
- The 30-day trial means a developer can try it at work immediately, without waiting for approval to buy. After that, the license gives them a clear reason to file the expense.
- Other projects using Prosperity sell their private licenses through ordinary storefronts such as Gumroad, so a normal merchant-of-record checkout fits (§13.6).

### 13.2 Where personal use ends and business use begins

The README and the purchase page say this plainly. There is one rule: **if you use it for work, buy a license.** There are no employee-count or revenue thresholds; see Obsidian in §13.5 for why.

- An individual developer on a personal Mac, working on personal projects: **free**.
- An employee using it on a work Mac, or on work repositories on any Mac: **work**. The employer buys a license after the 30-day trial.
- A freelancer or contractor using it on client work: **work**.
- Students, teachers, nonprofits and public-sector organizations: **free**, under the license's noncommercial terms.

### 13.3 Contributor License Agreement

Selling private licenses requires the maintainer to hold the right to license every contribution commercially.

- External contributors sign a CLA once, before their first PR is merged. They keep their copyright and grant the maintainer the right to sublicense their contribution, including under commercial terms.
- **CI check:** the CLA Assistant GitHub Action (`contributor-assistant/github-action`). It comments on the PR with a link to the CLA, records signatures in a dedicated branch of the repository, and reports a status check. Branch protection requires that check, alongside the jobs in §9.2. Maintainers and bots are on an allow-list.
- `CONTRIBUTING.md` explains the CLA and links to its full text.

### 13.4 Third-party dependencies

- Only permissive licenses are allowed, and `cargo-deny` enforces this in CI (§9.2). Copyleft dependencies would conflict with both the Prosperity license and the commercial license.
- `cargo-about` generates `THIRD_PARTY_LICENSES`, which ships with every release and is linked from the app's About window.

### 13.5 Prior art

| Product | Model | Lesson for us |
|---|---|---|
| [Sublime Text](https://en.wikipedia.org/wiki/Sublime_Text) | Unlimited free evaluation with an occasional nag. A one-time personal license, and an annual per-seat business license. | An honor system with gentle reminders has supported a small company for over a decade. |
| [OrbStack](https://docs.orbstack.dev/licensing) | A macOS developer tool. Free for personal use; freelance and business use needs a per-user license after a 30-day trial. Users say which kind of use applies when they sign up. Organizations can buy licenses in bulk. | The closest match to our model. Asking "personal or work?" once, plus self-serve bulk buying, works for a Mac developer tool. |
| [Obsidian](https://obsidian.md/blog/free-for-work/) | Required a commercial license at companies with 2+ employees, on the honor system. In February 2025 that became optional because "the terms were confusing". | Keep the rule to one sentence. Anything with thresholds or edge cases invites confusion and nobody buys. |
| [Maccy](https://apps.apple.com/app/maccy/id1527619437) | MIT-licensed and free to build from source. The same app sells on the Mac App Store ($9.99) to fund development. | Confirms the "build it yourself free, or buy the convenient build" split for a small Mac utility. |

### 13.6 Purchase flow

The aim is to keep the free path completely smooth for hobbyists, and to make the work path a two-minute expense report.

- **Price:** per seat, low enough to expense without approval at most companies. Exact price and billing model still to decide (§13.10).
- **Checkout:** through a **merchant of record**, which collects and pays VAT and sales tax worldwide and issues invoices with the company name and tax ID that expense systems require. Candidates: Paddle, Lemon Squeezy, Polar. All three charge roughly 5% + $0.50 per transaction. Polar is aimed at open-source projects; Paddle is the most established.
- **Multiple seats** can be bought in one checkout. For 20+ seats there's an invoice / purchase-order path.
- **The receipt is a license certificate:** a PDF naming the licensed company and the number of seats. Procurement and auditors ask for exactly this.
- **"Ask my company to pay" button** on the purchase page. It produces either:
  - a ready-made email to a manager with the price, a link and a one-line justification ("it saves several GB per repo on our Macs, and funds an independent developer"), or
  - a payment link the manager can pay directly.
- **Reminders in the product.** These are honor-system only: they never block or limit anything.
  - At first run (`init` and the app's onboarding), the user is asked once: **Personal or Work?** Choosing Personal means no further prompts. Choosing Work shows the purchase link and a note about the 30-day trial.
  - For Work users without a recorded purchase after 30 days: a single footer line in the popover and in `stowaway status`, e.g. "Using this at work? Expense a license →". There are no pop-up dialogs and no notifications.
  - "I've bought a license" stores the order ID locally. The footer disappears and About shows "Licensed to <company>". This isn't verified (honor system).
  - The reminder never appears in `--json` output or when the CLI isn't running in an interactive terminal.
- **README / website wording:** "Free for personal use. Using it at work? Your company should buy a license: it costs $X, takes two minutes to expense, and funds independent software."

### 13.7 Distribution channels

| Channel | For | Price |
|---|---|---|
| Source on GitHub (`cargo build`, `xcodebuild`) | Developers who build it themselves | Free for personal use; work use buys a license (§13.6) |
| Homebrew tap (formula and cask, §9.1) | Developers | Same as above |
| **Mac App Store** | Non-developers, and anyone who wants a signed, auto-updating app | Paid upfront. An App Store purchase **includes a commercial license for one user**, stated in a custom EULA, so companies can also buy it this way, including in bulk through Apple Business Manager. |
| Direct download (notarized DMG, sold through the merchant of record) | Fallback if the App Store build isn't feasible (§13.8). Also possible on Setapp | Same price as the App Store |

### 13.8 Risk: whether the App Store version is feasible

Every Mac App Store app must be sandboxed. Stowaway does several things the sandbox restricts:

- **Writing outside the app's container:** symlinks in `~/code`, `~/.cargo`, `~/Library/pnpm`, `~/Library/Developer/Xcode` and on the external drive. A sandboxed app can only reach folders the user has chosen, through security-scoped bookmarks. Symlinks that need to keep working across restarts are known to be difficult in the sandbox.
- **Home-folder paths:** a sandboxed app's home directory is redirected into its container, so `~/.stowaway/links` would end up inside the container. On recent macOS, other apps (node, cargo) touching another app's container trigger "access data from other apps" permission prompts.
- **Background agent and CLI:** a persistent launch agent, plus a CLI on `PATH`. The App Store doesn't allow bundling command-line tools that aren't sandboxed, and requires apps to work without installing extra components.
- **Inspecting other processes:** checking other programs' open files with `lsof`, and ejecting volumes.

Plan:

1. In M3, build a **feasibility prototype**: a sandboxed build using security-scoped bookmarks for the roots, the global cache folders and the drive. The links directory lives in a folder the user grants. Background work runs as an `SMAppService` login item inside the sandbox, and open files are checked via `proc_pidinfo` instead of `lsof`.
2. If the prototype works, ship the App Store build. It can have fewer features than the direct version, e.g. no CLI on `PATH`.
3. If it doesn't, non-developers buy the **direct download** through the merchant of record: the same app, signed and notarized, with Sparkle for updates. This is the usual route for Mac developer tools that can't be sandboxed.

### 13.9 Repository and package files

- `LICENSE`: the Prosperity 3.0.0 text, with the required notice naming the licensor and the contact for private licenses.
- `LICENSE-COMMERCIAL.md`: commercial terms, seat definition and how to buy.
- `CLA.md` and `CONTRIBUTING.md` (§13.3).
- `Cargo.toml`: `license-file = "LICENSE"` in `[workspace.package]`. This avoids depending on SPDX tools recognizing Prosperity, and it satisfies Clippy's `cargo_common_metadata` lint.
- crates.io: don't publish. Distribute through GitHub, the tap and the paid channels.

### 13.10 Open decisions

1. Pricing: annual or one-time, and the per-seat price. The App Store price should match the direct price.
2. Which merchant of record: Paddle, Lemon Squeezy or Polar.
3. The outcome of the App Store prototype (§13.8).
4. Who holds the copyright: you personally, or an LLC. An LLC is the usual choice for selling licenses and for the App Store developer account.
5. Product name: decided. It is **Stowaway** (§14).

## 14. Brand and positioning

This section is the source for the landing page, the App Store listing, the README and the in-app wording.

### 14.1 Name

- **Product name:** Stowaway. It is written with a capital S in prose.
- **Lowercase `stowaway`** is used for the command, the Homebrew formula and cask, the crate and the repository name, and the paths `~/.stowaway` and `~/.config/stowaway`.
- **The metaphor:** a stowaway rides along in the ship's hold, out of sight. Your dependencies and build files ride along on the external drive, out of your internal disk's way. The name also nods to GNU Stow, the classic symlink-farm manager.
- **Never in the product name, App Store name or logo:** "Cargo", "Rust", "Node.js", "npm", "Xcode", "Swift", or any Apple or Microsoft feature name (Sidecar, Time Machine, Dev Drive). These are trademarks. They may appear in descriptive copy ("works with Cargo, npm, pnpm and Xcode"), never as part of the brand.
- **Checks before launch:** the name is available in App Store Connect, the name `stowaway` is free on Homebrew and crates.io, and a USPTO/EUIPO trademark search for software (class 9) is clear. If `stowaway` is taken as a CLI name, the fallback is `stow-away` for the command only.
- **This repository** is currently named `space-shifter`. Rename it to `stowaway` before the public release.

### 14.2 App Store listing

| Field | Text | Limit |
|---|---|---|
| Name | **Stowaway – Free Dev Disk Space** | 30/30 |
| Subtitle | **Offload node_modules to an SSD** | 30/30 |
| Keywords | `xcode,deriveddata,cargo,gradle,storage,cleaner,external,drive,cache,developer,huggingface` | under 100 |
| Category | Developer Tools (primary), Utilities (secondary) | |

- Words already in the name or subtitle are never repeated in the keywords field; repeating them doesn't improve ranking.
- The cleaner alternative, if the brand matters more than search ranking, is the name "Stowaway" with the subtitle "Free disk space for developers".

### 14.3 Positioning

- **One-liner:** Keep your dependencies and build files on an external SSD, and keep working when it's unplugged.
- **For:** developers on Macs with expensive, limited internal storage and many repositories checked out (Rust, JavaScript/TypeScript, Swift/iOS, Android, Go, ML).
- **The problem, in their words:** "My 512 GB Mac is full, and half of it is `node_modules`, `target/` and DerivedData."
- **What sets it apart:**

| Alternative | What it does | Why Stowaway is different |
|---|---|---|
| Cleaners (npkill, DevCleaner, `cargo clean`) | Delete the files | Stowaway keeps the cache, so there's no slow rebuild and no re-download |
| A hand-made symlink to an external drive | Moves the files | Breaks the moment the drive is unplugged. Stowaway falls back to the local disk automatically |
| A bigger internal SSD | Fixes the problem | Apple's storage upgrades cost several times the price of an equivalent external drive |

### 14.4 Messaging pillars

These are the landing page sections, in order:

1. **Free up gigabytes of space.** "Stowaway is offloading 182 GB" as the hero number, shown as a real screenshot of the menu bar popover.
2. **Unplug at any time.** When the drive is gone, your next `npm install` or `cargo build` works locally, as if nothing happened. When you plug it back in, everything moves back automatically.
3. **No setup per project.** Point it at `~/code` once. New projects are handled automatically.
4. **Works with your stack.** A logo-free list of the supported tools: `node_modules`, pnpm, Cargo `target/` and registry, Xcode DerivedData, Gradle, Go, Hugging Face models.
5. **Know whether your drive is the bottleneck.** Speed test and plain-language hints (§8.1).
6. **Safe by design.** It only touches files that can be rebuilt. Source code is never moved. Uninstalling puts everything back (§6).
7. **Pricing.** Free for personal use. "Using it at work? Expense a license." (§13.6)

### 14.5 Voice

- **Plain, calm and specific.** Use numbers ("182 GB", "Thunderbolt 3, 2.6 GB/s"), not adjectives ("blazing fast").
- **Address the reader as "you"** and the product as "Stowaway". Avoid "we" in the UI.
- **Developer-literate without being cute.** Real paths and commands appear in the copy (`node_modules`, `cargo build`), shown as code.
- **Errors and hints say what happened and what to do** in one or two short sentences (see the hint table in §8.1).
- **Asking for payment** is friendly and short, never guilt-tripping, and never interrupts work (§13.6).

### 14.6 Visual identity

- **App icon concept:** a ship's crate or trunk with a small arrow going into it, or an external drive shaped like a ship's hold. It should read clearly at 16 px in Finder and in Login Items.
- **Menu bar glyph:** a simplified one-colour crate outline as a template image, with the state variants in §8. The "transferring" animation is the arrow sliding into the crate, at a few frames per second.
- **Colour:** for the landing page and app accent, a deep nautical blue with one warm signal colour (brass or amber) for warnings and the "offloading" number. The menu bar glyph stays monochrome.
- **Type:** the system fonts in the app (SF Pro, SF Mono). The landing page uses one sans-serif headline font plus a monospace font for paths and commands.
- **Screenshots** show the real popover with realistic numbers, in both light and dark mode, and the Configure Folders window.

### 14.7 Brand assets to produce

- [ ] App icon (macOS icon set, all sizes) and an SVG master
- [ ] Menu bar template glyphs: idle, the transferring animation frames, disconnected, warning, error, paused
- [ ] Wordmark: "Stowaway" set in the headline font
- [ ] Landing page (the sections in §14.4) and the purchase page (§13.6)
- [ ] App Store screenshots and preview text (§14.2)
- [ ] README header, plus the GitHub social preview image (1280×640)
