//! Stowaway keeps dependency and build caches on an external drive, mounted in place, and falls
//! back to the local disk whenever the drive is unplugged. See `SPEC.md`.
#![forbid(unsafe_code)]

pub mod agent;
pub mod bench;
pub mod bugreport;
pub mod cli;
pub mod cmd;
pub mod config;
pub mod diskload;
pub mod drive;
pub mod engine;
pub mod error;
pub mod fsutil;
pub mod hdiutil;
pub mod idle;
pub mod ipc;
pub mod kinds;
pub mod launchd;
pub mod ops;
pub mod paths;
pub mod registry;
pub mod report;
pub mod scan;
pub mod status;

pub use error::{Error, Result};

/// The current time in Unix seconds.
#[must_use]
pub fn now_unix() -> i64 {
    fsutil::unix_seconds(std::time::SystemTime::now())
}
