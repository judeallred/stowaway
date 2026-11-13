# How Stowaway works

Stowaway is one sandboxed process: a SwiftUI menu bar app with the engine
([`StowawayCore`](../StowawayCore)) running inside it.

## Why it works this way

Every Mac App Store app runs in the App Sandbox, and that rules out the obvious design: mounting
a disk image from the drive at each folder's own path. The sandbox allows mounts only inside the
app's container, and no documented entitlement lifts that. What the sandbox does allow is folders
the user grants, symlinks, ordinary copies and volume notifications, so Stowaway is built from
those:

- **A folder moves to the drive and a symlink takes its place.** Tools follow the link and run
  at the drive's speed: in testing on an external NVMe SSD, Cargo builds, pnpm installs, module
  resolution and `tsc` ran as fast as from a mounted image, and often faster than the internal
  disk while Spotlight was indexing it.
- **npm gets "deep links" instead** (below): npm treats a symlinked package as a `link:`
  dependency and reinstalls everything on every run. With real package folders and linked
  contents, `npm install` with nothing to change takes about 0.3 s. (The benchmarks and method
  are in the
  [sandbox experiments](https://github.com/judeallred/stowaway/blob/b27bbd3/research/sandbox-probe/results/bench.md),
  since removed from the repository.)
- **Unplugging swaps each link for a local folder,** which is quicker than reattaching images
  (under a second for 20 folders) and costs nothing per folder. The tradeoff is that the app has
  to be running: quit while the drive is away, links dangle until it starts again.
- **There's no true in-use check.** The sandbox hides other processes (`lsof`, `ps`), so
  Stowaway uses heuristics: a running Cargo build's lock, an editor with the project open, and
  recent changes.
- **`files.user-selected.executable`** is the one unusual entitlement, and App Review looks at it
  closely; see the [review notes](app-store/review-notes.md).

## Access

The App Sandbox lets Stowaway see only what the user grants in an open panel. It keeps each grant
as a security-scoped bookmark (`Engine.grant`), in two roles:

- **Roots:** folders to scan and manage, such as `~/code`, or `~/.npm` for npm's caches. To swap a
  folder for a link, Stowaway needs the folder that *contains* it, so the onboarding and Settings
  ask for the parent of each cache.
- **The stow location:** an external drive, or any folder. Stowaway keeps everything in
  `Stowaway.noindex/<install-id>/` there. Spotlight skips `*.noindex` folders, and the random
  install ID keeps two Macs sharing a drive apart.

To suggest which folder to choose, onboarding asks Spotlight for project manifests
(`ProjectFinder`): the sandbox lets Spotlight return paths across the home folder, though not
read the files. Editors' recent-project lists (VS Code, Cursor, Xcode) are out of reach.

Bookmarks are resolved without mounting or prompting, so an unplugged drive fails fast, and stale
bookmarks are re-created. The entitlement `files.user-selected.executable` stops the sandbox from
quarantining the files Stowaway copies; without it, binaries on the drive wouldn't run.

## Finding folders

`Scanner` walks each root up to 6 levels deep, without following symlinks or crossing into other
volumes. It skips hidden folders, `.git`, the inside of `node_modules`, and anything under a
`.stowaway-ignore` file. In the home folder it skips Desktop, Documents and Downloads
(`Scanner.homeSkips`): macOS asks the user before an app reads each of them, so a project kept
there is added by choosing it. Common worktree containers (`.claude/worktrees`, `.cursor/worktrees`, `.codex/worktrees`,
`.t3/worktrees`, `.worktrees`, `.git-worktrees`, `.trees`, `worktrees`) are scanned as separate
projects. Hidden worktree containers can also be granted directly. The Folders window lists a repository's
worktrees together under it: each project's checkout and repository are read from its `.git`
(a linked worktree's `.git` file names `<repository>/.git/worktrees/<name>`), by `GitIndex.checkout`. A folder counts when it sits next to its kind's manifest (`Kind.projectRule`):

| Kind | Folder | Next to | Also requires |
|---|---|---|---|
| node | `node_modules` | `package.json` | not inside another project with node_modules |
| cargo-target | `target` | `Cargo.toml` | `CACHEDIR.TAG` inside; no `target-dir` override in `.cargo/config` |
| next | `.next` | `package.json` | |
| venv | `.venv` | `pyproject.toml` | `pyvenv.cfg` inside |

A mixed `target` without `CACHEDIR.TAG` is searched up to six levels for Cargo profiles with
`deps` plus `.fingerprint` or `.cargo-lock`. Only each profile's `deps`, `incremental` and `build`
folders become `cargo-cache` candidates. They are revalidated before stowing or deletion and
checked for Cargo locks; surrounding worktrees, executables and experiment outputs stay local.

Machine-wide caches (`Kind.defaultLocations`) count when they exist under a root. A sandboxed app
can't ask the tools (`pnpm store path`, `go env`) or read the shell's environment, so custom
locations are added by granting them.

**Sizes** are allocated blocks, measured with `fts`. **"Last changed"** is the newest of the
folder, its top level, and the project's manifest and lockfiles.

## Stowing a folder

`Engine.adopt` validates first. The folder must:
- be a real directory inside a root, not a root itself;
- not overlap the store or an existing entry;
- not be tracked by git.

Git tracking is read from the repository's index file directly by `GitIndex`, which handles
index versions 2–4 and worktrees, because `/usr/bin/git` can't run in the sandbox. If the index
can't be read, the folder is left alone.

Then it copies the folder into the store with a parallel copier (`Copier`), swaps the original
for a symlink, and records an `Entry` in `entries.json` in the app's container. The local copy
is deleted afterwards, in the background. **Splits:**
- a Cargo `target/` is stowed as its `deps`, `incremental` and `build` folders, so built
  programs stay local;
- DerivedData is stowed as its intermediates, indexes and packages, so built apps stay local.

Build output in a JavaScript project gets a `node_modules` link beside it in the store, leading
back to the project's. Next.js's compiled server code `require`s packages from its real path on
the drive, and this is how it finds them.

### npm projects: deep links

npm deletes a symlinked `node_modules`, and replaces a symlinked package folder on every install.
So for `node_modules`, every package folder stays a real directory, and only its *contents* link
into the store (`DeepLinks.swift`):

```
~/code/app/node_modules/react/              real folder (npm is satisfied)
  package.json -> <store>/<id>/d/…/d/node_modules/react/package.json
  index.js     -> …
<store>/<id>/d/…/d/node_modules/react/      only react lives in this node_modules
<store>/<id>/d/…/node_modules -> ~/code/app/node_modules     one level up: back to the Mac
<store>/<id>/d/node_modules   -> ~/code/node_modules          and so on, one level for each
<store>/<id>/node_modules     -> ~/node_modules               folder Node would search
```

(Simplified: there's one `d` level per folder on Node's lookup path, and a nested package gets its
parent package's `node_modules` first.)

- **Paths still look normal.** A file's real path reads `…/node_modules/react/…`, which tools
  such as Next.js test for.
- **Resolution goes through the Mac.** Walking up from it, Node finds `node_modules` links that
  lead back to the project's own folders. So an upgraded dependency is never shadowed by an old
  copy on the drive.
- **npm's lockfile lives on the drive too.** The hidden lockfile (`node_modules/.package-lock.json`)
  moves to the store, and folder modification times are preserved. With the drive connected,
  npm trusts the lockfile and an install with nothing to change stays fast. Without the drive,
  npm can't read it, so it rescans and repairs everything locally.
- **After an install.** An install that adds or upgrades packages extracts them locally. Once
  `node_modules` has been quiet for 20 seconds, `reconcile` moves them to the store, reusing any
  identical copy already there.

A `node_modules` with Next.js in it is refused: Next's bundler, Turbopack, won't read a
`package.json` that's a link, and deep links make every package's one. No setting gets around
it, and whether a project uses Turbopack can't be told reliably (a flag typed by hand, Next 16's
default, a script in a workspace package), so any project with Next keeps its `node_modules`.
Its `.next` can still be stowed, except in a workspace (npm, Yarn or pnpm): there its packages
are split between the package's `node_modules` and the workspace root's, and the one link back
from the drive can't cover both. pnpm projects are refused too: stowing pnpm's store covers
them.

## The drive coming and going

`Engine.reconcile` runs at launch, on every volume mount and unmount (bursts are coalesced), and
every 2 minutes:

- **Drive gone:** each link becomes an empty local folder, and tools rebuild into it. npm deep
  links are left dangling. npm can't read its lockfile then, so the next install repairs them.
- **Drive back:** whatever was built locally is merged into the store (local files win), the
  link returns, and the local copy is deleted in the background.
- **A tool replaced a link** (for example, `cargo clean` then a build): the tool's new folder
  goes onto the drive in place of the old copy (not merged into it, so what the tool deleted
  stays deleted), and the link returns.
- **A link leads somewhere else** (the drive mounted under another name): it's pointed back at
  the copy. If the copy is gone, the folder becomes a local one.
- **The project is gone** (a worktree removed with `git worktree remove`, a project folder
  deleted): once it's stayed gone for an hour (`Engine.vanishedGrace`, counted across launches),
  its copies on the drive are deleted and its entries forgotten. Only the project folder itself
  missing counts, not its `target/` (that's `cargo clean`), and only under a root that's still
  there, so a grant that didn't resolve is never taken for a deletion.

Merging or replacing waits while a tool may still be writing: until nothing in the folder has
changed for 20 seconds, and no Cargo build holds its profile's lock (`Engine.isBeingWritten`).

Tools keep writing into stowed folders, so after a scan (at most every 10 minutes) the app
re-measures them on the drive (`Engine.recountStowed`), keeping the stowed total and the free
limit honest.

The app has to be running for the first two to happen automatically, which is why onboarding
offers Open at Login.

## Stowing automatically

Once a drive is chosen, the app rescans when watched folders change (at most once a minute, and
hourly regardless) and stows every folder,
caches included, that hasn't changed for the window set in Settings (5 minutes by default; it can
be turned off). "Immediately" stows anything that's been quiet for 30 seconds, so a folder is
never copied mid-write. "Changed" looks two levels into the folder, so a build writing into
`target/debug/deps` counts. It skips folders a tool is using right now:
- a Cargo `target/` whose `.cargo-lock` is held (`Measure.isBusy`);
- DerivedData while Xcode is running;
- Gradle's caches while Android Studio or IntelliJ is running.

It also skips folders the user brought back ("Kept on Mac", until they're stowed by hand) and
folders it couldn't stow (a pnpm project), until they change. It stops at the free limit, and
waits until purchases are read, so a paying user is never held to it. Stowaway never deletes a
folder of yours on its own; it only cleans up its own copies (a package's old copy on the drive
after an upgrade, a local folder after it's moved to the drive, the copies of a deleted project).

## Identical files, stored once

On an APFS drive, identical files share their storage as clones (`clonefile`), which are
copy-on-write: writing to one never changes another. Worktrees compile the same dependencies, so
there's a lot to share: on one real drive, a third of 727 GB. Sizes, the stowed total and the
free limit still count every file in full; what sharing saves is shown on top ("21.7 GB saved by
storing identical files once"). ExFAT and HFS+ drives can't clone, and say so beside their format.

**The index** (`SharedIndex`, SQLite in the app's container, never on the drive) holds each
large file's stamp (inode, size, modification and change times; any write changes the change
time), its SHA-256 once read, and whether it shares storage with the other files of its hash.
Every file of a hash marked shared shares one copy, so the saving is, per hash, the size times
the number marked, less one. It's tied to the drive's volume UUID and the store's path: another
drive, or the same one reformatted, starts afresh.

**The sweep** (`Engine.sweepSharedFiles`):
1. *Walk* each stowed folder, comparing stamps with the index; only what changed is written.
   Then what the index knows is checked against the drive a page at a time, and what's gone is
   forgotten, so memory stays flat however big a folder is. A sweep resuming after it made way
   skips the walk if the last one finished in the last 10 minutes.
2. *Read* only files whose size another file has (biggest first), and never one that changed in
   the last 10 minutes or while being read.
3. *Share*: clone the file already sharing (or the first) beside each duplicate, give the clone
   the duplicate's own permissions, attributes, ACL, flags and dates, check that neither file
   changed, and rename it over the duplicate in one step. The folder's dates are put back (npm
   trusts them), unless something else changed the folder meanwhile; a read-only folder is
   opened and closed again. Anything holding the old file
   open keeps it.

It skips hard links, locked and compressed files, Stowaway's own work in progress, and folders a
Cargo build holds (on the Mac, or in the shared build folder on the drive). A file that can't
be swapped for lasting reasons (a permission) isn't tried again until it changes; one that
failed for a passing one (a full drive) is. A crash mid-swap leaves only a `.stowaway-clone-…`
file, which the next sweep deletes.

**When it runs** (`AppModel+Sharing`): only when Stowaway has nothing else to do, at the
lowest disk priority, and it gives way between files as soon as any other work starts (stowing,
bringing back, deleting, reconciling, a speed test); the next chance carries on from the index.
It holds the engine's lock only in 0.2-second turns. When the drive is nearly full, getting
space back is the work: it runs at once, at normal priority, without giving way. Pausing,
ejecting and stopping use of the drive always stop it (an eject waits for it).

Its progress (files checked, bytes read of those to read, files deduplicated of those to do)
shows in the status line. Bringing folders back checks the Mac has room for their full size
first: on the drive they may take less.

**Copying what the drive has**: when stowing, merging or replacing copies a file whose size the
index has seen, it's hashed first; if the drive already has it, it's cloned from there (with
the source's own metadata) instead of written again.

## Cargo's build folder (opt-in)

Cargo 1.91+ can keep a build's intermediate files (`deps`, `incremental`, `build`,
`.fingerprint`) in a separate `build.build-dir`, leaving only built programs in `target/`. With
the setting on (in the setup wizard, Settings, or suggested on the main window once 20 GB of
Cargo build files have been stowed), Stowaway (`CargoBuildFolder`):

- makes `~/.cargo/stowaway-build`, a machine-wide cache of kind `cargo-build`, and stows it at
  once while it's empty, so it's a link to the drive (or a local folder while the drive is away);
- adds one marked line to Cargo's config (`config.toml`, or the older `config` when that's in
  use): `build.build-dir = "~/.cargo/stowaway-build/{workspace-path-hash}"`, or `build-dir` inside
  an existing `[build]` table. A config that sets `build-dir` itself, or `build` as an inline
  table, is left alone.

So every project and worktree builds onto the drive from its first build, each in its own
folder. A deleted worktree's folder would stay there for good, so once a day
(`Engine.pruneCargoBuildFolder`) projects no build has changed anything in for 30 days are
deleted (a project that builds again just builds from scratch). One a build holds is kept, and
nothing is touched while the drive is away. Cargo's locks in it (`<hash>/<hash>/<profile>/.cargo-lock`) count as busy, as a
target's do. Turning it off removes the line and deletes the folder. It needs `~/.cargo` (or
the home folder) to be granted, and asks for it if not.

## Deleting

`Cleaner` applies the same guard rails as stowing, and runs under the engine's lock
(`Engine.delete`), so a delete can't interleave with stowing the same folder. It refuses folders outside the roots,
folders git tracks, stowed folders, and folders that no longer match their kind. It deletes
project folders outright, but only empties a cache folder, so the user's grant for it stays
valid. Deleting a stowed folder (`Engine.discard`) removes the link and its copy on the drive.

## Safety rules

- **No following symlinks out.** Deletion uses `unlinkat` relative to open directory handles and
  never follows symlinks; copying copies symlinks as symlinks.
- **One operation at a time.** Engine operations hold an `flock`, so the timer, the UI and
  anything else can't interleave.
- **The drive isn't trusted.** It may be shared or modified. Paths read from it (entries, the
  deep-link manifest) are rejected if they escape the store (`Engine.storePath`,
  `Engine.validated`).
- **The list of stowed folders is never guessed.** It's saved before a local folder is touched,
  and a stow fails if it can't be. A list that can't be read is never written over: stowing,
  bringing back and deleting stop, and the app says so at launch.
- **Data is never held hostage.** Bringing folders back and deleting them never require a
  purchase; the free limit only stops *new* stows.

## Purchases

`Store` uses StoreKit 2. Thirteen non-consumable products (seven personal, six business) all unlock
the same thing: no stowing limit. The app passes a limit to `Engine.adopt` (100 GB unless
something's been bought) when adopting. Only verified, unrevoked transactions count.
