//! The agent's IPC protocol: newline-delimited JSON over a Unix socket (spec §9.1).
//!
//! Clients send [`Request`]s and get [`Response`]s with the same `id`. After a `subscribe`
//! request, the agent also pushes [`Notification`]s (no `id`) on that connection.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::config::{TransferPriority, Usage};
use crate::engine::{EngineEvent, TransferStep};
use crate::error::{Error, Result};
use crate::kinds::KindId;
use crate::status::{AdoptionPlan, StatusReport};

/// Protocol version; bumped on incompatible changes.
pub const PROTOCOL_VERSION: u32 = 1;

/// A request from a client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Request {
    /// Echoed in the response.
    pub id: u64,
    /// What to do.
    #[serde(flatten)]
    pub call: Call,
}

/// The available calls.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "method", content = "params", rename_all = "kebab-case")]
pub enum Call {
    /// Returns a [`StatusReport`].
    Status,
    /// Keeps the connection open and pushes [`Notification`]s.
    Subscribe,
    /// Asks the agent to reconcile now (sent by the CLI after it changes something).
    Refresh,
    /// Discovers and adopts folders now.
    Scan,
    /// Adds a watched root. With `dry_run`, only previews what would be adopted.
    RootsAdd {
        /// The folder.
        path: PathBuf,
        /// Preview only.
        dry_run: bool,
    },
    /// Removes a watched root, releasing its entries.
    RootsRemove {
        /// The folder.
        path: PathBuf,
        /// Copy contents back to the Mac instead of letting them be re-downloaded.
        copy: bool,
    },
    /// Detaches all images and ejects the drive.
    Eject,
    /// Stops any copy in progress, detaches all images so folders fall back to their local
    /// contents, and stops the agent. It reattaches them when it next starts.
    Quit,
    /// Pauses auto-adoption.
    Pause,
    /// Resumes auto-adoption.
    Resume,
    /// Sets whether copies yield to other disk activity. Applies to a copy already running.
    SetTransferPriority {
        /// The new priority.
        priority: TransferPriority,
    },
    /// Turns offloading of a kind on or off. Turning it off releases its managed folders.
    SetKindEnabled {
        /// The kind.
        kind: KindId,
        /// Offload it.
        enabled: bool,
        /// When turning off, copy contents back to the Mac instead of letting them be
        /// re-downloaded.
        copy: bool,
    },
    /// Runs health checks; with `fix`, also reconciles.
    Doctor {
        /// Repair what can be repaired.
        fix: bool,
    },
    /// Runs the speed test.
    Bench {
        /// Smaller, faster test.
        quick: bool,
    },
    /// Records the personal/work answer.
    SetUsage {
        /// The answer.
        usage: Usage,
    },
    /// Records a purchased license (honor system).
    RecordLicense {
        /// Order ID from the receipt.
        order_id: String,
        /// Company or person licensed.
        licensee: Option<String>,
    },
}

/// The agent's reply to a [`Request`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Response {
    /// The request's `id`.
    pub id: u64,
    /// Whether it succeeded.
    pub ok: bool,
    /// The result, for successful calls that return something.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    /// The error message, on failure.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// A pushed update for subscribers.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", content = "data", rename_all = "kebab-case")]
pub enum Notification {
    /// A fresh status snapshot.
    Status(Box<StatusReport>),
    /// Transfer progress or completion, and other engine events.
    Engine(EngineEvent),
    /// The auto-adoption pass changed; `None` when it finished.
    Plan(Option<AdoptionPlan>),
}

/// Result of a `roots-add` preview.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RootPreview {
    /// Projects found.
    pub projects: usize,
    /// Bytes that can be offloaded now.
    pub offloadable_bytes: u64,
}

/// Sends one request to the agent and waits for its response.
///
/// # Errors
///
/// Fails if the agent isn't running, times out, or reports an error.
pub fn call(socket: &Path, call: Call, timeout: Duration) -> Result<Option<serde_json::Value>> {
    let stream = UnixStream::connect(socket).map_err(|e| Error::Command {
        command: "connect to agent".to_owned(),
        detail: e.to_string(),
    })?;
    stream
        .set_read_timeout(Some(timeout))
        .and_then(|()| stream.set_write_timeout(Some(timeout)))
        .map_err(|e| Error::io("configuring", socket, e))?;
    let request = Request { id: 1, call };
    let mut line = serde_json::to_vec(&request)?;
    line.push(b'\n');
    (&stream)
        .write_all(&line)
        .map_err(|e| Error::io("writing to", socket, e))?;
    let mut reader = BufReader::new(&stream);
    let mut buf = String::new();
    loop {
        buf.clear();
        let read = reader
            .read_line(&mut buf)
            .map_err(|e| Error::io("reading from", socket, e))?;
        if read == 0 {
            return Err(Error::Command {
                command: "agent".to_owned(),
                detail: "closed the connection".to_owned(),
            });
        }
        if let Ok(response) = serde_json::from_str::<Response>(&buf)
            && response.id == request.id
        {
            return if response.ok {
                Ok(response.result)
            } else {
                Err(Error::Invalid(response.error.unwrap_or_default()))
            };
        }
    }
}

/// Whether the agent is answering on `socket`.
#[must_use]
pub fn agent_running(socket: &Path) -> bool {
    UnixStream::connect(socket).is_ok()
}

/// Example of every message, one JSON document per line. The Swift app's tests decode these to
/// prove both sides agree on the protocol (`cargo xtask ipc-schema`).
#[must_use]
pub fn samples() -> Vec<serde_json::Value> {
    let (status, progress, transfer) = sample_status();
    let requests = sample_requests();
    let wrap = |kind: &str, message: serde_json::Value| serde_json::json!({ "kind": kind, "message": message });
    let mut out: Vec<serde_json::Value> = Vec::new();
    for (id, call) in (1_u64..).zip(requests) {
        out.push(wrap(
            "request",
            serde_json::to_value(Request { id, call }).unwrap_or_default(),
        ));
    }
    let preview = RootPreview {
        projects: 23,
        offloadable_bytes: 41_200_000_000,
    };
    let responses = [
        Response {
            id: 1,
            ok: true,
            result: serde_json::to_value(&status).ok(),
            error: None,
        },
        Response {
            id: 5,
            ok: true,
            result: serde_json::to_value(preview).ok(),
            error: None,
        },
        Response {
            id: 7,
            ok: false,
            result: None,
            error: Some("can't eject: files on the drive are open in node (pid 4242)".into()),
        },
    ];
    for response in responses {
        out.push(wrap(
            "response",
            serde_json::to_value(response).unwrap_or_default(),
        ));
    }
    let mut flushing = progress.clone();
    if let EngineEvent::TransferProgress { step, bytes, .. } = &mut flushing {
        *step = TransferStep::Flushing;
        *bytes = 3_400_000_000;
    }
    let notifications = [
        Notification::Status(Box::new(status)),
        Notification::Engine(progress),
        Notification::Engine(flushing),
        Notification::Engine(EngineEvent::TransferAborted {
            entry_id: "01jdef".into(),
        }),
        Notification::Engine(EngineEvent::TransferDone { transfer }),
        Notification::Engine(EngineEvent::EntriesChanged),
        Notification::Engine(EngineEvent::DriveChanged { connected: false }),
        Notification::Plan(Some(AdoptionPlan {
            phase: crate::status::PlanPhase::Measuring,
            folders_done: 12,
            folders_total: 66,
            planned_bytes: 41_200_000_000,
            moved_bytes: 0,
        })),
        Notification::Plan(None),
    ];
    for note in notifications {
        out.push(wrap(
            "notification",
            serde_json::to_value(note).unwrap_or_default(),
        ));
    }
    out
}

fn sample_requests() -> [Call; 16] {
    [
        Call::Status,
        Call::Subscribe,
        Call::Refresh,
        Call::Scan,
        Call::RootsAdd {
            path: "/Users/me/code".into(),
            dry_run: true,
        },
        Call::RootsRemove {
            path: "/Users/me/code".into(),
            copy: false,
        },
        Call::Eject,
        Call::Quit,
        Call::Pause,
        Call::Resume,
        Call::SetTransferPriority {
            priority: TransferPriority::Normal,
        },
        Call::SetKindEnabled {
            kind: KindId::PnpmStore,
            enabled: false,
            copy: true,
        },
        Call::Doctor { fix: false },
        Call::Bench { quick: true },
        Call::SetUsage { usage: Usage::Work },
        Call::RecordLicense {
            order_id: "ORD-1".into(),
            licensee: Some("Acme".into()),
        },
    ]
}

fn sample_bench() -> crate::bench::BenchReport {
    use crate::bench::{BenchReport, Connection, DiskResult};
    BenchReport {
        at: 1_790_000_000,
        connection: Connection {
            transport: Some("Thunderbolt".into()),
            link_label: Some("Up to 40 Gb/s".into()),
            link_gbps: Some(40.0),
            model: Some("Samsung X5".into()),
            solid_state: Some(true),
            format: Some("APFS".into()),
            encrypted: Some(false),
        },
        internal: DiskResult {
            seq_write_mbps: 3100.0,
            seq_read_mbps: 3400.0,
            small_file_ops_per_sec: 12_000.0,
            small_file_p50_ms: 0.08,
            small_file_p99_ms: 0.4,
            random_read_iops: 45_000.0,
        },
        external: DiskResult {
            seq_write_mbps: 2100.0,
            seq_read_mbps: 2600.0,
            small_file_ops_per_sec: 9_600.0,
            small_file_p50_ms: 0.1,
            small_file_p99_ms: 0.7,
            random_read_iops: 30_000.0,
        },
        hint: None,
    }
}

fn sample_globals() -> Vec<crate::status::GlobalReport> {
    use crate::status::GlobalReport;

    vec![
        GlobalReport {
            kind: KindId::PnpmStore,
            label: "pnpm store".into(),
            description: KindId::PnpmStore.spec().description.into(),
            paths: vec!["/Users/me/Library/pnpm/store".into()],
            detected: true,
            enabled: true,
            entries: 1,
            offloaded_bytes: 12_800_000_000,
            pending_bytes: None,
        },
        GlobalReport {
            kind: KindId::Huggingface,
            label: "Hugging Face models".into(),
            description: KindId::Huggingface.spec().description.into(),
            paths: Vec::new(),
            detected: false,
            enabled: true,
            entries: 0,
            offloaded_bytes: 0,
            pending_bytes: None,
        },
    ]
}

fn sample_status() -> (StatusReport, EngineEvent, crate::registry::Transfer) {
    use crate::engine::{Problem, Severity};
    use crate::registry::{EntryStatus, Transfer};
    use crate::status::{DriveStatus, EntryReport, Performance, RootReport};

    let transfer = Transfer {
        entry_id: "01jabc".into(),
        op: "adopt".into(),
        bytes: 3_400_000_000,
        files: 81_000,
        seconds: 8.3,
        finished_at: 1_790_000_000,
    };
    let progress = EngineEvent::TransferProgress {
        entry_id: "01jabc".into(),
        path: "/Users/me/code/my-app/node_modules".into(),
        op: "adopt".into(),
        bytes: 1_200_000_000,
        total_bytes: 3_400_000_000,
        files: 30_000,
        total_files: 81_000,
        elapsed_seconds: 2.9,
        waiting_for_disk: true,
        step: TransferStep::Copying,
    };
    let status = StatusReport {
        version: "0.1.0".into(),
        drive: DriveStatus {
            name: Some("FastSSD".into()),
            connected: true,
            mount_point: Some("/Volumes/FastSSD".into()),
            total_bytes: 2_000_000_000_000,
            available_bytes: 1_400_000_000_000,
            low_space: false,
            full: false,
        },
        offloaded_bytes: 182_400_000_000,
        local_bytes: 0,
        entries: vec![EntryReport {
            id: "01jabc".into(),
            kind: KindId::Node,
            path: "/Users/me/code/my-app/node_modules".into(),
            status: EntryStatus::Mounted,
            used_bytes: 3_400_000_000,
            image_bytes: 3_500_000_000,
            note: None,
        }],
        roots: vec![RootReport {
            path: "/Users/me/code".into(),
            exists: true,
            entries: 23,
            offloaded_bytes: 41_200_000_000,
        }],
        globals: sample_globals(),
        active_transfers: vec![progress.clone()],
        plan: Some(AdoptionPlan {
            phase: crate::status::PlanPhase::Adopting,
            folders_done: 3,
            folders_total: 56,
            planned_bytes: 182_400_000_000,
            moved_bytes: 12_300_000_000,
        }),
        recent_transfers: vec![transfer.clone()],
        problems: vec![Problem {
            severity: Severity::Warning,
            message: "the drive is nearly full (8% free)".into(),
            hint: Some("run `stowaway gc`".into()),
        }],
        performance: Performance {
            last_bench: Some(sample_bench()),
            recent_transfer_mbps: Some(410.0),
            recent_transfer_files_per_sec: Some(8200.0),
            hint: None,
            format_note: Some("Formatted as APFS, the best format for Stowaway.".into()),
            at_least_internal: false,
        },
        attached_images: 23,
        paused: false,
        transfer_priority: TransferPriority::Background,
        agent_running: true,
        license_reminder: false,
    };
    (status, progress, transfer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_wire_format() {
        let r = Request {
            id: 3,
            call: Call::RootsAdd {
                path: "/x".into(),
                dry_run: true,
            },
        };
        let json = serde_json::to_string(&r).unwrap();
        assert_eq!(
            json,
            r#"{"id":3,"method":"roots-add","params":{"path":"/x","dry_run":true}}"#
        );
        assert_eq!(serde_json::from_str::<Request>(&json).unwrap(), r);
        let status: Request = serde_json::from_str(r#"{"id":1,"method":"status"}"#).unwrap();
        assert_eq!(status.call, Call::Status);
    }

    #[test]
    fn samples_round_trip() {
        for sample in samples() {
            let message = sample.get("message").unwrap().clone();
            match sample
                .get("kind")
                .and_then(serde_json::Value::as_str)
                .unwrap()
            {
                "request" => {
                    serde_json::from_value::<Request>(message).unwrap();
                }
                "response" => {
                    serde_json::from_value::<Response>(message).unwrap();
                }
                _ => {
                    serde_json::from_value::<Notification>(message).unwrap();
                }
            }
        }
    }
}
