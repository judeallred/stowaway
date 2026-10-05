//! Thin, safe wrappers over the few macOS system calls Stowaway needs.
//!
//! This is the only crate in the workspace allowed to contain `unsafe` code. Every wrapper keeps
//! its `unsafe` block to a single FFI call and validates inputs and outputs on the safe side.
#![expect(unsafe_code, reason = "this crate exists to wrap macOS FFI calls")]

use std::ffi::{CString, c_char, c_int};
use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// Capacity and identity of the filesystem that contains a path, from `statfs(2)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FsStats {
    /// Total size of the filesystem in bytes.
    pub total_bytes: u64,
    /// Free bytes, including blocks reserved for the superuser.
    pub free_bytes: u64,
    /// Bytes available to unprivileged users.
    pub available_bytes: u64,
    /// Filesystem type name, e.g. `apfs`, `hfs`, `msdos`, `exfat`.
    pub fs_type: String,
    /// Where the filesystem is mounted.
    pub mount_point: PathBuf,
    /// The device or source the filesystem was mounted from, e.g. `/dev/disk5s1`.
    pub mounted_from: String,
}

impl FsStats {
    /// Bytes in use: total minus free.
    #[must_use]
    pub const fn used_bytes(&self) -> u64 {
        self.total_bytes.saturating_sub(self.free_bytes)
    }
}

/// Returns `statfs(2)` information for the filesystem containing `path`.
///
/// # Errors
///
/// Returns the OS error if the path doesn't exist or can't be inspected.
pub fn fs_stats(path: &Path) -> io::Result<FsStats> {
    let c_path = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains a NUL byte"))?;
    let mut buf = std::mem::MaybeUninit::<libc::statfs>::zeroed();
    // SAFETY: `c_path` is a valid NUL-terminated string and `buf` points to writable memory large
    // enough for a `statfs` struct; `statfs` fully initializes it when it returns 0.
    let rc = unsafe { libc::statfs(c_path.as_ptr(), buf.as_mut_ptr()) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `statfs` returned 0, so it initialized the whole struct.
    let st = unsafe { buf.assume_init() };
    let block = u64::from(st.f_bsize);
    Ok(FsStats {
        total_bytes: st.f_blocks.saturating_mul(block),
        free_bytes: st.f_bfree.saturating_mul(block),
        available_bytes: st.f_bavail.saturating_mul(block),
        fs_type: c_chars_to_string(&st.f_fstypename),
        mount_point: PathBuf::from(c_chars_to_string(&st.f_mntonname)),
        mounted_from: c_chars_to_string(&st.f_mntfromname),
    })
}

fn c_chars_to_string(chars: &[c_char]) -> String {
    let bytes: Vec<u8> = chars
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| u8::from_ne_bytes(c.to_ne_bytes()))
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

const IOPOL_TYPE_DISK: c_int = 0;
const IOPOL_SCOPE_THREAD: c_int = 1;
const IOPOL_DEFAULT: c_int = 0;
const IOPOL_UTILITY: c_int = 4;

unsafe extern "C" {
    fn setiopolicy_np(iotype: c_int, scope: c_int, policy: c_int) -> c_int;
}

/// Lowers (or restores) the disk I/O priority of the calling thread.
///
/// Background copies run at "utility" priority so they don't slow down builds or the UI.
///
/// # Errors
///
/// Returns the OS error if the policy can't be set.
pub fn set_thread_background_io(background: bool) -> io::Result<()> {
    let policy = if background {
        IOPOL_UTILITY
    } else {
        IOPOL_DEFAULT
    };
    // SAFETY: `setiopolicy_np` takes plain integers and only affects the calling thread.
    let rc = unsafe { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, policy) };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Turns the unified buffer cache off (or on) for an open file, so benchmarks measure the drive
/// rather than RAM.
///
/// # Errors
///
/// Returns the OS error if `fcntl(F_NOCACHE)` fails.
pub fn set_no_cache(file: &File, no_cache: bool) -> io::Result<()> {
    // SAFETY: the descriptor is owned by `file` and stays open for the duration of the call;
    // `F_NOCACHE` takes an integer argument.
    let rc = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_NOCACHE, c_int::from(no_cache)) };
    if rc == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fs_stats_reports_the_root_filesystem() {
        let stats = fs_stats(Path::new("/")).unwrap();
        assert!(stats.total_bytes > 0);
        assert!(stats.free_bytes <= stats.total_bytes);
        assert!(!stats.fs_type.is_empty());
        assert_eq!(stats.mount_point, PathBuf::from("/"));
    }

    #[test]
    fn fs_stats_fails_for_missing_paths() {
        assert!(fs_stats(Path::new("/definitely/not/here")).is_err());
    }

    #[test]
    fn background_io_can_be_toggled() {
        set_thread_background_io(true).unwrap();
        set_thread_background_io(false).unwrap();
    }

    #[test]
    fn no_cache_can_be_set_on_a_file() {
        let file = File::open("/etc/hosts").unwrap();
        set_no_cache(&file, true).unwrap();
    }
}
