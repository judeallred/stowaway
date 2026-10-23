# Release checklist

What's done in the repository, and what needs you (an Apple Developer account, App Store
Connect, the website). Work top to bottom.

## Done in the repository

- [x] Sandboxed app, with only the entitlements it needs and no temporary exceptions
      (`App/project.yml`).
- [x] Privacy manifest declaring the required-reason APIs it uses (file timestamps, disk space,
      user defaults), with no tracking and no data collected.
- [x] Export compliance: `ITSAppUsesNonExemptEncryption = NO`.
- [x] Category Developer Tools, menu bar app (`LSUIElement`), minimum macOS 14.
- [x] App icon in every macOS size (`App/scripts/make-icon.swift`).
- [x] StoreKit 2 purchases with Restore Purchases, verified transactions, refunds honored, and a
      local StoreKit configuration for testing (`Products.storekit`).
- [x] No license screens or keys (2.4.5(vi)), no self-updating (2.4.5(vii)), nothing at login
      without consent (2.4.5(iii)), nothing downloaded or installed (2.4.5(iv)).
- [x] No hidden features: Debug-only tooling is compiled out, and `App/scripts/check-release.sh`
      fails the build if any reaches Release. CI runs it on every push.
- [x] Links to the support page, privacy policy and Terms of Use (Apple's standard EULA) in the
      app.
- [x] Review notes, listing metadata, in-app purchase descriptions and a privacy policy draft
      (this folder).

## Needs you

1. **Apple Developer Program** membership (paid, individual or organization).
   - If you want "Brooklyn Spaceport" as the seller name, enroll as an organization; that needs
     a D-U-N-S number.
   - The app's copyright currently reads "© 2026 Jude Allred" (`App/project.yml`); change it if
     the seller is a company.
2. **Agreements, Tax and Banking** in App Store Connect: the Paid Apps agreement is required for
   in-app purchases.
3. **App Store Small Business Program:** enroll for the 15% commission.
4. **Bundle ID:** register `com.brooklynspaceport.stowaway` (Certificates, Identifiers &
   Profiles). Enable In-App Purchase; no other capabilities are needed.
5. **Signing:** set `DEVELOPMENT_TEAM` in `App/project.yml` (or in Xcode's Signing &
   Capabilities), keep automatic signing, and regenerate the project if you edit the YAML.
6. **App record** in App Store Connect: create the macOS app and fill in `metadata.md`.
7. **In-app purchases:** create the thirteen non-consumables (seven personal, six business) in `metadata.md`, set prices
   (`pricing.md`), set Family Sharing on for personal and off for business, and attach a review
   screenshot to each.
8. **Website:** publish brooklynspaceport.com/stowaway, `/support` and `/privacy`
   (`privacy-policy.md`) before submitting. Review checks that the links load.
9. **Screenshots:** `App/scripts/screenshots.sh`, then upload.
10. **Build and upload:** in Xcode, Product → Archive, then Distribute App → App Store Connect.
    Bump `CURRENT_PROJECT_VERSION` for every upload.
11. **TestFlight:** install the TestFlight build on a Mac and run through `review-notes.md`
    end to end. Test a sandbox purchase, Restore, and an unplug and replug with a real drive.
12. **Submit**, with `review-notes.md` pasted into App Review Information.

## Before each release

- [ ] `swift test --package-path StowawayCore` passes.
- [ ] `App/scripts/build.sh && App/scripts/check-release.sh` passes.
- [ ] Version and build number bumped in `App/project.yml`.
- [ ] Review notes still describe the app accurately.
