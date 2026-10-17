# Stowaway

Keep your dependencies and build files on an external SSD, and keep working when it's unplugged.

Stowaway is a Mac App Store app for developers. It finds the re-creatable folders that fill up a
Mac (`node_modules`, Cargo `target/`, Xcode DerivedData, package caches, downloaded models), lets
you delete them, and can keep them on an external drive instead: unplug the drive and your tools
rebuild locally; plug it back in and everything moves back.

**Status:** being rebuilt as a sandboxed App Store app (October 2026). The engine is in
[`StowawayCore/`](StowawayCore); the app is coming next.
[docs/WHITEPAPER.md](docs/WHITEPAPER.md) explains the design and why it replaced the original
disk-image engine, which is preserved at the `rust-core-final` tag.

Website: [brooklynspaceport.com/stowaway](https://brooklynspaceport.com/stowaway)
