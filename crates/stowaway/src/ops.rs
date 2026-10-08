//! Operations shared by the CLI and the agent's IPC handlers.

use std::path::{Path, PathBuf};

use crate::bench::{self, BenchReport, BenchSizes};
use crate::config::{Config, TransferPriority, Usage};
use crate::engine::{Engine, Problem};
use crate::error::{Error, IoContext, Result};
use crate::fsutil;
use crate::ipc::RootPreview;
use crate::kinds::KindId;
use crate::paths::Layout;

/// Validates and adds a watched root, or previews it with `dry_run`.
///
/// # Errors
///
/// Rejects folders that overlap an existing root, live in Stowaway's storage or on the drive,
/// or are system locations.
pub fn roots_add(engine: &mut Engine, path: &Path, dry_run: bool) -> Result<RootPreview> {
    let expanded = engine.layout.expand(path);
    let root = std::fs::canonicalize(&expanded).ctx("finding", &expanded)?;
    if !root.is_dir() {
        return Err(Error::Invalid(format!("{} isn't a folder", root.display())));
    }
    let forbidden = [
        Path::new("/"),
        Path::new("/System"),
        Path::new("/Library"),
        Path::new("/Applications"),
        Path::new("/usr"),
        Path::new("/private"),
        engine.layout.home.as_path(),
    ];
    if forbidden.contains(&root.as_path())
        || root.starts_with("/Volumes")
        || root.starts_with(&engine.layout.state_dir)
        || root.starts_with(engine.layout.home.join("Library"))
    {
        return Err(Error::Invalid(format!(
            "{} can't be watched; choose a folder of projects such as ~/code",
            root.display()
        )));
    }
    if let Some(existing) = engine
        .config
        .roots
        .iter()
        .find(|r| root.starts_with(r) || r.starts_with(&root))
    {
        return Err(Error::Invalid(format!(
            "{} overlaps the watched folder {}",
            root.display(),
            existing.display()
        )));
    }
    let previous = std::mem::replace(&mut engine.config.roots, vec![root.clone()]);
    let found = engine.discover();
    engine.config.roots = previous;
    let found: Vec<_> = found?
        .into_iter()
        .filter(|c| c.path.starts_with(&root))
        .collect();
    let preview = RootPreview {
        projects: found.len(),
        offloadable_bytes: found
            .iter()
            .filter(|c| c.exists)
            .map(|c| fsutil::allocated_bytes(&c.path).unwrap_or(0))
            .sum(),
    };
    if !dry_run {
        engine.config.roots.push(root);
        engine.config.save(&engine.layout)?;
    }
    Ok(preview)
}

/// Removes a watched root, releasing every entry under it.
///
/// # Errors
///
/// Fails if the root isn't watched or an entry can't be released.
pub fn roots_remove(engine: &mut Engine, path: &Path, copy: bool) -> Result<Vec<PathBuf>> {
    let expanded = engine.layout.expand(path);
    let root = std::fs::canonicalize(&expanded).unwrap_or(expanded);
    let Some(index) = engine.config.roots.iter().position(|r| r == &root) else {
        return Err(Error::Invalid(format!(
            "{} isn't a watched folder",
            root.display()
        )));
    };
    let mut released = Vec::new();
    for entry in engine.registry.entries()? {
        if entry.path.starts_with(&root) {
            engine.release(&entry.path, copy)?;
            released.push(entry.path);
        }
    }
    engine.config.roots.remove(index);
    engine.config.save(&engine.layout)?;
    Ok(released)
}

/// Sets or clears the paused flag.
///
/// # Errors
///
/// Fails if the config can't be saved.
pub fn set_paused(engine: &mut Engine, paused: bool) -> Result<()> {
    engine.config.paused = paused;
    engine.config.save(&engine.layout)
}

/// Sets whether copies yield to other disk activity. Doesn't take the engine lock: a running copy
/// holds it, and that copy re-reads this setting from the config file.
///
/// # Errors
///
/// Fails if the config can't be loaded or saved.
pub fn set_transfer_priority(layout: &Layout, priority: TransferPriority) -> Result<()> {
    let mut config = Config::load_required(layout)?;
    config.transfer_priority = priority;
    config.save(layout)
}

/// Turns offloading of a kind on or off.
///
/// Like [`set_transfer_priority`], doesn't take the engine lock, so it doesn't wait for a copy in
/// progress; the agent stops adopting a disabled kind before its next copy. Folders already
/// offloaded stay managed until [`release_kind`].
///
/// # Errors
///
/// Fails if the config can't be loaded or saved.
pub fn set_kind_enabled(layout: &Layout, kind: KindId, enabled: bool) -> Result<()> {
    let mut config = Config::load_required(layout)?;
    config.kinds.retain(|&k| k != kind);
    if enabled {
        config.kinds.push(kind);
        config.kinds.sort();
    }
    config.save(layout)
}

/// Releases every managed folder of `kind`, copying contents back with `copy`.
///
/// # Errors
///
/// Fails if a folder is in use or (with `copy`) the drive is offline.
pub fn release_kind(engine: &mut Engine, kind: KindId, copy: bool) -> Result<Vec<PathBuf>> {
    let mut released = Vec::new();
    for entry in engine.registry.entries()? {
        if entry.kind == kind {
            engine.release(&entry.path, copy)?;
            released.push(entry.path);
        }
    }
    Ok(released)
}

/// Records the personal/work answer.
///
/// # Errors
///
/// Fails if the config can't be saved.
pub fn set_usage(engine: &mut Engine, usage: Usage) -> Result<()> {
    let licensing = &mut engine.config.licensing;
    if licensing.usage != Some(usage) {
        licensing.usage = Some(usage);
        licensing.answered_at = Some(u64::try_from(crate::now_unix()).unwrap_or(0));
    }
    engine.config.save(&engine.layout)
}

/// Records a purchased license (not verified).
///
/// # Errors
///
/// Fails if the config can't be saved.
pub fn record_license(engine: &mut Engine, order_id: &str, licensee: Option<&str>) -> Result<()> {
    engine.config.licensing.order_id = Some(order_id.to_owned());
    engine.config.licensing.licensee = licensee.map(str::to_owned);
    engine.config.save(&engine.layout)
}

/// Runs the speed test and stores the result.
///
/// # Errors
///
/// Fails if the drive is offline or the scratch files can't be written.
pub fn bench(engine: &mut Engine, quick: bool) -> Result<BenchReport> {
    let drive = engine.drive().ok_or(Error::DriveOffline)?;
    let internal = engine.layout.state_dir.join("bench");
    let external = drive.layout.trash_dir();
    let mut sizes = if quick {
        BenchSizes::QUICK
    } else {
        BenchSizes::FULL
    };
    // Never use more than 5% of the drive's free space for the test file.
    let free = stowaway_macos::fs_stats(&drive.mount_point).map_or(0, |s| s.available_bytes);
    sizes.sequential_bytes = sizes.sequential_bytes.min(free / 20);
    if sizes.sequential_bytes < 8_000_000 {
        return Err(Error::Invalid(
            "the drive is too full to run a speed test".to_owned(),
        ));
    }
    let report = bench::run(&internal, &external, &drive.mount_point, sizes)?;
    let _ignored = std::fs::remove_dir(&internal);
    if let Some(uuid) = engine.config.volume_uuid.as_deref() {
        engine
            .registry
            .record_bench(uuid, &serde_json::to_string(&report)?, report.at)?;
    }
    Ok(report)
}

/// Runs health checks; with `fix`, reconciles first.
///
/// # Errors
///
/// Fails on a database error.
pub fn doctor(engine: &mut Engine, fix: bool) -> Result<Vec<Problem>> {
    if fix {
        engine.reconcile()?;
    }
    engine.problems()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn toggling_a_kind_keeps_display_order() {
        let dir = tempfile::tempdir().unwrap();
        let layout = Layout::rooted(dir.path(), dir.path());
        Config {
            volume_uuid: Some("UUID".into()),
            ..Config::default()
        }
        .save(&layout)
        .unwrap();
        set_kind_enabled(&layout, KindId::PnpmStore, false).unwrap();
        let kinds = Config::load_required(&layout).unwrap().kinds;
        assert!(!kinds.contains(&KindId::PnpmStore));
        set_kind_enabled(&layout, KindId::PnpmStore, true).unwrap();
        set_kind_enabled(&layout, KindId::PnpmStore, true).unwrap();
        assert_eq!(Config::load_required(&layout).unwrap().kinds, KindId::ALL);
    }
}
