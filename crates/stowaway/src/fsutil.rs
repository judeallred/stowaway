//! Copying, measuring and emptying directory trees.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File, FileTimes, Permissions};
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime};

use walkdir::WalkDir;

use crate::error::{Error, IoContext, Result};

/// Files macOS creates on its own that don't make a folder "non-empty".
const IGNORABLE: &[&str] = &[
    ".DS_Store",
    ".metadata_never_index",
    ".fseventsd",
    ".Spotlight-V100",
    ".Trashes",
];

/// Running totals reported while copying.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CopyProgress {
    /// Bytes of file data copied so far.
    pub bytes: u64,
    /// Entries (files, links, directories) copied so far.
    pub files: u64,
}

/// What a finished copy did.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct CopyStats {
    /// Bytes of file data copied.
    pub bytes: u64,
    /// Entries copied.
    pub files: u64,
    /// Wall-clock duration in seconds.
    pub seconds: f64,
}

/// How an existing destination file is treated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Overwrite {
    /// Replace files that already exist.
    Replace,
    /// Keep files that already exist (no-clobber merge).
    Keep,
}

/// Copies the contents of `src` into the existing directory `dst`.
///
/// Preserves symlinks (as symlinks), permissions, modification times and hard links (by inode),
/// and doesn't cross into other filesystems. Read-only directories get their permissions applied
/// after their contents are written.
///
/// # Errors
///
/// Fails on the first entry that can't be read or written.
pub fn copy_tree(
    src: &Path,
    dst: &Path,
    overwrite: Overwrite,
    progress: &mut dyn FnMut(CopyProgress),
) -> Result<CopyStats> {
    let started = Instant::now();
    let mut totals = CopyProgress::default();
    let mut linked: HashMap<(u64, u64), PathBuf> = HashMap::new();
    let mut dirs: Vec<(PathBuf, fs::Metadata)> = Vec::new();
    let mut last_report = Instant::now();

    for entry in WalkDir::new(src).min_depth(1).same_file_system(true) {
        let entry = entry.map_err(|e| walk_error(src, e))?;
        let rel = entry.path().strip_prefix(src).map_err(|_| {
            Error::Invalid(format!("{} escaped the copy root", entry.path().display()))
        })?;
        let target = dst.join(rel);
        let meta = entry
            .path()
            .symlink_metadata()
            .ctx("inspecting", entry.path())?;
        let file_type = meta.file_type();

        if file_type.is_dir() {
            match fs::symlink_metadata(&target) {
                Ok(existing) if existing.is_dir() => make_writable(&target, &existing)?,
                _ => fs::create_dir_all(&target).ctx("creating", &target)?,
            }
            dirs.push((target, meta));
        } else if target.symlink_metadata().is_ok() && overwrite == Overwrite::Keep {
            continue;
        } else if file_type.is_symlink() {
            remove_if_present(&target)?;
            let link = fs::read_link(entry.path()).ctx("reading link", entry.path())?;
            symlink(&link, &target).ctx("creating link", &target)?;
        } else if file_type.is_file() {
            remove_if_present(&target)?;
            let key = (meta.dev(), meta.ino());
            if meta.nlink() > 1
                && let Some(first) = linked.get(&key)
            {
                fs::hard_link(first, &target).ctx("hard-linking", &target)?;
            } else {
                fs::copy(entry.path(), &target).ctx("copying", entry.path())?;
                set_times(&target, &meta)?;
                totals.bytes = totals.bytes.saturating_add(meta.len());
                if meta.nlink() > 1 {
                    linked.insert(key, target.clone());
                }
            }
        }
        // Sockets, FIFOs and devices are skipped: they never belong in caches.
        totals.files = totals.files.saturating_add(1);
        if last_report.elapsed().as_millis() >= 200 {
            progress(totals);
            last_report = Instant::now();
        }
    }

    for (dir, meta) in dirs.iter().rev() {
        fs::set_permissions(dir, Permissions::from_mode(meta.mode()))
            .ctx("setting permissions", dir)?;
        set_times(dir, meta)?;
    }
    progress(totals);
    Ok(CopyStats {
        bytes: totals.bytes,
        files: totals.files,
        seconds: started.elapsed().as_secs_f64(),
    })
}

fn set_times(path: &Path, meta: &fs::Metadata) -> Result<()> {
    let modified = meta.modified().ctx("reading mtime", path)?;
    let accessed = meta.accessed().unwrap_or(modified);
    let times = FileTimes::new()
        .set_modified(modified)
        .set_accessed(accessed);
    let file = if path.is_dir() {
        File::open(path)
    } else {
        fs::OpenOptions::new()
            .write(true)
            .open(path)
            .or_else(|_| File::open(path))
    };
    // Read-only files can't be opened for writing; their times are best-effort.
    if let Ok(file) = file {
        let _ignored = file.set_times(times);
    }
    Ok(())
}

fn make_writable(path: &Path, meta: &fs::Metadata) -> Result<()> {
    let mode = meta.mode();
    if mode & 0o200 == 0 {
        fs::set_permissions(path, Permissions::from_mode(mode | 0o700))
            .ctx("making writable", path)?;
    }
    Ok(())
}

fn remove_if_present(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => remove_tree(path),
        Ok(_) => fs::remove_file(path).ctx("removing", path),
        Err(_) => Ok(()),
    }
}

fn walk_error(root: &Path, e: walkdir::Error) -> Error {
    let path = e
        .path()
        .map_or_else(|| root.to_path_buf(), Path::to_path_buf);
    let io = e
        .into_io_error()
        .unwrap_or_else(|| std::io::Error::other("filesystem loop"));
    Error::io("walking", &path, io)
}

/// A cheap summary of a tree, used to detect changes during a copy.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Fingerprint {
    /// Number of entries.
    pub entries: u64,
    /// Sum of file sizes.
    pub bytes: u64,
    /// Newest modification time, in nanoseconds since the epoch.
    pub newest_mtime_ns: i128,
}

/// Summarizes `dir` (not following symlinks, not crossing filesystems).
///
/// # Errors
///
/// Fails if the tree can't be read.
pub fn fingerprint(dir: &Path) -> Result<Fingerprint> {
    let mut fp = Fingerprint::default();
    for entry in WalkDir::new(dir).min_depth(1).same_file_system(true) {
        let entry = entry.map_err(|e| walk_error(dir, e))?;
        let meta = entry
            .path()
            .symlink_metadata()
            .ctx("inspecting", entry.path())?;
        fp.entries = fp.entries.saturating_add(1);
        if meta.is_file() {
            fp.bytes = fp.bytes.saturating_add(meta.len());
        }
        let mtime = i128::from(meta.mtime())
            .saturating_mul(1_000_000_000)
            .saturating_add(i128::from(meta.mtime_nsec()));
        fp.newest_mtime_ns = fp.newest_mtime_ns.max(mtime);
    }
    Ok(fp)
}

/// Seconds since anything under `dir` was last modified, or `None` if it's empty.
///
/// # Errors
///
/// Fails if the tree can't be read.
pub fn seconds_since_last_change(dir: &Path) -> Result<Option<u64>> {
    let fp = fingerprint(dir)?;
    if fp.entries == 0 {
        return Ok(None);
    }
    let newest = i64::try_from(fp.newest_mtime_ns / 1_000_000_000).unwrap_or(i64::MAX);
    Ok(Some(
        u64::try_from(crate::now_unix().saturating_sub(newest)).unwrap_or(0),
    ))
}

/// Whether `dir` has no entries other than ones macOS creates by itself.
///
/// # Errors
///
/// Fails if `dir` exists but can't be read.
pub fn is_effectively_empty(dir: &Path) -> Result<bool> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(true),
        Err(e) => return Err(Error::io("reading", dir, e)),
    };
    for entry in entries {
        let entry = entry.ctx("reading", dir)?;
        let name = entry.file_name();
        if !IGNORABLE.iter().any(|i| name == *i) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Whether `dir` contains any of the named files directly inside it.
#[must_use]
pub fn contains_any(dir: &Path, names: &[&str]) -> bool {
    names.iter().any(|n| dir.join(n).symlink_metadata().is_ok())
}

/// Deletes everything inside `dir` but keeps `dir` itself (it may be a mount point).
/// Read-only directories (Go's module cache) are made writable first.
///
/// # Errors
///
/// Fails if something can't be removed.
pub fn clear_dir_contents(dir: &Path) -> Result<()> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(Error::io("reading", dir, e)),
    };
    for entry in entries {
        let entry = entry.ctx("reading", dir)?;
        let name = entry.file_name();
        if IGNORABLE.iter().any(|i| name == *i) {
            continue;
        }
        remove_if_present(&entry.path())?;
    }
    Ok(())
}

/// Deletes a tree, making read-only directories writable as needed.
///
/// # Errors
///
/// Fails if something can't be removed.
pub fn remove_tree(path: &Path) -> Result<()> {
    match fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            for entry in WalkDir::new(path).same_file_system(true) {
                let Ok(entry) = entry else { continue };
                if entry.file_type().is_dir()
                    && let Ok(meta) = entry.metadata()
                {
                    make_writable(entry.path(), &meta)?;
                }
            }
            fs::remove_dir_all(path).ctx("removing", path)
        }
        Err(e) => Err(Error::io("removing", path, e)),
    }
}

/// Bytes actually allocated on disk under `path`, counting hard-linked files once and staying
/// on one filesystem.
///
/// # Errors
///
/// Fails if the tree can't be read.
pub fn allocated_bytes(path: &Path) -> Result<u64> {
    let mut seen: HashSet<(u64, u64)> = HashSet::new();
    let mut total: u64 = 0;
    for entry in WalkDir::new(path).same_file_system(true) {
        let entry = entry.map_err(|e| walk_error(path, e))?;
        let meta = entry
            .path()
            .symlink_metadata()
            .ctx("inspecting", entry.path())?;
        if meta.nlink() > 1 && !meta.is_dir() && !seen.insert((meta.dev(), meta.ino())) {
            continue;
        }
        total = total.saturating_add(meta.blocks().saturating_mul(512));
    }
    Ok(total)
}

/// Unix time in seconds of a `SystemTime`, clamped to zero.
#[must_use]
pub fn unix_seconds(time: SystemTime) -> i64 {
    time.duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn write(path: &Path, contents: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }

    #[test]
    fn copies_files_links_hardlinks_and_times() {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        write(&src.path().join("a/b.txt"), "hello");
        symlink("a/b.txt", src.path().join("link")).unwrap();
        fs::hard_link(src.path().join("a/b.txt"), src.path().join("hard")).unwrap();
        let old = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000_000);
        File::options()
            .write(true)
            .open(src.path().join("a/b.txt"))
            .unwrap()
            .set_modified(old)
            .unwrap();

        let stats = copy_tree(src.path(), dst.path(), Overwrite::Replace, &mut |_| {}).unwrap();

        assert_eq!(
            fs::read_to_string(dst.path().join("a/b.txt")).unwrap(),
            "hello"
        );
        assert_eq!(
            fs::read_link(dst.path().join("link")).unwrap(),
            PathBuf::from("a/b.txt")
        );
        let a = fs::metadata(dst.path().join("a/b.txt")).unwrap();
        let h = fs::metadata(dst.path().join("hard")).unwrap();
        assert_eq!(a.ino(), h.ino(), "hard link preserved");
        assert_eq!(a.modified().unwrap(), old, "mtime preserved");
        assert_eq!(stats.bytes, 5, "hard-linked data counted once");
    }

    #[test]
    fn keep_mode_does_not_clobber() {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        write(&src.path().join("same"), "new");
        write(&src.path().join("only-src"), "x");
        write(&dst.path().join("same"), "old");
        copy_tree(src.path(), dst.path(), Overwrite::Keep, &mut |_| {}).unwrap();
        assert_eq!(fs::read_to_string(dst.path().join("same")).unwrap(), "old");
        assert!(dst.path().join("only-src").exists());
    }

    #[test]
    fn read_only_trees_copy_and_clear() {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        write(&src.path().join("ro/file"), "data");
        fs::set_permissions(src.path().join("ro"), Permissions::from_mode(0o555)).unwrap();
        copy_tree(src.path(), dst.path(), Overwrite::Replace, &mut |_| {}).unwrap();
        let mode = fs::metadata(dst.path().join("ro")).unwrap().mode();
        assert_eq!(mode & 0o777, 0o555);
        clear_dir_contents(dst.path()).unwrap();
        clear_dir_contents(src.path()).unwrap();
        assert!(is_effectively_empty(dst.path()).unwrap());
        assert!(is_effectively_empty(src.path()).unwrap());
    }

    #[test]
    fn emptiness_ignores_finder_files() {
        let dir = tempfile::tempdir().unwrap();
        assert!(is_effectively_empty(dir.path()).unwrap());
        write(&dir.path().join(".DS_Store"), "");
        assert!(is_effectively_empty(dir.path()).unwrap());
        write(&dir.path().join("x"), "");
        assert!(!is_effectively_empty(dir.path()).unwrap());
        assert!(is_effectively_empty(&dir.path().join("missing")).unwrap());
    }

    #[test]
    fn fingerprint_changes_with_content() {
        let dir = tempfile::tempdir().unwrap();
        write(&dir.path().join("a"), "1");
        let before = fingerprint(dir.path()).unwrap();
        write(&dir.path().join("b"), "22");
        let after = fingerprint(dir.path()).unwrap();
        assert_ne!(before, after);
        assert_eq!(after.entries, 2);
        assert_eq!(after.bytes, 3);
    }

    #[test]
    fn allocated_counts_hard_links_once() {
        let dir = tempfile::tempdir().unwrap();
        write(&dir.path().join("a"), &"x".repeat(100_000));
        let single = allocated_bytes(dir.path()).unwrap();
        fs::hard_link(dir.path().join("a"), dir.path().join("b")).unwrap();
        assert_eq!(allocated_bytes(dir.path()).unwrap(), single);
    }
}
