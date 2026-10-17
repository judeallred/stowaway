# How Stowaway works

Stowaway is one sandboxed process: a SwiftUI menu bar app with the engine
([`StowawayCore`](../StowawayCore)) running inside it. [WHITEPAPER.md](WHITEPAPER.md) explains
why it's built this way; this page describes what it does.

## Access

The App Sandbox lets Stowaway see only what the user grants in an open panel. It keeps each grant
as a security-scoped bookmark (`Engine.grant`), in two roles:

- **Roots:** folders to scan and manage, such as `~/code`, or `~/.npm` for npm's caches. To swap a
  folder for a link, Stowaway needs the folder that *contains* it, so the onboarding and Settings
  ask for the parent of each cache.
- **The offload location:** an external drive, or any folder. Stowaway keeps everything in
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
`.stowaway-ignore` file. Claude Code's `.claude/worktrees` checkouts are scanned as separate
projects. A folder counts when it sits next to its kind's manifest (`Kind.projectRule`):

| Kind | Folder | Next to | Also requires |
|---|---|---|---|
| node | `node_modules` | `package.json` | not inside another project with node_modules |
| cargo-target | `target` | `Cargo.toml` | `CACHEDIR.TAG` inside; no `target-dir` override in `.cargo/config` |
| next | `.next` | `package.json` | |
| venv | `.venv` | `pyproject.toml` | `pyvenv.cfg` inside |

Machine-wide caches (`Kind.defaultLocations`) count when they exist under a root. A sandboxed app
can't ask the tools (`pnpm store path`, `go env`) or read the shell's environment, so custom
locations are added by granting them.

**Sizes** are allocated blocks, measured with `fts`. **"Last changed"** is the newest of the
folder, its top level, and the project's manifest and lockfiles.

## Offloading a folder

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
- a Cargo `target/` is offloaded as its `deps`, `incremental` and `build` folders, so built
  programs stay local;
- DerivedData is offloaded as its intermediates, indexes and packages, so built apps stay local.

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

Projects that build with Turbopack (Next.js 16 by default) are refused unless they set
`turbopack.root`, because Turbopack rejects files outside the project. pnpm projects are refused
too: offloading pnpm's store covers them.

## The drive coming and going

`Engine.reconcile` runs at launch, on every volume mount and unmount (bursts are coalesced), and
every 30 seconds:

- **Drive gone:** each link becomes an empty local folder, and tools rebuild into it. npm deep
  links are left dangling. npm can't read its lockfile then, so the next install repairs them.
- **Drive back:** whatever was built locally is merged into the store (local files win), the
  link returns, and the local copy is deleted in the background.
- **A tool replaced a link** (for example, `cargo clean` then a build): the new folder is merged
  and linked again.

The app has to be running for the first two to happen automatically, which is why onboarding
offers Open at Login.

## Offloading automatically

Once an offload location is chosen, the app rescans every 2 minutes and offloads every folder,
caches included, that hasn't changed for the window set in Settings (5 minutes by default; it can
be turned off). "Immediately" offloads anything that's been quiet for 30 seconds, so a folder is
never copied mid-write. "Changed" looks two levels into the folder, so a build writing into
`target/debug/deps` counts. It skips folders a tool is using right now:
- a Cargo `target/` whose `.cargo-lock` is held (`Measure.isBusy`);
- DerivedData while Xcode is running;
- Gradle's caches while Android Studio or IntelliJ is running.

It stops at the free limit. Nothing is ever deleted automatically.

## Deleting

`Cleaner` applies the same guard rails as offloading. It refuses folders outside the roots,
folders git tracks, offloaded folders, and folders that no longer match their kind. It deletes
project folders outright, but only empties a cache folder, so the user's grant for it stays
valid. Deleting an offloaded folder (`Engine.discard`) removes the link and its copy on the drive.

## Safety rules

- **No following symlinks out.** Deletion uses `unlinkat` relative to open directory handles and
  never follows symlinks; copying copies symlinks as symlinks.
- **One operation at a time.** Engine operations hold an `flock`, so the timer, the UI and
  anything else can't interleave.
- **The drive isn't trusted.** It may be shared or modified. Paths read from it (entries, the
  deep-link manifest) are rejected if they escape the store (`Engine.storePath`,
  `Engine.validated`).
- **Data is never held hostage.** Bringing folders back and deleting them never require a
  purchase; the free limit only stops *new* offloads.

## Purchases

`Store` uses StoreKit 2. Twelve non-consumable products (seven personal, five business) all unlock
the same thing: no stowing limit. The app passes a limit to `Engine.adopt` (100 GB unless
something's been bought) when adopting. Only verified, unrevoked transactions count.
