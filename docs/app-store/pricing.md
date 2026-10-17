# Pricing and price discrimination on the Mac App Store

Researched October 2026. Apple's rules change; re-check anything marked *verify* in App Store
Connect before relying on it.

## What's built

Stowaway is free to download. Finding and deleting folders is free, and so is stowing up to
**100 GB**. **Any** purchase, at any price, makes stowing unlimited for good. The upgrade sheet
offers two groups of prices, picked with a "For Me / For Work" switch:

| Group | Product IDs | Family Sharing | Message |
|---|---|---|---|
| Personal, pay what you want | `com.brooklynspaceport.stowaway.personal.1` … `.8` | **On** | "Share the love… your purchase means everything to us." |
| Business, pay what you will | `com.brooklynspaceport.stowaway.business.1` … `.11` | **Off** | "At work and able to expense it?… keep prices low for everyone using it personally." |

- **Prices aren't in the code.** Product IDs name a slot, not a price, and the app shows whatever
  you set in App Store Connect, sorted low to high. You can reprice without an app update.
- **Changing the number of slots** means editing `Store.productIDs`. Unused slots that don't
  exist in App Store Connect are simply not shown.
- **Everything is non-consumable.** A purchase is restorable and applies on every Mac signed in
  to the same Apple Account.
- **The limit:** 100 GB is `Store.freeOffloadLimit`. The limit only stops *new* offloads: nothing
  already on the drive stops working, and bringing folders back and deleting are never limited.
  That last point matters for App Review and for trust.

## What Apple lets you set

- **Price points:** up to 800 default price points, plus 100 higher ones on request, up to
  **$10,000** per item. ([App Store Connect Help][prices])
- **Per-country prices:** pick a base country and let Apple derive the rest, or set prices per
  storefront yourself. Geographic price discrimination is fully supported.
- **Family Sharing:** turned on per product. That's why personal is on and business is off: a
  business purchase shouldn't flow to an employee's family. ([Apple][family]) *Verify:* Apple
  has said Family Sharing can't be turned off once it's on, so decide before the first release.
- **Offer codes** for one-time purchases (macOS 15 and later): useful for comping press,
  open-source maintainers or support cases. Up to 10 active offers and 1,000,000 codes per app
  per quarter. ([StoreKit offer codes][offers]) *Verify:* the old in-app purchase promo codes
  reportedly stopped being creatable on March 26, 2026.
- **Commission:** 15% under the App Store Small Business Program (under $1M a year in proceeds;
  enroll in App Store Connect), otherwise 30%.

## How far can you price-discriminate?

| Lever | Possible? | Notes |
|---|---|---|
| Self-declared personal vs business | **Yes**, honor system | Apple can't verify it, and neither can you. Keep the product names and descriptions honest ("Business: for use at work"), and never imply a personal purchase is illegitimate at work. Reviewers do read the descriptions. |
| Pay what you want (several price points for the same unlock) | **Yes** | Common "tip jar"-style unlock. Every price must deliver the stated value; here, unlimited offloading. |
| Real differences between tiers | **Yes**, and recommended for business | Strengthens the business tier and protects it in review. Ideas: Family Sharing off (done), priority email support, a named thank-you on the website, or a future feature such as managing several drives. |
| Geography | **Yes** | Per-storefront prices. |
| Volume licensing for companies (Apple Business Manager) | **No** for in-app purchases | Apple's volume purchasing doesn't cover in-app purchases. ([forum][abm], [Jamf][jamf]) Options: each employee buys and expenses it; a paid **custom app** for one company through Apple Business Manager (a separate build sold privately); or offer codes for a team. |
| Subscriptions for business (recurring expense) | **Possible** | An auto-renewing yearly subscription is easy to expense, but Apple expects ongoing value from one. Worth adding later if companies ask for it. |
| Linking to your own checkout | **US only** | Not needed: everything is an in-app purchase. |

## Suggested prices (yours to set in App Store Connect)

- **Personal:** eight prices doubling from $8 to $1,024, each with a line in the app: "A
  sandwich", "A really nice sandwich", "Sandwiches for the whole team", "Dinner for one", "Dinner
  for the whole team", "Still cheaper than upgrading your storage", "We will send you a
  hand-written thank you card", "We'll send you a birthday card every year".
- **Business:** ten prices from $50 to $500 in $50 steps, under "I can expense:", asking people to
  pick what fits their auto-approve expense budget; then a full-width $5,000 "Enterprise".
- Apple's price points include round prices such as $8.00 and $50.00, but *verify* each in App
  Store Connect, especially $1,024 and $5,000 (prices above the default range must be requested).
- **Sanity check:** a 1 TB external SSD costs about $80–120, and Apple typically charges around $200
  to go from 512 GB to 1 TB at purchase. A personal price well below the drive and a business price below
  the internal upgrade is an easy story.
- **Later:** run an offer code for launch press, and revisit the 100 GB free limit once you see
  real usage. It's one constant.

## Copy

The upgrade sheet uses your words, lightly edited for clarity ("gobs of money" became "paying
for a bigger internal drive"). It's in
`App/Stowaway/Views/SupportView.swift`; change it freely. Product display names and
descriptions live in App Store Connect; suggested text is in `metadata.md`.

[prices]: https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/set-a-price-for-an-in-app-purchase
[family]: https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/turn-on-family-sharing-for-in-app-purchases
[offers]: https://developer.apple.com/documentation/storekit/supporting-offer-codes-in-your-app
[abm]: https://developer.apple.com/forums/thread/660196
[jamf]: https://support.jamf.com/en/articles/11029581-in-app-purchases-for-volume-purchasing-managed-apps-from-jamf-now
