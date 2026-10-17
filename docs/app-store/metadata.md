# App Store listing

Everything App Store Connect asks for, with character limits. Drafts: edit freely.

## App information

| Field | Value | Limit |
|---|---|---|
| Name | Stowaway | 30. If taken: "Stowaway: Dev Disk Space" |
| Subtitle | Stow build files and caches | 30 (30) |
| Bundle ID | com.brooklynspaceport.stowaway | |
| SKU | stowaway-mac | |
| Primary category | Developer Tools | |
| Secondary category | Utilities | |
| Content rights | Doesn't contain third-party content | |
| Age rating | 4+ (answer "None" to every question) | |
| Copyright | 2026 Jude Allred | |
| Support URL | https://brooklynspaceport.com/stowaway/support | Must load before you submit |
| Marketing URL | https://brooklynspaceport.com/stowaway | |
| Privacy Policy URL | https://brooklynspaceport.com/stowaway/privacy | Must load before you submit; text in `privacy-policy.md` |

## Promotional text (170)

> Your Mac fills up with node_modules, build files and caches. Stowaway finds them, deletes them
> on request, or keeps them on an external drive. Free up to 100 GB.

## Description (4,000)

> Your Mac's drive fills up with folders your tools can re-create: node_modules, Cargo and Xcode
> build files, package caches, downloaded models. Stowaway finds them, shows you how big they
> are and when you last used them, and lets you delete them in a click.
>
> Or keep them on an external drive instead.
>
> STOW ON AN EXTERNAL DRIVE
> • Stowaway moves a folder to your drive and leaves a link behind, so npm, Cargo, Xcode and
>   your other tools find it exactly where it always was.
> • Unplug the drive and your tools rebuild locally, without asking.
> • Plug it back in and everything moves back to the drive, including anything built while it
>   was away.
> • Folders you haven't changed in 5 minutes move to the drive on their own, so your Mac stays
>   tidy without you thinking about it. (Or stow by hand: it's a setting.)
> • npm projects stay fast: `npm install` with nothing to change takes as long as it always did.
>
> FINDS WHAT YOU CAN SAFELY REMOVE
> • node_modules, Next.js .next, Python .venv
> • Cargo build files and the Cargo registry
> • Xcode DerivedData (built apps stay on your Mac)
> • pnpm, npm, Yarn and bun caches, npx packages
> • Go and Gradle caches, Hugging Face models
>
> CAREFUL BY DESIGN
> • Stowaway only looks in the folders you choose.
> • It never touches source code, and never touches folders git tracks.
> • Bringing folders back and deleting them are always free.
> • No accounts, no tracking, no data collected.
>
> FREE, WITH UNLIMITED STOWING WHEN YOU'RE READY
> Finding and deleting folders is free, and so is stowing up to 100 GB. Are we helping you
> avoid an expensive storage upgrade? Any purchase, at a price you choose, makes stowing
> unlimited. Using it at work? Please choose a business price: business purchases
> keep Stowaway free for everyone using it personally.
>
> Made by Brooklyn Spaceport, a 3-person team making creative products.

## Keywords (100)

`node_modules,cache,cleaner,disk space,developer,xcode,deriveddata,cargo,npm,external drive,ssd`
(94 characters.)

## What's New (first release)

> The first release of Stowaway on the Mac App Store.

## App privacy

Answer **Data Not Collected**. Stowaway sends nothing anywhere; "Report a Bug…" only opens a
browser page the user submits themselves.

## In-app purchases

Create each as **Non-Consumable**. Prices are yours to choose (see `pricing.md`); every one
unlocks the same thing, unlimited stowing. Each needs a review screenshot of the upgrade
sheet: render one with the snapshot mode (`CONTRIBUTING.md`) or take one in the app.

| Product ID | Reference name | Display name (30) | Description (45) | Family Sharing |
|---|---|---|---|---|
| …`personal.1` | Personal 1 | Thanks | Unlimited stowing. Pay what you want. | On |
| …`personal.2` | Personal 2 | Big Thanks | Unlimited stowing. Pay what you want. | On |
| …`personal.3` | Personal 3 | Huge Thanks | Unlimited stowing. Pay what you want. | On |
| …`business.1` | Business 1 | Business | Unlimited stowing for use at work. | Off |
| …`business.2` | Business 2 | Business Plus | Unlimited stowing for use at work. | Off |
| …`business.3` | Business 3 | Business Pro | Unlimited stowing for use at work. | Off |
| …`business.4` | Business 4 | Business Patron | Unlimited stowing for use at work. | Off |

(…= `com.brooklynspaceport.stowaway.`)

## Screenshots

macOS screenshots must be 16:10: 1280×800, 1440×900, 2560×1600 or 2880×1800. 1 to 10 of them.
Suggested set:
1. The library, with a mix of folders on the Mac and on the drive.
2. The menu bar window.
3. Onboarding's welcome screen ("Get your disk space back").
4. The upgrade sheet ("For Me / For Work").

`App/scripts/screenshots.sh` renders these from demo data at 2880×1800.
