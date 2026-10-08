//! Human-readable formatting for the CLI.

/// Appends a formatted line to a `String` (writing to a `String` can't fail).
macro_rules! line {
    ($out:expr, $($arg:tt)*) => {{
        $out.push_str(&format!($($arg)*));
        $out.push('\n');
    }};
}

use crate::bench::BenchReport;
use crate::registry::EntryStatus;
use crate::status::{AdoptionPlan, Performance, PlanPhase, StatusReport};

fn performance(out: &mut String, perf: &Performance) {
    line!(out, "\nDrive performance:");
    if let Some(bench) = &perf.last_bench {
        line!(out, "  {}", bench_line(bench));
    } else {
        line!(out, "  No speed test yet (run `stowaway bench`).");
    }
    if let Some(rate) = perf.recent_transfer_mbps {
        line!(
            out,
            "  Recent transfers: {} · {:.0} files/s",
            format_rate(rate),
            perf.recent_transfer_files_per_sec.unwrap_or_default()
        );
    }
    if let Some(hint) = &perf.hint {
        line!(out, "  Hint: {hint}");
    } else if perf.at_least_internal {
        line!(out, "  Faster than or equal to internal.");
    }
    if let Some(note) = &perf.format_note {
        line!(out, "  {note}");
    }
}

/// Converts a byte or file count to `f64` for display arithmetic.
#[must_use]
pub fn bytes_f64(value: u64) -> f64 {
    let high = u32::try_from(value >> 32).unwrap_or(u32::MAX);
    let low = u32::try_from(value & 0xFFFF_FFFF).unwrap_or(0);
    f64::from(high) * 4_294_967_296.0 + f64::from(low)
}

/// Formats bytes the way Finder does: decimal units, one decimal place.
#[must_use]
pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["bytes", "KB", "MB", "GB", "TB"];
    let mut value = bytes_f64(bytes);
    let mut unit = 0;
    while value >= 1000.0 && unit + 1 < UNITS.len() {
        value /= 1000.0;
        unit += 1;
    }
    let name = UNITS.get(unit).copied().unwrap_or("bytes");
    if unit == 0 {
        format!("{bytes} {name}")
    } else {
        format!("{value:.1} {name}")
    }
}

/// Formats a rate in MB/s.
#[must_use]
pub fn format_rate(mbps: f64) -> String {
    if mbps >= 1000.0 {
        format!("{:.1} GB/s", mbps / 1000.0)
    } else {
        format!("{mbps:.0} MB/s")
    }
}

const fn status_word(status: EntryStatus) -> &'static str {
    match status {
        EntryStatus::Mounted => "on drive",
        EntryStatus::Local => "local",
        EntryStatus::PendingReconnect => "waiting",
        EntryStatus::Error => "error",
    }
}

/// Describes the auto-adoption pass in progress.
#[must_use]
pub fn plan_line(plan: &AdoptionPlan) -> String {
    match plan.phase {
        PlanPhase::Measuring if plan.folders_total == 0 => {
            "Looking for folders to offload…".to_owned()
        }
        PlanPhase::Measuring => format!(
            "Measuring folders: {} of {} checked, {} to offload so far.",
            plan.folders_done,
            plan.folders_total,
            format_bytes(plan.planned_bytes)
        ),
        PlanPhase::Adopting => format!(
            "Offloading {}: {} of {} folders done, {} moved.",
            format_bytes(plan.planned_bytes),
            plan.folders_done,
            plan.folders_total,
            format_bytes(plan.moved_bytes)
        ),
    }
}

/// Renders `stowaway status`.
#[must_use]
pub fn status(report: &StatusReport) -> String {
    let mut out = String::new();
    let name = report.drive.name.as_deref().unwrap_or("the drive");
    if report.drive.connected {
        line!(
            out,
            "Stowaway is offloading {}.",
            format_bytes(report.offloaded_bytes)
        );
        line!(
            out,
            "Drive: {name} — connected, {} free of {}{}",
            format_bytes(report.drive.available_bytes),
            format_bytes(report.drive.total_bytes),
            if report.drive.full {
                " (FULL)"
            } else if report.drive.low_space {
                " (nearly full)"
            } else {
                ""
            }
        );
    } else {
        line!(
            out,
            "Drive disconnected — working locally. {} is waiting on {name}.",
            format_bytes(report.offloaded_bytes)
        );
        if report.local_bytes > 0 {
            line!(
                out,
                "{} is being used locally until the drive comes back.",
                format_bytes(report.local_bytes)
            );
        }
    }
    if let Some(plan) = &report.plan {
        line!(out, "{}", plan_line(plan));
    }
    if report.paused {
        line!(out, "Auto-adoption is paused.");
    }
    if !report.agent_running {
        line!(
            out,
            "The background agent isn't running (start it with `stowaway agent install`)."
        );
    }

    if !report.entries.is_empty() {
        line!(
            out,
            "\nManaged folders ({}, {} images attached):",
            report.entries.len(),
            report.attached_images
        );
        for e in &report.entries {
            line!(
                out,
                "  {:<9} {:>10}  {:<18} {}{}",
                status_word(e.status),
                format_bytes(e.used_bytes),
                e.kind.as_str(),
                e.path.display(),
                e.note
                    .as_deref()
                    .map(|n| format!("  ({n})"))
                    .unwrap_or_default()
            );
        }
    }

    performance(&mut out, &report.performance);

    if !report.problems.is_empty() {
        line!(out, "\nProblems:");
        for p in &report.problems {
            line!(out, "  • {}", p.message);
            if let Some(hint) = &p.hint {
                line!(out, "    → {hint}");
            }
        }
    }
    out
}

/// One-line performance summary.
#[must_use]
pub fn bench_line(bench: &BenchReport) -> String {
    let c = &bench.connection;
    let link = match (&c.transport, &c.link_label) {
        (Some(t), Some(l)) => format!("{t} ({l}) · "),
        (Some(t), None) => format!("{t} · "),
        _ => String::new(),
    };
    let ratio = if bench.internal.small_file_ops_per_sec > 0.0 {
        bench.external.small_file_ops_per_sec / bench.internal.small_file_ops_per_sec
    } else {
        0.0
    };
    format!(
        "{link}read {} · write {} · small files {ratio:.1}× internal",
        format_rate(bench.external.seq_read_mbps),
        format_rate(bench.external.seq_write_mbps)
    )
}

/// Renders `stowaway bench`.
#[must_use]
pub fn bench_table(bench: &BenchReport) -> String {
    let mut out = String::new();
    let c = &bench.connection;
    line!(
        out,
        "Connection: {} {}{}",
        c.transport.as_deref().unwrap_or("unknown"),
        c.link_label
            .as_deref()
            .map(|l| format!("({l})"))
            .unwrap_or_default(),
        c.model
            .as_deref()
            .map(|m| format!(" · {m}"))
            .unwrap_or_default()
    );
    line!(out, "\n{:<26} {:>14} {:>14}", "", "Internal", "External");
    let rows: [(&str, f64, f64, &str); 6] = [
        (
            "Sequential write",
            bench.internal.seq_write_mbps,
            bench.external.seq_write_mbps,
            "MB/s",
        ),
        (
            "Sequential read",
            bench.internal.seq_read_mbps,
            bench.external.seq_read_mbps,
            "MB/s",
        ),
        (
            "Small-file ops",
            bench.internal.small_file_ops_per_sec,
            bench.external.small_file_ops_per_sec,
            "/s",
        ),
        (
            "Small-file latency p50",
            bench.internal.small_file_p50_ms,
            bench.external.small_file_p50_ms,
            "ms",
        ),
        (
            "Small-file latency p99",
            bench.internal.small_file_p99_ms,
            bench.external.small_file_p99_ms,
            "ms",
        ),
        (
            "Random 4 KB reads",
            bench.internal.random_read_iops,
            bench.external.random_read_iops,
            "IOPS",
        ),
    ];
    for (label, internal, external, unit) in rows {
        line!(
            out,
            "{label:<26} {internal:>9.1} {unit:<4} {external:>9.1} {unit:<4}"
        );
    }
    if let Some(hint) = &bench.hint {
        line!(out, "\nHint: {hint}");
    } else if crate::bench::at_least_internal(bench) {
        line!(
            out,
            "\nThe external drive is at least as fast as your internal disk."
        );
    }
    if let Some(note) = crate::bench::format_note(&bench.connection) {
        line!(out, "{note}");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_are_decimal_like_finder() {
        assert_eq!(format_bytes(0), "0 bytes");
        assert_eq!(format_bytes(999), "999 bytes");
        assert_eq!(format_bytes(182_400_000_000), "182.4 GB");
        assert_eq!(format_bytes(1_500_000), "1.5 MB");
        assert_eq!(format_bytes(u64::MAX), "18446744.1 TB");
    }

    #[test]
    fn rates() {
        assert_eq!(format_rate(410.0), "410 MB/s");
        assert_eq!(format_rate(2600.0), "2.6 GB/s");
    }

    #[test]
    fn status_mentions_offloaded_amount() {
        let report = StatusReport {
            offloaded_bytes: 182_400_000_000,
            drive: crate::status::DriveStatus {
                connected: true,
                name: Some("FastSSD".into()),
                ..Default::default()
            },
            agent_running: true,
            ..Default::default()
        };
        let text = status(&report);
        assert!(
            text.starts_with("Stowaway is offloading 182.4 GB."),
            "{text}"
        );
        let offline = StatusReport {
            drive: crate::status::DriveStatus::default(),
            ..report
        };
        assert!(status(&offline).contains("Drive disconnected — working locally."));
    }
}
