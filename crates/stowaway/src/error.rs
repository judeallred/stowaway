//! The crate's error type.

use std::path::{Path, PathBuf};

/// Result type used throughout Stowaway.
pub type Result<T, E = Error> = std::result::Result<T, E>;

/// Everything that can go wrong in Stowaway.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// A filesystem operation failed.
    #[error("{action} {}: {source}", path.display())]
    Io {
        /// What was being attempted, e.g. "reading".
        action: &'static str,
        /// The path involved.
        path: PathBuf,
        /// The underlying OS error.
        #[source]
        source: std::io::Error,
    },
    /// An external command (hdiutil, diskutil, lsof, ...) failed.
    #[error("`{command}` failed: {detail}")]
    Command {
        /// The command line that was run.
        command: String,
        /// Exit status and stderr, or the spawn error.
        detail: String,
    },
    /// Output from an external command couldn't be understood.
    #[error("unexpected output from `{command}`: {detail}")]
    Parse {
        /// The command whose output was parsed.
        command: String,
        /// What was wrong with it.
        detail: String,
    },
    /// The configuration file is invalid.
    #[error("config: {0}")]
    Config(String),
    /// The state database failed.
    #[error("state database: {0}")]
    Database(#[from] rusqlite::Error),
    /// JSON (de)serialization failed.
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    /// `stowaway init` hasn't been run.
    #[error("Stowaway isn't set up yet. Run `stowaway init --volume <drive> --root <folder>`.")]
    NotInitialized,
    /// The configured external drive isn't connected.
    #[error("the external drive isn't connected")]
    DriveOffline,
    /// The request is invalid in the current state.
    #[error("{0}")]
    Invalid(String),
    /// Something is using the files, so the operation was postponed.
    #[error("{0}")]
    Busy(String),
}

impl Error {
    /// Builds an [`Error::Io`] for `path`.
    #[must_use]
    pub fn io(action: &'static str, path: &Path, source: std::io::Error) -> Self {
        Self::Io {
            action,
            path: path.to_path_buf(),
            source,
        }
    }
}

/// Adds path context to `std::io::Result`.
pub trait IoContext<T> {
    /// Converts an I/O error into [`Error::Io`] describing `action` on `path`.
    ///
    /// # Errors
    ///
    /// Returns the wrapped error if `self` is an error.
    fn ctx(self, action: &'static str, path: &Path) -> Result<T>;
}

impl<T> IoContext<T> for std::io::Result<T> {
    fn ctx(self, action: &'static str, path: &Path) -> Result<T> {
        self.map_err(|e| Error::io(action, path, e))
    }
}
