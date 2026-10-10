//! The status snapshot shared by `stowaway status`, the agent and the menu bar app.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::bench::{self, BenchReport};
use crate::config::TransferPriority;
use crate::engine::{Engine, EngineEvent, Problem};
use crate::error::Result;
use crate::fsutil;
use crate::idle;
use crate::kinds::KindId;
use crate::registry::{EntryStatus, Transfer};

/// Thirty days, the Prosperity license's commercial trial.
const TRIAL_SECONDS: i64 = 30 * 86_400;

/// The drive's state.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DriveStatus {
    /// Volume name recorded at setup.
    pub name: Option<String>,
    /// Whether it's connected.
    pub connected: bool,
    /// Where it's mounted.
    pub mount_point: Option<PathBuf>,
    /// Capacity in bytes.
    pub total_bytes: u64,
    /// Free bytes.
    pub available_bytes: u64,
    /// Below the "nearly full" threshold.
    pub low_space: bool,
    /// Effectively full (under 2% free).
    pub full: bool,
}

/// One managed folder.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntryReport {
    /// Entry ID.
    pub id: String,
    /// Kind.
    pub kind: KindId,
    /// Folder path.
    pub path: PathBuf,
    /// Status.
    pub status: EntryStatus,
    /// Bytes of data in the image.
    pub used_bytes: u64,
    /// Bytes the image occupies on the drive.
    pub image_bytes: u64,
    /// Explanation, if any.
    pub note: Option<String>,
}

/// A watched root.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RootReport {
    /// The folder.
    pub path: PathBuf,
    /// Whether it exists.
    pub exists: bool,
    /// Managed entries under it.
    pub entries: usize,
    /// Bytes offloaded from it.
    pub offloaded_bytes: u64,
}

/// A machine-wide cache kind (spec §4.8), for the folders window.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GlobalReport {
    /// The kind.
    pub kind: KindId,
    /// Human-readable name, e.g. "pnpm store".
    pub label: String,
    /// What the cache holds.
    pub description: String,
    /// Its locations that exist on this Mac.
    pub paths: Vec<PathBuf>,
    /// Whether any of its locations exist.
    pub detected: bool,
    /// Whether Stowaway offloads it.
    pub enabled: bool,
    /// Managed entries of this kind.
    pub entries: usize,
    /// Bytes offloaded from it.
    pub offloaded_bytes: u64,
    /// Last measured size of locations not offloaded yet, if they've been measured.
    pub pending_bytes: Option<u64>,
}

/// Drive performance for the popover and `status` (spec §8.1).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Performance {
    /// The latest speed test, if one has run.
    pub last_bench: Option<BenchReport>,
    /// Median throughput of recent transfers, MB/s.
    pub recent_transfer_mbps: Option<f64>,
    /// Median files per second of recent transfers.
    pub recent_transfer_files_per_sec: Option<f64>,
    /// The current hint, if any.
    pub hint: Option<String>,
    /// Whether the drive's format is the best one for Stowaway, from the latest speed test.
    #[serde(default)]
    pub format_note: Option<String>,
    /// The drive keeps up with the internal disk everywhere.
    pub at_least_internal: bool,
}

/// What an auto-adoption pass is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PlanPhase {
    /// Adding up folder sizes to decide what's worth adopting.
    Measuring,
    /// Moving the chosen folders onto the drive.
    Adopting,
}

/// The agent's current auto-adoption pass (filled in by the agent).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdoptionPlan {
    /// What the pass is doing.
    pub phase: PlanPhase,
    /// Folders measured (while measuring) or handled (while adopting) so far.
    pub folders_done: usize,
    /// Folders in this phase.
    pub folders_total: usize,
    /// Bytes this pass will offload. Grows while measuring.
    pub planned_bytes: u64,
    /// Bytes this pass has offloaded, not counting the copy in progress.
    pub moved_bytes: u64,
}

/// Everything the UI shows.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct StatusReport {
    /// Stowaway's version.
    pub version: String,
    /// Drive state.
    pub drive: DriveStatus,
    /// Bytes stored on the drive instead of the internal disk.
    pub offloaded_bytes: u64,
    /// Bytes currently held in local fallback folders.
    pub local_bytes: u64,
    /// Managed folders.
    pub entries: Vec<EntryReport>,
    /// Watched roots.
    pub roots: Vec<RootReport>,
    /// Global cache kinds, detected or not.
    #[serde(default)]
    pub globals: Vec<GlobalReport>,
    /// Copies in progress (filled in by the agent).
    pub active_transfers: Vec<EngineEvent>,
    /// The auto-adoption pass in progress, if any.
    #[serde(default)]
    pub plan: Option<AdoptionPlan>,
    /// Recent finished copies.
    pub recent_transfers: Vec<Transfer>,
    /// Problems to show.
    pub problems: Vec<Problem>,
    /// Drive performance.
    pub performance: Performance,
    /// Number of images currently attached.
    pub attached_images: usize,
    /// Auto-adoption is paused.
    pub paused: bool,
    /// Offload transfer priority: whether transfers yield to other disk activity.
    #[serde(default)]
    pub transfer_priority: TransferPriority,
    /// Whether the background agent answered.
    pub agent_running: bool,
    /// Show the "Using this at work? Expense a license" line.
    pub license_reminder: bool,
}

/// Builds a status snapshot.
///
/// # Errors
///
/// Fails on a database error.
pub fn build(engine: &mut Engine) -> Result<StatusReport> {
    let drive = engine.drive();
    let drive_status = drive_status(engine, drive.as_ref());

    let mut entries = Vec::new();
    let mut offloaded: u64 = 0;
    let mut local: u64 = 0;
    for entry in engine.registry.entries()? {
        offloaded = offloaded.saturating_add(entry.used_bytes);
        if entry.status != EntryStatus::Mounted
            && entry.path.exists()
            && !idle::is_mount_point(&entry.path)
        {
            local = local.saturating_add(fsutil::allocated_bytes(&entry.path).unwrap_or(0));
        }
        entries.push(EntryReport {
            id: entry.id,
            kind: entry.kind,
            path: entry.path,
            status: entry.status,
            used_bytes: entry.used_bytes,
            image_bytes: entry.image_bytes,
            note: entry.note,
        });
    }

    let roots = engine
        .config
        .roots
        .iter()
        .map(|root| {
            let under: Vec<&EntryReport> = entries
                .iter()
                .filter(|e| e.path.starts_with(root))
                .collect();
            RootReport {
                path: root.clone(),
                exists: root.is_dir(),
                entries: under.len(),
                offloaded_bytes: under.iter().map(|e| e.used_bytes).sum(),
            }
        })
        .collect();
    let globals = globals(engine, &entries)?;

    let recent_transfers = engine.registry.recent_transfers(20)?;
    let mut performance = performance(&recent_transfers);
    if let Some(uuid) = engine.config.volume_uuid.as_deref()
        && let Some(json) = engine.registry.latest_bench(uuid)?
    {
        performance.last_bench = serde_json::from_str(&json).ok();
    }
    if let Some(report) = &performance.last_bench {
        performance.hint = bench::diagnose(report);
        performance.format_note = bench::format_note(&report.connection);
        performance.at_least_internal = bench::at_least_internal(report);
    }

    let attached_images = drive.as_ref().map_or(0, |d| {
        crate::hdiutil::attached().map_or(0, |all| {
            all.iter()
                .filter(|a| a.image_path.starts_with(&d.mount_point))
                .count()
        })
    });

    let licensing = &engine.config.licensing;
    let license_reminder = licensing.usage == Some(crate::config::Usage::Work)
        && licensing.order_id.is_none()
        && licensing
            .answered_at
            .is_some_and(|t| crate::now_unix() - i64::try_from(t).unwrap_or(0) > TRIAL_SECONDS);

    let mut transfers = recent_transfers;
    transfers.truncate(10);
    Ok(StatusReport {
        version: env!("CARGO_PKG_VERSION").to_owned(),
        drive: drive_status,
        offloaded_bytes: offloaded,
        local_bytes: local,
        entries,
        roots,
        globals,
        active_transfers: Vec::new(),
        plan: None,
        recent_transfers: transfers,
        problems: engine.problems()?,
        performance,
        attached_images,
        paused: engine.config.paused,
        transfer_priority: engine.config.transfer_priority,
        agent_running: false,
        license_reminder,
    })
}

fn globals(engine: &Engine, entries: &[EntryReport]) -> Result<Vec<GlobalReport>> {
    let mut out = Vec::new();
    for (&kind, locations) in &engine.config.globals {
        let managed: Vec<&EntryReport> = entries.iter().filter(|e| e.kind == kind).collect();
        // A split cache (DerivedData) counts as managed when any of its parts is.
        let is_managed = |path: &PathBuf| managed.iter().any(|e| e.path.starts_with(path));
        let paths: Vec<PathBuf> = locations
            .iter()
            .filter(|p| p.is_dir() || is_managed(p))
            .cloned()
            .collect();
        let mut pending_bytes = None;
        for path in paths.iter().filter(|p| !is_managed(p)) {
            if let Some(m) = engine.registry.measurement(path)? {
                pending_bytes = Some(pending_bytes.unwrap_or(0) + m.bytes);
            }
        }
        let spec = kind.spec();
        out.push(GlobalReport {
            kind,
            label: spec.label.to_owned(),
            description: spec.description.to_owned(),
            detected: !paths.is_empty(),
            paths,
            enabled: engine.config.kind_enabled(kind),
            entries: managed.len(),
            offloaded_bytes: managed.iter().map(|e| e.used_bytes).sum(),
            pending_bytes,
        });
    }
    Ok(out)
}

fn drive_status(engine: &Engine, drive: Option<&crate::engine::Drive>) -> DriveStatus {
    let mut status = DriveStatus {
        name: engine.config.volume_name.clone(),
        connected: drive.is_some(),
        mount_point: drive.map(|d| d.mount_point.clone()),
        ..DriveStatus::default()
    };
    if let Some(stats) = drive.and_then(|d| stowaway_macos::fs_stats(&d.mount_point).ok()) {
        status.total_bytes = stats.total_bytes;
        status.available_bytes = stats.available_bytes;
        let percent_free = stats
            .available_bytes
            .saturating_mul(100)
            .checked_div(stats.total_bytes)
            .unwrap_or(0);
        status.low_space = percent_free < u64::from(engine.config.drive_low_space_percent);
        status.full = percent_free < 2;
    }
    status
}

fn performance(transfers: &[Transfer]) -> Performance {
    let meaningful: Vec<&Transfer> = transfers
        .iter()
        .filter(|t| t.seconds > 0.5 && t.bytes > 10_000_000)
        .collect();
    let median = |mut values: Vec<f64>| {
        if values.is_empty() {
            return None;
        }
        values.sort_by(f64::total_cmp);
        values.get(values.len() / 2).copied()
    };
    Performance {
        recent_transfer_mbps: median(
            meaningful
                .iter()
                .map(|t| crate::report::bytes_f64(t.bytes) / 1_000_000.0 / t.seconds)
                .collect(),
        ),
        recent_transfer_files_per_sec: median(
            meaningful
                .iter()
                .map(|t| crate::report::bytes_f64(t.files) / t.seconds)
                .collect(),
        ),
        ..Performance::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transfer_medians_ignore_tiny_copies() {
        let t = |bytes, seconds| Transfer {
            entry_id: "a".into(),
            op: "adopt".into(),
            bytes,
            files: 1000,
            seconds,
            finished_at: 0,
        };
        let perf = performance(&[t(100_000_000, 1.0), t(300_000_000, 1.0), t(1, 0.01)]);
        assert_eq!(perf.recent_transfer_mbps, Some(300.0));
        assert!(performance(&[]).recent_transfer_mbps.is_none());
    }
}
