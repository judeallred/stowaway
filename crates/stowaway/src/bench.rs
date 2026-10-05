//! Drive speed test, connection details and bottleneck hints (spec §8.1).

use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::drive;
use crate::error::{IoContext, Result};

/// How the drive is connected.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Connection {
    /// `USB`, `Thunderbolt`, `PCI-Express`, `Disk Image`, ...
    pub transport: Option<String>,
    /// The negotiated link speed, as reported (e.g. "Up to 10 Gb/s").
    pub link_label: Option<String>,
    /// The negotiated link speed in Gb/s, if it could be parsed.
    pub link_gbps: Option<f64>,
    /// Drive model.
    pub model: Option<String>,
    /// Whether it's an SSD.
    pub solid_state: Option<bool>,
}

/// Results for one disk.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct DiskResult {
    /// Sequential write, MB/s.
    pub seq_write_mbps: f64,
    /// Sequential read, MB/s.
    pub seq_read_mbps: f64,
    /// Small-file operations (create+write, stat, read, delete) per second.
    pub small_file_ops_per_sec: f64,
    /// Median small-file create latency, ms.
    pub small_file_p50_ms: f64,
    /// 99th percentile small-file create latency, ms.
    pub small_file_p99_ms: f64,
    /// Random 4 KB reads per second.
    pub random_read_iops: f64,
}

/// A full speed-test report.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct BenchReport {
    /// When it ran (Unix seconds).
    pub at: i64,
    /// The drive's connection.
    pub connection: Connection,
    /// Internal disk results.
    pub internal: DiskResult,
    /// External drive results.
    pub external: DiskResult,
    /// At most one plain-language hint.
    pub hint: Option<String>,
}

/// How much work each test does.
#[derive(Debug, Clone, Copy)]
pub struct BenchSizes {
    /// Bytes for the sequential test.
    pub sequential_bytes: u64,
    /// Number of small files.
    pub small_files: u32,
    /// How long to run random reads.
    pub random_duration: Duration,
}

impl BenchSizes {
    /// The default: ~1 GB sequential, 20k small files, 2 s of random reads.
    pub const FULL: Self = Self {
        sequential_bytes: 1_000_000_000,
        small_files: 20_000,
        random_duration: Duration::from_secs(2),
    };
    /// A quick run for tests and `--quick`.
    pub const QUICK: Self = Self {
        sequential_bytes: 64_000_000,
        small_files: 2_000,
        random_duration: Duration::from_millis(300),
    };
}

/// Reads connection details for the drive mounted at `mount_point`.
#[must_use]
pub fn connection(mount_point: &Path) -> Connection {
    let Ok(volume) = drive::disk_info(&mount_point.to_string_lossy()) else {
        return Connection::default();
    };
    let whole = volume.physical_whole_disk();
    let disk = whole
        .as_deref()
        .and_then(|d| drive::disk_info(d).ok())
        .unwrap_or_default();
    let (link_label, link_gbps) = whole.as_deref().map_or((None, None), link_speed);
    Connection {
        transport: disk.bus_protocol.or(volume.bus_protocol),
        link_gbps,
        link_label,
        model: disk.media_name,
        solid_state: disk.solid_state.or(volume.solid_state),
    }
}

/// Finds the negotiated link speed for a BSD disk name in `system_profiler` output.
fn link_speed(bsd_name: &str) -> (Option<String>, Option<f64>) {
    let Ok(out) = crate::cmd::run(
        "system_profiler",
        [
            "-json",
            "SPUSBHostDataType",
            "SPUSBDataType",
            "SPThunderboltDataType",
        ],
    ) else {
        return (None, None);
    };
    let Ok(json) = serde_json::from_slice::<serde_json::Value>(&out) else {
        return (None, None);
    };
    let label = find_speed_for(&json, bsd_name, None);
    let gbps = label.as_deref().and_then(parse_gbps);
    (label, gbps)
}

/// Walks the device tree; the nearest ancestor speed field above the node with our BSD name wins.
fn find_speed_for(
    value: &serde_json::Value,
    bsd_name: &str,
    inherited: Option<&str>,
) -> Option<String> {
    match value {
        serde_json::Value::Object(map) => {
            let own = map
                .iter()
                .find(|(k, v)| k.to_ascii_lowercase().contains("speed") && v.is_string())
                .and_then(|(_, v)| v.as_str());
            let speed = own.or(inherited);
            let matches = map
                .get("bsd_name")
                .and_then(serde_json::Value::as_str)
                .is_some_and(|n| n == bsd_name);
            if matches {
                return speed.map(str::to_owned);
            }
            map.values()
                .find_map(|v| find_speed_for(v, bsd_name, speed))
        }
        serde_json::Value::Array(items) => items
            .iter()
            .find_map(|v| find_speed_for(v, bsd_name, inherited)),
        _ => None,
    }
}

/// Parses "Up to 10 Gb/s", "480 Mb/s", "40 Gb/s x2" and similar into Gb/s.
#[must_use]
pub fn parse_gbps(label: &str) -> Option<f64> {
    let lower = label.to_ascii_lowercase().replace(',', ".");
    let words: Vec<&str> = lower.split_whitespace().collect();
    for (i, word) in words.iter().enumerate() {
        let Ok(number) = word
            .trim_end_matches(|c: char| !c.is_ascii_digit())
            .parse::<f64>()
        else {
            continue;
        };
        let unit = words.get(i + 1).copied().unwrap_or_default();
        let rest = word.trim_start_matches(|c: char| c.is_ascii_digit() || c == '.');
        let unit = if rest.is_empty() { unit } else { rest };
        if unit.starts_with("gb") {
            return Some(number);
        }
        if unit.starts_with("mb") {
            return Some(number / 1000.0);
        }
    }
    None
}

/// Runs the speed test in `internal_dir` and `external_dir`, cleaning up afterwards.
///
/// # Errors
///
/// Fails if the scratch directories can't be written.
pub fn run(
    internal_dir: &Path,
    external_dir: &Path,
    drive_mount: &Path,
    sizes: BenchSizes,
) -> Result<BenchReport> {
    let internal = measure(internal_dir, sizes)?;
    let external = measure(external_dir, sizes)?;
    let connection = connection(drive_mount);
    let mut report = BenchReport {
        at: crate::now_unix(),
        connection,
        internal,
        external,
        hint: None,
    };
    report.hint = diagnose(&report, None);
    Ok(report)
}

fn measure(dir: &Path, sizes: BenchSizes) -> Result<DiskResult> {
    let scratch = dir.join(format!("stowaway-bench-{}", std::process::id()));
    fs::create_dir_all(&scratch).ctx("creating", &scratch)?;
    let result = measure_in(&scratch, sizes);
    let _ignored = crate::fsutil::remove_tree(&scratch);
    result
}

fn measure_in(scratch: &Path, sizes: BenchSizes) -> Result<DiskResult> {
    let mut result = DiskResult::default();
    let big = scratch.join("sequential.bin");
    let chunk = vec![0xA5_u8; 1 << 20];
    let chunks = (sizes.sequential_bytes >> 20).max(1);

    let started = Instant::now();
    {
        let mut file = File::create(&big).ctx("creating", &big)?;
        let _ignored = stowaway_macos::set_no_cache(&file, true);
        for _ in 0..chunks {
            file.write_all(&chunk).ctx("writing", &big)?;
        }
        file.sync_all().ctx("syncing", &big)?;
    }
    let total_mb = mb(chunks << 20);
    result.seq_write_mbps = total_mb / started.elapsed().as_secs_f64().max(1e-9);

    let started = Instant::now();
    {
        let mut file = File::open(&big).ctx("opening", &big)?;
        let _ignored = stowaway_macos::set_no_cache(&file, true);
        let mut buf = vec![0_u8; 1 << 20];
        while file.read(&mut buf).ctx("reading", &big)? > 0 {}
    }
    result.seq_read_mbps = total_mb / started.elapsed().as_secs_f64().max(1e-9);

    result.random_read_iops = random_reads(&big, chunks << 20, sizes.random_duration)?;
    fs::remove_file(&big).ctx("removing", &big)?;

    let (ops, p50, p99) = small_files(scratch, sizes.small_files)?;
    result.small_file_ops_per_sec = ops;
    result.small_file_p50_ms = p50;
    result.small_file_p99_ms = p99;
    Ok(result)
}

fn random_reads(path: &Path, len: u64, duration: Duration) -> Result<f64> {
    let mut file = File::open(path).ctx("opening", path)?;
    let _ignored = stowaway_macos::set_no_cache(&file, true);
    let blocks = (len / 4096).max(1);
    let mut buf = [0_u8; 4096];
    let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut reads: u32 = 0;
    let started = Instant::now();
    while started.elapsed() < duration {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        file.seek(SeekFrom::Start((state % blocks) * 4096))
            .ctx("seeking", path)?;
        file.read_exact(&mut buf).ctx("reading", path)?;
        reads = reads.saturating_add(1);
    }
    Ok(f64::from(reads) / started.elapsed().as_secs_f64().max(1e-9))
}

fn small_files(scratch: &Path, count: u32) -> Result<(f64, f64, f64)> {
    let root = scratch.join("small");
    let payload = [0x5A_u8; 4096];
    let mut latencies: Vec<f64> = Vec::with_capacity(usize::try_from(count).unwrap_or(0));
    let paths: Vec<PathBuf> = (0..count)
        .map(|i| root.join(format!("d{}", i % 100)).join(format!("f{i}")))
        .collect();
    let started = Instant::now();
    for path in &paths {
        let t = Instant::now();
        if let Some(dir) = path.parent()
            && !dir.exists()
        {
            fs::create_dir_all(dir).ctx("creating", dir)?;
        }
        let mut file = File::create(path).ctx("creating", path)?;
        file.write_all(&payload).ctx("writing", path)?;
        drop(file);
        latencies.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    for path in &paths {
        fs::metadata(path).ctx("inspecting", path)?;
    }
    let mut buf = Vec::with_capacity(4096);
    for path in &paths {
        buf.clear();
        File::open(path)
            .ctx("opening", path)?
            .read_to_end(&mut buf)
            .ctx("reading", path)?;
    }
    for path in &paths {
        fs::remove_file(path).ctx("removing", path)?;
    }
    let ops = f64::from(count) * 4.0 / started.elapsed().as_secs_f64().max(1e-9);
    latencies.sort_by(f64::total_cmp);
    Ok((
        ops,
        percentile(&latencies, 0.5),
        percentile(&latencies, 0.99),
    ))
}

fn percentile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let last = sorted.len() - 1;
    let rank = (q * f64::from(u32::try_from(last).unwrap_or(u32::MAX))).round();
    let index = format!("{rank:.0}")
        .parse::<usize>()
        .unwrap_or(last)
        .min(last);
    sorted.get(index).copied().unwrap_or_default()
}

fn mb(bytes: u64) -> f64 {
    let whole = u32::try_from(bytes / 1_000_000).unwrap_or(u32::MAX);
    let frac = u32::try_from(bytes % 1_000_000).unwrap_or(0);
    f64::from(whole) + f64::from(frac) / 1_000_000.0
}

/// Picks the single most useful hint (spec §8.1). `recent_transfer_mbps` is the median of
/// recent real transfers, if any.
#[must_use]
pub fn diagnose(report: &BenchReport, recent_transfer_mbps: Option<f64>) -> Option<String> {
    let ext = &report.external;
    let int = &report.internal;
    let link_mbps = report.connection.link_gbps.map(|g| g * 1000.0 / 8.0);
    if let Some(link) = link_mbps {
        if ext.seq_read_mbps >= link * 0.7 && link <= 700.0 {
            let target = 1250.0_f64;
            let factor = (target / ext.seq_read_mbps.max(1.0)).max(1.0);
            return Some(format!(
                "Your connection is the limit. A 10 Gb/s USB or Thunderbolt port or cable could make this about {factor:.0}× faster."
            ));
        }
        if ext.seq_read_mbps < link * 0.3 {
            return Some(
                "The drive itself is the limit. An NVMe drive in a matching enclosure would be faster."
                    .to_owned(),
            );
        }
    }
    if int.small_file_ops_per_sec > 0.0
        && ext.small_file_ops_per_sec < int.small_file_ops_per_sec * 0.5
    {
        return Some(
            "Small-file performance is the limit (common with cheaper SSDs and some enclosures). Installs will be slower than on your internal disk."
                .to_owned(),
        );
    }
    if let Some(transfer) = recent_transfer_mbps
        && transfer < ext.seq_write_mbps * 0.25
    {
        return Some(
            "Transfers are slower than this drive can handle. Stowaway copies at low priority so builds stay fast; heavy disk activity or Spotlight indexing can also slow it down."
                .to_owned(),
        );
    }
    None
}

/// Whether the external drive keeps up with the internal disk in every test.
#[must_use]
pub fn at_least_internal(report: &BenchReport) -> bool {
    let (e, i) = (&report.external, &report.internal);
    e.seq_read_mbps >= i.seq_read_mbps
        && e.seq_write_mbps >= i.seq_write_mbps
        && e.small_file_ops_per_sec >= i.small_file_ops_per_sec
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_link_labels() {
        assert_eq!(parse_gbps("Up to 10 Gb/s"), Some(10.0));
        assert_eq!(parse_gbps("480 Mb/s"), Some(0.48));
        assert_eq!(parse_gbps("40 Gb/s x2"), Some(40.0));
        assert_eq!(parse_gbps("5Gb/s"), Some(5.0));
        assert_eq!(parse_gbps("unknown"), None);
    }

    #[test]
    fn finds_speed_in_device_tree() {
        let json = serde_json::json!({
            "SPUSBHostDataType": [{
                "_name": "USB 3.1 Bus",
                "_items": [{
                    "_name": "Samsung T7",
                    "USBDeviceKeyLinkSpeed": "10 Gb/s",
                    "Media": [{ "bsd_name": "disk4" }]
                }]
            }]
        });
        assert_eq!(
            find_speed_for(&json, "disk4", None).as_deref(),
            Some("10 Gb/s")
        );
        assert_eq!(find_speed_for(&json, "disk9", None), None);
    }

    fn report(link_gbps: Option<f64>, ext_read: f64, ext_small: f64) -> BenchReport {
        BenchReport {
            connection: Connection {
                link_gbps,
                ..Connection::default()
            },
            internal: DiskResult {
                seq_read_mbps: 3000.0,
                seq_write_mbps: 3000.0,
                small_file_ops_per_sec: 10_000.0,
                ..DiskResult::default()
            },
            external: DiskResult {
                seq_read_mbps: ext_read,
                seq_write_mbps: ext_read,
                small_file_ops_per_sec: ext_small,
                ..DiskResult::default()
            },
            ..BenchReport::default()
        }
    }

    #[test]
    fn diagnoses_bottlenecks() {
        let slow_link = diagnose(&report(Some(5.0), 450.0, 9000.0), None).unwrap();
        assert!(slow_link.contains("connection is the limit"), "{slow_link}");
        let slow_drive = diagnose(&report(Some(40.0), 400.0, 9000.0), None).unwrap();
        assert!(slow_drive.contains("drive itself"), "{slow_drive}");
        let small = diagnose(&report(Some(40.0), 2500.0, 2000.0), None).unwrap();
        assert!(small.contains("Small-file"), "{small}");
        let slow_transfers = diagnose(&report(Some(40.0), 2500.0, 9000.0), Some(50.0)).unwrap();
        assert!(
            slow_transfers.contains("Transfers are slower"),
            "{slow_transfers}"
        );
        assert_eq!(
            diagnose(&report(Some(40.0), 2500.0, 9000.0), Some(1500.0)),
            None
        );
    }

    #[test]
    fn quick_bench_runs() {
        let a = tempfile::tempdir().unwrap();
        let sizes = BenchSizes {
            sequential_bytes: 4_000_000,
            small_files: 200,
            random_duration: Duration::from_millis(50),
        };
        let r = measure(a.path(), sizes).unwrap();
        assert!(r.seq_write_mbps > 0.0 && r.seq_read_mbps > 0.0);
        assert!(r.small_file_ops_per_sec > 0.0 && r.random_read_iops > 0.0);
        assert!(
            fs::read_dir(a.path()).unwrap().next().is_none(),
            "scratch cleaned up"
        );
    }

    #[test]
    fn percentiles() {
        let v = [1.0, 2.0, 3.0, 4.0, 100.0];
        assert!((percentile(&v, 0.5) - 3.0).abs() < f64::EPSILON);
        assert!((percentile(&v, 0.99) - 100.0).abs() < f64::EPSILON);
        assert!(percentile(&[], 0.5).abs() < f64::EPSILON);
    }
}
