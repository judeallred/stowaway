# Contributing to Stowaway

Thanks for helping out. A few things to know before you open a pull request.

## Contributor License Agreement

Stowaway is source-available (Prosperity Public License 3.0.0) and is sold on the Mac App Store,
which funds its development. To make that possible, every external contributor signs the
[Contributor License Agreement](CLA.md) once. You keep your copyright.

When you open your first pull request, a bot comments with a link to the CLA. Reply with the
sentence it asks for and the check turns green. Pull requests can't be merged until it passes.

## Setup

You need Xcode 26 or later (macOS 14 is the minimum the app supports).

```sh
git config core.hooksPath .githooks   # swift-format check on commit, core tests on push
open App/Stowaway.xcodeproj
```

The Xcode project is generated from [`App/project.yml`](App/project.yml) and committed, so you
only need [XcodeGen](https://github.com/yonaskolb/XcodeGen) to change the project itself (adding
a file counts):

```sh
xcodegen generate --spec App/project.yml
```

Running the app from Xcode uses `App/Stowaway/Resources/Products.storekit`, so purchases work
locally without App Store Connect.

To use your build day to day, install it:

```sh
./install.sh
```

It builds a Release signed to run on this Mac only (no developer team needed), quits any running
copy, replaces `/Applications/Stowaway.app` and opens it.

## Checks

These are what CI runs:

```sh
xcrun swift-format lint --strict --recursive StowawayCore App/Stowaway App/scripts/make-icon.swift
swift test --package-path StowawayCore -Xswiftc -warnings-as-errors
App/scripts/build.sh && App/scripts/check-release.sh
```

`swift test` needs to attach a small disk image (`hdiutil`) for the unplug test.
`check-release.sh` inspects the Release build for what App Review cares about: no test hooks in
the binary, exactly the expected entitlements, a privacy manifest.

## Standards

- Swift 6 language mode with strict concurrency; warnings are errors.
- `swift-format` with the repository's `.swift-format`, strict.
- Anything that deletes or moves user data goes through `StowawayCore` and has a test. Paths read
  from the drive are untrusted (see `Engine.storePath` and `Engine.validated`).
- Debug-only tooling lives behind `#if DEBUG` and must not reach Release; `check-release.sh`
  enforces it.
- No new entitlements without updating `check-release.sh` and the
  [review notes](docs/app-store/review-notes.md).

## Screenshots and layout checks

```sh
App/scripts/screenshots.sh
```

This renders every screen with demo data, in light and dark, plus the App Store screenshots at
2880×1800, into `App/build/screenshots`. It uses a Debug build's snapshot mode, so it doesn't need
screen recording permission.

## App icon

```sh
swiftc -swift-version 5 -parse-as-library -o /tmp/make-icon App/scripts/make-icon.swift \
  App/Stowaway/Branding/Logo.swift
/tmp/make-icon App/Stowaway/Resources/Assets.xcassets/AppIcon.appiconset
```

## Releasing

See [docs/app-store/checklist.md](docs/app-store/checklist.md). In short: bump
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `App/project.yml`, regenerate the project,
then in Xcode use Product → Archive and Distribute App → App Store Connect.
