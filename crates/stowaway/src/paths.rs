//! Where Stowaway keeps its files, locally and on the external drive.

use std::path::{Component, Path, PathBuf};

use crate::error::{Error, Result};

/// Local file layout. `STOWAWAY_HOME` overrides everything, which tests rely on.
#[derive(Debug, Clone)]
pub struct Layout {
    /// The user's home directory.
    pub home: PathBuf,
    /// `~/.stowaway`.
    pub state_dir: PathBuf,
    /// `~/.config/stowaway/config.toml`.
    pub config_file: PathBuf,
}

impl Layout {
    /// Resolves the layout from the environment.
    ///
    /// # Errors
    ///
    /// Fails if `HOME` isn't set.
    pub fn from_env() -> Result<Self> {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| Error::Config("HOME is not set".to_owned()))?;
        Ok(std::env::var_os("STOWAWAY_HOME").map_or_else(
            || Self {
                state_dir: home.join(".stowaway"),
                config_file: home.join(".config/stowaway/config.toml"),
                home: home.clone(),
            },
            |custom| Self::rooted(&home, &PathBuf::from(custom)),
        ))
    }

    /// A layout with all state under `root`, as used by tests.
    #[must_use]
    pub fn rooted(home: &Path, root: &Path) -> Self {
        Self {
            home: home.to_path_buf(),
            state_dir: root.to_path_buf(),
            config_file: root.join("config.toml"),
        }
    }

    /// Private mount points used while copying data into an image.
    #[must_use]
    pub fn staging_dir(&self) -> PathBuf {
        self.state_dir.join("staging")
    }

    /// The SQLite registry.
    #[must_use]
    pub fn db_path(&self) -> PathBuf {
        self.state_dir.join("state.db")
    }

    /// Lock held by whichever process is changing entries.
    #[must_use]
    pub fn lock_path(&self) -> PathBuf {
        self.state_dir.join("engine.lock")
    }

    /// The agent's IPC socket. Unix socket paths are limited to 104 bytes on macOS, so a state
    /// directory with a very long path gets its socket in a private folder under `/tmp` instead.
    #[must_use]
    pub fn socket_path(&self) -> PathBuf {
        let preferred = self.state_dir.join("agent.sock");
        if preferred.as_os_str().len() < 100 {
            return preferred;
        }
        let hash = self
            .state_dir
            .as_os_str()
            .as_encoded_bytes()
            .iter()
            .fold(0xcbf2_9ce4_8422_2325_u64, |h, &b| {
                (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
            });
        self.private_tmp_dir().join(format!("{hash:016x}.sock"))
    }

    /// `/tmp/stowaway-<uid>`, used only for long socket paths.
    #[must_use]
    pub fn private_tmp_dir(&self) -> PathBuf {
        use std::os::unix::fs::MetadataExt;
        let uid = std::fs::metadata(&self.home).map_or(0, |m| m.uid());
        PathBuf::from(format!("/tmp/stowaway-{uid}"))
    }

    /// The agent's log file.
    #[must_use]
    pub fn log_path(&self) -> PathBuf {
        self.state_dir.join("stowaway-agent.log")
    }

    /// Expands a leading `~` and makes the path absolute.
    #[must_use]
    pub fn expand(&self, path: &Path) -> PathBuf {
        let expanded = path
            .strip_prefix("~")
            .map_or_else(|_| path.to_path_buf(), |rest| self.home.join(rest));
        let absolute = if expanded.is_absolute() {
            expanded
        } else {
            std::env::current_dir().map_or_else(|_| expanded.clone(), |cwd| cwd.join(&expanded))
        };
        normalize(&absolute)
    }
}

/// Layout of Stowaway's directory on the external drive.
#[derive(Debug, Clone)]
pub struct DriveLayout {
    /// `<mount>/.stowaway`.
    pub root: PathBuf,
    /// `<mount>/.stowaway/<machine-id>.noindex`. Spotlight skips folders named `*.noindex` and
    /// everything in them, so it doesn't re-examine images on every write.
    /// `.metadata_never_index` would only be honored at the root of a volume.
    pub machine_dir: PathBuf,
}

impl DriveLayout {
    /// The layout for a drive mounted at `mount_point`, for this machine.
    #[must_use]
    pub fn new(mount_point: &Path, machine_id: &str) -> Self {
        let root = mount_point.join(".stowaway");
        Self {
            machine_dir: root.join(format!("{machine_id}.noindex")),
            root,
        }
    }

    /// `volume.json`, which ties the directory to a volume UUID.
    #[must_use]
    pub fn volume_file(&self) -> PathBuf {
        self.root.join("volume.json")
    }

    /// Directory holding one sparse bundle per entry.
    #[must_use]
    pub fn images_dir(&self) -> PathBuf {
        self.machine_dir.join("images")
    }

    /// The image for an entry.
    #[must_use]
    pub fn image_path(&self, entry_id: &str) -> PathBuf {
        self.images_dir().join(format!("{entry_id}.sparsebundle"))
    }

    /// Scratch space for deletions and speed tests.
    #[must_use]
    pub fn trash_dir(&self) -> PathBuf {
        self.machine_dir.join("trash")
    }
}

/// Lexically normalizes a path: removes `.` and resolves `..` without touching the filesystem.
#[must_use]
pub fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

/// Whether `path` is `ancestor` or lies inside it (lexically).
#[must_use]
pub fn is_within(path: &Path, ancestor: &Path) -> bool {
    path.starts_with(ancestor)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_resolves_dots() {
        assert_eq!(normalize(Path::new("/a/./b/../c/")), PathBuf::from("/a/c"));
    }

    #[test]
    fn expand_handles_tilde() {
        let layout = Layout::rooted(Path::new("/Users/me"), Path::new("/tmp/s"));
        assert_eq!(
            layout.expand(Path::new("~/code")),
            PathBuf::from("/Users/me/code")
        );
        assert_eq!(layout.expand(Path::new("/x/../y")), PathBuf::from("/y"));
    }

    #[test]
    fn drive_layout_paths() {
        let d = DriveLayout::new(Path::new("/Volumes/SSD"), "MID");
        assert_eq!(
            d.image_path("e1"),
            PathBuf::from("/Volumes/SSD/.stowaway/MID.noindex/images/e1.sparsebundle")
        );
        assert_eq!(
            d.volume_file(),
            PathBuf::from("/Volumes/SSD/.stowaway/volume.json")
        );
    }

    #[test]
    fn within_is_component_aware() {
        assert!(is_within(Path::new("/a/b/c"), Path::new("/a/b")));
        assert!(!is_within(Path::new("/a/bc"), Path::new("/a/b")));
    }
}
