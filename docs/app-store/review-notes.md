# Notes for App Review

Paste the text below into App Store Connect → the version → **App Review Information → Notes**.
Keep it current when behavior changes.

---

Stowaway helps developers reclaim disk space from folders their tools can re-create
(node_modules, Cargo and Xcode build files, package caches). It finds them in folders the user
chooses, and can delete them or keep them on an external drive.

HOW TO TRY IT (no external drive needed)

1. Create a small sample project to try it on: open Terminal, paste the commands below and
   press Return. They make a folder named "Stowaway Review" in your home folder, holding a web
   project with node_modules and a Rust project with build files (about 25 MB; nothing in it
   runs). Delete the folder when you're done.

   cd ~ && mkdir "Stowaway Review" && cd "Stowaway Review" &&
   mkdir -p web-app rust-tool/src rust-tool/target/debug &&
   printf '{ "name": "web-app", "private": true }\n' > web-app/package.json &&
   for i in $(seq 1 40); do
     p=web-app/node_modules/package-$i && mkdir -p "$p/lib" &&
     printf '{ "name": "package-%s", "version": "1.0.0" }\n' "$i" > "$p/package.json" &&
     for f in $(seq 1 12); do head -c 24000 /dev/urandom | base64 > "$p/lib/module-$f.js"; done
   done &&
   printf '[package]\nname = "rust-tool"\nversion = "0.1.0"\nedition = "2021"\n' > rust-tool/Cargo.toml &&
   echo 'fn main() {}' > rust-tool/src/main.rs &&
   echo 'Signature: 8a477f597d28d172789f06886806bc55' > rust-tool/target/CACHEDIR.TAG &&
   for d in deps incremental build; do
     mkdir -p "rust-tool/target/debug/$d" &&
     for f in $(seq 1 10); do head -c 300000 /dev/urandom > "rust-tool/target/debug/$d/file-$f.rlib"; done
   done &&
   echo 'Created "Stowaway Review" in your home folder.'

   Then open Stowaway. Its window opens with a short welcome: click "Set Up Later", then
   "Choose a Folder…" and choose "Stowaway Review" in your home folder. (Or go through the
   welcome steps and choose it there; each step is optional.)
2. The main window shows what Stowaway found, by kind, and what it's doing. Click "Folders…"
   (bottom right) to see each folder with its size.
3. Click "Choose a Drive…" (top right of the main window) and pick any folder, for
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
prefilled GitHub issue in the browser for the user to review, edit and submit; it contains
version numbers, counts, what kind of location the drive is and the last few drive choices
(described, never as paths), and the last few problems, with paths, file names and the drive's
name redacted.
