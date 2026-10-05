//! The background agent: polls for the drive, reconciles entries, adopts new folders, and
//! serves the IPC socket for the CLI and the menu bar app.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime};

use tracing::{info, warn};

use crate::engine::{Engine, EngineEvent, EngineLock, Observer};
use crate::error::{Error, IoContext, Result};
use crate::ipc::{Call, Notification, Request, Response};
use crate::paths::Layout;
use crate::registry::EntryStatus;
use crate::{ops, status};

const TICK: Duration = Duration::from_secs(2);
const RECONCILE_EVERY: Duration = Duration::from_secs(60);
const RETRY_PENDING_EVERY: Duration = Duration::from_secs(15);
const SCAN_EVERY: Duration = Duration::from_mins(10);
const FS_SCAN_DEBOUNCE: Duration = Duration::from_secs(20);
const SIZES_EVERY: Duration = Duration::from_mins(30);
const GC_EVERY: Duration = Duration::from_hours(24);
const STATUS_EVERY: Duration = Duration::from_secs(15);

/// Names whose creation or deletion under a root may mean there's something to adopt or clean up.
const INTERESTING: &[&str] = &[
    "node_modules",
    "target",
    "package.json",
    "Cargo.toml",
    "Cargo.lock",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "bun.lock",
    "bun.lockb",
];

struct Shared {
    layout: Layout,
    subscribers: Mutex<Vec<UnixStream>>,
    active: Mutex<BTreeMap<String, EngineEvent>>,
    status_dirty: AtomicBool,
    fs_dirty: AtomicBool,
    wake: Mutex<Sender<()>>,
}

impl Shared {
    fn broadcast(&self, note: &Notification) {
        let Ok(mut line) = serde_json::to_vec(note) else {
            return;
        };
        line.push(b'\n');
        let mut subs = self
            .subscribers
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        subs.retain_mut(|s| s.write_all(&line).is_ok());
    }

    fn has_subscribers(&self) -> bool {
        !self
            .subscribers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_empty()
    }

    fn wake(&self) {
        let _ignored = self
            .wake
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .send(());
    }

    fn active_transfers(&self) -> Vec<EngineEvent> {
        self.active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .cloned()
            .collect()
    }
}

fn observer_for(shared: &Arc<Shared>) -> Observer {
    let shared = Arc::clone(shared);
    Arc::new(move |event: &EngineEvent| {
        match event {
            EngineEvent::TransferProgress { entry_id, .. } => {
                shared
                    .active
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .insert(entry_id.clone(), event.clone());
            }
            EngineEvent::TransferDone { transfer } => {
                shared
                    .active
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .remove(&transfer.entry_id);
                shared.status_dirty.store(true, Ordering::Relaxed);
            }
            EngineEvent::EntriesChanged | EngineEvent::DriveChanged { .. } => {
                shared.status_dirty.store(true, Ordering::Relaxed);
            }
        }
        shared.broadcast(&Notification::Engine(event.clone()));
    })
}

fn open_engine(shared: &Arc<Shared>) -> Result<Engine> {
    let mut engine = Engine::open(shared.layout.clone())?;
    engine.set_observer(Some(observer_for(shared)));
    Ok(engine)
}

/// Runs the agent until the process is terminated.
///
/// # Errors
///
/// Fails if Stowaway isn't initialized or the socket can't be created.
pub fn run(layout: &Layout) -> Result<()> {
    init_logging(layout)?;
    info!(version = env!("CARGO_PKG_VERSION"), "agent starting");
    let (wake_tx, wake_rx) = mpsc::channel();
    let shared = Arc::new(Shared {
        layout: layout.clone(),
        subscribers: Mutex::new(Vec::new()),
        active: Mutex::new(BTreeMap::new()),
        status_dirty: AtomicBool::new(true),
        fs_dirty: AtomicBool::new(true),
        wake: Mutex::new(wake_tx),
    });
    let listener = bind_socket(layout)?;
    {
        let shared = Arc::clone(&shared);
        std::thread::Builder::new()
            .name("ipc".into())
            .spawn(move || serve(&listener, &shared))
            .map_err(|e| Error::io("spawning", Path::new("ipc thread"), e))?;
    }
    main_loop(&shared, &wake_rx)
}

fn init_logging(layout: &Layout) -> Result<()> {
    std::fs::create_dir_all(&layout.state_dir).ctx("creating", &layout.state_dir)?;
    let path = layout.log_path();
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .ctx("opening", &path)?;
    let _ignored = tracing_subscriber::fmt()
        .with_ansi(false)
        .with_target(false)
        .with_writer(Mutex::new(file))
        .try_init();
    Ok(())
}

fn bind_socket(layout: &Layout) -> Result<UnixListener> {
    let path = &layout.socket_path();
    let private = layout.private_tmp_dir();
    if path.parent() == Some(private.as_path()) {
        prepare_private_dir(&private)?;
    }
    if path.exists() {
        if UnixStream::connect(path).is_ok() {
            return Err(Error::Invalid(
                "another Stowaway agent is already running".to_owned(),
            ));
        }
        std::fs::remove_file(path).ctx("removing stale", path)?;
    }
    let listener = UnixListener::bind(path).ctx("binding", path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).ctx("securing", path)?;
    Ok(listener)
}

/// Creates (or validates) a directory only we can use, so nobody else can plant a socket there.
fn prepare_private_dir(dir: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    if !dir.exists() {
        std::fs::create_dir_all(dir).ctx("creating", dir)?;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            .ctx("securing", dir)?;
    }
    let meta = std::fs::symlink_metadata(dir).ctx("inspecting", dir)?;
    let home_uid = std::env::var_os("HOME")
        .and_then(|h| std::fs::metadata(h).ok())
        .map(|m| m.uid());
    if !meta.is_dir() || meta.mode() & 0o077 != 0 || Some(meta.uid()) != home_uid {
        return Err(Error::Invalid(format!(
            "{} isn't a private directory owned by you; remove it and try again",
            dir.display()
        )));
    }
    Ok(())
}

struct Timers {
    reconcile: Instant,
    scan: Instant,
    fs_scan: Instant,
    sizes: Instant,
    gc: Instant,
    status: Instant,
}

struct AgentLoop {
    shared: Arc<Shared>,
    engine: Engine,
    timers: Timers,
    long_ago: Instant,
    last_connected: Option<bool>,
    config_stamp: Option<SystemTime>,
    /// Held only to keep the `FSEvents` stream alive.
    watcher: Option<notify::RecommendedWatcher>,
    bench_attempted: bool,
}

fn main_loop(shared: &Arc<Shared>, wake: &Receiver<()>) -> Result<()> {
    let engine = open_engine(shared)?;
    let long_ago = Instant::now()
        .checked_sub(Duration::from_hours(48))
        .unwrap_or_else(Instant::now);
    let mut agent = AgentLoop {
        watcher: start_watcher(shared, &engine.config.roots),
        shared: Arc::clone(shared),
        engine,
        timers: Timers {
            reconcile: long_ago,
            scan: long_ago,
            fs_scan: long_ago,
            sizes: Instant::now(),
            gc: long_ago,
            status: long_ago,
        },
        long_ago,
        last_connected: None,
        config_stamp: config_mtime(&shared.layout),
        bench_attempted: false,
    };
    loop {
        agent.tick();
        let _ignored = wake.recv_timeout(TICK);
    }
}

impl AgentLoop {
    fn tick(&mut self) {
        self.reload_config_if_changed();
        let connected = self.engine.drive().is_some();
        let drive_changed = self.last_connected != Some(connected);
        if drive_changed {
            self.on_drive_changed(connected);
        }
        let fs_dirty = self.shared.fs_dirty.load(Ordering::Relaxed)
            && self.timers.fs_scan.elapsed() >= FS_SCAN_DEBOUNCE;
        self.maybe_reconcile(connected, drive_changed, fs_dirty);
        if connected {
            self.maybe_adopt(drive_changed, fs_dirty);
            self.housekeeping();
        }
        self.maybe_broadcast_status();
    }

    fn reload_config_if_changed(&mut self) {
        let stamp = config_mtime(&self.shared.layout);
        if stamp == self.config_stamp {
            return;
        }
        self.config_stamp = stamp;
        match self.engine.reload_config() {
            Ok(()) => {
                info!("config reloaded");
                self.watcher = start_watcher(&self.shared, &self.engine.config.roots);
                self.shared.status_dirty.store(true, Ordering::Relaxed);
                self.timers.scan = self.long_ago;
            }
            Err(e) => warn!(error = %e, "config reload failed"),
        }
    }

    fn on_drive_changed(&self, connected: bool) {
        info!(connected, "drive state changed");
        if self.last_connected == Some(true) && !self.shared.active_transfers().is_empty() {
            notify_user(
                "Drive disconnected",
                "Stowaway's transfers stopped; your projects now use local folders.",
            );
        }
        self.shared
            .broadcast(&Notification::Engine(EngineEvent::DriveChanged {
                connected,
            }));
        self.shared
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();
        self.shared.status_dirty.store(true, Ordering::Relaxed);
    }

    fn maybe_reconcile(&mut self, connected: bool, drive_changed: bool, fs_dirty: bool) {
        let pending = self.engine.registry.entries().is_ok_and(|entries| {
            entries
                .iter()
                .any(|e| matches!(e.status, EntryStatus::PendingReconnect | EntryStatus::Error))
        });
        let since = self.timers.reconcile.elapsed();
        if !(drive_changed
            || fs_dirty
            || since >= RECONCILE_EVERY
            || (pending && since >= RETRY_PENDING_EVERY))
        {
            return;
        }
        let engine = &mut self.engine;
        let done = with_lock(&self.shared, "reconcile", || {
            for (entry, outcome) in engine.reconcile()? {
                info!(path = %entry.path.display(), ?outcome, "reconciled");
            }
            Ok(())
        });
        if done {
            self.timers.reconcile = Instant::now();
            self.last_connected = Some(connected);
        }
    }

    fn maybe_adopt(&mut self, drive_changed: bool, fs_dirty: bool) {
        if self.engine.config.paused
            || !(fs_dirty || drive_changed || self.timers.scan.elapsed() >= SCAN_EVERY)
        {
            return;
        }
        self.shared.fs_dirty.store(false, Ordering::Relaxed);
        self.timers.fs_scan = Instant::now();
        let engine = &mut self.engine;
        let done = with_lock(&self.shared, "auto-adopt", || {
            for (candidate, outcome) in engine.auto_adopt()? {
                match outcome {
                    Ok(entry) => info!(path = %entry.path.display(), kind = %entry.kind, "adopted"),
                    Err(Error::Busy(why)) => {
                        info!(path = %candidate.path.display(), %why, "adoption postponed");
                    }
                    Err(e) => {
                        warn!(path = %candidate.path.display(), error = %e, "adoption failed");
                    }
                }
            }
            Ok(())
        });
        if done {
            self.timers.scan = Instant::now();
        }
    }

    fn housekeeping(&mut self) {
        let engine = &mut self.engine;
        if self.timers.sizes.elapsed() >= SIZES_EVERY {
            let _done = with_lock(&self.shared, "housekeeping", || {
                engine.refresh_all_sizes()?;
                let reclaimed = engine.compact(None, false)?;
                if reclaimed > 0 {
                    info!(reclaimed, "compacted images");
                }
                Ok(())
            });
            self.timers.sizes = Instant::now();
            self.shared.status_dirty.store(true, Ordering::Relaxed);
        }
        if self.timers.gc.elapsed() >= GC_EVERY {
            let _done = with_lock(&self.shared, "gc", || {
                let removed = engine.gc(false)?;
                if !removed.is_empty() {
                    info!(count = removed.len(), "garbage-collected images");
                }
                Ok(())
            });
            self.timers.gc = Instant::now();
        }
        if !self.bench_attempted && first_bench_needed(engine) {
            // The speed test only writes scratch files, so it runs without the engine lock and
            // doesn't hold up adoption or CLI commands.
            self.bench_attempted = true;
            match ops::bench(engine, false) {
                Ok(report) => info!(
                    read = report.external.seq_read_mbps,
                    write = report.external.seq_write_mbps,
                    "speed test"
                ),
                Err(e) => warn!(error = %e, "speed test failed"),
            }
            self.shared.status_dirty.store(true, Ordering::Relaxed);
        }
    }

    fn maybe_broadcast_status(&mut self) {
        if !self.shared.has_subscribers() {
            return;
        }
        let dirty = self.shared.status_dirty.swap(false, Ordering::Relaxed);
        if !dirty && self.timers.status.elapsed() < STATUS_EVERY {
            return;
        }
        if let Ok(report) = snapshot(&mut self.engine, &self.shared) {
            self.shared
                .broadcast(&Notification::Status(Box::new(report)));
        }
        self.timers.status = Instant::now();
    }
}

fn first_bench_needed(engine: &Engine) -> bool {
    engine
        .config
        .volume_uuid
        .as_deref()
        .is_some_and(|uuid| matches!(engine.registry.latest_bench(uuid), Ok(None)))
}

/// Runs `f` under the engine lock. Returns false if the lock was busy, so the caller retries.
fn with_lock(shared: &Shared, what: &str, f: impl FnOnce() -> Result<()>) -> bool {
    match EngineLock::acquire(&shared.layout, Duration::from_secs(1)) {
        Ok(_lock) => {
            if let Err(e) = f() {
                warn!(error = %e, "{what} failed");
            }
            true
        }
        Err(e) => {
            info!(reason = %e, "{what} skipped");
            false
        }
    }
}

fn snapshot(engine: &mut Engine, shared: &Shared) -> Result<status::StatusReport> {
    let mut report = status::build(engine)?;
    report.agent_running = true;
    report.active_transfers = shared.active_transfers();
    Ok(report)
}

fn config_mtime(layout: &Layout) -> Option<SystemTime> {
    std::fs::metadata(&layout.config_file)
        .and_then(|m| m.modified())
        .ok()
}

fn start_watcher(shared: &Arc<Shared>, roots: &[PathBuf]) -> Option<notify::RecommendedWatcher> {
    use notify::{RecursiveMode, Watcher};
    let flag = Arc::clone(shared);
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if let Ok(event) = res
            && event.paths.iter().any(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| INTERESTING.contains(&n))
            })
        {
            flag.fs_dirty.store(true, Ordering::Relaxed);
        }
    })
    .ok()?;
    for root in roots {
        if let Err(e) = watcher.watch(root, RecursiveMode::Recursive) {
            warn!(root = %root.display(), error = %e, "can't watch folder");
        }
    }
    Some(watcher)
}

fn serve(listener: &UnixListener, shared: &Arc<Shared>) {
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let shared = Arc::clone(shared);
        let spawned = std::thread::Builder::new()
            .name("ipc-client".into())
            .spawn(move || handle_client(stream, &shared));
        if let Err(e) = spawned {
            warn!(error = %e, "can't start IPC client thread");
        }
    }
}

fn handle_client(stream: UnixStream, shared: &Arc<Shared>) {
    let Ok(reader_stream) = stream.try_clone() else {
        return;
    };
    let mut writer = stream;
    let reader = BufReader::new(reader_stream);
    for line in reader.lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<Request>(&line) {
            Ok(request) => {
                let subscribe = request.call == Call::Subscribe;
                let response = respond(request, shared);
                if subscribe && let Ok(clone) = writer.try_clone() {
                    shared
                        .subscribers
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .push(clone);
                    shared.status_dirty.store(true, Ordering::Relaxed);
                    shared.wake();
                }
                response
            }
            Err(e) => Response {
                id: 0,
                ok: false,
                result: None,
                error: Some(format!("bad request: {e}")),
            },
        };
        let Ok(mut bytes) = serde_json::to_vec(&response) else {
            break;
        };
        bytes.push(b'\n');
        if writer.write_all(&bytes).is_err() {
            break;
        }
    }
}

fn respond(request: Request, shared: &Arc<Shared>) -> Response {
    let id = request.id;
    match dispatch(request.call, shared) {
        Ok(result) => Response {
            id,
            ok: true,
            result,
            error: None,
        },
        Err(e) => Response {
            id,
            ok: false,
            result: None,
            error: Some(e.to_string()),
        },
    }
}

fn dispatch(call: Call, shared: &Arc<Shared>) -> Result<Option<serde_json::Value>> {
    let locked = |f: &mut dyn FnMut(&mut Engine) -> Result<Option<serde_json::Value>>| {
        let _lock = EngineLock::acquire(&shared.layout, Duration::from_secs(30))?;
        let mut engine = open_engine(shared)?;
        let result = f(&mut engine);
        shared.status_dirty.store(true, Ordering::Relaxed);
        shared.wake();
        result
    };
    match call {
        Call::Status => {
            let mut engine = open_engine(shared)?;
            Ok(Some(serde_json::to_value(snapshot(&mut engine, shared)?)?))
        }
        Call::Subscribe => Ok(None),
        Call::Refresh => {
            shared.fs_dirty.store(true, Ordering::Relaxed);
            shared.status_dirty.store(true, Ordering::Relaxed);
            shared.wake();
            Ok(None)
        }
        Call::Scan => locked(&mut |engine| {
            engine.reconcile()?;
            let adopted: Vec<String> = engine
                .auto_adopt()?
                .into_iter()
                .filter_map(|(c, r)| r.ok().map(|_| c.path.display().to_string()))
                .collect();
            Ok(Some(serde_json::to_value(adopted)?))
        }),
        Call::RootsAdd { path, dry_run } => locked(&mut |engine| {
            let preview = ops::roots_add(engine, &path, dry_run)?;
            Ok(Some(serde_json::to_value(preview)?))
        }),
        Call::RootsRemove { path, copy } => locked(&mut |engine| {
            let released = ops::roots_remove(engine, &path, copy)?;
            Ok(Some(serde_json::to_value(released)?))
        }),
        Call::Eject => locked(&mut |engine| engine.eject().map(|()| None)),
        Call::Pause => locked(&mut |engine| ops::set_paused(engine, true).map(|()| None)),
        Call::Resume => locked(&mut |engine| ops::set_paused(engine, false).map(|()| None)),
        Call::Doctor { fix } => locked(&mut |engine| {
            let problems = ops::doctor(engine, fix)?;
            Ok(Some(serde_json::to_value(problems)?))
        }),
        Call::Bench { quick } => {
            let mut engine = open_engine(shared)?;
            let report = ops::bench(&mut engine, quick)?;
            shared.status_dirty.store(true, Ordering::Relaxed);
            shared.wake();
            Ok(Some(serde_json::to_value(report)?))
        }
        Call::SetUsage { usage } => {
            locked(&mut |engine| ops::set_usage(engine, usage).map(|()| None))
        }
        Call::RecordLicense { order_id, licensee } => locked(&mut |engine| {
            ops::record_license(engine, &order_id, licensee.as_deref()).map(|()| None)
        }),
    }
}

/// Posts a macOS notification. Failures are ignored: notifications are a courtesy.
pub fn notify_user(title: &str, message: &str) {
    let script = format!(
        "display notification {} with title {}",
        applescript_string(message),
        applescript_string(title)
    );
    let _ignored = crate::cmd::run("osascript", ["-e", &script]);
}

fn applescript_string(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn applescript_strings_are_escaped() {
        assert_eq!(
            applescript_string(r#"say "hi" \ bye"#),
            r#""say \"hi\" \\ bye""#
        );
    }
}
