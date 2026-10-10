# Stowaway (beta)

Keep your dependencies and build files on an external SSD, and keep working when it's unplugged.

Stowaway watches your code folder (e.g. `~/code`) and moves re-creatable folders such as
`node_modules`, Cargo `target/`, Xcode DerivedData and package-manager caches onto an external
drive. Each one becomes a small disk image on the drive, **mounted in place**, so your tools see an
ordinary folder at its usual path. Unplug the drive and the mount disappears: the next
`npm install` or `cargo build` simply works locally. Plug it back in and everything moves back.

> **Beta:** Stowaway is beta software (v0.1). It moves folders on your disk, so expect rough edges
> and keep backups of anything you can't rebuild. macOS 14+ only. If something goes wrong, run
> `stowaway bug-report` (or use **Report a Bug…** in the menu bar app) to file an issue with
> diagnostics. See [SPEC.md](SPEC.md) for the design.

## Quick start

```sh
cargo install --path crates/stowaway
stowaway init --volume /Volumes/FastSSD --root ~/code
stowaway status
```

`init` sets up the drive, records where your global caches live, and starts a background agent
that adopts folders as they go idle.

## What it manages

| Kind | Folder |
|---|---|
| `node` | a project's `node_modules` |
| `cargo-target` | a Cargo workspace's `target/` |
| `pnpm-store`, `cargo-home`, `js-caches` | pnpm's store, `~/.cargo/registry` and `git`, npm/yarn/bun caches |
| `xcode-derived-data`, `gradle-home`, `go`, `huggingface` | DerivedData, Gradle caches, Go caches, downloaded models |

Folders tracked by git are never touched, and source code never moves.

## Things to know

- **Deleting a managed folder:** `rm -rf node_modules` and `cargo clean` delete everything inside,
  then report "Resource busy" because the folder is a mount point. Use `stowaway clean` (or
  `rm -rf node_modules/*`) instead.
- **Ejecting:** use `stowaway eject` or the menu bar app, which detach the images first. A plain
  Finder eject reports the drive as in use.
- **Drive format:** the external drive must be APFS.

## Commands

```
stowaway status | bench | scan | adopt <path> | release <path> | clean [path]
stowaway compact | doctor [--fix] | gc | roots list|add|remove | eject | pause | resume
stowaway agent install|uninstall | uninstall | license personal|work|purchased
```

## License

Stowaway is **source-available** under the [Prosperity Public License 3.0.0](LICENSE): free for
personal and noncommercial use. **Using it at work?** Your company gets a 30-day trial, then needs
a license. It's a small expense that funds independent software; see
[LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md).

Contributions are welcome under the [CLA](CLA.md); see [CONTRIBUTING.md](CONTRIBUTING.md).
