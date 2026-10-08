//! Pacing copies around other work: noticing when other programs are keeping the internal disk
//! busy, so copies can step aside, and sizing a copy's worker pool to the machine's CPU load.
//!
//! Copies run at normal disk priority (macOS's lower tiers made them 100× slower whenever
//! anything else touched the disk) and pause instead while other work is moving data.

use std::sync::OnceLock;
use std::time::{Duration, Instant};

use crate::cmd;
use crate::config::{Config, TransferPriority};
use crate::paths::Layout;
use crate::report::bytes_f64;

/// Other programs moving more than this many bytes per second count as busy.
const BUSY_BYTES_PER_SECOND: f64 = 30_000_000.0;
/// How often the disk is sampled.
const SAMPLE_EVERY: Duration = Duration::from_secs(1);
/// Calm samples in a row needed before a paused copy resumes.
const CALM_SAMPLES_TO_RESUME: u32 = 3;
/// `iostat` reports megabytes of 2^20 bytes.
const IOSTAT_MB: f64 = 1_048_576.0;

/// Watches the internal disk for other programs' activity.
#[derive(Debug)]
pub struct DiskLoad {
    last: Option<Sample>,
    paused: bool,
    calm: u32,
}

#[derive(Debug, Clone, Copy)]
struct Sample {
    at: Instant,
    disk_bytes: f64,
    own_bytes: f64,
}

impl Default for DiskLoad {
    fn default() -> Self {
        Self::new()
    }
}

impl DiskLoad {
    /// Starts watching. The first sample is taken on the first call to [`DiskLoad::busy`].
    #[must_use]
    pub const fn new() -> Self {
        Self {
            last: None,
            paused: false,
            calm: 0,
        }
    }

    /// Whether a copy should wait. Samples at most once a second; between samples, repeats the
    /// last answer. Once busy, stays busy until the disk has been calm for a few seconds.
    pub fn busy(&mut self) -> bool {
        if self.last.is_some_and(|s| s.at.elapsed() < SAMPLE_EVERY) {
            return self.paused;
        }
        let Some(now) = sample() else {
            return false;
        };
        let previous = self.last.replace(now);
        let Some(previous) = previous else {
            return self.paused;
        };
        let seconds = now.at.duration_since(previous.at).as_secs_f64();
        if seconds <= 0.0 {
            return self.paused;
        }
        let others = ((now.disk_bytes - previous.disk_bytes)
            - (now.own_bytes - previous.own_bytes))
            .max(0.0);
        let busy = others / seconds > BUSY_BYTES_PER_SECOND;
        if busy {
            self.paused = true;
            self.calm = 0;
        } else if self.paused {
            self.calm += 1;
            if self.calm >= CALM_SAMPLES_TO_RESUME {
                self.paused = false;
            }
        }
        self.paused
    }
}

/// Decides whether a transfer should wait, following the configured [`TransferPriority`].
///
/// The setting is re-read from the config file at most once a second, so a change made while a
/// transfer is running (from the CLI or the menu bar app) takes effect on that transfer.
#[derive(Debug)]
pub struct TransferGovernor<'a> {
    layout: &'a Layout,
    priority: TransferPriority,
    checked: Option<Instant>,
    load: DiskLoad,
}

impl<'a> TransferGovernor<'a> {
    /// Starts with `priority`, until the config says otherwise.
    #[must_use]
    pub const fn new(layout: &'a Layout, priority: TransferPriority) -> Self {
        Self {
            layout,
            priority,
            checked: None,
            load: DiskLoad::new(),
        }
    }

    /// Whether the copy should wait before continuing.
    pub fn should_wait(&mut self) -> bool {
        if self.checked.is_none_or(|at| at.elapsed() >= SAMPLE_EVERY) {
            self.checked = Some(Instant::now());
            if let Ok(Some(config)) = Config::load(self.layout) {
                self.priority = config.transfer_priority;
            }
        }
        match self.priority {
            TransferPriority::Normal => {
                self.load = DiskLoad::new();
                false
            }
            TransferPriority::Background => self.load.busy(),
        }
    }
}

/// Total CPU use above which copies drop a worker.
const CPU_CEILING: f64 = 0.80;
/// Total CPU use below which copies may add a worker.
const CPU_ROOM_TO_GROW: f64 = 0.70;
/// Workers a copy starts with before it has a CPU sample.
const START_THREADS: usize = 2;

/// How many files a copy works on at once.
///
/// It starts small and adjusts by one worker each second: fewer while the whole machine's CPU
/// use is above 80%, more while it's below 70%. Copies wait
/// mostly on the disk, so extra workers usually cost little CPU, but builds running alongside
/// shouldn't lose cores to them.
#[derive(Debug)]
pub struct CopyThreads {
    max: usize,
    allowed: usize,
    last: Option<(Instant, stowaway_macos::CpuTicks)>,
}

impl CopyThreads {
    /// Allows up to `max` workers (at least one).
    #[must_use]
    pub fn new(max: usize) -> Self {
        let max = max.max(1);
        Self {
            max,
            allowed: START_THREADS.min(max),
            last: None,
        }
    }

    /// Workers currently allowed.
    #[must_use]
    pub const fn allowed(&self) -> usize {
        self.allowed
    }

    /// Samples CPU use at most once a second and returns the new allowance.
    pub fn adjust(&mut self) -> usize {
        if self.last.is_some_and(|(at, _)| at.elapsed() < SAMPLE_EVERY) {
            return self.allowed;
        }
        let Ok(now) = stowaway_macos::cpu_ticks() else {
            return self.allowed;
        };
        if let Some((_, earlier)) = self.last.replace((Instant::now(), now))
            && let Some(busy) = now.busy_fraction_since(&earlier)
        {
            self.allowed = next_allowance(self.allowed, self.max, busy);
        }
        self.allowed
    }
}

fn next_allowance(allowed: usize, max: usize, busy: f64) -> usize {
    if busy > CPU_CEILING {
        allowed.saturating_sub(1).max(1)
    } else if busy < CPU_ROOM_TO_GROW {
        (allowed + 1).min(max)
    } else {
        allowed
    }
}

fn sample() -> Option<Sample> {
    let disk = internal_disk()?;
    let out = cmd::run_string("iostat", ["-Id", disk]).ok()?;
    let disk_bytes = parse_iostat_total_mb(&out)? * IOSTAT_MB;
    let own_bytes = bytes_f64(stowaway_macos::own_disk_read_bytes().ok()?);
    Some(Sample {
        at: Instant::now(),
        disk_bytes,
        own_bytes,
    })
}

/// The whole disk holding the startup volume, e.g. `disk0`, looked up once.
fn internal_disk() -> Option<&'static str> {
    static DISK: OnceLock<Option<String>> = OnceLock::new();
    DISK.get_or_init(find_internal_disk).as_deref()
}

fn find_internal_disk() -> Option<String> {
    let parent = |device: &str| {
        crate::drive::disk_info(device)
            .ok()
            .and_then(|i| i.parent_whole_disk)
    };
    let container = parent("/")?;
    let store = crate::drive::disk_info(&container)
        .ok()?
        .apfs_physical_stores
        .into_iter()
        .next()?
        .device;
    parent(&store)
}

/// The cumulative megabytes in `iostat -Id <disk>` output.
fn parse_iostat_total_mb(out: &str) -> Option<f64> {
    out.lines().last()?.split_whitespace().nth(2)?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_iostat_totals() {
        let out = "              disk0 \n    KB/t xfrs   MB \n   22.36 931710316 20346244.61 \n";
        assert_eq!(parse_iostat_total_mb(out), Some(20_346_244.61));
        assert_eq!(parse_iostat_total_mb(""), None);
    }

    #[test]
    fn idle_disk_is_not_busy() {
        let mut load = DiskLoad::new();
        assert!(!load.busy());
    }

    #[test]
    fn copy_threads_follow_cpu_load() {
        assert_eq!(next_allowance(2, 8, 0.30), 3, "room to grow");
        assert_eq!(next_allowance(8, 8, 0.30), 8, "capped at max");
        assert_eq!(
            next_allowance(4, 8, 0.75),
            4,
            "between thresholds holds steady"
        );
        assert_eq!(next_allowance(4, 8, 0.95), 3, "busy machine sheds a worker");
        assert_eq!(next_allowance(1, 8, 0.95), 1, "never below one");
        assert_eq!(CopyThreads::new(0).allowed(), 1);
    }

    #[test]
    fn governor_follows_the_config_file() {
        let dir = tempfile::tempdir().unwrap();
        let layout = Layout::rooted(dir.path(), dir.path());
        let config = Config {
            transfer_priority: TransferPriority::Normal,
            ..Config::default()
        };
        config.save(&layout).unwrap();
        let mut governor = TransferGovernor::new(&layout, TransferPriority::Background);
        assert!(!governor.should_wait());
        assert_eq!(governor.priority, TransferPriority::Normal);
    }
}
