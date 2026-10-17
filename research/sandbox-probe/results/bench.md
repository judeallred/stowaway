# Stowaway Lite vs core: performance

Run on 2026-10-15: Apple M4 Pro, macOS 26.6.2, OWC Express 1M2 external SSD over PCI-Express
(APFS, 1.8 TB). Each cell is the median of three runs. Raw numbers are in `bench-raw.tsv`, and
the full log is in `bench-log.txt`. To reproduce, run `scripts/bench.sh "/Volumes/<drive>" 3`.

- **local** is a plain folder on the Mac's internal SSD.
- **core** is a sparse-bundle image on the drive, mounted in place, using the same `hdiutil`
  flags and staging-then-mount flow as `hdiutil.rs` and `engine.rs`.
- **lite** is a folder on the drive with a symlink in place, run by the sandboxed Stowaway Lite
  app.

Core and Lite move data with the same parallel copier, so the comparison is between the two
mechanisms, not two copy implementations.

| Workload | Step | local | core (image) | lite (symlink) | lite vs core |
|---|---|---|---|---|---|
| Cargo, this workspace (542 MB, 2,173 files) | clean build | 7.58 s | 7.81 s | 7.61 s | 0.97× |
| | no-op build | 0.57 s | 0.54 s | 0.30 s | 0.55× |
| | incremental build | 1.56 s | 0.87 s | 0.71 s | 0.81× |
| npm, Next.js app (376 MB, 15,128 files); Lite uses deep links | `npm install` from the lockfile into an empty `node_modules` | 3.83 s | 2.73 s | 3.22 s | 1.18× |
| | `npm install` with nothing to change | 0.24 s | 0.24 s | **0.28 s** | 1.16× |
| | after a fresh install: move packages to the drive (once quiet) | | | 0.71 s | |
| | after a fresh install: delete the local copies (background) | | | 2.39 s | |
| | walk `node_modules` | 0.17 s | 0.12 s | 0.10 s | 0.83× |
| | `require` every dependency | 0.33 s | 0.31 s | 0.30 s | 0.97× |
| | `tsc --noEmit` | 1.67 s | 1.62 s | 1.53 s | 0.94× |
| pnpm, global virtual store, store on each design | first install (network, noisy) | 18.14 s | 8.06 s | 9.57 s | 1.19× |
| | install, offline | 7.89 s | 2.45 s | 2.33 s | 0.95× |
| | walk the store | 0.75 s | 0.36 s | 0.46 s | 1.29× |
| | `require` every dependency | 0.95 s | 0.31 s | 0.36 s | 1.16× |
| | `tsc --noEmit` | 2.25 s | 1.82 s | 1.69 s | 0.93× |
| **Adopt** an existing folder onto the drive | Cargo `target/` | | 3.77 s | 0.83 s | **0.22×** |
| | `node_modules` | | 9.71 s | 8.98 s | 0.92× |
| **Unplug** the drive with 20 managed folders | until tools see local folders | | 5.79 s | 0.72 s | **0.12×** |
| **Plug back in** | until everything is on the drive again | | 26.4 s | 5.31 s | **0.20×** |
| Overhead per managed folder | | | 7–8 MB empty image | one symlink | |

## What it shows

- **Day-to-day speed is the same.** Builds, installs, module resolution and type-checking run
  at drive speed under both designs. Most gaps are within run-to-run noise. Lite is slightly
  faster on Cargo no-op and incremental builds: it reads the drive's APFS directly, while an
  image is APFS inside a sparse bundle on APFS. Core is slightly faster at walking huge trees,
  probably because each image is a small filesystem of its own. Neither difference is large
  enough to matter.
- **npm projects run as fast under Lite as under core.** Lite uses *deep links*: every package
  folder stays real and only its contents link to the drive, so npm sees ordinary installed
  packages and leaves them alone. An `npm install` with nothing to change takes 0.28 s, against
  0.24 s for core. An earlier design linked whole package folders, and npm reinstalled all of
  them on every run (5.4 s instead of 0.7 s). An install that adds packages extracts only those
  locally, and Lite moves them to the drive once the project is quiet. (The npm rows come from a
  later run than the rest of the table; the machine was less busy then, so compare them only
  with each other.)
- **Lite adopts much faster when folders are small.** Core pays about 3 s per folder to create
  an image, attach it at a staging path, detach it and mount it in place. Lite only copies and
  swaps in a symlink. For the 542 MB `target/` that's 0.8 s against 3.8 s. For a 15,800-file
  `node_modules`, copying dominates and the two are close.
- **Lite handles the drive coming and going far better, and the gap grows with folder count.**
  - **Unplug:** with 20 folders, Lite swaps in local folders in about 0.7 s. Core's mounts take
    about 6 s to disappear after the drive goes.
  - **Plug back in:** Lite is back in about 5 s, including merging what was built offline.
    Core needs about 26 s, because it clears the stale image devices a yank leaves behind and
    reattaches every image at about 1.2 s each. Your machine has 55 mounted `node_modules`
    alone, so at that rate core would take over a minute to fully return after a replug.
- **The local baseline is slower than the external drive here.** That's background work on the
  internal disk, not the disk itself: Spotlight is indexing every freshly written file there,
  and the same pnpm install ranged from 7.3 s to 14.3 s. Core's images are marked never-index,
  and Lite now uses a `.noindex` folder on the drive.

## Caveats

- **Core is replayed, not run.** I didn't point the real engine at your drive, because its
  `init` writes drive-level setup that your live agent depends on. The real engine also paces
  copies around other disk activity, which these numbers leave out.
- **The unplug and replug tests use a throwaway image as the drive**, because I couldn't
  physically unplug your SSD. They measure how fast each design reacts, not drive I/O.
- **Under pnpm's global virtual store, `tsc` reports "missing declaration" errors**, because the
  `@types` packages aren't visible from the store. It reads the same files in every variant, so
  the timings still compare like with like.
- **Three runs per cell.** The spread is in `bench-raw.tsv`. Steady-state differences under
  about 15% are within noise.

## Bugs found along the way

1. **Core (real, affects you today): `npm ci` fails on every Stowaway-mounted `node_modules`.**
   macOS creates a `.fseventsd` folder at the root of each mounted volume, owned by root and
   readable only by root. `npm ci` scans `node_modules` before emptying it and fails with
   `EACCES: permission denied, scandir '…/node_modules/.fseventsd'`. All 55 of your mounted
   `node_modules` have that folder. `npm install` isn't affected. The spec's note that
   `npm ci` works was probably tested before macOS had created the folder.
2. **Lite (fixed):** on unplug, resolving the drive's bookmark without `.withoutMounting` could
   stall, and a burst of volume notifications caused one reconcile per event. The engine now
   resolves without mounting or UI and coalesces bursts of events.
3. **`hdiutil` (worth handling in core):** during bursts of attaches it sometimes fails with
   "attach failed - no mountable file systems". One run hit it, while setting up 20 images.
   The benchmark now retries up to three times, though the final run didn't need to.
