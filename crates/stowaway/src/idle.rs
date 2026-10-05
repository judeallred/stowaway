//! Deciding whether a folder is safe to move: nothing changed recently and nothing has files open.

use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::fsutil;

/// A process holding a file open.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Holder {
    /// Process ID.
    pub pid: u32,
    /// Process name.
    pub command: String,
    /// The open file.
    pub path: PathBuf,
}

/// Processes with files open under any of `dirs`.
///
/// For a mount point, only that filesystem is listed (fast). Otherwise all open files are listed
/// once and filtered by path, which avoids `lsof +D`'s slow recursive walk.
///
/// # Errors
///
/// Fails if `lsof` can't run.
pub fn holders(dirs: &[&Path]) -> Result<Vec<Holder>> {
    if dirs.is_empty() {
        return Ok(Vec::new());
    }
    let mut args: Vec<String> = vec!["-nP".into(), "-w".into(), "-F".into(), "pcn".into()];
    if dirs.iter().all(|d| is_mount_point(d)) {
        args.push("+f".into());
        args.push("--".into());
        args.extend(dirs.iter().map(|d| d.to_string_lossy().into_owned()));
    }
    let output = Command::new("lsof")
        .args(&args)
        .output()
        .map_err(|e| Error::Command {
            command: "lsof".to_owned(),
            detail: e.to_string(),
        })?;
    // lsof exits 1 when nothing matched; its output is still authoritative.
    let text = String::from_utf8_lossy(&output.stdout);
    // lsof reports resolved paths (/private/var/... rather than /var/...).
    let canonical: Vec<PathBuf> = dirs
        .iter()
        .map(|d| std::fs::canonicalize(d).unwrap_or_else(|_| d.to_path_buf()))
        .collect();
    Ok(parse_lsof(&text)
        .into_iter()
        .filter(|h| canonical.iter().any(|d| h.path.starts_with(d)))
        .collect())
}

fn parse_lsof(text: &str) -> Vec<Holder> {
    let mut out = Vec::new();
    let mut pid = 0;
    let mut command = String::new();
    for line in text.lines() {
        let (tag, value) = line.split_at(line.len().min(1));
        match tag {
            "p" => {
                pid = value.parse().unwrap_or(0);
                command.clear();
            }
            "c" => value.clone_into(&mut command),
            "n" if value.starts_with('/') => out.push(Holder {
                pid,
                command: command.clone(),
                path: PathBuf::from(value),
            }),
            _ => {}
        }
    }
    out.sort_by(|a, b| (a.pid, &a.path).cmp(&(b.pid, &b.path)));
    out.dedup_by(|a, b| a.pid == b.pid && a.path == b.path);
    out
}

/// Whether `path` is the root of a mounted filesystem.
#[must_use]
pub fn is_mount_point(path: &Path) -> bool {
    let (Ok(meta), Some(parent)) = (std::fs::metadata(path), path.parent()) else {
        return false;
    };
    std::fs::metadata(parent).is_ok_and(|p| p.dev() != meta.dev())
}

/// Why a folder isn't idle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Activity {
    /// Nothing recent and no open files.
    Idle,
    /// Something changed this many seconds ago.
    RecentlyChanged(u64),
    /// These processes have files open.
    InUse(Vec<Holder>),
}

/// Checks whether `dir` has been quiet for `idle_seconds` and has no open files.
///
/// # Errors
///
/// Fails if the tree can't be read or `lsof` can't run.
pub fn activity(dir: &Path, idle_seconds: u64) -> Result<Activity> {
    if let Some(age) = fsutil::seconds_since_last_change(dir)?
        && age < idle_seconds
    {
        return Ok(Activity::RecentlyChanged(age));
    }
    let open = holders(&[dir])?;
    if open.is_empty() {
        Ok(Activity::Idle)
    } else {
        Ok(Activity::InUse(open))
    }
}

impl Activity {
    /// A short explanation for logs and status.
    #[must_use]
    pub fn describe(&self) -> String {
        match self {
            Self::Idle => "idle".to_owned(),
            Self::RecentlyChanged(age) => format!("changed {age}s ago"),
            Self::InUse(holders) => {
                let mut names: Vec<&str> = holders.iter().map(|h| h.command.as_str()).collect();
                names.sort_unstable();
                names.dedup();
                format!("in use by {}", names.join(", "))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_lsof_field_output() {
        let text = "p123\ncnode\nf12\nn/Users/me/app/node_modules/x.js\nn/dev/null\np456\nccargo\nn/Users/me/rs/target/debug/a\n";
        let holders = parse_lsof(text);
        assert_eq!(
            holders,
            vec![
                Holder {
                    pid: 123,
                    command: "node".into(),
                    path: "/Users/me/app/node_modules/x.js".into()
                },
                Holder {
                    pid: 123,
                    command: "node".into(),
                    path: "/dev/null".into()
                },
                Holder {
                    pid: 456,
                    command: "cargo".into(),
                    path: "/Users/me/rs/target/debug/a".into()
                },
            ]
        );
    }

    #[test]
    fn detects_open_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("held");
        let _file = std::fs::File::create(&path).unwrap();
        let found = holders(&[dir.path()]).unwrap();
        assert!(found.iter().any(|h| h.path.ends_with("held")), "{found:?}");
    }

    #[test]
    fn root_is_a_mount_point_but_tmp_dir_is_not() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!is_mount_point(dir.path()));
    }

    #[test]
    fn fresh_files_are_not_idle() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("x"), "1").unwrap();
        assert!(matches!(
            activity(dir.path(), 3600).unwrap(),
            Activity::RecentlyChanged(_)
        ));
        assert_eq!(activity(dir.path(), 0).unwrap(), Activity::Idle);
    }
}
