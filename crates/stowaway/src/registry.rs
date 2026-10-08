//! The SQLite registry of entries, transfers, operation journal and speed tests.

use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

use crate::error::{IoContext, Result};
use crate::kinds::KindId;

/// Where an entry's data currently is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum EntryStatus {
    /// The image is attached at the entry's path.
    Mounted,
    /// The drive is gone or the image isn't attached; tools use the local folder.
    Local,
    /// The drive is back but local work is waiting for the folder to go idle.
    PendingReconnect,
    /// The last operation failed; see the note.
    Error,
}

impl EntryStatus {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Mounted => "mounted",
            Self::Local => "local",
            Self::PendingReconnect => "pending-reconnect",
            Self::Error => "error",
        }
    }

    fn parse(s: &str) -> Self {
        match s {
            "mounted" => Self::Mounted,
            "pending-reconnect" => Self::PendingReconnect,
            "error" => Self::Error,
            _ => Self::Local,
        }
    }
}

/// A managed folder.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// ULID; also the image's filename.
    pub id: String,
    /// What kind of folder this is.
    pub kind: KindId,
    /// The folder's path (the mount point).
    pub path: PathBuf,
    /// When it was adopted (Unix seconds).
    pub created_at: i64,
    /// Bytes of data inside the image when last measured.
    pub used_bytes: u64,
    /// Bytes the image occupies on the drive when last measured.
    pub image_bytes: u64,
    /// Last time the agent saw the project (Unix seconds).
    pub last_seen_at: i64,
    /// When the project was found missing (Unix seconds), if it is.
    pub orphaned_at: Option<i64>,
    /// Current status.
    pub status: EntryStatus,
    /// Last error or explanatory note.
    pub note: Option<String>,
}

/// A finished copy, used for throughput history (spec §8.1).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Transfer {
    /// The entry that was copied.
    pub entry_id: String,
    /// `adopt`, `reconnect`, `merge`, `compact` or `release`.
    pub op: String,
    /// Bytes copied.
    pub bytes: u64,
    /// Files copied.
    pub files: u64,
    /// Duration.
    pub seconds: f64,
    /// When it finished (Unix seconds).
    pub finished_at: i64,
}

/// An operation in progress, for crash recovery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JournalItem {
    /// The entry being changed.
    pub entry_id: String,
    /// Operation name.
    pub op: String,
    /// The step reached.
    pub phase: String,
}

/// A cached size of a folder that isn't managed yet (an adoption candidate).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Measurement {
    /// Allocated bytes when measured.
    pub bytes: u64,
    /// The folder's own modification time then, in nanoseconds since the epoch. It changes when
    /// direct children are added or removed, e.g. by an install.
    pub dir_mtime_ns: i64,
    /// When it was measured (Unix seconds).
    pub measured_at: i64,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS entries (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    path TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    used_bytes INTEGER NOT NULL DEFAULT 0,
    image_bytes INTEGER NOT NULL DEFAULT 0,
    last_seen_at INTEGER NOT NULL,
    orphaned_at INTEGER,
    status TEXT NOT NULL,
    note TEXT
);
CREATE TABLE IF NOT EXISTS transfers (
    id INTEGER PRIMARY KEY,
    entry_id TEXT NOT NULL,
    op TEXT NOT NULL,
    bytes INTEGER NOT NULL,
    files INTEGER NOT NULL,
    seconds REAL NOT NULL,
    finished_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS journal (
    entry_id TEXT PRIMARY KEY,
    op TEXT NOT NULL,
    phase TEXT NOT NULL,
    started_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS bench (
    id INTEGER PRIMARY KEY,
    volume_uuid TEXT NOT NULL,
    results TEXT NOT NULL,
    at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS measurements (
    path TEXT PRIMARY KEY,
    bytes INTEGER NOT NULL,
    dir_mtime_ns INTEGER NOT NULL,
    measured_at INTEGER NOT NULL
);
PRAGMA user_version = 1;
";

/// Handle to the registry. Each thread opens its own.
#[derive(Debug)]
pub struct Registry {
    conn: Connection,
}

fn to_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn to_u64(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

impl Registry {
    /// Opens (creating if needed) the registry at `path`.
    ///
    /// # Errors
    ///
    /// Fails if the database can't be opened or migrated.
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).ctx("creating", dir)?;
        }
        let conn = Connection::open(path)?;
        conn.busy_timeout(Duration::from_secs(10))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self { conn })
    }

    /// An in-memory registry for tests.
    ///
    /// # Errors
    ///
    /// Fails if SQLite can't create it.
    pub fn in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self { conn })
    }

    fn row_to_entry(row: &Row<'_>) -> rusqlite::Result<Entry> {
        let kind: String = row.get("kind")?;
        let path: String = row.get("path")?;
        let status: String = row.get("status")?;
        Ok(Entry {
            id: row.get("id")?,
            kind: KindId::parse(&kind).unwrap_or(KindId::Node),
            path: PathBuf::from(path),
            created_at: row.get("created_at")?,
            used_bytes: to_u64(row.get("used_bytes")?),
            image_bytes: to_u64(row.get("image_bytes")?),
            last_seen_at: row.get("last_seen_at")?,
            orphaned_at: row.get("orphaned_at")?,
            status: EntryStatus::parse(&status),
            note: row.get("note")?,
        })
    }

    /// Inserts a new entry.
    ///
    /// # Errors
    ///
    /// Fails if an entry already exists for the path.
    pub fn insert(&self, entry: &Entry) -> Result<()> {
        self.conn.execute(
            "INSERT INTO entries (id, kind, path, created_at, used_bytes, image_bytes, last_seen_at,
                                  orphaned_at, status, note)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                entry.id,
                entry.kind.as_str(),
                entry.path.to_string_lossy(),
                entry.created_at,
                to_i64(entry.used_bytes),
                to_i64(entry.image_bytes),
                entry.last_seen_at,
                entry.orphaned_at,
                entry.status.as_str(),
                entry.note,
            ],
        )?;
        Ok(())
    }

    /// All entries, ordered by path.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn entries(&self) -> Result<Vec<Entry>> {
        let mut stmt = self.conn.prepare("SELECT * FROM entries ORDER BY path")?;
        let rows = stmt.query_map([], Self::row_to_entry)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// The entry managing `path`, if any.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn by_path(&self, path: &Path) -> Result<Option<Entry>> {
        Ok(self
            .conn
            .query_row(
                "SELECT * FROM entries WHERE path = ?1",
                [path.to_string_lossy()],
                Self::row_to_entry,
            )
            .optional()?)
    }

    /// The entry with `id`, if any.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn by_id(&self, id: &str) -> Result<Option<Entry>> {
        Ok(self
            .conn
            .query_row(
                "SELECT * FROM entries WHERE id = ?1",
                [id],
                Self::row_to_entry,
            )
            .optional()?)
    }

    /// Updates status and note.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn set_status(&self, id: &str, status: EntryStatus, note: Option<&str>) -> Result<()> {
        self.conn.execute(
            "UPDATE entries SET status = ?2, note = ?3 WHERE id = ?1",
            params![id, status.as_str(), note],
        )?;
        Ok(())
    }

    /// Records a new path (the repository moved).
    ///
    /// # Errors
    ///
    /// Fails on a database error, including when another entry already has that path.
    pub fn set_path(&self, id: &str, path: &Path) -> Result<()> {
        self.conn.execute(
            "UPDATE entries SET path = ?2 WHERE id = ?1",
            params![id, path.to_string_lossy()],
        )?;
        Ok(())
    }

    /// Records measured sizes.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn set_sizes(&self, id: &str, used_bytes: u64, image_bytes: u64) -> Result<()> {
        self.conn.execute(
            "UPDATE entries SET used_bytes = ?2, image_bytes = ?3 WHERE id = ?1",
            params![id, to_i64(used_bytes), to_i64(image_bytes)],
        )?;
        Ok(())
    }

    /// Marks the project as seen now (clearing any orphan mark), or as missing.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn set_seen(&self, id: &str, present: bool, now: i64) -> Result<()> {
        if present {
            self.conn.execute(
                "UPDATE entries SET last_seen_at = ?2, orphaned_at = NULL WHERE id = ?1",
                params![id, now],
            )?;
        } else {
            self.conn.execute(
                "UPDATE entries SET orphaned_at = COALESCE(orphaned_at, ?2) WHERE id = ?1",
                params![id, now],
            )?;
        }
        Ok(())
    }

    /// Deletes an entry.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn delete(&self, id: &str) -> Result<()> {
        self.conn
            .execute("DELETE FROM entries WHERE id = ?1", [id])?;
        self.conn
            .execute("DELETE FROM journal WHERE entry_id = ?1", [id])?;
        Ok(())
    }

    /// Records a completed transfer.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn record_transfer(&self, transfer: &Transfer) -> Result<()> {
        self.conn.execute(
            "INSERT INTO transfers (entry_id, op, bytes, files, seconds, finished_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                transfer.entry_id,
                transfer.op,
                to_i64(transfer.bytes),
                to_i64(transfer.files),
                transfer.seconds,
                transfer.finished_at,
            ],
        )?;
        self.conn.execute(
            "DELETE FROM transfers WHERE id NOT IN (SELECT id FROM transfers ORDER BY id DESC LIMIT 500)",
            [],
        )?;
        Ok(())
    }

    /// The most recent transfers, newest first.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn recent_transfers(&self, limit: usize) -> Result<Vec<Transfer>> {
        let mut stmt = self
            .conn
            .prepare("SELECT * FROM transfers ORDER BY id DESC LIMIT ?1")?;
        let rows = stmt.query_map([i64::try_from(limit).unwrap_or(i64::MAX)], |row| {
            Ok(Transfer {
                entry_id: row.get("entry_id")?,
                op: row.get("op")?,
                bytes: to_u64(row.get("bytes")?),
                files: to_u64(row.get("files")?),
                seconds: row.get("seconds")?,
                finished_at: row.get("finished_at")?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Starts or advances a journaled operation.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn journal(&self, entry_id: &str, op: &str, phase: &str, now: i64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO journal (entry_id, op, phase, started_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(entry_id) DO UPDATE SET op = ?2, phase = ?3",
            params![entry_id, op, phase, now],
        )?;
        Ok(())
    }

    /// Ends a journaled operation.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn journal_done(&self, entry_id: &str) -> Result<()> {
        self.conn
            .execute("DELETE FROM journal WHERE entry_id = ?1", [entry_id])?;
        Ok(())
    }

    /// Operations interrupted by a crash.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn unfinished(&self) -> Result<Vec<JournalItem>> {
        let mut stmt = self
            .conn
            .prepare("SELECT entry_id, op, phase FROM journal")?;
        let rows = stmt.query_map([], |row| {
            Ok(JournalItem {
                entry_id: row.get(0)?,
                op: row.get(1)?,
                phase: row.get(2)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Stores a speed-test result as JSON.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn record_bench(&self, volume_uuid: &str, results_json: &str, now: i64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO bench (volume_uuid, results, at) VALUES (?1, ?2, ?3)",
            params![volume_uuid, results_json, now],
        )?;
        Ok(())
    }

    /// The latest speed-test result for a volume.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn latest_bench(&self, volume_uuid: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row(
                "SELECT results FROM bench WHERE volume_uuid = ?1 ORDER BY id DESC LIMIT 1",
                [volume_uuid],
                |row| row.get(0),
            )
            .optional()?)
    }

    /// The cached size of a candidate folder.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn measurement(&self, path: &Path) -> Result<Option<Measurement>> {
        Ok(self
            .conn
            .query_row(
                "SELECT bytes, dir_mtime_ns, measured_at FROM measurements WHERE path = ?1",
                [path.to_string_lossy()],
                |row| {
                    Ok(Measurement {
                        bytes: to_u64(row.get(0)?),
                        dir_mtime_ns: row.get(1)?,
                        measured_at: row.get(2)?,
                    })
                },
            )
            .optional()?)
    }

    /// Caches the size of a candidate folder.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn record_measurement(&self, path: &Path, measurement: Measurement) -> Result<()> {
        self.conn.execute(
            "INSERT INTO measurements (path, bytes, dir_mtime_ns, measured_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(path) DO UPDATE SET bytes = ?2, dir_mtime_ns = ?3, measured_at = ?4",
            params![
                path.to_string_lossy(),
                to_i64(measurement.bytes),
                measurement.dir_mtime_ns,
                measurement.measured_at
            ],
        )?;
        Ok(())
    }

    /// Drops cached sizes measured before `before` (Unix seconds).
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn prune_measurements(&self, before: i64) -> Result<()> {
        self.conn
            .execute("DELETE FROM measurements WHERE measured_at < ?1", [before])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, path: &str) -> Entry {
        Entry {
            id: id.into(),
            kind: KindId::Node,
            path: PathBuf::from(path),
            created_at: 1,
            used_bytes: 10,
            image_bytes: 20,
            last_seen_at: 1,
            orphaned_at: None,
            status: EntryStatus::Mounted,
            note: None,
        }
    }

    #[test]
    fn entries_crud() {
        let reg = Registry::in_memory().unwrap();
        reg.insert(&entry("a", "/x/node_modules")).unwrap();
        assert!(
            reg.insert(&entry("b", "/x/node_modules")).is_err(),
            "paths are unique"
        );
        reg.set_status("a", EntryStatus::Local, Some("drive gone"))
            .unwrap();
        reg.set_sizes("a", 5, 6).unwrap();
        reg.set_seen("a", false, 100).unwrap();
        reg.set_seen("a", false, 200).unwrap();
        let got = reg.by_id("a").unwrap().unwrap();
        assert_eq!(got.status, EntryStatus::Local);
        assert_eq!(got.note.as_deref(), Some("drive gone"));
        assert_eq!((got.used_bytes, got.image_bytes), (5, 6));
        assert_eq!(
            got.orphaned_at,
            Some(100),
            "first sighting of absence is kept"
        );
        reg.set_seen("a", true, 300).unwrap();
        assert_eq!(
            reg.by_path(Path::new("/x/node_modules"))
                .unwrap()
                .unwrap()
                .orphaned_at,
            None
        );
        reg.delete("a").unwrap();
        assert!(reg.entries().unwrap().is_empty());
    }

    #[test]
    fn journal_tracks_unfinished_work() {
        let reg = Registry::in_memory().unwrap();
        reg.journal("a", "adopt", "copying", 1).unwrap();
        reg.journal("a", "adopt", "swapping", 1).unwrap();
        assert_eq!(
            reg.unfinished().unwrap(),
            vec![JournalItem {
                entry_id: "a".into(),
                op: "adopt".into(),
                phase: "swapping".into()
            }]
        );
        reg.journal_done("a").unwrap();
        assert!(reg.unfinished().unwrap().is_empty());
    }

    #[test]
    fn transfers_and_bench() {
        let reg = Registry::in_memory().unwrap();
        reg.record_transfer(&Transfer {
            entry_id: "a".into(),
            op: "adopt".into(),
            bytes: 1000,
            files: 3,
            seconds: 0.5,
            finished_at: 9,
        })
        .unwrap();
        assert_eq!(reg.recent_transfers(5).unwrap().len(), 1);
        reg.record_bench("U", "{}", 1).unwrap();
        reg.record_bench("U", "{\"v\":2}", 2).unwrap();
        assert_eq!(reg.latest_bench("U").unwrap().as_deref(), Some("{\"v\":2}"));
    }

    #[test]
    fn measurements_are_cached_and_pruned() {
        let reg = Registry::in_memory().unwrap();
        let path = Path::new("/x/node_modules");
        let first = Measurement {
            bytes: 10,
            dir_mtime_ns: 1,
            measured_at: 100,
        };
        reg.record_measurement(path, first).unwrap();
        let second = Measurement { bytes: 20, ..first };
        reg.record_measurement(path, second).unwrap();
        assert_eq!(reg.measurement(path).unwrap(), Some(second));
        reg.prune_measurements(100).unwrap();
        assert!(reg.measurement(path).unwrap().is_some());
        reg.prune_measurements(101).unwrap();
        assert_eq!(reg.measurement(path).unwrap(), None);
    }
}
