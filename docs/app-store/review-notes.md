# Notes for App Review

Paste the text below into App Store Connect → the version → **App Review Information → Notes**.
Keep it current when behavior changes.

---

Stowaway helps developers reclaim disk space from folders their tools can re-create
(node_modules, Cargo and Xcode build files, package caches). It finds them in folders the user
chooses, and can delete them or keep them on an external drive.

HOW TO TRY IT (no external drive needed)

1. On first launch the Stowaway window opens with a short welcome. Click "Set Up Later" to go
   straight to the main window, then click "Or Create a Sample Project to Try It…" and choose
   any folder, such as Documents. Stowaway creates a small sample (a web project with
   node_modules and a Rust project with build files) and adds it to the folders it looks in.
   (Or go through the welcome steps and choose any folder of your own that holds code; each
   step is optional.)
2. The main window shows what Stowaway found, by kind, and what it's doing. Click "Folders…"
   (bottom right) to see each folder with its size.
3. Click "Connect External Storage…" (top right of the main window) and pick any folder, for
   example a new folder in Documents. An external drive works the same way, but isn't required.
4. Stowing is automatic, after the folders are left unchanged for a few minutes. To see it at
   once: in Folders, select a row and click Stow. The folder moves to the drive, and Stowaway
   leaves a symbolic link where it was, so tools still find it. "Where" shows "Drive".
5. Right-click it for Bring Back to Mac, or click Delete… to remove it. Neither ever requires a
   purchase.

Once a drive is chosen, Stowaway also stows folders that have been left unchanged
for 5 minutes on its own (Settings → "Stow automatically": immediately, after a set time, or
never). Nothing is
stowed automatically before the user chooses a location, and nothing is ever deleted
automatically.

Stowing is free up to 100 GB. The in-app purchases lift that limit; every purchase unlocks
the same thing (unlimited stowing), at the price the user chooses. Folders already stowed keep
working, and bringing them back or deleting them is never limited.

EXPENSING A BUSINESS PURCHASE

Under "For Work", "Letter to Your Boss…" drafts an email-ready request, and "Preview Invoice…"
shows a sample invoice (watermarked PREVIEW) with the App Store's price, for the user's expense
software. After a purchase it becomes "Paid Invoice…", showing the price paid and the App Store
transaction ID. It states that the purchase was made through the Mac App Store and that Apple's
receipt is the official record of payment. Neither takes payment or links outside the app.
"Redeem Code…" (macOS 15 and later) opens Apple's offer code sheet.

ENTITLEMENTS

- com.apple.security.files.user-selected.read-write and bookmarks.app-scope: Stowaway only works
  in folders the user chooses in an open panel, and remembers them with security-scoped
  bookmarks.
- com.apple.security.files.user-selected.executable: Stowaway moves build folders and package
  caches between the user's folders and the drive. They contain executables: compiled build
  tools, native Node.js modules, the binaries in node_modules/.bin. Without this entitlement the
  sandbox quarantines every file Stowaway copies, and the user's build tools stop running. The
  executables are the user's own build output, never code Stowaway downloads or runs.

BACKGROUND BEHAVIOR

Stowaway is a menu bar app. It doesn't open at login unless the user turns on "Open Stowaway at
login" (the last onboarding step, where it's shown checked and applied only when the user
clicks Done, or Settings). While running, it watches for the drive being
unplugged and switches stowed folders to empty local folders so the user's builds keep
working.

DATA

Stowaway collects no data and makes no network requests of its own. During onboarding it asks
Spotlight where project files such as package.json are, to suggest folders like ~/code; it reads
only the paths Spotlight returns, on the Mac, and still asks the user to choose the folder. "Report a Bug…" opens a
prefilled GitHub issue in the browser for the user to review and submit; it contains only
version numbers and counts, no paths.
