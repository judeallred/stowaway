//! Copying, measuring and emptying directory trees.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File, FileTimes, Permissions};
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime};

use walkdir::WalkDir;

use crate::diskload::CopyThreads;
use crate::error::{Error, IoContext, Result};

/// Folders macOS keeps at the root of every volume, including each image. They're owned by root
/// and unreadable, and aren't part of the folder's contents.
const VOLUME_METADATA: &[&str] = &[".fseventsd", ".Spotlight-V100", ".Trashes"];

/// Walks `path` on one filesystem, skipping [`VOLUME_METADATA`] at its top level.
fn walk_tree(
    path: &Path,
    min_depth: usize,
) -> impl Iterator<Item = walkdir::Result<walkdir::DirEntry>> {
    WalkDir::new(path)
        .min_depth(min_depth)
        .same_file_system(true)
        .into_iter()
        .filter_entry(|e| e.depth() != 1 || !VOLUME_METADATA.iter().any(|m| e.file_name() == *m))
}

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

/// What a copy's progress callback wants next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pace {
    /// Keep copying.
    Go,
    /// Stop starting new files; the callback is asked again a second later.
    Wait,
    /// Abandon the copy: it fails with [`Error::Busy`].
    Stop,
}

/// Most files one copy works on at once.
const MAX_COPY_THREADS: usize = 8;
/// Files waiting for a worker. Small, so a [`Pace::Wait`] takes effect quickly.
const QUEUE_DEPTH: usize = 256;
/// How often the progress callback is called.
const REPORT_EVERY: Duration = Duration::from_millis(200);

/// One file for a worker to copy.
struct Job {
    src: PathBuf,
    dst: PathBuf,
    meta: fs::Metadata,
}

/// State shared between the walker and the workers of one copy.
struct Shared {
    queue: Mutex<Receiver<Job>>,
    /// Workers with an index below this may take jobs; the rest idle.
    allowed: AtomicUsize,
    /// Jobs queued or in progress.
    pending: AtomicUsize,
    bytes: AtomicU64,
    files: AtomicU64,
    /// Set when the walk and every job are done, or on the first error.
    stop: AtomicBool,
    error: Mutex<Option<Error>>,
}

impl Shared {
    fn totals(&self) -> CopyProgress {
        CopyProgress {
            bytes: self.bytes.load(Ordering::Relaxed),
            files: self.files.load(Ordering::Relaxed),
        }
    }

    fn fail(&self, error: Error) {
        self.error
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_or_insert(error);
        self.stop.store(true, Ordering::Relaxed);
    }

    fn work(&self, index: usize) {
        while !self.stop.load(Ordering::Relaxed) {
            if index >= self.allowed.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
            let job = self
                .queue
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .recv_timeout(Duration::from_millis(20));
            match job {
                Ok(job) => {
                    match copy_file(&job) {
                        Ok(()) => {
                            self.bytes.fetch_add(job.meta.len(), Ordering::Relaxed);
                            self.files.fetch_add(1, Ordering::Relaxed);
                        }
                        Err(e) => self.fail(e),
                    }
                    self.pending.fetch_sub(1, Ordering::Relaxed);
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
    }
}

fn copy_file(job: &Job) -> Result<()> {
    remove_if_present(&job.dst)?;
    fs::copy(&job.src, &job.dst).ctx("copying", &job.src)?;
    set_times(&job.dst, &job.meta)
}

/// Calls `progress` and, while it asks to wait, idles every worker and asks again each second.
fn pace(
    shared: &Shared,
    threads: &mut CopyThreads,
    progress: &mut dyn FnMut(CopyProgress) -> Pace,
) {
    loop {
        match progress(shared.totals()) {
            Pace::Go => break,
            Pace::Wait if !shared.stop.load(Ordering::Relaxed) => {
                shared.allowed.store(0, Ordering::Relaxed);
                std::thread::sleep(Duration::from_secs(1));
            }
            Pace::Wait => return,
            Pace::Stop => {
                shared.fail(Error::Busy("the copy was stopped".to_owned()));
                return;
            }
        }
    }
    shared.allowed.store(threads.adjust(), Ordering::Relaxed);
}

/// Copies the contents of `src` into the existing directory `dst`.
///
/// Preserves symlinks (as symlinks), permissions, modification times and hard links (by inode),
/// and doesn't cross into other filesystems. Read-only directories get their permissions applied
/// after their contents are written.
///
/// One thread walks the tree, creating directories and links in order, and hands regular files
/// to a pool of workers sized by [`CopyThreads`]: copying many small files is limited by
/// per-file latency, so several in flight are much faster than one. Hard links to a file are
/// created after every file is copied, so their target always exists. `progress` is called on
/// this thread about every 200 ms and can pause the copy with [`Pace::Wait`].
///
/// # Errors
///
/// Fails on the first entry that can't be read or written.
pub fn copy_tree(
    src: &Path,
    dst: &Path,
    overwrite: Overwrite,
    progress: &mut dyn FnMut(CopyProgress) -> Pace,
) -> Result<CopyStats> {
    let started = Instant::now();
    let max = std::thread::available_parallelism().map_or(1, |n| n.get().min(MAX_COPY_THREADS));
    let mut threads = CopyThreads::new(max);
    let (sender, receiver) = mpsc::sync_channel::<Job>(QUEUE_DEPTH);
    let shared = Shared {
        queue: Mutex::new(receiver),
        allowed: AtomicUsize::new(threads.allowed()),
        pending: AtomicUsize::new(0),
        bytes: AtomicU64::new(0),
        files: AtomicU64::new(0),
        stop: AtomicBool::new(false),
        error: Mutex::new(None),
    };
    let mut dirs: Vec<(PathBuf, fs::Metadata)> = Vec::new();
    let mut links: Vec<(PathBuf, PathBuf)> = Vec::new();

    std::thread::scope(|scope| {
        for index in 0..max {
            let shared = &shared;
            scope.spawn(move || shared.work(index));
        }
        let mut last_report: Option<Instant> = None;
        let mut tick = |shared: &Shared| {
            if last_report.is_none_or(|at| at.elapsed() >= REPORT_EVERY) {
                pace(shared, &mut threads, progress);
                last_report = Some(Instant::now());
            }
        };
        let walked = walk_into(
            src, dst, overwrite, &shared, &sender, &mut dirs, &mut links, &mut tick,
        );
        if let Err(e) = walked {
            shared.fail(e);
        }
        while shared.pending.load(Ordering::Relaxed) > 0 && !shared.stop.load(Ordering::Relaxed) {
            tick(&shared);
            std::thread::sleep(Duration::from_millis(10));
        }
        shared.stop.store(true, Ordering::Relaxed);
    });
    if let Some(error) = shared
        .error
        .into_inner()
        .unwrap_or_else(PoisonError::into_inner)
    {
        return Err(error);
    }

    let mut totals = CopyProgress {
        bytes: shared.bytes.into_inner(),
        files: shared.files.into_inner(),
    };
    for (first, target) in &links {
        remove_if_present(target)?;
        fs::hard_link(first, target).ctx("hard-linking", target)?;
        totals.files = totals.files.saturating_add(1);
    }
    for (dir, meta) in dirs.iter().rev() {
        fs::set_permissions(dir, Permissions::from_mode(meta.mode()))
            .ctx("setting permissions", dir)?;
        set_times(dir, meta)?;
    }
    let _final = progress(totals);
    Ok(CopyStats {
        bytes: totals.bytes,
        files: totals.files,
        seconds: started.elapsed().as_secs_f64(),
    })
}

/// The walking half of [`copy_tree`]: creates directories and symlinks, records hard links for
/// later, and queues regular files for the workers.
#[expect(
    clippy::too_many_arguments,
    reason = "internal helper threading the copy's shared state"
)]
fn walk_into(
    src: &Path,
    dst: &Path,
    overwrite: Overwrite,
    shared: &Shared,
    sender: &SyncSender<Job>,
    dirs: &mut Vec<(PathBuf, fs::Metadata)>,
    links: &mut Vec<(PathBuf, PathBuf)>,
    tick: &mut dyn FnMut(&Shared),
) -> Result<()> {
    let mut linked: HashMap<(u64, u64), PathBuf> = HashMap::new();
    for entry in walk_tree(src, 1) {
        if shared.stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        tick(shared);
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
            shared.files.fetch_add(1, Ordering::Relaxed);
        } else if target.symlink_metadata().is_ok() && overwrite == Overwrite::Keep {
            // An existing file wins in a no-clobber merge.
        } else if file_type.is_symlink() {
            remove_if_present(&target)?;
            let link = fs::read_link(entry.path()).ctx("reading link", entry.path())?;
            symlink(&link, &target).ctx("creating link", &target)?;
            shared.files.fetch_add(1, Ordering::Relaxed);
        } else if file_type.is_file() {
            if meta.nlink() > 1 {
                let key = (meta.dev(), meta.ino());
                if let Some(first) = linked.get(&key) {
                    links.push((first.clone(), target));
                    continue;
                }
                linked.insert(key, target.clone());
            }
            shared.pending.fetch_add(1, Ordering::Relaxed);
            let mut job = Job {
                src: entry.path().to_path_buf(),
                dst: target,
                meta,
            };
            loop {
                match sender.try_send(job) {
                    Ok(()) => break,
                    Err(TrySendError::Full(back)) => {
                        if shared.stop.load(Ordering::Relaxed) {
                            return Ok(());
                        }
                        job = back;
                        tick(shared);
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    Err(TrySendError::Disconnected(_)) => return Ok(()),
                }
            }
        }
        // Sockets, FIFOs and devices are skipped: they never belong in caches.
    }
    Ok(())
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
    for entry in walk_tree(dir, 1) {
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
    for entry in walk_tree(path, 0) {
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

        let stats = copy_tree(src.path(), dst.path(), Overwrite::Replace, &mut |_| {
            Pace::Go
        })
        .unwrap();

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
    fn parallel_copies_are_complete_and_can_pause() {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        for i in 0..600 {
            write(
                &src.path().join(format!("d{}/e{}/f{i}", i % 7, i % 3)),
                &i.to_string().repeat(i % 50 + 1),
            );
        }
        for i in 0..40 {
            fs::hard_link(
                src.path().join(format!("d{}/e{}/f{i}", i % 7, i % 3)),
                src.path().join(format!("link{i}")),
            )
            .unwrap();
        }
        let mut calls = 0;
        let stats = copy_tree(src.path(), dst.path(), Overwrite::Replace, &mut |_| {
            calls += 1;
            if calls == 1 { Pace::Wait } else { Pace::Go }
        })
        .unwrap();

        for i in 0..600 {
            let rel = format!("d{}/e{}/f{i}", i % 7, i % 3);
            assert_eq!(
                fs::read_to_string(dst.path().join(&rel)).unwrap(),
                i.to_string().repeat(i % 50 + 1),
                "{rel}"
            );
        }
        for i in 0..40 {
            let original = fs::metadata(dst.path().join(format!("d{}/e{}/f{i}", i % 7, i % 3)));
            let link = fs::metadata(dst.path().join(format!("link{i}"))).unwrap();
            assert_eq!(
                original.unwrap().ino(),
                link.ino(),
                "link{i} is a hard link"
            );
        }
        assert_eq!(
            fingerprint(dst.path()).unwrap().bytes,
            fingerprint(src.path()).unwrap().bytes
        );
        assert_eq!(stats.files, fingerprint(src.path()).unwrap().entries);
    }

    #[test]
    fn volume_metadata_is_skipped() {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        write(
            &src.path().join("pkg/index.js"),
            "x".repeat(10_000).as_str(),
        );
        let events = src.path().join(".fseventsd");
        write(&events.join("0001"), "log");
        fs::set_permissions(&events, Permissions::from_mode(0o000)).unwrap();

        let allocated = allocated_bytes(src.path());
        let print = fingerprint(src.path());
        let copied = copy_tree(src.path(), dst.path(), Overwrite::Replace, &mut |_| {
            Pace::Go
        });
        fs::set_permissions(&events, Permissions::from_mode(0o700)).unwrap();

        assert!(allocated.unwrap() >= 10_000);
        assert_eq!(print.unwrap().entries, 2, "pkg and pkg/index.js");
        copied.unwrap();
        assert!(dst.path().join("pkg/index.js").exists());
        assert!(!dst.path().join(".fseventsd").exists());
    }

    #[test]
    fn stopped_copies_fail() {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        for i in 0..50 {
            write(&src.path().join(format!("f{i}")), "x");
        }
        let result = copy_tree(src.path(), dst.path(), Overwrite::Replace, &mut |_| {
            Pace::Stop
        });
        assert!(matches!(result, Err(Error::Busy(_))));
    }

    #[test]
    fn copy_errors_are_reported() {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        write(&src.path().join("ok"), "fine");
        write(&src.path().join("secret"), "nope");
        fs::set_permissions(src.path().join("secret"), Permissions::from_mode(0o000)).unwrap();
        let result = copy_tree(src.path(), dst.path(), Overwrite::Replace, &mut |_| {
            Pace::Go
        });
        fs::set_permissions(src.path().join("secret"), Permissions::from_mode(0o600)).unwrap();
        assert!(result.is_err());
    }

    #[test]
    fn keep_mode_does_not_clobber() {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        write(&src.path().join("same"), "new");
        write(&src.path().join("only-src"), "x");
        write(&dst.path().join("same"), "old");
        copy_tree(src.path(), dst.path(), Overwrite::Keep, &mut |_| Pace::Go).unwrap();
        assert_eq!(fs::read_to_string(dst.path().join("same")).unwrap(), "old");
        assert!(dst.path().join("only-src").exists());
    }

    #[test]
    fn read_only_trees_copy_and_clear() {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        write(&src.path().join("ro/file"), "data");
        fs::set_permissions(src.path().join("ro"), Permissions::from_mode(0o555)).unwrap();
        copy_tree(src.path(), dst.path(), Overwrite::Replace, &mut |_| {
            Pace::Go
        })
        .unwrap();
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
