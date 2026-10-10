//! End-to-end tests against a real APFS disk image standing in for the external drive.
//!
//! These attach and force-detach disk images, so they're `#[ignore]`d by default and run with
//! `cargo test -p stowaway --test disk_image -- --ignored --test-threads=1`.
#![expect(clippy::unwrap_used, reason = "test helpers should fail loudly")]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use stowaway::config::Config;
use stowaway::engine::{self, AdoptOptions, AttachOutcome, Engine};
use stowaway::fsutil::{self, Overwrite, Pace};
use stowaway::hdiutil;
use stowaway::idle::is_mount_point;
use stowaway::kinds::KindId;
use stowaway::paths::Layout;
use stowaway::registry::{Entry, EntryStatus};

struct TestDrive {
    image: PathBuf,
    mount_point: PathBuf,
    device: String,
    _dir: tempfile::TempDir,
}

impl TestDrive {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let name = format!("StowTest{}", std::process::id());
        let image = dir.path().join("drive.sparseimage");
        run(
            "hdiutil",
            &[
                "create",
                "-quiet",
                "-size",
                "2g",
                "-fs",
                "APFS",
                "-volname",
                &name,
                "-type",
                "SPARSE",
                image.to_str().unwrap(),
            ],
        );
        let mut drive = Self {
            image,
            mount_point: PathBuf::new(),
            device: String::new(),
            _dir: dir,
        };
        drive.attach();
        drive
    }

    fn attach(&mut self) {
        let out = run(
            "hdiutil",
            &[
                "attach",
                "-nobrowse",
                "-owners",
                "on",
                self.image.to_str().unwrap(),
            ],
        );
        // The first line names the whole-disk device; the line with a path is the mount.
        out.split_whitespace()
            .next()
            .unwrap()
            .clone_into(&mut self.device);
        for line in out.lines() {
            if let Some(mount) = line
                .split('\t')
                .map(str::trim)
                .find(|f| f.starts_with("/Volumes/"))
            {
                self.mount_point = PathBuf::from(mount);
            }
        }
        assert!(self.mount_point.is_dir(), "drive mounted: {out}");
    }

    /// Simulates unplugging the drive without ejecting it, then waits for `mounts` (the images on
    /// it) to vanish: macOS tears nested mounts down asynchronously, and writing into a folder
    /// before then fails with an I/O error.
    fn yank(&self, mounts: &[&Path]) {
        run("hdiutil", &["detach", "-force", &self.device]);
        assert!(!self.mount_point.exists() || fs::read_dir(&self.mount_point).is_err());
        let started = std::time::Instant::now();
        while mounts.iter().any(|m| is_mount_point(m)) && started.elapsed().as_secs() < 30 {
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        assert!(!mounts.iter().any(|m| is_mount_point(m)));
    }
}

impl Drop for TestDrive {
    fn drop(&mut self) {
        // Detach images that live on this drive, then the drive itself, looking each device up
        // by its image. Device numbers are reused, so after a yank `self.device` may already
        // belong to someone else's image, such as a real Stowaway mount.
        let Ok(out) = Command::new("hdiutil").args(["info"]).output() else {
            return;
        };
        let text = String::from_utf8_lossy(&out.stdout);
        let drive_root = self.mount_point.to_str().unwrap_or("?");
        let own_image = self.image.to_str().unwrap_or("?");
        let mut nested = Vec::new();
        let mut drive_devices = Vec::new();
        let mut current: Option<String> = None;
        for line in text.lines() {
            if let Some(path) = line.strip_prefix("image-path      : ") {
                current = Some(path.to_owned());
            } else if line.starts_with("/dev/disk")
                && let Some(path) = current.take()
            {
                let device = line
                    .split_whitespace()
                    .next()
                    .unwrap_or_default()
                    .to_owned();
                if path.starts_with(drive_root) {
                    nested.push(device);
                } else if path == own_image || path.ends_with(own_image) {
                    drive_devices.push(device);
                }
            }
        }
        for device in nested.iter().chain(&drive_devices) {
            let _detached = Command::new("hdiutil")
                .args(["detach", "-force", device])
                .output();
        }
    }
}

fn run(program: &str, args: &[&str]) -> String {
    let out = Command::new(program).args(args).output().unwrap();
    assert!(
        out.status.success(),
        "{program} {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

struct Setup {
    drive: TestDrive,
    engine: Engine,
    code: PathBuf,
    _home: tempfile::TempDir,
}

fn setup() -> Setup {
    let drive = TestDrive::new();
    let home = tempfile::tempdir().unwrap();
    let home_path = fs::canonicalize(home.path()).unwrap();
    let code = home_path.join("code");
    fs::create_dir_all(&code).unwrap();
    let layout = Layout::rooted(&home_path, &home_path.join(".stowaway"));
    engine::init(&layout, &drive.mount_point, std::slice::from_ref(&code)).unwrap();
    let mut config = Config::load_required(&layout).unwrap();
    config.disabled_kinds = KindId::ALL
        .into_iter()
        .filter(|k| ![KindId::Node, KindId::CargoTarget].contains(k))
        .collect();
    config.idle_seconds = 0;
    config.min_adopt_bytes = 0;
    config.save(&layout).unwrap();
    let engine = Engine::open(layout).unwrap();
    Setup {
        drive,
        engine,
        code,
        _home: home,
    }
}

fn write(path: &Path, contents: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, contents).unwrap();
}

fn node_project(code: &Path, name: &str, with_modules: bool) -> PathBuf {
    let project = code.join(name);
    write(&project.join("package.json"), "{}");
    write(&project.join("package-lock.json"), "{}");
    if with_modules {
        write(
            &project.join("node_modules/dep/index.js"),
            "module.exports = 1;",
        );
        write(&project.join("node_modules/.package-lock.json"), "{}");
    }
    project.join("node_modules")
}

#[test]
#[ignore = "attaches disk images"]
fn adopt_yank_work_offline_and_reconnect() {
    let mut s = setup();
    let modules = node_project(&s.code, "app", true);

    let entry = s
        .engine
        .adopt(&modules, KindId::Node, AdoptOptions::default())
        .unwrap();
    assert_eq!(entry.status, EntryStatus::Mounted);
    assert!(
        is_mount_point(&modules),
        "node_modules is now the image's volume"
    );
    assert_eq!(
        fs::read_to_string(modules.join("dep/index.js")).unwrap(),
        "module.exports = 1;"
    );

    // Unplug: the mount disappears (macOS tears nested mounts down asynchronously) and the
    // empty local folder shows through.
    s.drive.yank(&[&modules]);
    assert!(fsutil::is_effectively_empty(&modules).unwrap());
    s.engine.reconcile().unwrap();
    assert_eq!(
        s.engine.registry.entries().unwrap()[0].status,
        EntryStatus::Local
    );

    // Work offline: a finished install lands in the local folder.
    write(&modules.join("dep/index.js"), "module.exports = 2;");
    write(&modules.join(".package-lock.json"), "{}");

    // Plug back in: local wins because it's a complete install, and moves to the drive.
    s.drive.attach();
    let outcomes = s.engine.reconcile().unwrap();
    assert!(
        outcomes.iter().any(|(_, o)| *o == AttachOutcome::Mounted),
        "{outcomes:?}"
    );
    assert!(is_mount_point(&modules));
    assert_eq!(
        fs::read_to_string(modules.join("dep/index.js")).unwrap(),
        "module.exports = 2;"
    );
}

#[test]
#[ignore = "attaches disk images"]
fn incomplete_offline_work_does_not_replace_the_drive_copy() {
    let mut s = setup();
    let modules = node_project(&s.code, "app", true);
    s.engine
        .adopt(&modules, KindId::Node, AdoptOptions::default())
        .unwrap();
    s.drive.yank(&[&modules]);
    s.engine.reconcile().unwrap();
    // Only a tool cache was written while offline: no install marker.
    write(&modules.join(".cache/eslint/x"), "cache");
    s.drive.attach();
    s.engine.reconcile().unwrap();
    assert!(is_mount_point(&modules));
    assert!(
        modules.join("dep/index.js").exists(),
        "the complete install survived"
    );
    assert!(!modules.join(".cache").exists());
}

#[test]
#[ignore = "attaches disk images"]
fn cargo_target_keeps_the_drive_copy_on_reconnect() {
    let mut s = setup();
    let project = s.code.join("rs");
    write(&project.join("Cargo.toml"), "[package]\nname = \"rs\"\n");
    write(&project.join("Cargo.lock"), "");
    write(
        &project.join("target/CACHEDIR.TAG"),
        "Signature: 8a477f597d28d172789f06886806bc55",
    );
    write(&project.join("target/debug/deps/big-build"), "full build");
    write(&project.join("target/debug/rs"), "the program");
    let deps = project.join("target/debug/deps");
    s.engine
        .adopt(&deps, KindId::CargoTarget, AdoptOptions::default())
        .unwrap();
    s.drive.yank(&[&deps]);
    s.engine.reconcile().unwrap();
    assert!(
        project.join("target/debug/rs").exists(),
        "the program stays runnable without the drive"
    );
    write(&deps.join("partial"), "offline");
    s.drive.attach();
    s.engine.reconcile().unwrap();
    assert!(is_mount_point(&deps));
    assert!(deps.join("big-build").exists());
    assert!(!deps.join("partial").exists());
}

/// Recreates what v0.1 left behind: a whole `target/` stowed as one image and mounted on it.
fn stow_whole(s: &mut Setup, target: &Path) -> Entry {
    let id = "01legacywholetarget0000000a".to_owned();
    let image = s.engine.drive().unwrap().layout.image_path(&id);
    hdiutil::create(&image, 1_000_000_000, "stow legacy", false).unwrap();
    let staging = tempfile::tempdir().unwrap();
    let attached = hdiutil::attach(&image, staging.path()).unwrap();
    fsutil::copy_tree(target, staging.path(), Overwrite::Replace, &mut |_| {
        Pace::Go
    })
    .unwrap();
    hdiutil::detach(&attached.device, false).unwrap();
    fsutil::clear_dir_contents(target).unwrap();
    hdiutil::attach(&image, target).unwrap();
    let entry = Entry {
        id,
        kind: KindId::CargoTarget,
        path: target.to_path_buf(),
        created_at: 0,
        used_bytes: 0,
        image_bytes: 0,
        last_seen_at: 0,
        orphaned_at: None,
        status: EntryStatus::Mounted,
        note: None,
    };
    s.engine.registry.insert(&entry).unwrap();
    entry
}

#[test]
#[ignore = "attaches disk images"]
fn whole_targets_are_split_into_build_folders() {
    let mut s = setup();
    let project = s.code.join("rs");
    write(&project.join("Cargo.toml"), "[package]\nname = \"rs\"\n");
    write(&project.join("Cargo.lock"), "");
    let target = project.join("target");
    write(
        &target.join("CACHEDIR.TAG"),
        "Signature: 8a477f597d28d172789f06886806bc55",
    );
    for file in [
        "debug/deps/librs-1.rlib",
        "debug/incremental/rs-2/s-3/dep-graph.bin",
        "debug/build/rs-4/output",
        "release/deps/rs-5",
    ] {
        write(&target.join(file), "intermediate");
    }
    write(&target.join("debug/rs"), "debug program");
    write(&target.join("release/rs"), "release program");
    write(
        &target.join("debug/.fingerprint/rs-1/lib-rs"),
        "fingerprint",
    );
    let old = stow_whole(&mut s, &target);
    assert!(is_mount_point(&target));
    assert_eq!(s.engine.whole_entries().unwrap().len(), 1);

    let parts = s.engine.split_entry(&old).unwrap();

    let mut paths: Vec<_> = parts
        .iter()
        .map(|e| e.path.strip_prefix(&target).unwrap().display().to_string())
        .collect();
    paths.sort();
    assert_eq!(
        paths,
        [
            "debug/build",
            "debug/deps",
            "debug/incremental",
            "release/deps"
        ]
    );
    assert!(!is_mount_point(&target), "target itself is local again");
    for part in &parts {
        assert!(is_mount_point(&part.path), "{}", part.path.display());
    }
    assert!(target.join("debug/deps/librs-1.rlib").exists());
    assert!(
        target
            .join("debug/incremental/rs-2/s-3/dep-graph.bin")
            .exists()
    );
    assert_eq!(
        fs::read_to_string(target.join("release/rs")).unwrap(),
        "release program"
    );
    assert!(target.join("debug/.fingerprint/rs-1/lib-rs").exists());
    assert!(s.engine.registry.by_id(&old.id).unwrap().is_none());
    assert!(s.engine.whole_entries().unwrap().is_empty());

    let mounts: Vec<&Path> = parts.iter().map(|e| e.path.as_path()).collect();
    s.drive.yank(&mounts);
    assert_eq!(
        fs::read_to_string(target.join("debug/rs")).unwrap(),
        "debug program",
        "the programs stay runnable without the drive"
    );
    s.drive.attach();
    s.engine.reconcile().unwrap();
    assert!(parts.iter().all(|e| is_mount_point(&e.path)));
}

#[test]
#[ignore = "attaches disk images"]
fn pre_adoption_and_auto_adopt() {
    let mut s = setup();
    let fresh = node_project(&s.code, "fresh", false);
    let existing = node_project(&s.code, "existing", true);
    let member = s.code.join("existing/packages/ui");
    write(&member.join("package.json"), "{}");
    write(&member.join("node_modules/x/index.js"), "");

    let results = s.engine.auto_adopt().unwrap();
    assert_eq!(results.len(), 2, "{results:?}");
    assert!(results.iter().all(|(_, r)| r.is_ok()), "{results:?}");
    assert!(
        is_mount_point(&fresh),
        "pre-adopted before the first install"
    );
    assert!(is_mount_point(&existing));
    assert!(
        !is_mount_point(&member.join("node_modules")),
        "workspace member stays local"
    );
}

#[test]
#[ignore = "attaches disk images"]
fn release_with_copy_restores_a_plain_folder() {
    let mut s = setup();
    let modules = node_project(&s.code, "app", true);
    let entry = s
        .engine
        .adopt(&modules, KindId::Node, AdoptOptions::default())
        .unwrap();
    let image = s.drive.mount_point.join(format!(
        ".stowaway/{}.noindex/images/{}.sparsebundle",
        s.engine.config.machine_id, entry.id
    ));
    assert!(image.exists());
    s.engine.release(&modules, true).unwrap();
    assert!(!is_mount_point(&modules));
    assert_eq!(
        fs::read_to_string(modules.join("dep/index.js")).unwrap(),
        "module.exports = 1;"
    );
    assert!(!image.exists());
    assert!(s.engine.registry.entries().unwrap().is_empty());
}

#[test]
#[ignore = "attaches disk images"]
fn deleted_and_moved_repositories() {
    let mut s = setup();
    let gone = node_project(&s.code, "gone", true);
    let moving = node_project(&s.code, "moving", true);
    s.engine
        .adopt(&gone, KindId::Node, AdoptOptions::default())
        .unwrap();
    s.engine
        .adopt(&moving, KindId::Node, AdoptOptions::default())
        .unwrap();

    // `rm -rf gone` deletes everything except the mount point, then fails.
    let rm = Command::new("rm")
        .args(["-rf", s.code.join("gone").to_str().unwrap()])
        .output()
        .unwrap();
    assert!(
        !rm.status.success(),
        "rm hits Resource busy on the mount point"
    );
    fs::rename(s.code.join("moving"), s.code.join("moved")).unwrap();

    s.engine.reconcile().unwrap();
    let entries = s.engine.registry.entries().unwrap();
    assert_eq!(entries.len(), 1, "{entries:?}");
    assert_eq!(
        entries[0].path,
        s.code.join("moved/node_modules"),
        "path followed the move"
    );
    assert!(!s.code.join("gone").exists(), "empty leftovers removed");
}

#[test]
#[ignore = "attaches disk images"]
fn clean_compact_and_gc() {
    let mut s = setup();
    let modules = node_project(&s.code, "app", true);
    s.engine
        .adopt(&modules, KindId::Node, AdoptOptions::default())
        .unwrap();

    let cleaned = s.engine.clean(&s.code).unwrap();
    assert_eq!(cleaned, vec![modules.clone()]);
    assert!(is_mount_point(&modules), "clean keeps the mount");
    assert!(fsutil::is_effectively_empty(&modules).unwrap());

    write(&modules.join("again/index.js"), "x");
    s.engine.compact(None, true).unwrap();
    assert!(is_mount_point(&modules));
    assert!(
        modules.join("again/index.js").exists(),
        "contents survive compaction"
    );

    let orphan = s.drive.mount_point.join(format!(
        ".stowaway/{}.noindex/images/stray.sparsebundle",
        s.engine.config.machine_id
    ));
    fs::create_dir_all(&orphan).unwrap();
    assert_eq!(s.engine.gc(true).unwrap(), vec![orphan.clone()]);
    s.engine.gc(false).unwrap();
    assert!(!orphan.exists());
}

#[test]
#[ignore = "attaches disk images"]
fn tracked_folders_are_never_adopted() {
    let mut s = setup();
    let modules = node_project(&s.code, "action", true);
    let repo = s.code.join("action");
    run("git", &["-C", repo.to_str().unwrap(), "init", "-q"]);
    run(
        "git",
        &["-C", repo.to_str().unwrap(), "add", "node_modules"],
    );
    let err = s
        .engine
        .adopt(&modules, KindId::Node, AdoptOptions { force: true })
        .unwrap_err();
    assert!(err.to_string().contains("tracked by git"), "{err}");
    assert!(!is_mount_point(&modules));
}

#[test]
#[ignore = "attaches disk images and runs cargo"]
fn real_cargo_builds_through_the_mount_and_offline() {
    let mut s = setup();
    let project = s.code.join("hello");
    run(
        "cargo",
        &["new", "-q", "--vcs", "none", project.to_str().unwrap()],
    );
    let build = |dir: &Path| {
        let out = Command::new("cargo")
            .args(["build", "-q", "--offline"])
            .current_dir(dir)
            .env_remove("CARGO_TARGET_DIR")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    };
    build(&project);
    let target = project.join("target");
    let results = s.engine.auto_adopt().unwrap();
    assert!(results.iter().all(|(_, r)| r.is_ok()), "{results:?}");
    let deps = target.join("debug/deps");
    assert!(is_mount_point(&deps));
    assert!(!is_mount_point(&target), "target itself stays local");
    build(&project);
    let hello = target.join("debug/hello");
    assert!(hello.exists());

    let mounts: Vec<PathBuf> = s
        .engine
        .registry
        .entries()
        .unwrap()
        .into_iter()
        .map(|e| e.path)
        .collect();
    let mount_refs: Vec<&Path> = mounts.iter().map(PathBuf::as_path).collect();
    s.drive.yank(&mount_refs);
    let ran = Command::new(&hello).output().unwrap();
    assert!(
        ran.status.success(),
        "the built program runs without the drive"
    );
    build(&project);
    assert!(hello.exists(), "builds locally while the drive is gone");

    s.drive.attach();
    let outcomes = s.engine.reconcile().unwrap();
    assert!(
        is_mount_point(&deps),
        "{outcomes:?} {:?}",
        s.engine.registry.entries().unwrap()
    );
    build(&project);
}
