//! `~/.config/stowaway/config.toml`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use globset::{Glob, GlobSet, GlobSetBuilder};
use serde::{Deserialize, Serialize};

use crate::error::{Error, IoContext, Result};
use crate::kinds::KindId;
use crate::paths::Layout;

/// How the user said they use Stowaway (spec §13.6). Only used for a gentle reminder.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum Usage {
    /// Personal or noncommercial use: free.
    Personal,
    /// Use for work: a license is needed after the 30-day trial.
    Work,
}

/// Offload transfer priority: how hard copies to and from the drive compete with other work for
/// the internal disk.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum TransferPriority {
    /// Pause transfers while other programs keep the internal disk busy.
    #[default]
    Background,
    /// Transfer at normal priority, never pausing.
    Normal,
}

/// Licensing details the user chose to record. Not verified (honor system).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Licensing {
    /// Personal or work use.
    pub usage: Option<Usage>,
    /// When the usage question was answered (Unix seconds).
    pub answered_at: Option<u64>,
    /// Order ID of a purchased license.
    pub order_id: Option<String>,
    /// Who the license was bought for.
    pub licensee: Option<String>,
}

/// The configuration file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    /// UUID of the external volume.
    pub volume_uuid: Option<String>,
    /// Volume name when it was set up, for messages only.
    pub volume_name: Option<String>,
    /// This Mac's hardware UUID, used to namespace storage on the drive.
    pub machine_id: String,
    /// Folders scanned for projects.
    pub roots: Vec<PathBuf>,
    /// Enabled kinds.
    pub kinds: Vec<KindId>,
    /// Glob patterns of paths never to manage.
    pub exclude: Vec<String>,
    /// Seconds without changes before a folder counts as idle.
    pub idle_seconds: u64,
    /// Folders smaller than this aren't adopted.
    pub min_adopt_bytes: u64,
    /// Create images for new projects before their first install.
    pub pre_adopt: bool,
    /// Days before an orphaned image is garbage-collected.
    pub gc_orphan_days: u64,
    /// "Nearly full" threshold for the drive, in percent free.
    pub drive_low_space_percent: u8,
    /// Global cache locations recorded at `init`, by kind.
    pub globals: BTreeMap<KindId, Vec<PathBuf>>,
    /// `CARGO_TARGET_DIR` as seen at `init`; when set, `cargo-target` is skipped.
    pub cargo_target_dir: Option<PathBuf>,
    /// Whether the internal disk is case-sensitive; images match it.
    pub internal_case_sensitive: bool,
    /// Personal/work answer and purchase record.
    pub licensing: Licensing,
    /// Auto-adoption paused.
    pub paused: bool,
    /// Whether copies yield to other disk activity. Read again during copies, so a change
    /// applies to one already running.
    pub transfer_priority: TransferPriority,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            volume_uuid: None,
            volume_name: None,
            machine_id: String::new(),
            roots: Vec::new(),
            kinds: KindId::ALL.to_vec(),
            exclude: Vec::new(),
            idle_seconds: 120,
            min_adopt_bytes: 50_000_000,
            pre_adopt: true,
            gc_orphan_days: 14,
            drive_low_space_percent: 10,
            globals: BTreeMap::new(),
            cargo_target_dir: None,
            internal_case_sensitive: false,
            licensing: Licensing::default(),
            paused: false,
            transfer_priority: TransferPriority::Background,
        }
    }
}

impl Config {
    /// Loads the config, or returns `Ok(None)` if it doesn't exist.
    ///
    /// # Errors
    ///
    /// Fails if the file exists but can't be read or parsed.
    pub fn load(layout: &Layout) -> Result<Option<Self>> {
        let path = &layout.config_file;
        match std::fs::read_to_string(path) {
            Ok(text) => toml::from_str(&text)
                .map(Some)
                .map_err(|e| Error::Config(format!("{}: {e}", path.display()))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(Error::io("reading", path, e)),
        }
    }

    /// Loads the config, failing if Stowaway hasn't been set up.
    ///
    /// # Errors
    ///
    /// [`Error::NotInitialized`] if there's no config or no volume.
    pub fn load_required(layout: &Layout) -> Result<Self> {
        match Self::load(layout)? {
            Some(config) if config.volume_uuid.is_some() => Ok(config),
            _ => Err(Error::NotInitialized),
        }
    }

    /// Writes the config atomically.
    ///
    /// # Errors
    ///
    /// Fails if the file can't be written.
    pub fn save(&self, layout: &Layout) -> Result<()> {
        let path = &layout.config_file;
        let text =
            toml::to_string_pretty(self).map_err(|e| Error::Config(format!("serializing: {e}")))?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).ctx("creating", dir)?;
        }
        let tmp = path.with_extension("toml.tmp");
        std::fs::write(&tmp, text).ctx("writing", &tmp)?;
        std::fs::rename(&tmp, path).ctx("replacing", path)
    }

    /// Whether `kind` is enabled.
    #[must_use]
    pub fn kind_enabled(&self, kind: KindId) -> bool {
        self.kinds.contains(&kind)
    }

    /// Compiles the exclude globs.
    ///
    /// # Errors
    ///
    /// Fails on an invalid glob.
    pub fn exclude_set(&self, layout: &Layout) -> Result<GlobSet> {
        let mut builder = GlobSetBuilder::new();
        for pattern in &self.exclude {
            let expanded = layout.expand(Path::new(pattern));
            let glob = Glob::new(&expanded.to_string_lossy())
                .map_err(|e| Error::Config(format!("exclude pattern {pattern:?}: {e}")))?;
            builder.add(glob);
        }
        builder
            .build()
            .map_err(|e| Error::Config(format!("exclude patterns: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_toml() {
        let dir = tempfile::tempdir().unwrap();
        let layout = Layout::rooted(dir.path(), dir.path());
        let mut config = Config {
            volume_uuid: Some("UUID".into()),
            machine_id: "MID".into(),
            roots: vec![PathBuf::from("/Users/me/code")],
            ..Config::default()
        };
        config.globals.insert(
            KindId::CargoHome,
            vec![PathBuf::from("/Users/me/.cargo/registry")],
        );
        config.save(&layout).unwrap();
        assert_eq!(Config::load(&layout).unwrap(), Some(config));
    }

    #[test]
    fn missing_config_is_not_initialized() {
        let dir = tempfile::tempdir().unwrap();
        let layout = Layout::rooted(dir.path(), dir.path());
        assert!(matches!(
            Config::load_required(&layout),
            Err(Error::NotInitialized)
        ));
    }

    #[test]
    fn unknown_keys_are_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let layout = Layout::rooted(dir.path(), dir.path());
        std::fs::write(&layout.config_file, "bogus = 1\n").unwrap();
        assert!(Config::load(&layout).is_err());
    }

    #[test]
    fn excludes_expand_tilde() {
        let layout = Layout::rooted(Path::new("/Users/me"), Path::new("/tmp/x"));
        let config = Config {
            exclude: vec!["~/code/scratch/**".into()],
            ..Config::default()
        };
        let set = config.exclude_set(&layout).unwrap();
        assert!(set.is_match("/Users/me/code/scratch/app/node_modules"));
        assert!(!set.is_match("/Users/me/code/app/node_modules"));
    }
}
