# Stowaway

Keep your dependencies and build files on an external SSD, and keep working when it's unplugged.

Stowaway is a Mac App Store app for developers. It finds the folders your tools can re-create
(`node_modules`, Cargo and Xcode build files, package caches, downloaded models), shows how much
space they take, and lets you delete them, or keep them on an external drive instead:

- **Stow:** the folder moves to your drive and a link takes its place, so npm, Cargo, Xcode
  and your other tools find it where it always was.
- **Unplug:** your tools rebuild locally, without asking.
- **Plug back in:** everything moves back to the drive, including anything built while it was
  away.

Finding and deleting folders is free, and so is stowing up to 100 GB. Any purchase, at a price
you choose, makes stowing unlimited.

**Website:** [brooklynspaceport.com/stowaway](https://brooklynspaceport.com/stowaway)

## What it manages

| Kind | Folder |
|---|---|
| node_modules | a project's `node_modules` (npm, Yarn, bun) |
| Next.js | a project's `.next` |
| Python | a project's `.venv` (next to `pyproject.toml`) |
| Cargo | a workspace's `target/` build folders (the programs it builds stay on your Mac), and `~/.cargo/registry` and `git` |
| Xcode | DerivedData's intermediates and indexes (built apps stay on your Mac) |
| Caches | pnpm's store, npm, Yarn and bun caches, npx packages, Go's module and build caches, Gradle's caches, Hugging Face models |

Stowaway only looks in the folders you choose, never touches source code, and never touches a
folder git tracks. To exclude a folder, put a file named `.stowaway-ignore` in it.

## Repository

| Path | What |
|---|---|
| [`StowawayCore/`](StowawayCore) | The engine: scanning, stowing, npm deep links, the cleaner, a git index reader. A Swift package with its tests. |
| [`App/`](App) | The sandboxed menu bar app (SwiftUI, StoreKit 2). The Xcode project is generated from `App/project.yml`. |
| [`install.sh`](install.sh) | Builds the app and installs it in `/Applications`. |
| [`docs/architecture.md`](docs/architecture.md) | How it works, and why. |
| [`docs/app-store/`](docs/app-store) | App Store listing, review notes, pricing, privacy policy draft, release checklist. |

[CONTRIBUTING.md](CONTRIBUTING.md) covers building and testing. Report security issues as
described in [SECURITY.md](SECURITY.md).

## License

The source is available under the [Prosperity Public License 3.0.0](LICENSE): free for personal
and noncommercial use. The App Store app is licensed under Apple's standard terms; see
[LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md). Contributions are welcome under the
[CLA](CLA.md).
