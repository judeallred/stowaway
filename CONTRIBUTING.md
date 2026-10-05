# Contributing to Stowaway

Thanks for helping out. A few things to know before you open a pull request.

## Contributor License Agreement

Stowaway is source-available (Prosperity Public License 3.0.0) and is also sold under commercial
licenses, which fund its development. To make that possible, every external contributor signs the
[Contributor License Agreement](CLA.md) once. You keep your copyright.

When you open your first pull request, a bot comments with a link to the CLA. Reply with the
sentence it asks for and the check turns green. Pull requests can't be merged until it passes.

## Development setup

```sh
cargo xtask install-hooks   # format check on commit, clippy + unit tests on push
cargo xtask ci              # runs exactly what CI runs
```

The toolchain is pinned in `rust-toolchain.toml`; `rustup` picks it up automatically.

## Standards

- Clippy runs with `all`, `pedantic`, `nursery`, `cargo` and a set of `restriction` lints, and CI
  fails on any warning.
- Never use `#[allow(...)]`. If a lint has to be silenced, use
  `#[expect(lint, reason = "...")]` on the smallest possible scope.
- `unsafe` code lives only in `crates/stowaway-macos`, and every block has a `// SAFETY:` comment.
- Dependencies must be permissively licensed; `cargo deny check` enforces the list in `deny.toml`.
