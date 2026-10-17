# Notes for App Review

Paste the text below into App Store Connect → the version → **App Review Information → Notes**.
Keep it current when behavior changes.

---

Stowaway helps developers reclaim disk space from folders their tools can re-create
(node_modules, Cargo and Xcode build files, package caches). It finds them in folders the user
chooses, and can delete them or keep them on an external drive.

HOW TO TRY IT (no external drive needed)

1. On first launch the Stowaway window opens with a short welcome. Click "Set Up Later" to go
   straight to the library, then click "Or Create a Sample Project to Try It…" and choose any
   folder, such as Documents. Stowaway creates a small sample (a web project with node_modules
   and a Rust project with build files) and adds it to the folders it looks in. (Or go through
   the welcome steps and choose any folder of your own that holds code; each step is optional.)
2. The library window lists the sample's node_modules and Cargo build files with their sizes.
3. Click "Choose Offload Location…" (top right) and pick any folder, for example a new folder in
   Documents. An external drive works the same way, but isn't required.
4. Select the row and click Offload. The folder moves to the offload location, and Stowaway
   leaves a symbolic link where it was, so tools still find it. "Where" shows "Drive".
5. Click Bring Back to restore it, or Delete… to remove it. Neither ever requires a purchase.

Once an offload location is chosen, Stowaway also offloads folders that have been left unchanged
for 5 minutes on its own (Settings → "Offload automatically": immediately, after a set time, or
never). Nothing is
offloaded automatically before the user chooses a location, and nothing is ever deleted
automatically.

Offloading is free up to 100 GB. The in-app purchases lift that limit; every purchase unlocks
the same thing (unlimited offloading), at the price the user chooses.

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
clicks Done, or Settings). While running, it watches for the offload drive being
unplugged and switches offloaded folders to empty local folders so the user's builds keep
working.

DATA

Stowaway collects no data and makes no network requests of its own. During onboarding it asks
Spotlight where project files such as package.json are, to suggest folders like ~/code; it reads
only the paths Spotlight returns, on the Mac, and still asks the user to choose the folder. "Report a Bug…" opens a
prefilled GitHub issue in the browser for the user to review and submit; it contains only
version numbers and counts, no paths.
