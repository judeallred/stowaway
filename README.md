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

Download **Stowaway.app** from the [latest release](https://github.com/judeallred/stowaway/releases)
(Apple silicon and Intel), move it to Applications and open it. Beta builds aren't signed with a
Developer ID yet: approve the first launch in **System Settings → Privacy & Security**.

Or build the command-line tool from source:

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
| `cargo-target` | the build files in a Cargo workspace's `target/` (`deps/`, `incremental/`, `build/`); the programs it builds stay on your Mac, so they run without the drive |
| `next` | a Next.js project's `.next/` |
| `venv` | a Python project's `.venv/` (next to `pyproject.toml`) |
| `pnpm-store`, `cargo-home`, `js-caches`, `npx` | pnpm's store, `~/.cargo/registry` and `git`, npm/yarn/bun caches, `~/.npm/_npx` |
| `xcode-derived-data`, `gradle-home`, `go`, `huggingface` | Xcode's intermediates and indexes (built apps stay local), Gradle caches, Go caches, downloaded models |

Besides your watched folders, Stowaway also scans the worktrees coding agents create:
`~/.cursor/worktrees`, `~/.codex/worktrees` and Claude Code's `.claude/worktrees` inside your
repositories. To skip them, add an `exclude` pattern such as `~/.cursor/worktrees/**`.

Folders tracked by git are never touched, and source code never moves.

## Things to know

- **Deleting a managed folder:** `rm -rf node_modules` and `cargo clean` delete everything inside,
  then report "Resource busy" because the folder is a mount point. Use `stowaway clean` (or
  `rm -rf node_modules/*`) instead. The same goes for tools that delete and recreate `.venv`,
  such as `uv venv --clear` or changing a project's Python version.
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
