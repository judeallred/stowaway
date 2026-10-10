//! The engine: adopting folders into images, attaching them, applying reconnect policies, and
//! the housekeeping commands (spec §4).

use std::fs::{self, File};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tracing::info;

use crate::config::Config;
use crate::diskload::TransferGovernor;
use crate::drive::{self, DriveLocator};
use crate::error::{Error, IoContext, Result};
use crate::fsutil::{self, CopyProgress, CopyStats, Fingerprint, Overwrite, Pace};
use crate::hdiutil::{self, AttachedImage};
use crate::idle::{self, Activity};
use crate::kinds::{self, KindId, ReconnectPolicy, Scope};
use crate::paths::{DriveLayout, Layout};
use crate::registry::{Entry, EntryStatus, Measurement, Registry, Transfer};
use crate::scan::{self, Candidate, ScanOptions};

mod split;

/// Something the engine did that observers (the agent's IPC clients) may want to show.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum EngineEvent {
    /// A copy is in progress.
    TransferProgress {
        /// Entry being copied.
        entry_id: String,
        /// Its folder.
        path: PathBuf,
        /// `adopt`, `reconnect`, `merge`, `compact` or `release`.
        op: String,
        /// Bytes copied so far.
        bytes: u64,
        /// Total bytes to copy.
        total_bytes: u64,
        /// Entries copied so far.
        files: u64,
        /// Total entries to copy.
        total_files: u64,
        /// Seconds since the copy started.
        elapsed_seconds: f64,
        /// Paused because other programs are keeping the internal disk busy.
        #[serde(default)]
        waiting_for_disk: bool,
        /// What the transfer is doing; only [`TransferStep::Copying`] moves `bytes` and `files`.
        #[serde(default)]
        step: TransferStep,
    },
    /// A transfer finished, including the steps after its copy.
    TransferDone {
        /// The finished transfer.
        transfer: Transfer,
    },
    /// A transfer stopped without finishing (it failed or was postponed).
    TransferAborted {
        /// Entry that was being transferred.
        entry_id: String,
    },
    /// An entry was added, removed or changed status.
    EntriesChanged,
    /// The drive appeared or disappeared.
    DriveChanged {
        /// Whether it's connected now.
        connected: bool,
    },
}

/// The steps of a transfer, in order. Not every operation has every step.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TransferStep {
    /// Creating the image and taking stock of the folder.
    Preparing,
    /// Copying files.
    #[default]
    Copying,
    /// Detaching the image, which writes its buffered data out to the drive.
    Flushing,
    /// Checking that the folder didn't change during the copy.
    Verifying,
    /// Deleting what's no longer needed: the local files after adopting or reconnecting, or the
    /// old image after compacting.
    Cleaning,
    /// Attaching the image in place.
    Mounting,
    /// Measuring the folder and its image.
    Measuring,
}

impl TransferStep {
    /// A short description for progress lines, e.g. "writing to the drive".
    #[must_use]
    pub const fn describe(self) -> &'static str {
        match self {
            Self::Preparing => "preparing",
            Self::Copying => "copying",
            Self::Flushing => "writing to the drive",
            Self::Verifying => "checking nothing changed",
            Self::Cleaning => "removing the old copy",
            Self::Mounting => "mounting",
            Self::Measuring => "measuring",
        }
    }
}

/// Receives [`EngineEvent`]s.
pub type Observer = Arc<dyn Fn(&EngineEvent) + Send + Sync>;

/// Reports one transfer's progress through its steps. Dropping it before
/// [`TransferTracker::finish`] reports the transfer as aborted, so observers never keep showing
/// a transfer that failed partway.
struct TransferTracker {
    observer: Option<Observer>,
    entry_id: String,
    path: PathBuf,
    op: &'static str,
    started: Instant,
    total: Fingerprint,
    done: CopyProgress,
    finished: bool,
}

impl TransferTracker {
    fn new(observer: Option<Observer>, entry_id: &str, path: &Path, op: &'static str) -> Self {
        let tracker = Self {
            observer,
            entry_id: entry_id.to_owned(),
            path: path.to_path_buf(),
            op,
            started: Instant::now(),
            total: Fingerprint::default(),
            done: CopyProgress::default(),
            finished: false,
        };
        tracker.report(TransferStep::Preparing, false);
        tracker
    }

    fn report(&self, step: TransferStep, waiting_for_disk: bool) {
        if let Some(observer) = &self.observer {
            observer(&EngineEvent::TransferProgress {
                entry_id: self.entry_id.clone(),
                path: self.path.clone(),
                op: self.op.to_owned(),
                bytes: self.done.bytes,
                total_bytes: self.total.bytes,
                files: self.done.files,
                total_files: self.total.entries,
                elapsed_seconds: self.started.elapsed().as_secs_f64(),
                waiting_for_disk,
                step,
            });
        }
    }

    fn step(&self, step: TransferStep) {
        info!(path = %self.path.display(), op = self.op, ?step, "transfer step");
        self.report(step, false);
    }

    fn finish(mut self, transfer: Transfer) {
        self.finished = true;
        if let Some(observer) = &self.observer {
            observer(&EngineEvent::TransferDone { transfer });
        }
    }
}

impl Drop for TransferTracker {
    fn drop(&mut self) {
        if !self.finished
            && let Some(observer) = &self.observer
        {
            observer(&EngineEvent::TransferAborted {
                entry_id: self.entry_id.clone(),
            });
        }
    }
}

/// The connected drive.
#[derive(Debug, Clone)]
pub struct Drive {
    /// Where it's mounted.
    pub mount_point: PathBuf,
    /// Stowaway's directories on it.
    pub layout: DriveLayout,
}

/// Exclusive lock serializing changes between the agent and CLI invocations.
#[derive(Debug)]
pub struct EngineLock {
    _file: File,
}

impl EngineLock {
    /// Waits up to `timeout` for the lock.
    ///
    /// # Errors
    ///
    /// [`Error::Busy`] if another process holds it for longer.
    pub fn acquire(layout: &Layout, timeout: Duration) -> Result<Self> {
        let path = layout.lock_path();
        fs::create_dir_all(&layout.state_dir).ctx("creating", &layout.state_dir)?;
        let file = File::options()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&path)
            .ctx("opening", &path)?;
        let started = Instant::now();
        loop {
            match file.try_lock() {
                Ok(()) => return Ok(Self { _file: file }),
                Err(fs::TryLockError::WouldBlock) if started.elapsed() < timeout => {
                    std::thread::sleep(Duration::from_millis(100));
                }
                Err(fs::TryLockError::WouldBlock) => {
                    return Err(Error::Busy(
                        "another Stowaway operation is running; try again shortly".to_owned(),
                    ));
                }
                Err(fs::TryLockError::Error(e)) => return Err(Error::io("locking", &path, e)),
            }
        }
    }
}

/// Options for [`Engine::adopt`].
#[derive(Debug, Clone, Copy, Default)]
pub struct AdoptOptions {
    /// Skip the idle and minimum-size checks (an explicit `stowaway adopt`).
    pub force: bool,
}

/// How often a long copy stops to reattach other entries whose mounts disappeared. A copy holds
/// the engine lock, so the agent's regular reconcile can't run until it finishes.
const HEAL_DURING_COPY_EVERY: Duration = Duration::from_secs(30);

/// How long a candidate's measured size is trusted. Changes deep inside a folder (a rebuild
/// growing `target/`) don't touch its modification time, so cached sizes also expire.
const MEASUREMENT_TTL_SECS: i64 = 6 * 60 * 60;

/// What [`Engine::adoption_candidates`] found.
#[derive(Debug, Default)]
pub struct AdoptionCandidates {
    /// Candidates the pre-adoption and size settings allow adopting, with their sizes.
    pub ready: Vec<(Candidate, u64)>,
    /// Candidates whose size couldn't be measured, with the reason.
    pub unmeasured: Vec<(Candidate, Error)>,
}

/// How far [`Engine::adoption_candidates`] has got.
#[derive(Debug, Clone, Copy)]
pub struct MeasureProgress {
    /// Candidates measured so far.
    pub done: usize,
    /// Candidates to measure.
    pub total: usize,
    /// Total size of the candidates found worth adopting so far.
    pub ready_bytes: u64,
}

/// Outcome of handling one entry during reconciliation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachOutcome {
    /// Already mounted where it belongs.
    AlreadyMounted,
    /// Mounted now.
    Mounted,
    /// Local work is waiting for the folder to go idle.
    Waiting(String),
    /// The project is gone and its image was cleaned up.
    Removed,
}

/// A problem reported by `doctor` or `status`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Problem {
    /// `error` or `warning`.
    pub severity: Severity,
    /// What's wrong.
    pub message: String,
    /// What to do about it.
    pub hint: Option<String>,
}

/// How serious a [`Problem`] is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Severity {
    /// Something is broken.
    Error,
    /// Worth knowing about.
    Warning,
}

/// The engine. Not thread-safe: each thread or process opens its own.
pub struct Engine {
    /// Local layout.
    pub layout: Layout,
    /// Loaded configuration.
    pub config: Config,
    /// The registry.
    pub registry: Registry,
    locator: DriveLocator,
    observer: Option<Observer>,
    cancel: Option<Arc<AtomicBool>>,
    /// The drive as last located, for work done in the middle of a copy.
    located: Option<Drive>,
}

impl std::fmt::Debug for Engine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Engine")
            .field("layout", &self.layout)
            .field("config", &self.config)
            .finish_non_exhaustive()
    }
}

const STAGING_PREFIX: &str = "stage-";

impl Engine {
    /// Opens the engine for an initialized installation.
    ///
    /// # Errors
    ///
    /// [`Error::NotInitialized`] if `init` hasn't run; database errors otherwise.
    pub fn open(layout: Layout) -> Result<Self> {
        let mut config = Config::load_required(&layout)?;
        // Kinds added since `init` get their locations recorded once.
        if config.record_missing_globals(&layout.home, &kinds::ProcessEnvironment)
            && let Err(e) = config.save(&layout)
        {
            tracing::warn!(error = %e, "can't save the new cache locations");
        }
        let registry = Registry::open(&layout.db_path())?;
        Ok(Self {
            layout,
            config,
            registry,
            locator: DriveLocator::default(),
            observer: None,
            cancel: None,
            located: None,
        })
    }

    /// Sets the event observer.
    pub fn set_observer(&mut self, observer: Option<Observer>) {
        self.observer = observer;
    }

    /// Sets a flag that, once raised, stops copies in progress. The interrupted operation fails
    /// with [`Error::Busy`] and is retried later, like any postponed transfer.
    pub fn set_cancel(&mut self, cancel: Option<Arc<AtomicBool>>) {
        self.cancel = cancel;
    }

    fn cancelled(&self) -> bool {
        self.cancel
            .as_ref()
            .is_some_and(|c| c.load(Ordering::Relaxed))
    }

    fn emit(&self, event: &EngineEvent) {
        if let Some(observer) = &self.observer {
            observer(event);
        }
    }

    /// Re-reads the config file (the agent does this when it changes).
    ///
    /// # Errors
    ///
    /// Fails if the config can't be loaded.
    pub fn reload_config(&mut self) -> Result<()> {
        self.config = Config::load_required(&self.layout)?;
        Ok(())
    }

    /// The connected drive, if it's present. Recreates Stowaway's folders on it if they've been
    /// deleted, so the store heals instead of failing every operation.
    pub fn drive(&mut self) -> Option<Drive> {
        self.located = self
            .config
            .volume_uuid
            .clone()
            .and_then(|uuid| self.locator.locate(&uuid, &[]))
            .map(|mount_point| Drive {
                layout: DriveLayout::new(&mount_point, &self.config.machine_id),
                mount_point,
            });
        if let Some(drive) = &self.located {
            for dir in [drive.layout.images_dir(), drive.layout.trash_dir()] {
                if !dir.is_dir() {
                    match fs::create_dir_all(&dir) {
                        Ok(()) => info!(path = %dir.display(), "recreated a folder on the drive"),
                        Err(e) => {
                            tracing::warn!(path = %dir.display(), error = %e, "can't create a folder on the drive");
                        }
                    }
                }
            }
        }
        self.located.clone()
    }

    fn require_drive(&mut self) -> Result<Drive> {
        self.drive().ok_or(Error::DriveOffline)
    }

    // ----- adoption ---------------------------------------------------------------------------

    /// Adopts `path` as `kind`: moves an existing folder into a new image, or pre-adopts a folder
    /// that doesn't exist yet. Callers hold the [`EngineLock`].
    ///
    /// # Errors
    ///
    /// Fails if the path isn't eligible, the drive is offline, the folder is busy, or a copy or
    /// `hdiutil` step fails. On failure nothing is left half-done.
    pub fn adopt(&mut self, path: &Path, kind: KindId, opts: AdoptOptions) -> Result<Entry> {
        let path = canonical_target(path)?;
        if kinds::is_container(kind, &path) {
            return Err(Error::Invalid(format!(
                "{} is managed one build folder at a time (its {} parts), so the programs it \
                 builds stay on this Mac; adopt those folders instead",
                path.display(),
                kind
            )));
        }
        self.check_eligible(&path)?;
        let drive = self.require_drive()?;
        let exists = path.symlink_metadata().is_ok();
        if exists {
            let meta = path.symlink_metadata().ctx("inspecting", &path)?;
            if !meta.is_dir() {
                return Err(Error::Invalid(format!("{} isn't a folder", path.display())));
            }
            if idle::is_mount_point(&path) {
                return Err(Error::Invalid(format!(
                    "{} is already a mount point",
                    path.display()
                )));
            }
            if scan::has_tracked_files(&path) {
                return Err(Error::Invalid(format!(
                    "{} contains files tracked by git, so it isn't safe to manage",
                    path.display()
                )));
            }
        }

        let id = ulid::Ulid::generate().to_string().to_ascii_lowercase();
        let image = drive.layout.image_path(&id);
        let _cargo = cargo_package_lock(kind, &path)?;
        let now = crate::now_unix();

        if !exists || fsutil::is_effectively_empty(&path)? {
            fs::create_dir_all(&path).ctx("creating", &path)?;
            self.create_image(&drive, &image, kind, &path)?;
            if let Err(e) = hdiutil::attach(&image, &path) {
                let _ignored = fsutil::remove_tree(&image);
                return Err(e);
            }
            let entry = new_entry(&id, kind, &path, now, EntryStatus::Mounted);
            self.registry.insert(&entry)?;
            self.refresh_sizes(&entry, &drive);
            self.emit(&EngineEvent::EntriesChanged);
            return self
                .registry
                .by_id(&id)?
                .ok_or_else(|| Error::Invalid("entry vanished".into()));
        }

        if !opts.force {
            match idle::activity(&path, self.config.idle_seconds)? {
                Activity::Idle => {}
                other => {
                    return Err(Error::Busy(format!(
                        "{} is {}; it will be adopted once it's idle",
                        path.display(),
                        other.describe()
                    )));
                }
            }
        }

        self.registry.journal(&id, "adopt", "creating", now)?;
        let result = self.adopt_existing(&drive, &id, kind, &path, &image);
        if result.is_err() {
            let _ignored = self.discard_failed_image(&id, &image);
        }
        self.registry.journal_done(&id)?;
        result
    }

    fn adopt_existing(
        &self,
        drive: &Drive,
        id: &str,
        kind: KindId,
        path: &Path,
        image: &Path,
    ) -> Result<Entry> {
        let mut tracker = TransferTracker::new(self.observer.clone(), id, path, "adopt");
        self.registry
            .journal(id, "adopt", "copying", crate::now_unix())?;
        let stats = self.copy_into_new_image(drive, &mut tracker, kind, path, image)?;
        self.registry
            .journal(id, "adopt", "swapping", crate::now_unix())?;
        let entry = new_entry(id, kind, path, crate::now_unix(), EntryStatus::Local);
        self.registry.insert(&entry)?;
        tracker.step(TransferStep::Cleaning);
        fsutil::clear_dir_contents(path)?;
        tracker.step(TransferStep::Mounting);
        hdiutil::attach(image, path)?;
        self.registry.set_status(id, EntryStatus::Mounted, None)?;
        tracker.step(TransferStep::Measuring);
        self.refresh_sizes(&entry, drive);
        self.record_transfer(tracker, stats)?;
        self.emit(&EngineEvent::EntriesChanged);
        self.registry
            .by_id(id)?
            .ok_or_else(|| Error::Invalid("entry vanished".into()))
    }

    fn check_eligible(&self, path: &Path) -> Result<()> {
        if self.registry.by_path(path)?.is_some() {
            return Err(Error::Invalid(format!(
                "{} is already managed",
                path.display()
            )));
        }
        if crate::paths::is_within(path, &self.layout.state_dir) || path.starts_with("/Volumes") {
            return Err(Error::Invalid(format!(
                "{} can't be managed (it's Stowaway's own storage or on another volume)",
                path.display()
            )));
        }
        if path
            .ancestors()
            .any(|a| a.join(scan::IGNORE_MARKER).exists())
        {
            return Err(Error::Invalid(format!(
                "{} is inside a folder marked with {}",
                path.display(),
                scan::IGNORE_MARKER
            )));
        }
        for entry in self.registry.entries()? {
            if path.starts_with(&entry.path) || entry.path.starts_with(path) {
                return Err(Error::Invalid(format!(
                    "{} overlaps the managed folder {}",
                    path.display(),
                    entry.path.display()
                )));
            }
        }
        Ok(())
    }

    /// Copies the folder at `path` into a new image at `image`, failing with [`Error::Busy`] if
    /// it changed meanwhile. The folder itself is left as it was.
    fn copy_into_new_image(
        &self,
        drive: &Drive,
        tracker: &mut TransferTracker,
        kind: KindId,
        path: &Path,
        image: &Path,
    ) -> Result<CopyStats> {
        self.create_image(drive, image, kind, path)?;
        let before = fsutil::fingerprint(path)?;
        tracker.total = before;
        let staging = self.staging_mount(&tracker.entry_id)?;
        let stats = {
            let attached = hdiutil::attach(image, &staging)?;
            let copied = self.copy_with_progress(tracker, path, &staging, Overwrite::Replace, &[]);
            tracker.step(TransferStep::Flushing);
            hdiutil::detach(&attached.device, false)?;
            copied?
        };
        let _ignored = fs::remove_dir(&staging);
        tracker.step(TransferStep::Verifying);
        if fsutil::fingerprint(path)? != before {
            return Err(Error::Busy(format!(
                "{} changed while it was being copied; it will be retried once it's idle",
                path.display()
            )));
        }
        Ok(stats)
    }

    /// The container that a part of a splitting kind sits in; `None` for any other folder.
    fn container_of(&self, kind: KindId, path: &Path) -> Option<PathBuf> {
        if !kinds::is_part(kind, path) {
            return None;
        }
        match kind.spec().scope {
            Scope::Project { dir_name, .. } => {
                kinds::project_dir(kind, path).map(|p| p.join(dir_name))
            }
            Scope::Global => self
                .config
                .globals
                .get(&kind)?
                .iter()
                .find(|g| path.starts_with(g))
                .cloned(),
        }
    }

    fn create_image(&self, drive: &Drive, image: &Path, kind: KindId, path: &Path) -> Result<()> {
        let capacity = stowaway_macos::fs_stats(&drive.mount_point)
            .map(|s| s.total_bytes)
            .ctx("inspecting", &drive.mount_point)?;
        let name = volume_name(kind, path, self.container_of(kind, path).as_deref());
        hdiutil::create(image, capacity, &name, self.config.internal_case_sensitive)
    }

    fn staging_mount(&self, id: &str) -> Result<PathBuf> {
        let staging = self
            .layout
            .staging_dir()
            .join(format!("{STAGING_PREFIX}{id}"));
        fs::create_dir_all(&staging).ctx("creating", &staging)?;
        Ok(staging)
    }

    fn discard_failed_image(&self, id: &str, image: &Path) -> Result<()> {
        let staging = self
            .layout
            .staging_dir()
            .join(format!("{STAGING_PREFIX}{id}"));
        detach_mounted_at(&staging);
        let _ignored = fs::remove_dir(&staging);
        if self.registry.by_id(id)?.is_none() {
            fsutil::remove_tree(image)?;
        }
        Ok(())
    }

    fn copy_with_progress(
        &self,
        tracker: &mut TransferTracker,
        src: &Path,
        dst: &Path,
        overwrite: Overwrite,
        skip: &[PathBuf],
    ) -> Result<CopyStats> {
        tracker.step(TransferStep::Copying);
        let mut governor = TransferGovernor::new(&self.layout, self.config.transfer_priority);
        let mut waiting = false;
        let mut healed = Instant::now();
        let mut report = |p: CopyProgress| {
            tracker.done = p;
            if self.cancelled() {
                info!(path = %tracker.path.display(), "copy stopped");
                return Pace::Stop;
            }
            if healed.elapsed() >= HEAL_DURING_COPY_EVERY {
                healed = Instant::now();
                self.reattach_lost_mounts(&tracker.entry_id);
            }
            let wait = governor.should_wait();
            if wait != waiting {
                waiting = wait;
                if wait {
                    info!(path = %tracker.path.display(), "copy paused: the disk is busy");
                } else {
                    info!(path = %tracker.path.display(), "copy resumed");
                }
            }
            tracker.report(TransferStep::Copying, wait);
            if wait { Pace::Wait } else { Pace::Go }
        };
        fsutil::copy_tree_except(src, dst, overwrite, skip, &mut report)
    }

    /// Records a finished transfer; the copy's own statistics, not the steps around it.
    fn record_transfer(&self, tracker: TransferTracker, stats: CopyStats) -> Result<()> {
        let transfer = Transfer {
            entry_id: tracker.entry_id.clone(),
            op: tracker.op.to_owned(),
            bytes: stats.bytes,
            files: stats.files,
            seconds: stats.seconds,
            finished_at: crate::now_unix(),
        };
        self.registry.record_transfer(&transfer)?;
        tracker.finish(transfer);
        Ok(())
    }

    // ----- attaching and reconnecting -----------------------------------------------------------

    /// Brings every entry in line with the drive's presence (spec §4.2, §4.3).
    /// Returns per-entry outcomes for entries that weren't already mounted.
    ///
    /// # Errors
    ///
    /// Fails if `hdiutil info` fails; per-entry failures are recorded on the entry instead.
    pub fn reconcile(&mut self) -> Result<Vec<(Entry, AttachOutcome)>> {
        let Some(drive) = self.drive() else {
            self.handle_drive_absent()?;
            return Ok(Vec::new());
        };
        self.recover_unfinished(&drive)?;
        let images_dir = drive.layout.images_dir();
        // Clear stale devices (attached but unmounted, e.g. after a yank) before attaching
        // anything: device numbers are reused, so detaching later could hit a fresh mount.
        for stale in hdiutil::attached()?
            .iter()
            .filter(|a| a.mount_point.is_none() && a.image_path.starts_with(&images_dir))
        {
            let _ignored = hdiutil::detach(&stale.device, true);
        }
        let attached = hdiutil::attached()?;
        let mut outcomes = Vec::new();
        let mut changed = false;
        for entry in self.registry.entries()? {
            let image = drive.layout.image_path(&entry.id);
            let current = attached.iter().find(|a| same_file(&a.image_path, &image));
            let outcome = match self.reconcile_entry(&drive, &entry, current) {
                Ok(outcome) => outcome,
                Err(e) => {
                    self.registry.set_status(
                        &entry.id,
                        EntryStatus::Error,
                        Some(&e.to_string()),
                    )?;
                    changed = true;
                    continue;
                }
            };
            if outcome != AttachOutcome::AlreadyMounted {
                changed = true;
                outcomes.push((entry, outcome));
            }
        }
        if changed {
            self.emit(&EngineEvent::EntriesChanged);
        }
        Ok(outcomes)
    }

    /// Reattaches mounted entries whose mount vanished and whose folder is still empty, skipping
    /// `busy` (the entry being copied). Entries with local changes wait for a full reconcile,
    /// which applies their reconnect policy. Failures are logged and retried later.
    fn reattach_lost_mounts(&self, busy: &str) {
        let Some(drive) = &self.located else { return };
        let Ok(entries) = self.registry.entries() else {
            return;
        };
        let lost: Vec<Entry> = entries
            .into_iter()
            .filter(|e| {
                e.id != busy
                    && e.status == EntryStatus::Mounted
                    && !idle::is_mount_point(&e.path)
                    && fsutil::is_effectively_empty(&e.path).unwrap_or(false)
            })
            .collect();
        if lost.is_empty() {
            return;
        }
        let Ok(attached) = hdiutil::attached() else {
            return;
        };
        for entry in lost {
            let image = drive.layout.image_path(&entry.id);
            let current = attached.iter().find(|a| same_file(&a.image_path, &image));
            if current.is_some_and(|a| a.mount_point.is_some()) || !image.exists() {
                continue;
            }
            if let Some(stale) = current {
                let _ignored = hdiutil::detach(&stale.device, true);
            }
            match hdiutil::attach(&image, &entry.path) {
                Ok(_) => info!(path = %entry.path.display(), "reattached a lost mount"),
                Err(e) => {
                    tracing::warn!(path = %entry.path.display(), error = %e, "reattach failed");
                }
            }
        }
    }

    fn reconcile_entry(
        &self,
        drive: &Drive,
        entry: &Entry,
        current: Option<&AttachedImage>,
    ) -> Result<AttachOutcome> {
        if let Some(mounted) = current.and_then(|a| a.mount_point.clone()) {
            let staging_root = self.layout.staging_dir();
            if mounted.starts_with(&staging_root) {
                detach_mounted_at(&mounted);
            } else {
                if !same_file(&mounted, &entry.path) {
                    // The repository moved; the mount followed it.
                    self.registry.set_path(&entry.id, &mounted)?;
                }
                if project_deleted(entry.kind, &mounted) {
                    self.remove_deleted(drive, entry, &mounted)?;
                    return Ok(AttachOutcome::Removed);
                }
                self.registry.set_seen(&entry.id, true, crate::now_unix())?;
                if entry.used_bytes == 0 {
                    self.refresh_sizes(entry, drive);
                }
                if entry.status != EntryStatus::Mounted {
                    self.registry
                        .set_status(&entry.id, EntryStatus::Mounted, None)?;
                    return Ok(AttachOutcome::Mounted);
                }
                return Ok(AttachOutcome::AlreadyMounted);
            }
        } else if let Some(stale) = current {
            let _ignored = hdiutil::detach(&stale.device, true);
        }
        self.attach_entry(drive, entry)
    }

    /// The repository was deleted around a mounted entry (spec §4.5): detach, delete the image,
    /// and remove the empty folders left behind.
    fn remove_deleted(&self, drive: &Drive, entry: &Entry, mounted: &Path) -> Result<()> {
        if !idle::holders(&[mounted])?.is_empty() {
            return Err(Error::Busy(format!(
                "{} is still in use",
                mounted.display()
            )));
        }
        detach_mounted_at(mounted);
        fsutil::remove_tree(&drive.layout.image_path(&entry.id))?;
        self.registry.delete(&entry.id)?;
        let roots = self.scan_roots();
        let mut dir = Some(mounted.to_path_buf());
        while let Some(d) = dir {
            if roots.iter().any(|r| same_file(r, &d)) || !fsutil::is_effectively_empty(&d)? {
                break;
            }
            fsutil::clear_dir_contents(&d)?;
            if fs::remove_dir(&d).is_err() {
                break;
            }
            dir = d.parent().map(Path::to_path_buf);
        }
        Ok(())
    }

    fn attach_entry(&self, drive: &Drive, entry: &Entry) -> Result<AttachOutcome> {
        let path = &entry.path;
        if !path.exists() {
            let parent_present = path.parent().is_some_and(Path::exists);
            let manifest_present = match entry.kind.spec().scope {
                Scope::Project { manifest, .. } => {
                    kinds::project_dir(entry.kind, path).is_some_and(|p| p.join(manifest).exists())
                }
                Scope::Global => parent_present,
            };
            if !manifest_present {
                self.registry
                    .set_seen(&entry.id, false, crate::now_unix())?;
                self.registry.set_status(
                    &entry.id,
                    EntryStatus::Local,
                    Some("the project folder is missing"),
                )?;
                return Ok(AttachOutcome::Waiting("project missing".to_owned()));
            }
            fs::create_dir_all(path).ctx("creating", path)?;
        }
        self.registry.set_seen(&entry.id, true, crate::now_unix())?;
        let image = drive.layout.image_path(&entry.id);
        if !image.exists() {
            self.create_image(drive, &image, entry.kind, path)?;
        }
        if fsutil::is_effectively_empty(path)? {
            hdiutil::attach(&image, path)?;
            self.registry
                .set_status(&entry.id, EntryStatus::Mounted, None)?;
            self.refresh_sizes(entry, drive);
            return Ok(AttachOutcome::Mounted);
        }
        match idle::activity(path, self.config.idle_seconds)? {
            Activity::Idle => {}
            other => {
                let why = format!("local changes waiting: {}", other.describe());
                self.registry
                    .set_status(&entry.id, EntryStatus::PendingReconnect, Some(&why))?;
                return Ok(AttachOutcome::Waiting(why));
            }
        }
        let _cargo = cargo_package_lock(entry.kind, path)?;
        self.apply_reconnect_policy(entry, &image)?;
        hdiutil::attach(&image, path)?;
        self.registry
            .set_status(&entry.id, EntryStatus::Mounted, None)?;
        self.refresh_sizes(entry, drive);
        Ok(AttachOutcome::Mounted)
    }

    fn apply_reconnect_policy(&self, entry: &Entry, image: &Path) -> Result<()> {
        let path = &entry.path;
        // Whether the image is emptied first, and whether local files replace the image's.
        let (clear_image, overwrite, op) = match entry.kind.spec().policy {
            ReconnectPolicy::LocalWinsIfComplete(markers) => {
                if !fsutil::contains_any(path, markers) {
                    fsutil::clear_dir_contents(path)?;
                    return Ok(());
                }
                (true, Overwrite::Replace, "reconnect")
            }
            ReconnectPolicy::MergeLocalWins => (false, Overwrite::Replace, "merge"),
            ReconnectPolicy::MergeNoClobber => (false, Overwrite::Keep, "merge"),
        };
        let mut tracker = TransferTracker::new(self.observer.clone(), &entry.id, path, op);
        self.registry
            .journal(&entry.id, op, "copying", crate::now_unix())?;
        let before = fsutil::fingerprint(path)?;
        tracker.total = before;
        let staging = self.staging_mount(&entry.id)?;
        let attached = hdiutil::attach(image, &staging)?;
        let copied = (|| {
            if clear_image {
                fsutil::clear_dir_contents(&staging)?;
            }
            self.copy_with_progress(&mut tracker, path, &staging, overwrite, &[])
        })();
        tracker.step(TransferStep::Flushing);
        hdiutil::detach(&attached.device, false)?;
        let _ignored = fs::remove_dir(&staging);
        let stats = copied?;
        tracker.step(TransferStep::Verifying);
        if fsutil::fingerprint(path)? != before {
            self.registry.journal_done(&entry.id)?;
            return Err(Error::Busy(format!(
                "{} changed while it was being copied; will retry",
                path.display()
            )));
        }
        self.registry
            .journal(&entry.id, op, "clearing", crate::now_unix())?;
        tracker.step(TransferStep::Cleaning);
        fsutil::clear_dir_contents(path)?;
        self.registry.journal_done(&entry.id)?;
        self.record_transfer(tracker, stats)
    }

    /// Cleans up after an interrupted operation: staging mounts are detached and half-adopted
    /// images that never got registered are deleted. Data still in local folders is handled by
    /// the normal reconnect logic afterwards.
    fn recover_unfinished(&self, drive: &Drive) -> Result<()> {
        for item in self.registry.unfinished()? {
            let staging = self
                .layout
                .staging_dir()
                .join(format!("{STAGING_PREFIX}{}", item.entry_id));
            detach_mounted_at(&staging);
            let _ignored = fs::remove_dir(&staging);
            if self.registry.by_id(&item.entry_id)?.is_none() {
                fsutil::remove_tree(&drive.layout.image_path(&item.entry_id))?;
            }
            self.registry.journal_done(&item.entry_id)?;
        }
        Ok(())
    }

    /// The drive is gone: clear stale image devices and mark entries local.
    ///
    /// # Errors
    ///
    /// Fails if `hdiutil info` fails.
    pub fn handle_drive_absent(&mut self) -> Result<()> {
        let mut changed = false;
        for image in hdiutil::attached()? {
            let ours = image
                .image_path
                .extension()
                .is_some_and(|e| e == "sparsebundle")
                && image.image_path.parent().is_some_and(|p| {
                    p.ends_with(Path::new(&self.config.machine_id).join("images"))
                });
            if ours && !image.image_path.exists() {
                let _ignored = hdiutil::detach(&image.device, true);
                changed = true;
            }
        }
        for entry in self.registry.entries()? {
            if entry.status != EntryStatus::Local || entry.note.is_some() {
                self.registry
                    .set_status(&entry.id, EntryStatus::Local, None)?;
                changed = true;
            }
        }
        if changed {
            self.emit(&EngineEvent::EntriesChanged);
        }
        Ok(())
    }

    // ----- user commands ----------------------------------------------------------------------

    /// Turns a managed folder back into a plain local folder (spec §4.2).
    ///
    /// # Errors
    ///
    /// Fails if the folder isn't managed, is in use, or (with `copy`) the drive is offline.
    pub fn release(&mut self, path: &Path, copy: bool) -> Result<()> {
        let path = canonical_target(path)?;
        let entry = self
            .registry
            .by_path(&path)?
            .ok_or_else(|| Error::Invalid(format!("{} isn't managed", path.display())))?;
        let drive = self.drive();
        if copy && drive.is_none() {
            return Err(Error::DriveOffline);
        }
        if idle::is_mount_point(&path) {
            let holders = idle::holders(&[&path])?;
            if !holders.is_empty() {
                return Err(busy_with(&path, &holders));
            }
            detach_mounted_at(&path);
        }
        if let Some(drive) = drive {
            let image = drive.layout.image_path(&entry.id);
            if copy && image.exists() {
                let mut tracker =
                    TransferTracker::new(self.observer.clone(), &entry.id, &path, "release");
                let staging = self.staging_mount(&entry.id)?;
                let attached = hdiutil::attach(&image, &staging)?;
                tracker.total = fsutil::fingerprint(&staging)?;
                let copied =
                    self.copy_with_progress(&mut tracker, &staging, &path, Overwrite::Keep, &[]);
                tracker.step(TransferStep::Flushing);
                hdiutil::detach(&attached.device, false)?;
                let _ignored = fs::remove_dir(&staging);
                let stats = copied?;
                tracker.step(TransferStep::Cleaning);
                fsutil::remove_tree(&image)?;
                self.record_transfer(tracker, stats)?;
            }
            fsutil::remove_tree(&image)?;
        }
        self.registry.delete(&entry.id)?;
        self.emit(&EngineEvent::EntriesChanged);
        Ok(())
    }

    /// Empties every managed folder at or under `path` without deleting the folders themselves,
    /// avoiding the "Resource busy" error of `rm -rf` on a mount point (spec §4.5).
    ///
    /// # Errors
    ///
    /// Fails if something can't be deleted.
    pub fn clean(&mut self, path: &Path) -> Result<Vec<PathBuf>> {
        let target = canonical_target(path)?;
        let mut cleaned = Vec::new();
        for entry in self.registry.entries()? {
            if entry.path.starts_with(&target) && entry.path.exists() {
                fsutil::clear_dir_contents(&entry.path)?;
                cleaned.push(entry.path);
            }
        }
        Ok(cleaned)
    }

    /// Rebuilds bloated images (spec §4.10). With `force`, rebuilds regardless of bloat.
    /// Returns the bytes reclaimed on the drive.
    ///
    /// # Errors
    ///
    /// Fails if the drive is offline; per-entry failures are skipped.
    pub fn compact(&mut self, path: Option<&Path>, force: bool) -> Result<u64> {
        let drive = self.require_drive()?;
        let target = path.map(canonical_target).transpose()?;
        let mut reclaimed: u64 = 0;
        for entry in self.registry.entries()? {
            if target.as_ref().is_some_and(|t| !entry.path.starts_with(t))
                || entry.status != EntryStatus::Mounted
            {
                continue;
            }
            if let Ok(saved) = self.compact_entry(&drive, &entry, force) {
                reclaimed = reclaimed.saturating_add(saved);
            }
        }
        Ok(reclaimed)
    }

    fn compact_entry(&self, drive: &Drive, entry: &Entry, force: bool) -> Result<u64> {
        let image = drive.layout.image_path(&entry.id);
        let image_bytes = fsutil::allocated_bytes(&image)?;
        let used = stowaway_macos::fs_stats(&entry.path)
            .map(|s| s.used_bytes())
            .ctx("inspecting", &entry.path)?;
        let waste = image_bytes.saturating_sub(used);
        let bloated = image_bytes > used.saturating_mul(3) / 2 && waste > 1_000_000_000;
        if !force && !bloated {
            return Ok(0);
        }
        if idle::activity(&entry.path, self.config.idle_seconds)? != Activity::Idle {
            return Err(Error::Busy(format!("{} is in use", entry.path.display())));
        }
        let mut tracker =
            TransferTracker::new(self.observer.clone(), &entry.id, &entry.path, "compact");
        let fresh = image.with_file_name(format!("{}-compacting.sparsebundle", entry.id));
        fsutil::remove_tree(&fresh)?;
        self.create_image(drive, &fresh, entry.kind, &entry.path)?;
        let before = fsutil::fingerprint(&entry.path)?;
        tracker.total = before;
        let staging = self.staging_mount(&entry.id)?;
        let attached = hdiutil::attach(&fresh, &staging)?;
        let copied =
            self.copy_with_progress(&mut tracker, &entry.path, &staging, Overwrite::Replace, &[]);
        tracker.step(TransferStep::Flushing);
        hdiutil::detach(&attached.device, false)?;
        let _ignored = fs::remove_dir(&staging);
        tracker.step(TransferStep::Verifying);
        let stats = match copied {
            Ok(stats) if fsutil::fingerprint(&entry.path)? == before => stats,
            _ => {
                fsutil::remove_tree(&fresh)?;
                return Err(Error::Busy("changed during compaction".to_owned()));
            }
        };
        tracker.step(TransferStep::Mounting);
        detach_mounted_at(&entry.path);
        let old = drive
            .layout
            .trash_dir()
            .join(format!("{}.old.sparsebundle", entry.id));
        fs::rename(&image, &old).ctx("moving", &image)?;
        fs::rename(&fresh, &image).ctx("moving", &fresh)?;
        hdiutil::attach(&image, &entry.path)?;
        tracker.step(TransferStep::Cleaning);
        fsutil::remove_tree(&old)?;
        tracker.step(TransferStep::Measuring);
        let new_bytes = fsutil::allocated_bytes(&image)?;
        self.refresh_sizes(entry, drive);
        self.record_transfer(tracker, stats)?;
        Ok(image_bytes.saturating_sub(new_bytes))
    }

    /// Deletes orphaned images: entries whose project has been missing for `gc_orphan_days`, and
    /// images with no entry at all. Returns what was (or, with `dry_run`, would be) deleted.
    ///
    /// # Errors
    ///
    /// Fails if the drive is offline.
    pub fn gc(&mut self, dry_run: bool) -> Result<Vec<PathBuf>> {
        let drive = self.require_drive()?;
        let cutoff = crate::now_unix()
            - i64::try_from(self.config.gc_orphan_days.saturating_mul(86_400)).unwrap_or(i64::MAX);
        let mut removed = Vec::new();
        let entries = self.registry.entries()?;
        for entry in &entries {
            if entry.orphaned_at.is_some_and(|t| t < cutoff) && !idle::is_mount_point(&entry.path) {
                let image = drive.layout.image_path(&entry.id);
                if !dry_run {
                    fsutil::remove_tree(&image)?;
                    self.registry.delete(&entry.id)?;
                }
                removed.push(image);
            }
        }
        if let Ok(dir) = fs::read_dir(drive.layout.images_dir()) {
            for item in dir.flatten() {
                let path = item.path();
                let id = path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .and_then(|n| n.strip_suffix(".sparsebundle"))
                    .map(str::to_owned);
                let registered = id
                    .as_deref()
                    .is_some_and(|id| entries.iter().any(|e| e.id == id));
                let in_flight = id.as_deref().is_some_and(|id| id.ends_with("-compacting"));
                if !registered && !in_flight {
                    if !dry_run {
                        fsutil::remove_tree(&path)?;
                    }
                    removed.push(path);
                }
            }
        }
        if !dry_run && let Ok(dir) = fs::read_dir(drive.layout.trash_dir()) {
            for item in dir.flatten() {
                fsutil::remove_tree(&item.path())?;
            }
        }
        if !removed.is_empty() && !dry_run {
            self.emit(&EngineEvent::EntriesChanged);
        }
        Ok(removed)
    }

    /// Detaches every image and ejects the drive (spec §4.3).
    ///
    /// # Errors
    ///
    /// [`Error::Busy`] naming the processes that hold files open.
    pub fn eject(&mut self) -> Result<()> {
        let drive = self.require_drive()?;
        Self::detach_images(&drive, "eject")?;
        crate::cmd::run(
            "diskutil",
            ["eject".as_ref(), drive.mount_point.as_os_str()],
        )?;
        self.handle_drive_absent()?;
        self.emit(&EngineEvent::DriveChanged { connected: false });
        Ok(())
    }

    /// Detaches every image, leaving the drive connected, so each folder falls back to its local
    /// contents as if the drive were gone (spec §4.2). The next [`Engine::reconcile`] attaches
    /// them again. Does nothing while the drive is offline.
    ///
    /// # Errors
    ///
    /// [`Error::Busy`] naming the processes that hold files open.
    pub fn detach_all(&mut self) -> Result<()> {
        if let Some(drive) = self.drive() {
            Self::detach_images(&drive, "quit")?;
        }
        self.handle_drive_absent()
    }

    fn detach_images(drive: &Drive, action: &str) -> Result<()> {
        let mounts: Vec<PathBuf> = hdiutil::attached()?
            .into_iter()
            .filter(|a| a.image_path.starts_with(&drive.mount_point))
            .filter_map(|a| a.mount_point)
            .collect();
        let refs: Vec<&Path> = mounts.iter().map(PathBuf::as_path).collect();
        let holders = idle::holders(&refs)?;
        if !holders.is_empty() {
            let mut names: Vec<String> = holders
                .iter()
                .map(|h| format!("{} (pid {})", h.command, h.pid))
                .collect();
            names.sort();
            names.dedup();
            return Err(Error::Busy(format!(
                "can't {action}: files on the drive are open in {}. Quit them and try again.",
                names.join(", ")
            )));
        }
        for image in hdiutil::attached()? {
            if image.image_path.starts_with(&drive.mount_point) {
                hdiutil::detach(&image.device, false)?;
            }
        }
        Ok(())
    }

    // ----- discovery ----------------------------------------------------------------------------

    /// The folders scanned for projects: the configured roots, plus the folders where coding
    /// agents keep their worktrees.
    #[must_use]
    pub fn scan_roots(&self) -> Vec<PathBuf> {
        let mut roots = self.config.roots.clone();
        for dir in scan::AGENT_WORKTREE_DIRS
            .iter()
            .map(|d| self.layout.home.join(d))
        {
            if dir.is_dir() && !roots.contains(&dir) {
                roots.push(dir);
            }
        }
        roots
    }

    /// Finds folders that could be adopted: project folders under the roots and configured global
    /// caches, excluding ones already managed.
    ///
    /// # Errors
    ///
    /// Fails on an invalid exclude pattern or database error.
    pub fn discover(&self) -> Result<Vec<Candidate>> {
        let exclude = self.config.exclude_set(&self.layout)?;
        let project_kinds: Vec<KindId> = KindId::ALL
            .into_iter()
            .filter(|&k| {
                self.config.kind_enabled(k) && matches!(k.spec().scope, Scope::Project { .. })
            })
            .collect();
        let opts = ScanOptions {
            kinds: &project_kinds,
            exclude: &exclude,
            cargo_target_dir_set: self.config.cargo_target_dir.is_some(),
            max_depth: 6,
        };
        let mut found = Vec::new();
        for root in self.scan_roots() {
            found.extend(scan::scan(&root, &opts));
        }
        for (&kind, paths) in &self.config.globals {
            if !self.config.kind_enabled(kind) {
                continue;
            }
            for path in paths.iter().flat_map(|p| kinds::managed_folders(kind, p)) {
                if exclude.is_match(&path) {
                    continue;
                }
                let exists = path.is_dir();
                // Only pre-adopt a global cache whose tool is installed (its parent exists).
                if exists || path.parent().is_some_and(Path::is_dir) {
                    found.push(Candidate { kind, path, exists });
                }
            }
        }
        let managed = self.registry.entries()?;
        found.retain(|c| {
            let canonical = canonical_target(&c.path).unwrap_or_else(|_| c.path.clone());
            !managed
                .iter()
                .any(|e| e.path == canonical || canonical.starts_with(&e.path))
        });
        Ok(found)
    }

    /// Adopts what [`Engine::discover`] finds, respecting idle, size and pre-adoption settings.
    /// Returns what happened to each candidate.
    ///
    /// # Errors
    ///
    /// Fails if discovery fails; per-candidate failures are reported in the result.
    pub fn auto_adopt(&mut self) -> Result<Vec<(Candidate, Result<Entry>)>> {
        if self.config.paused {
            return Ok(Vec::new());
        }
        let found = self.adoption_candidates(&mut |_| {})?;
        let mut results: Vec<_> = found
            .unmeasured
            .into_iter()
            .map(|(c, e)| (c, Err(e)))
            .collect();
        for (candidate, _) in found.ready {
            let outcome = self.adopt(&candidate.path, candidate.kind, AdoptOptions::default());
            results.push((candidate, outcome));
        }
        Ok(results)
    }

    /// What [`Engine::discover`] finds that the pre-adoption and size settings allow adopting,
    /// plus the candidates that couldn't be measured. It only reads, so callers don't need the
    /// [`EngineLock`]; measuring a large tree can take minutes, so `on_measured` is called before
    /// the first candidate and after each one.
    ///
    /// # Errors
    ///
    /// Fails if discovery fails.
    pub fn adoption_candidates(
        &self,
        on_measured: &mut dyn FnMut(&MeasureProgress),
    ) -> Result<AdoptionCandidates> {
        let candidates = self.discover()?;
        let mut found = AdoptionCandidates::default();
        let mut progress = MeasureProgress {
            done: 0,
            total: candidates.len(),
            ready_bytes: 0,
        };
        on_measured(&progress);
        let now = crate::now_unix();
        let _ignored = self.registry.prune_measurements(now - MEASUREMENT_TTL_SECS);
        for candidate in candidates {
            if candidate.exists {
                match self.measure_candidate(&candidate.path, now) {
                    Ok(size) if size < self.config.min_adopt_bytes => {}
                    Ok(size) => {
                        progress.ready_bytes += size;
                        found.ready.push((candidate, size));
                    }
                    Err(e) => found.unmeasured.push((candidate, e)),
                }
            } else if self.config.pre_adopt {
                found.ready.push((candidate, 0));
            }
            progress.done += 1;
            on_measured(&progress);
        }
        Ok(found)
    }

    /// A candidate's size, from the cache when it's fresh. A cached size is reused until it
    /// expires or the folder's own modification time changes (an install adding or removing
    /// packages, a first build creating `target/debug`). Sizes only decide what's worth adopting
    /// and how much the plan expects to move; adoption itself copies whatever is there.
    fn measure_candidate(&self, path: &Path, now: i64) -> Result<u64> {
        let meta = path.symlink_metadata().ctx("inspecting", path)?;
        let dir_mtime_ns = meta
            .mtime()
            .saturating_mul(1_000_000_000)
            .saturating_add(meta.mtime_nsec());
        if let Ok(Some(cached)) = self.registry.measurement(path)
            && cached.dir_mtime_ns == dir_mtime_ns
            && now - cached.measured_at < MEASUREMENT_TTL_SECS
        {
            return Ok(cached.bytes);
        }
        let bytes = fsutil::allocated_bytes(path)?;
        let _ignored = self.registry.record_measurement(
            path,
            Measurement {
                bytes,
                dir_mtime_ns,
                measured_at: now,
            },
        );
        Ok(bytes)
    }

    // ----- measurement and status ---------------------------------------------------------------

    fn refresh_sizes(&self, entry: &Entry, drive: &Drive) {
        // Walk the files rather than asking the volume: an empty APFS image already reports
        // several MB of filesystem metadata as used.
        let used = fsutil::allocated_bytes(&entry.path).unwrap_or(0);
        let image = fsutil::allocated_bytes(&drive.layout.image_path(&entry.id)).unwrap_or(0);
        let _ignored = self.registry.set_sizes(&entry.id, used, image);
    }

    /// Re-measures every mounted entry.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn refresh_all_sizes(&mut self) -> Result<()> {
        if let Some(drive) = self.drive() {
            for entry in self.registry.entries()? {
                if entry.status == EntryStatus::Mounted && idle::is_mount_point(&entry.path) {
                    self.refresh_sizes(&entry, &drive);
                }
            }
        }
        Ok(())
    }

    /// Health checks for `doctor` and the menu bar's problem list.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn problems(&mut self) -> Result<Vec<Problem>> {
        let mut problems = Vec::new();
        for root in &self.config.roots {
            if !root.is_dir() {
                problems.push(Problem {
                    severity: Severity::Warning,
                    message: format!("watched folder {} doesn't exist", root.display()),
                    hint: Some("remove it with `stowaway roots remove`".to_owned()),
                });
            }
        }
        if let Some(drive) = self.drive() {
            if fs::read_dir(drive.layout.images_dir()).is_err() {
                problems.push(Problem {
                    severity: Severity::Error,
                    message: "can't read Stowaway's folder on the drive".to_owned(),
                    hint: Some(
                        "grant access in System Settings → Privacy & Security → Files and Folders → Removable Volumes"
                            .to_owned(),
                    ),
                });
            }
            if let Ok(stats) = stowaway_macos::fs_stats(&drive.mount_point) {
                let percent_free = stats
                    .available_bytes
                    .saturating_mul(100)
                    .checked_div(stats.total_bytes)
                    .unwrap_or(0);
                if percent_free < u64::from(self.config.drive_low_space_percent) {
                    problems.push(Problem {
                        severity: if percent_free < 2 {
                            Severity::Error
                        } else {
                            Severity::Warning
                        },
                        message: format!("the drive is nearly full ({percent_free}% free)"),
                        hint: Some(
                            "run `stowaway gc` and `stowaway compact`, or free up space".to_owned(),
                        ),
                    });
                }
            }
        }
        for entry in self.registry.entries()? {
            match entry.status {
                EntryStatus::Error => problems.push(Problem {
                    severity: Severity::Error,
                    message: format!(
                        "{}: {}",
                        entry.path.display(),
                        entry.note.as_deref().unwrap_or("failed")
                    ),
                    hint: Some("Stowaway retries automatically".to_owned()),
                }),
                EntryStatus::Mounted if !idle::is_mount_point(&entry.path) => {
                    problems.push(Problem {
                        severity: Severity::Warning,
                        message: format!(
                            "{} came off the drive; Stowaway is reattaching it",
                            entry.path.display()
                        ),
                        hint: None,
                    });
                }
                _ => {}
            }
        }
        Ok(problems)
    }
}

/// Holds Cargo's package-cache lock for `cargo-home` entries.
fn cargo_package_lock(kind: KindId, path: &Path) -> Result<Option<File>> {
    if !kind.spec().cargo_package_lock {
        return Ok(None);
    }
    let Some(cargo_home) = path.parent() else {
        return Ok(None);
    };
    let lock_path = cargo_home.join(".package-cache");
    let file = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&lock_path)
        .ctx("opening", &lock_path)?;
    file.lock().ctx("locking", &lock_path)?;
    Ok(Some(file))
}

fn project_deleted(kind: KindId, path: &Path) -> bool {
    match kind.spec().scope {
        Scope::Project { manifest, .. } => {
            kinds::project_dir(kind, path).is_some_and(|project| !project.join(manifest).exists())
        }
        Scope::Global => false,
    }
}

fn new_entry(id: &str, kind: KindId, path: &Path, now: i64, status: EntryStatus) -> Entry {
    Entry {
        id: id.to_owned(),
        kind,
        path: path.to_path_buf(),
        created_at: now,
        used_bytes: 0,
        image_bytes: 0,
        last_seen_at: now,
        orphaned_at: None,
        status,
        note: None,
    }
}

fn busy_with(path: &Path, holders: &[idle::Holder]) -> Error {
    let mut names: Vec<&str> = holders.iter().map(|h| h.command.as_str()).collect();
    names.sort_unstable();
    names.dedup();
    Error::Busy(format!(
        "{} is in use by {}; quit them and try again",
        path.display(),
        names.join(", ")
    ))
}

/// Detaches whatever image is mounted at `mount_point`, forcing if needed.
fn detach_mounted_at(mount_point: &Path) {
    if let Ok(images) = hdiutil::attached() {
        for image in images {
            if image
                .mount_point
                .as_deref()
                .is_some_and(|m| same_file(m, mount_point))
                && hdiutil::detach(&image.device, false).is_err()
            {
                let _ignored = hdiutil::detach(&image.device, true);
            }
        }
    }
}

/// Resolves symlinks in the parent so stored paths match what `hdiutil` and `lsof` report.
///
/// # Errors
///
/// Fails if the path has no file name.
pub fn canonical_target(path: &Path) -> Result<PathBuf> {
    let path = crate::paths::normalize(path);
    let name = path
        .file_name()
        .ok_or_else(|| Error::Invalid(format!("{} has no folder name", path.display())))?;
    let parent = path.parent().unwrap_or_else(|| Path::new("/"));
    let mut existing = parent.to_path_buf();
    let mut tail = Vec::new();
    while !existing.exists() {
        match (existing.file_name(), existing.parent()) {
            (Some(n), Some(p)) => {
                tail.push(n.to_owned());
                existing = p.to_path_buf();
            }
            _ => break,
        }
    }
    let mut resolved = fs::canonicalize(&existing).unwrap_or(existing);
    for part in tail.iter().rev() {
        resolved.push(part);
    }
    Ok(resolved.join(name))
}

fn same_file(a: &Path, b: &Path) -> bool {
    a == b || matches!((fs::canonicalize(a), fs::canonicalize(b)), (Ok(x), Ok(y)) if x == y)
}

/// A volume name for an image: shows in Disk Utility, so make it recognizable. A part is named
/// for its project and its place in `container`, e.g. "stow arbvark debug deps".
fn volume_name(kind: KindId, path: &Path, container: Option<&Path>) -> String {
    let file_name = |p: &Path| {
        p.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    };
    let project = kinds::project_dir(kind, path);
    let place = container
        .and_then(|c| path.strip_prefix(c).ok())
        .map(|rel| {
            rel.components()
                .map(|c| c.as_os_str().to_string_lossy().into_owned())
                .collect::<Vec<_>>()
                .join(" ")
        });
    let raw = match (place, project) {
        (Some(place), Some(project)) => format!("stow {} {place}", file_name(project)),
        (Some(place), None) => format!("stow {place}"),
        (None, Some(project)) => format!("stow {} {}", kind.as_str(), file_name(project)),
        (None, None) => format!("stow {} {}", kind.as_str(), file_name(path)),
    };
    raw.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == ' ' {
                c
            } else {
                '-'
            }
        })
        .take(27)
        .collect::<String>()
        .trim()
        .to_owned()
}

/// Sets up Stowaway: validates the drive, records configuration and prepares the drive.
///
/// # Errors
///
/// Fails if the drive isn't suitable or files can't be written.
pub fn init(layout: &Layout, volume: &Path, roots: &[PathBuf]) -> Result<Config> {
    let info = drive::validate_for_init(volume)?;
    let uuid = info
        .volume_uuid
        .clone()
        .ok_or_else(|| Error::Invalid("volume has no UUID".to_owned()))?;
    let machine_id = machine_id()?;
    let mut config = Config::load(layout)?.unwrap_or_default();
    config.volume_uuid = Some(uuid.clone());
    config.volume_name.clone_from(&info.volume_name);
    config.machine_id.clone_from(&machine_id);
    config.internal_case_sensitive = drive::disk_info("/").is_ok_and(|i| i.case_sensitive());
    for root in roots {
        let root = layout.expand(root);
        let root = fs::canonicalize(&root).ctx("finding", &root)?;
        if !config.roots.contains(&root) {
            config.roots.push(root);
        }
    }
    config.cargo_target_dir = std::env::var_os("CARGO_TARGET_DIR").map(PathBuf::from);
    config.globals.clear();
    config.record_missing_globals(&layout.home, &kinds::ProcessEnvironment);
    let mount_point = PathBuf::from(
        info.mount_point
            .clone()
            .ok_or_else(|| Error::Invalid("volume isn't mounted".to_owned()))?,
    );
    drive::prepare(&DriveLayout::new(&mount_point, &machine_id), &uuid)?;
    config.save(layout)?;
    Registry::open(&layout.db_path())?;
    Ok(config)
}

/// This Mac's hardware UUID.
///
/// # Errors
///
/// Fails if `ioreg` fails or its output lacks the UUID.
pub fn machine_id() -> Result<String> {
    let out = crate::cmd::run_string("ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"])?;
    out.lines()
        .find(|l| l.contains("IOPlatformUUID"))
        .and_then(|l| l.split('"').nth(3))
        .map(str::to_owned)
        .ok_or_else(|| Error::Parse {
            command: "ioreg".to_owned(),
            detail: "no IOPlatformUUID".to_owned(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn volume_names_are_short_and_safe() {
        assert_eq!(
            volume_name(
                KindId::Node,
                Path::new("/Users/me/code/my_app!/node_modules"),
                None
            ),
            "stow node my-app-"
        );
        let long = volume_name(
            KindId::CargoTarget,
            Path::new("/x/a-really-long-project-name-that-goes-on/target"),
            None,
        );
        assert!(long.len() <= 27, "{long}");
        assert_eq!(
            volume_name(
                KindId::CargoHome,
                Path::new("/Users/me/.cargo/registry"),
                None
            ),
            "stow cargo-home registry"
        );
        let target = Path::new("/code/arbvark/target");
        assert_eq!(
            volume_name(
                KindId::CargoTarget,
                &target.join("debug/deps"),
                Some(target)
            ),
            "stow arbvark debug deps"
        );
        // A custom DerivedData location is named for its place in it all the same.
        let dd = Path::new("/Volumes/Work/DD");
        assert_eq!(
            volume_name(
                KindId::XcodeDerivedData,
                &dd.join("App-abc/Index.noindex"),
                Some(dd)
            ),
            "stow App-abc Index-noindex"
        );
    }

    #[test]
    fn candidate_sizes_are_cached_until_the_folder_changes_or_expires() {
        let dir = tempfile::tempdir().unwrap();
        let layout = Layout::rooted(dir.path(), &dir.path().join("state"));
        Config {
            volume_uuid: Some("UUID".into()),
            ..Config::default()
        }
        .save(&layout)
        .unwrap();
        let engine = Engine::open(layout).unwrap();
        let folder = dir.path().join("proj/node_modules");
        fs::create_dir_all(folder.join("pkg")).unwrap();
        let deep = folder.join("pkg/index.js");
        fs::write(&deep, vec![1_u8; 100_000]).unwrap();
        let now = 1_000_000;
        let first = engine.measure_candidate(&folder, now).unwrap();
        assert!(first > 0);

        fs::write(&deep, vec![1_u8; 400_000]).unwrap();
        assert_eq!(
            engine.measure_candidate(&folder, now).unwrap(),
            first,
            "a change deep inside is picked up only when the cache expires"
        );
        let grown = engine
            .measure_candidate(&folder, now + MEASUREMENT_TTL_SECS)
            .unwrap();
        assert!(grown > first);

        fs::write(folder.join("new-package"), vec![1_u8; 400_000]).unwrap();
        assert!(
            engine
                .measure_candidate(&folder, now + MEASUREMENT_TTL_SECS)
                .unwrap()
                > grown,
            "adding a top-level item invalidates the cache"
        );
    }

    #[test]
    fn canonical_target_resolves_parent_symlinks() {
        let dir = tempfile::tempdir().unwrap();
        let resolved = canonical_target(&dir.path().join("proj/node_modules")).unwrap();
        let real = fs::canonicalize(dir.path()).unwrap();
        assert_eq!(resolved, real.join("proj/node_modules"));
    }

    #[test]
    fn machine_id_is_available() {
        let id = machine_id().unwrap();
        assert_eq!(id.len(), 36, "{id}");
    }

    #[test]
    fn lock_is_exclusive() {
        let dir = tempfile::tempdir().unwrap();
        let layout = Layout::rooted(dir.path(), dir.path());
        let first = EngineLock::acquire(&layout, Duration::from_millis(10)).unwrap();
        // A second handle in the same process contends on the same file lock.
        assert!(matches!(
            EngineLock::acquire(&layout, Duration::from_millis(50)),
            Err(Error::Busy(_))
        ));
        drop(first);
        EngineLock::acquire(&layout, Duration::from_millis(10)).unwrap();
    }
}
