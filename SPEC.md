# Stowaway — Specification (v0.1)

**Status:** Draft
**Platform:** macOS only (Apple Silicon and Intel, macOS 14+)
**License:** source-available (Prosperity 3.0.0). Free for personal and noncommercial use; work use needs a license after a 30-day trial (§13).

## 1. Problem

Internal storage on a Mac costs a lot. A developer with many repositories checked out piles up gigabytes of *re-creatable* data in each one, mostly `node_modules/` and Rust `target/` directories. That data can be regenerated from the network or by rebuilding, but it's slow to regenerate, so people keep it on disk.

A fast external SSD is a good place for this data. A plain symlink to the external drive doesn't work, though. Unplug the drive and every symlink dangles, and current npm and pnpm refuse a symlinked `node_modules` in the first place (§4.0).

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
| `cargo-target` | the build folders (`deps/`, `incremental/`, `build/`) inside a `target/` directory whose parent folder contains `Cargo.toml`, confirmed by the `CACHEDIR.TAG` file Cargo writes. The rest of `target/`, including the programs it builds, stays local (§4.11). | Only workspace roots normally have one |
| `next` | a `.next/` directory whose parent folder contains `package.json`; pre-adopted when a `next.config.*` file is there | Build output plus webpack/Turbopack caches. `next build` empties the folder but keeps it, so the mount survives. On reconnect a local production build (`BUILD_ID`) wins; a dev-server cache is discarded. |
| `venv` | a `.venv/` directory containing `pyvenv.cfg` whose parent folder contains `pyproject.toml` | Never pre-adopted: uv won't create a venv in a non-empty folder, and a mounted image always holds volume metadata. The venv's absolute paths stay valid because the image is mounted at the same path. uv installs by cloning from its cache, which falls back to copying across filesystems (§4.8). Tools that delete and recreate `.venv` hit the same "Resource busy" as `rm -rf node_modules`. |

There are also two **global** kinds. Each one is a single machine-wide cache rather than one directory per project (§4.8):

| Kind | Location | Notes |
|---|---|---|
| `pnpm-store` | the directory reported by `pnpm store path`; on macOS the default is under `~/Library/pnpm/store` | Content-addressable package store |
| `cargo-home` | `$CARGO_HOME/registry/` and `$CARGO_HOME/git/` (default `~/.cargo`) | Two entries. `~/.cargo/bin`, `config.toml` and credentials are never moved |

**Other global caches in v1.** Each of these is a well-known disk hog for its users. Each is a single machine-wide folder that can be fully rebuilt, so the same mechanism works with no per-project scanning. A kind is enabled only if its folder exists on the machine.

| Kind | Location (resolved at `init`, re-checked by `doctor`) | Typical size | Notes |
|---|---|---|---|
| `xcode-derived-data` | `~/Library/Developer/Xcode/DerivedData`, or a custom location if `defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation` sets one. Only its intermediates and caches are stowed; built apps in `Build/Products` stay local (§4.11). | 10–100+ GB | Xcode writes to it constantly while a project is open, so moving it waits until Xcode quits. `Archives/`, `CoreSimulator/Devices` and `iOS DeviceSupport` are never moved: archives hold the symbol files for shipped builds, and simulators hold app data. |
| `gradle-home` | `$GRADLE_USER_HOME/caches` and `.../wrapper/dists` (default `~/.gradle`) | 5–50 GB | A running Gradle daemon holds locks, so the idle check looks for open files. `gradle.properties` and init scripts stay local. |
| `go` | `go env GOMODCACHE` and `go env GOCACHE` | 2–30 GB | The module cache's files are read-only, so moving and deleting them have to make them writable first. |
| `js-caches` | `~/.npm/_cacache`, the yarn classic and berry global caches, `~/.bun/install/cache` | 1–20 GB | bun installs by copy-on-write cloning from its cache, so it has the same same-volume requirement as pnpm (§4.8). |
| `npx` | `~/.npm/_npx` | 1–5 GB | Packages `npx` installed to run. `npx` installs them again when they're missing. |
| `huggingface` | `$HF_HOME/hub` (default `~/.cache/huggingface/hub`) | 10–500 GB | Downloaded models: the biggest single disk hog for ML developers. Files are stored by content hash, and the links inside the cache are relative and stay inside it. |

**Candidates for v1.1.** They're worth doing, but each needs more care:

- **The `uv` cache** (`~/.cache/uv`), to pair with the `venv` kind. ML venvs (torch, CUDA wheels) are often several GB each.
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

### 4.0 What prototyping changed (2026-10-04)

The first draft of this spec put each managed folder behind a symlink that pointed at the external drive. Testing that against real tools on an APFS disk image ruled it out for `node_modules`:

| Experiment | Result |
|---|---|
| `npm install` (npm 11.3) with `node_modules` as a symlink to the drive | npm prints "Removing non-directory node_modules", deletes the symlink and reinstalls everything into a real local folder, **on every install**, even when nothing changed. |
| `pnpm install` (pnpm 10.17) with `node_modules` as a symlink | Fails with `ENOTDIR: not a directory, mkdir node_modules`. Node's own recursive `mkdir` rejects a symlinked directory. |
| `cargo build` with `target/` as a symlink | Works, but `cargo clean` deletes the symlink ("Removed 1 file"), so the next build writes to the internal disk. |
| pnpm with `--store-dir` pointing at a symlink | Works. |
| An APFS volume or disk image **mounted at** `node_modules` | npm, `npm ci`, pnpm and Node resolution all work, and a second `npm install` says "up to date". Tools see a real directory. |
| Force-detaching the drive while a project image is mounted | The mount disappears and the empty local folder underneath shows through. `npm install` then works offline into the local folder. |
| APFS volumes per container | About one per 512 MiB of container size, capped at 100 (a 2 GB test container allowed 4). Too few for one volume per project. |
| Sparse-bundle disk images per project | No count limit found. Each costs ~1 s to create, ~0.5 s to attach, ~8 MB on disk when empty, and one `diskimagesiod` process (~10 MB RSS). 60 attached at once worked. |
| Deleting files inside an image | The image doesn't shrink, and `hdiutil compact` reports "Function not implemented" for both APFS and HFS+ images on macOS 26. |
| Renaming a repository that contains a mounted image | Works; the mount follows the rename. |
| `rm -rf node_modules` or `cargo clean` on a mounted folder | All contents are deleted, then removing the folder itself fails with "Resource busy" (exit code 1 / 101). |
| Force-detaching the drive with images attached | The images' mounts vanish, but the image devices stay attached as stale entries and block re-attaching until they're detached with `hdiutil detach -force`. |

**Consequences:**

- Every managed folder becomes a **disk image stored on the external drive and mounted at the folder's own path**.
- There are no symlinks in working trees. That removes most of the compatibility problems found in review: module resolution, relative symlinks in workspaces, hoisting, Vite/Turbopack refusing paths outside the project, and `.gitignore` not matching a symlink.

### 4.1 Mounted entry images

Each managed folder (an **entry**) has its own sparse-bundle disk image on the external drive:

```
/Volumes/FastSSD/.stowaway/<machine-id>.noindex/images/<entry-id>.sparsebundle
```

- **Drive online:** the image is attached with `hdiutil attach -nobrowse -mountpoint <folder>`, so `~/code/my-app/node_modules` is the image's volume. Tools, Node's module resolution, git and Time Machine all see an ordinary directory. Time Machine skips mount points, so these folders also stop being backed up.
- **Drive offline:** nothing is mounted, and the real folder on the internal disk underneath the mount point is what tools see. It starts empty, so the next `npm install` or `cargo build` fills it from the network or by compiling. **This needs no action from the agent.** If the agent isn't running or crashes, the fallback still works.
- **Image format:** each image is created as APFS, sized to the external volume's capacity. It's sparse, so it only takes the space actually written. It matches the internal disk's case sensitivity. A `.metadata_never_index` file at the image's volume root keeps Spotlight out of its contents. On the drive, the per-machine folder is named `<machine-id>.noindex`, so Spotlight also skips the image files themselves instead of re-examining them on every write. (`.metadata_never_index` is only honored at the root of a volume, so it can't do this for a folder.)
- **Identity:** the entry ID is the image's filename. The agent can match mounts to entries by reading the mount table (`hdiutil info`), so if a repository is moved, the agent picks up its new path automatically.

### 4.2 Entry lifecycle

```
 [real folder] ──adopt──► [mounted] ◄──drive gone / drive back──► [local fallback]
       ▲                      │
       └────── release ───────┘
```

- **Adopt an existing folder:**
  1. Create the image, then attach it at a private staging mount point (`~/.stowaway/staging/<id>`).
  2. Copy the folder's contents into the image. Before and after the copy, take a fingerprint of the source (file count, total size, newest modification time). If anything changed during the copy, discard the copy and retry later.
  3. Empty the original folder, detach the image from staging, and attach it at the folder's path.

  This only happens when the folder is idle (§4.4).
- **Pre-adopt a new project:** create an empty image and mount it at a new, empty folder, so the very first install writes straight to the drive.
- **Drive disappears:** the mounts vanish by themselves. The agent detaches the stale image devices (`hdiutil detach -force`) so the images can be re-attached later.
- **Drive comes back:** for each entry, look at the local folder underneath the mount point:
  - **Empty:** attach the image.
  - **Not empty**, meaning the user worked offline: apply the kind's reconnect policy (§4.8). The image is attached at the staging point, the policy is applied, the local folder is emptied, and the image is moved to the project path. This only happens once the local folder is idle; until then the entry stays local.

  | Policy | Used by | What happens |
  |---|---|---|
  | `local-wins-if-complete` | `node` | If the local folder holds a finished install (`.package-lock.json`, `.modules.yaml`, `.yarn-state.yml` or `.yarn-integrity`), the image's contents are replaced with the local ones. Otherwise the local folder is discarded. This prevents a half-finished or tool-cache-only offline folder from wiping a complete install on the drive. |
  | `merge-local-wins` | `cargo-target`, DerivedData | Local files are copied over the image's, and the image's other files are kept. These build folders' records (Cargo's `.fingerprint/`, Xcode's products) stay local and already describe the offline build, so discarding its outputs would leave records pointing at files that are gone and the build broken until a clean (§4.11). |
  | `merge-no-clobber` | content-addressed global caches | Files that exist locally but not in the image are copied in; nothing in the image is overwritten. |
- **Release:**
  1. Detach the image.
  2. Optionally copy its contents back (`--copy`).
  3. Delete the image.
  4. The folder becomes a plain local folder again.

### 4.3 Detecting the drive

- **Identity:** the volume is identified by **volume UUID**, recorded at `init` and checked against `.stowaway/volume.json` on the drive. The volume name and mount path are never trusted, which guards against renames like "FastSSD 1" and against a different drive with the same name.
- **Polling:** the agent polls the mounted volumes every two seconds. It's cheap, and it covers sleep/wake and missed notifications. DiskArbitration callbacks can replace polling later. The unmount-approval callback is what will let a Finder eject detach the images first.
- **Ejecting:** an eject has to detach every image first, because otherwise their open backing files block it. `stowaway eject`, and the menu bar's Eject command, detach the images (naming any process that is holding files open), then eject the drive.
- **At startup**, the agent reconciles everything: it attaches images for entries whose local folders are empty, and queues reconnect work for the rest.
- **Self-healing:** problems the agent can fix are fixed, not reported as chores. It reconciles every minute, including between folders during a long adoption pass. A copy holds the engine lock, so every 30 seconds it also reattaches other entries whose mount vanished while their folder stayed empty. If Stowaway's folders on the drive are deleted, they're recreated the next time the drive is located. The popover only lists what still needs the user, such as a permission to grant.

### 4.4 Discovery and auto-adoption

- **Scanning:** the agent watches the configured roots with FSEvents, and also runs a full scan at startup and on `stowaway scan`. The scan never descends into `node_modules`, `target`, `.git` or mounted entries.
- **Agent worktrees:** coding agents check out whole repositories as worktrees, each with its own `node_modules` and `target/`. `~/.cursor/worktrees` and `~/.codex/worktrees` are scanned as extra roots whenever they exist, and Claude Code's `<repo>/.claude/worktrees/*` are scanned as separate projects, so the repository's own `node_modules` doesn't count as their ancestor. `exclude` patterns turn this off.
- **Node candidates:** a `node_modules` next to a `package.json`, adopted only when no ancestor folder up to the root has its own `node_modules`.
  - Workspace members' nested `node_modules` depend on finding packages hoisted to the root, so they stay local; they're usually small. With mounts this would technically work, but each extra image costs a process and an attach.
  - **Pre-adoption** happens when the folder doesn't exist yet and a lockfile is present (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`).
- **Cargo candidates:** a `target` next to a `Cargo.toml`, adopted when it contains Cargo's `CACHEDIR.TAG`.
  - Pre-adoption only happens where `Cargo.lock` exists. That skips test fixtures and workspace members.
  - Projects are skipped if `CARGO_TARGET_DIR` (recorded at `init`) or `build.target-dir` in any `.cargo/config.toml` up the folder tree redirects the target folder.
- **Never adopt:**
  - a folder that contains files tracked by git (checked with `git ls-files`), e.g. GitHub Actions repositories that commit `node_modules`
  - anything matched by `exclude` globs in the config
  - anything under a folder containing `.stowaway-ignore`
  - anything below a minimum size (default 50 MB). A small folder isn't worth an image and a process.
- **Idle check:** no file inside has been modified for `idle_seconds` (default 120), and no process has files open inside it. Open files are checked with a single `lsof` run filtered by path, rather than the slow `lsof +D`.

### 4.5 Deleting a mounted folder

Because the folder is a mount point, deleting the folder itself (as opposed to its contents) fails with "Resource busy":

| Command | Effect |
|---|---|
| `rm -rf node_modules` | Deletes all contents, then prints `Resource busy` and exits 1. A chained `rm -rf node_modules && npm i` stops at the error. |
| `cargo clean` | Deletes all contents, then reports `Resource busy (os error 16)` and exits 101. |
| `npm ci` | Works. npm empties `node_modules` rather than deleting it. |
| `rm -rf my-repo` (deleting the whole repository) | Deletes everything except the mounted folders, then fails on them and on the repository folder itself. |

Mitigations:

- **`stowaway clean [path]`:** empties managed folders under a path without the error. The docs recommend `rm -rf node_modules/*` or `stowaway clean`.
- **Deleted repositories:** when the agent sees that a mounted entry's manifest (`package.json`, `Cargo.toml`) is gone, it detaches the image and deletes it. It then removes the now-empty mount-point folder, and removes empty parent folders up to (but not including) the root, but only if they're empty. A second `rm -rf my-repo` then succeeds, and usually the agent has already finished the job.
- **`stowaway release <path>`** returns a folder to normal before a user deletes it on purpose.

### 4.6 Store layout

```
/Volumes/<Drive>/.stowaway/
  volume.json                 # format version, volume UUID it was initialized for
  <machine-id>.noindex/       # .noindex keeps Spotlight out of the images
    images/<entry-id>.sparsebundle
    trash/                    # images pending deletion, speed-test scratch files

~/.stowaway/
  staging/<entry-id>/         # private mount points used while copying
  state.db                    # registry (SQLite): entries, kinds, paths, status, sizes, history
  engine.lock                 # held by whichever process is changing entries (agent or CLI)
  agent.sock                  # IPC socket (§9.1)
  stowaway-agent.log
```

- Storage is namespaced by `machine-id` (`IOPlatformUUID`) so one drive can serve more than one Mac.
- **Serialization:** every operation that changes entries holds `engine.lock`, whether it comes from the agent or from the CLI, so they never race.

### 4.7 Moved, copied and deleted repositories

- **Moved or renamed:** the mount follows the move. The agent updates the entry's path from the mount table.
- **Copied** (`cp -R`, Finder duplicate): the copy contains a plain, unmanaged copy of the folder's contents, because `cp` copies through mount points. That's an ordinary unmanaged project, which the agent adopts like any other.
- **Deleted:** see §4.5.
- **Garbage collection:** `gc` deletes images whose entries have no project path anymore and haven't been seen for `gc_orphan_days`.

### 4.8 Kinds and global caches

**Each kind is a small declarative description**, so adding an ecosystem doesn't touch the mounting, migration or IPC code. A description specifies:

- **how to find the folder:** for project kinds, a folder name plus a manifest or lockfile check; for global kinds, an environment variable plus a default path
- **when it can be pre-adopted**
- **how to tell when it's idle:** a lock file to hold, or `lsof` plus modification times
- **what to do on reconnect:** `local-wins-if-complete`, `merge-local-wins` or `merge-no-clobber` (§4.2)
- **file-handling quirks**, such as read-only files (Go)

Global caches use the same mounted images as project folders, so `~/.cargo/registry` is the mount point of its image. Differences:

- **Discovery:** locations come from configuration recorded at `init`, when the CLI runs with the user's own environment. The background agent can't see that environment, which is why the locations are recorded rather than looked up later. A global kind added in a later version has its locations recorded the first time the CLI or agent opens the config afterwards. For pnpm, `pnpm store path` returns a versioned folder (`.../store/v10`); Stowaway manages its parent (`.../store`), because different projects can use different pnpm versions.
- **Cargo:** the agent holds Cargo's package-cache lock (`$CARGO_HOME/.package-cache`) while adopting or migrating `cargo-home` entries.
- **Reconnect:** `merge-no-clobber`, because the contents are effectively write-once. pnpm and Cargo `.crate` files are addressed by content hash or by name and version.

**pnpm, bun and uv:** these install by hard-linking or cloning files from a global store. That only works within a single filesystem, and every image is its own filesystem. So when the store and `node_modules` are both managed, pnpm falls back to copying files into each project's image. Everything still works; the cost is extra space on the cheap external drive instead of the internal disk. The pnpm store's own image keeps the internal disk free of the store.

### 4.9 Network drives (not in v1)

Supporting an SMB or NFS share looks like a small change, since it's "just a different mount point". It isn't, for these reasons:

| Problem | Why it matters here |
|---|---|
| **Latency on per-file operations** | `node_modules` holds 50k–300k small files, and Node, bundlers and package managers check each one. Over SMB every check is a network round trip, so installs and dev-server startup get *slower* than rebuilding locally. That defeats the "fast cache" goal. |
| **Images on a network share** | Disk images stored on SMB/NFS are fragile, and a network dropout behind an attached image can hang every process using it. |
| **File locking** | Cargo, Gradle and the agent itself depend on `flock`, which isn't reliable on network filesystems. Cargo warns about this on NFS. |
| **Hung mounts** | When a server or Wi-Fi drops out, calls on the mount can block for minutes instead of failing. Builds hang rather than erroring, and the agent's own checks could hang too. |
| **Frequent disconnects** | Wi-Fi roaming and sleep make the drive come and go often, which means constant reconnect work. |
| **Identity** | Network volumes have no volume UUID. Identity would have to come from the server URL and share name plus a marker file. |

**Verdict:** this is not a small addition, and per-project kinds should never be supported on network drives.

**A narrow version that might work later:** allow a network share as a second, read-mostly target, only for global kinds made of large files that are stored by content hash: `huggingface`, Ollama models, the Go module cache, the Gradle cache. These are mostly big files written once, which is the access pattern network storage handles well, and keeping models on a NAS is already common. It would still need the identity, timeout and hung-mount work described above, so it's worth considering only after v1 is stable.

### 4.10 Image housekeeping and costs

- **Images don't shrink when files are deleted.** Each one stays at the largest size it has ever reached. The agent compares an image's size on the drive with the space used inside it. When the image is idle and bloated (more than 1.5× the used space and over 1 GB of waste), the agent rebuilds it: a fresh image, a copy of the contents, then a swap. `stowaway compact` does the same on demand.
- **Memory and attach time:** each attached image runs a `diskimagesiod` process (about 10 MB RSS) and takes about 0.5 s to attach. `status` shows the count. The minimum size for adoption (§4.4) keeps small folders out. A later version can detach images for projects that have been dormant for a long time; that's a config option, off in v1.

### 4.11 Build products stay local

A build folder mixes two kinds of files. **Intermediates** are what the compiler needs to build: compiled dependencies, incremental caches, build-script output and indexes. **Products** are what the build makes: the programs and apps you run. Intermediates are almost all of the space, and are only needed while building. Products are small, and are needed whenever you run them, with or without the drive. Arbvark's `target/`, for example, is 45 GB, of which the programs (`debug/arbvark`, `release/arbvark`) are about 110 MB.

So for Cargo `target/` and Xcode DerivedData, Stowaway stows the intermediates one folder at a time and leaves the rest local:

| Kind | Stowed (one image each, over the adoption threshold) | Stays on the Mac |
|---|---|---|
| `cargo-target` | `deps/`, `incremental/` and `build/` in every profile folder: `target/debug`, `target/release`, custom profiles, `target/<triple>/<profile>`, and tool-specific folders such as `target/rust-analyzer/debug` | Everything else: the built programs and libraries at the top of each profile folder, `examples/`, `.fingerprint/`, `doc/`, and files programs write next to themselves |
| `xcode-derived-data` | `ModuleCache.noindex`, and in each project's folder `Build/Intermediates.noindex`, `Index.noindex` and `SourcePackages` | `Build/Products` (the built apps), logs and everything else |

- **Cargo still works across the split.** On macOS, Cargo copies each finished program out of `deps/` rather than hard-linking it, so the program lands locally even though `deps/` is on the drive. `.fingerprint/` can stay local because Cargo rebuilds anything whose outputs are missing or older than their inputs: with the drive gone, `deps/` is empty and the next build rebuilds. When the drive returns, the offline build's outputs are merged over the drive's (`merge-local-wins`), so every output the local records mention still exists. Discarding them instead broke builds: Cargo then treated crates rebuilt offline as fresh while their outputs were gone.
- **Discovery** looks for these folders inside each `target/` and DerivedData, and pre-adopts `target/debug/deps` and `target/debug/incremental` for a project with a `Cargo.lock` that hasn't been built yet. A profile built for the first time is picked up by the next pass. Each folder is its own entry with its own image, so a project has a few mounts rather than one.
- **Converting older entries:** entries adopted before this existed hold a whole `target/` or DerivedData. The agent converts each one when it's idle: it copies each intermediates folder over the threshold to its own new image, copies everything else back to this Mac (skipping those folders), detaches the old image and puts the products in place. Then a single registry transaction replaces the old entry with the new ones, which are mounted afterwards; the old image is deleted last. Nothing is removed from the old image, so a failure or interruption before the transaction leaves the old entry intact: recovery deletes the unregistered new images and reconcile reattaches the old one, merging in the local copy, whose files match the image's. After the transaction, mounts that failed are retried by reconcile and an undeleted old image by `gc`. `stowaway adopt ./target` adopts the build folders inside rather than `target/` itself.
- **Deleting:** `cargo clean` and Xcode's Clean Build Folder delete the contents of the stowed folders and then report "Resource busy" for the mount points themselves, as with any managed folder (§4.5).

## 5. Ecosystem compatibility notes

- **Node, bundlers, TypeScript, Vite, Turbopack:** they see a real `node_modules` folder at its normal path, so real paths stay inside the project.
- **git:** the usual `node_modules/` and `/target` ignore patterns match a mount point. Stowaway never edits git files.
- **Docker Desktop bind mounts:** a container may see the empty folder underneath the mount point instead of the image's contents, depending on how Docker shares files. This is a documented limitation; the usual Docker pattern of keeping `node_modules` in a container volume avoids it.
- **Speed:** each image adds a layer between the tools and the drive. `stowaway bench` measures the drive's performance (§8.1). Measuring the image layer's own overhead is a follow-up task.
- **Filesystem requirement:** the external volume must be APFS. exFAT and HFS+ are rejected at `init`. Images are always APFS.

## 6. Safety principles

1. Only folders that are **re-creatable by construction** are managed (§3), and never if they contain files tracked by git. Source files are never moved or deleted.
2. Every move is copy, verify, then swap. No step leaves an entry partly moved. An interrupted operation is either resumed or rolled back at the next startup.
3. Stowaway only deletes:
   - its own images
   - the contents of a managed folder after they have been copied into its image
   - local fallback contents, according to the kind's reconnect policy
   - empty folders left behind when a deleted repository is cleaned up (§4.5)
4. When in doubt, local wins. The fallback underneath the mount point always exists, so nothing can dangle.
5. `stowaway uninstall` returns every folder to a plain local folder (empty, or with its contents using `--copy`) and deletes the images.

## 7. Failure modes

| Situation | Behavior |
|---|---|
| Drive unplugged with no warning | The mounts vanish. Tools see the local folders immediately. Running builds and dev servers fail and need a re-run. The agent clears the stale image devices. |
| Agent not running and drive missing | The fallback still works because nothing points at the drive. When the agent comes back it attaches the images. |
| Agent not running and drive present | Images stay unattached. Tools use the local folders. When the agent comes back it applies the reconnect policies. |
| Drive mounted but full | Writes fail with ENOSPC. `status` and a notification report it. |
| A different drive with the same name | Ignored, because the volume UUID doesn't match. |
| Project deleted | §4.5. Orphaned images are garbage-collected after `gc_orphan_days` (default 14). |
| macOS blocks access to removable volumes (TCC) | `init` and `doctor` explain how to grant the "Removable Volumes" permission. |
| Finder eject while images are attached | Fails with "in use", until DiskArbitration integration lands. Use the menu bar's Eject or `stowaway eject`. |

## 8. Interface

### CLI

```
stowaway init --volume /Volumes/FastSSD --root ~/code   # set up config and store, install the LaunchAgent
stowaway status            # drive state, entries, bytes on external vs local, pending migrations, drive performance (§8.1)
stowaway bench [--json]    # run the drive speed test against the internal disk and the external drive (§8.1)
stowaway scan [--dry-run]  # discover and adopt now; dry-run lists what would happen
stowaway adopt <path>      # adopt a specific directory
stowaway release <path> [--copy]
stowaway doctor [--fix]    # check mounts, registry, images; repair
stowaway clean [<path>]    # empty managed folders under a path without the mount-point error (§4.5)
stowaway compact [<path>]  # rebuild bloated images to reclaim space on the drive (§4.10)
stowaway gc [--dry-run]
stowaway roots list | add <path> | remove <path> [--copy]   # watched folders (same as the menu bar's Configure Folders)
stowaway eject             # detach all images (naming processes that hold files), then eject the drive
stowaway detach | attach   # make managed folders plain local folders (nothing copied back), or undo it
stowaway pause | resume    # stop or resume auto-adoption (drive switching keeps working)
stowaway priority [background|normal]  # show or set offload transfer priority
stowaway bug-report [--print]  # open a GitHub issue prefilled with diagnostics, to review and submit
stowaway agent             # run the background agent in the foreground (used by launchd)
stowaway agent stop        # stop any transfer, detach all images (folders fall back to local) and stop the agent
stowaway agent start       # start the agent again; it reattaches the images
stowaway uninstall [--copy]
```

### Config — `~/.config/stowaway/config.toml`

```toml
volume_uuid = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
roots = ["~/code"]
disabled_kinds = []                # every other kind is on, including kinds added in later versions
exclude = ["~/code/scratch/**"]
idle_seconds = 120
min_adopt_bytes = 50_000_000         # folders smaller than this aren't worth an image (§4.4)
gc_orphan_days = 14
drive_low_space_percent = 10       # "nearly full" warning threshold
transfer_priority = "background"   # "background" pauses transfers while the disk is busy; "normal" doesn't
```

Every change to entries or this file happens under `~/.stowaway/engine.lock`, whether it comes from the agent, the CLI or the menu bar app (which goes through the agent over IPC, §9.1). The one exception is `transfer_priority`: it's written without the lock, because the copy it's meant to affect holds the lock. The CLI makes its changes directly under the lock and then asks the agent to refresh. When the file changes, including hand edits, the agent notices and reloads it.

### Menu bar app

The CLI can do everything. The menu bar app is an optional, friendlier view onto the same agent, and it adds no features of its own. Quitting the menu bar app never stops the agent.

**Icon**

- A monochrome template image, so it fits light mode, dark mode and tinted menu bars.
- The base is always the Stowaway logo. Each state adds a small badge overlapping the logo's bottom-right corner, with a thin transparent gap cut around the badge so the two shapes stay distinct. The logo is a lookout with big round eyes peering over the top of a braced cargo crate (a slat across the middle and a brace in each half). The head is solid, with its eyes and a small smile cut out, so it stays legible at menu bar size. It's drawn from paths in code (`Logo.swift`), so it needs no image assets. Badges are SF Symbols.
- The icon never animates, because motion in the menu bar is distracting. Each task gets its own static badge instead:

| State | Badge on the logo |
|---|---|
| Drive connected, idle | None |
| Measuring folders before adopting | Magnifying glass |
| Moving folders onto the drive | Down arrow |
| Syncing after a reconnect (reconnect, merge) | Circular arrows |
| Compacting images | Inward arrows |
| Releasing folders back to local | U-turn arrow |
| Drive disconnected (working locally) | Filled circle with an × |
| Drive nearly full or full | Filled circle with ! |
| Agent not running, permissions missing, links dangling, or another error | Filled warning triangle |
| Paused (`stowaway pause`) | Filled pause circle |
| Detached | Filled circle with a − |

**Popover** (opens when the icon is clicked)

1. **Headline:** "Stowaway is offloading **182.4 GB**". This is the space that managed entries take up on the drive for this machine, i.e. space your internal disk isn't using.
   - When the drive is disconnected, the headline becomes: "Drive disconnected — working locally. 182.4 GB is waiting on FastSSD." Below it: "3.1 GB is being used locally until the drive comes back."
2. **Drive row:** the volume name, connected or disconnected, and a free-space bar.
   - A "nearly full" warning appears below `drive_low_space_percent`, and a "full" error when writes are failing with ENOSPC.
   - The row also flags a drive that is connected but isn't APFS or has the wrong UUID.
3. **Activity:** shown only while transfers are running, e.g. "Moving my-app/node_modules to FastSSD — 1.2 of 3.4 GB · 410 MB/s · 8,200 files/s · about 6 s left", plus "and 4 more queued".
   - Each transfer reports its step: preparing (creating the image, taking stock of the folder), copying (the only step with a determinate bar), writing to the drive (detaching the image flushes its buffered data), checking nothing changed during the copy, removing the local copy (or the old image, when compacting), mounting, and measuring. Steps after the copy show an indeterminate bar with "1.5 GB copied · Writing to the drive…". A transfer that fails or is postponed partway disappears from the list instead of staying stuck.
   - While folders are being offloaded, an **Offload transfer priority** radio toggle offers **Background** (the default: transfers pause while other apps keep the disk busy) and **Normal** (transfers run at normal priority and never pause). The change applies to the transfer already running.
4. **Drive performance** (§8.1), e.g. "Thunderbolt 3 (40 Gb/s) · read 2.6 GB/s · write 2.1 GB/s · small files 0.8× internal". When a bottleneck is detected, a hint line appears below it. A "Run speed test" button sits next to the date of the last test.
5. **Problems:** one row per problem the agent knows about: dangling links, missing permissions (with a button that opens the right System Settings pane), a pnpm store that isn't usable, the agent not running (with a Start button), and so on. Clicking a row shows the matching `doctor` details.
6. **Actions:**
   - Configure Folders…
   - Eject Drive: runs the same flow as `stowaway eject`. If programs are still holding files on the drive, it lists them by name.
   - Detach… / Attach: Detach asks for confirmation, then detaches every image and keeps them detached, as if the drive were gone: each managed folder is an ordinary local folder again, empty until rebuilt or reinstalled. Nothing is copied back and the images stay on the drive. The setting (`detached` in the config) survives restarts and reconnects. While detached the headline reads "Detached — using local folders" and the button becomes Attach, which reattaches everything; folders filled in the meantime are reconciled with the reconnect policies (§4.2). Same as `stowaway detach` / `stowaway attach`.
   - Open Log
   - Report a Bug…: runs `stowaway bug-report`, which opens a new GitHub issue in the browser, prefilled with the Stowaway and macOS versions, the Mac model, whether the agent is running, the status summary and the end of the agent log. The home folder is shown as `~`. Nothing is sent until the user submits the issue. GitHub caps the link's length, so the log is trimmed to fit; the full report is saved to `~/.stowaway/bug-report.md`. The command works without the agent, which is when a report is often needed.
   - Quit Stowaway: runs the same flow as `stowaway agent stop`, then quits the app. Like Eject, it lists the programs holding files on the drive and stays open if there are any. When the app starts again it starts the agent, which reattaches the images (§4.3).

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

**Candidate sizes are cached.** Measuring candidates (folders not adopted yet) means walking them, which takes minutes for large `target/` folders, and auto-adoption rechecks candidates every 10 minutes and after file changes. Each measurement is stored in `state.db`'s `measurements` table, together with the folder's own modification time. A later pass reuses it unless it's more than 6 hours old or the folder's modification time has changed: that time changes when direct children are added or removed, e.g. by an install or a first build. Changes deeper inside, such as a rebuild growing `target/`, are picked up when the measurement expires. A stale size can only delay or reorder an adoption, because adoption copies whatever is there. Expired measurements are pruned at the start of each pass.

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
| The external drive is at least as fast as the internal disk in all tests | No hint. The status line shows "Faster than or equal to internal". |

- **Format note:** the speed test also records the drive's format and whether it's encrypted, and one line under the results says whether a different setup would be faster. Setup already requires APFS, so the usual line is "Formatted as APFS, the best format for Stowaway." Other notes: a non-APFS format (reformat as APFS, which erases the drive), a spinning hard drive (no format helps; an SSD would), or an encrypted volume on an Intel Mac.
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
  - **Why Swift for this part:** a native popover, folder picker and `SMAppService` are straightforward in SwiftUI and awkward through Rust's AppKit bindings.
  - **Thin client:** the app contains no logic for moving files or switching links. It only displays what the agent reports and sends it requests.
  - **The Rust-only alternative:** a status item and `NSMenu` built with `objc2-app-kit`, plus a raw AppKit window. That's possible, but it means much more code for a worse result.
- **IPC:** the agent listens on a Unix domain socket at `~/.stowaway/agent.sock`, which only your user account can access.
  - **Protocol:** versioned, newline-delimited JSON.
  - **Requests:** `status`, `roots.list`, `roots.add` (with a dry-run preview), `roots.remove`, `eject`, `quit`, `pause`, `resume`, `set-transfer-priority`, `scan`, `doctor`, `bench`.
  - **Events:** `subscribe` returns a stream of state changes, transfer progress, size updates and problems. The menu bar icon and popover are driven entirely by this stream.
  - **The CLI** uses the same socket for commands that need the live agent.
  - **Message types** are defined once in Rust and exported as a JSON Schema. A test in CI checks that the Swift side decodes them.
- **Distribution:**
  - Both are published from the project's own Homebrew tap. `homebrew-core` only accepts open-source licenses, and this project's license isn't one (§13).
  - **Homebrew formula (CLI only):** installs the binary, and `init` installs a plain launchd plist.
  - **Homebrew cask (`.app`):** bundles the Rust binary inside the app and registers the agent with `SMAppService.agent(plistName:)`. The agent then shows up under the app's name in System Settings → Login Items, and permission prompts name the app rather than a bare binary. On its first launch the app also registers itself with `SMAppService.mainApp`, so the menu bar app opens at login too. It registers only once, so turning it off in Login Items sticks.
- **Process model:** a per-user launchd agent (`~/Library/LaunchAgents/dev.stowaway.agent.plist`) with `RunAtLoad`, and `KeepAlive` set to restart it only after a crash: a `quit` request exits cleanly and the agent stays stopped until the app or `stowaway agent start` kickstarts it. A `quit` stops any copy in progress (the transfer is retried later), detaches every image while holding the engine lock until the process exits, and leaves entries in local fallback (§4.2). No root access and no kernel extension are needed.
- **State:** SQLite in `~/.stowaway/state.db`. A journal of in-flight operations supports crash recovery (§6.2).
- **Copies across volumes:** a Rust copier that preserves symlinks, permissions, read-only files and hard links (tracked by inode, so Cargo's hard-linked binaries aren't duplicated). One thread walks the tree, creating directories and links in order, and hands files to up to 8 worker threads. Folders of many small files are limited by per-file latency, so parallel copies are about 2.4× faster than serial ones (24k files: 6.7 s serial, 2.8 s with 4 workers; `cp`, `ditto`, `rsync` and `tar` were all slower than the serial copier). The worker count starts at 2 and adjusts by one each second: down while the whole machine's CPU use is above 80%, up while it's below 70%. Copies run at normal I/O priority. With the `transfer_priority = "background"` setting (the default), they also pause while other programs keep the internal disk busy (more than 30 MB/s that isn't the agent's own reads, sampled once a second with `iostat`), resuming after three calm seconds. With `"normal"`, they never pause. Copies re-read the setting once a second, and `set-transfer-priority` writes it without taking the engine lock, so a change reaches a copy that's already running. macOS's low I/O tiers were tried first: they made copies about 100× slower whenever anything else touched the disk. For the same reason the LaunchAgent uses `ProcessType` `Interactive`; `Adaptive` and `Standard` agents get throttled I/O.

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

1. Measure the image layer's overhead for small-file-heavy work (`npm install`, Node startup) against a plain folder on the same drive (§5).
2. Should pre-adoption (§4.4) be on by default, or opt-in per root?
3. When an offline local copy is migrated back, should it be skipped if the external copy turns out to be newer? (This could happen if a second Mac used the same entry. That can't happen in v1 because storage is namespaced per machine.)
4. Can a physical cable pull leave image devices in a worse state than `hdiutil detach -force` does in testing? This needs real hardware (§4.0).
5. Should we cap local fallback size and evict the least recently used entries while offline?
6. Docker Desktop: confirm whether bind mounts of a project show the mounted `node_modules` image or the empty folder underneath (§5).
7. Should images for long-dormant projects be detached to save memory, and how would a tool's first use re-attach them in time (§4.10)?

## 12. Milestones

1. **M0 — manual:** The repository setup from §9.2 comes first: toolchain, lints, hooks and CI, all in place and passing before any feature code lands. Then `init`, `adopt`, `release`, `clean`, `status`, and attaching/detaching images, all proven with disk-image tests.
2. **M1 — agent:** launchd agent with drive polling, automatic attach/detach, reconnect policies, reconcile at startup, and `doctor`. Global caches: `pnpm-store` and `cargo-home`, including Cargo lock handling.
3. **M2 — automatic:** FSEvents discovery, idle-gated adoption, pre-adoption, cleanup of deleted repositories, and image compaction.
4. **M3 — menu bar app:** the IPC socket and event stream, the icon and its states, the popover, the Configure Folders window, eject, drive performance and speed test (§8.1), `SMAppService` registration, and the App Store feasibility prototype (§13.8).
5. **M4 — release:** `gc`, `uninstall`, notifications, DiskArbitration eject integration, docs, Homebrew tap with the formula and cask, license and contributor agreement in place (§13), public source release.

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

- **Mounting images outside the app's container:** at folders in `~/code`, `~/.cargo`, `~/Library/pnpm`, `~/Library/Developer/Xcode`, with the images stored on the external drive. A sandboxed app can only reach folders the user has chosen, through security-scoped bookmarks, and running `hdiutil` from inside the sandbox is untested.
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
- **The metaphor:** a stowaway rides along in the ship's hold, out of sight. Your dependencies and build files ride along on the external drive, out of your internal disk's way. The name also nods to GNU Stow.
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
| A hand-made symlink to an external drive | Moves the files | Breaks the moment the drive is unplugged, and current npm and pnpm refuse a symlinked `node_modules` anyway. Stowaway mounts the drive's storage in place and falls back to the local disk automatically |
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
- **Menu bar glyph:** the lookout over a braced crate (§8) as a one-colour template image, with a static badge per state. It never animates.
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
