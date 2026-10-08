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
use std::sync::OnceLock;

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

/// Bytes this process has read from disk so far, as counted by the kernel.
///
/// # Errors
///
/// Returns the OS error if `proc_pid_rusage` fails.
pub fn own_disk_read_bytes() -> io::Result<u64> {
    let pid = c_int::try_from(std::process::id())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "process ID out of range"))?;
    // SAFETY: `rusage_info_v2` contains only integers, so all-zero bytes are a valid value.
    let mut info: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
    // SAFETY: `info` is a live, correctly sized `rusage_info_v2`, matching `RUSAGE_INFO_V2`.
    let rc = unsafe {
        libc::proc_pid_rusage(
            pid,
            libc::RUSAGE_INFO_V2,
            (&raw mut info).cast::<libc::rusage_info_t>(),
        )
    };
    if rc == 0 {
        Ok(info.ri_diskio_bytesread)
    } else {
        Err(io::Error::last_os_error())
    }
}

/// CPU time spent across all cores since boot, in scheduler ticks. The counters are 32-bit and
/// wrap, so compare two samples with [`CpuTicks::busy_fraction_since`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CpuTicks {
    /// Running user code.
    pub user: u32,
    /// Running kernel code.
    pub system: u32,
    /// Idle.
    pub idle: u32,
    /// Running low-priority (niced) user code.
    pub nice: u32,
}

impl CpuTicks {
    /// The fraction of CPU time that was busy between `earlier` and `self`, or `None` if no
    /// ticks elapsed.
    #[must_use]
    pub fn busy_fraction_since(&self, earlier: &Self) -> Option<f64> {
        let busy = u64::from(self.user.wrapping_sub(earlier.user))
            + u64::from(self.system.wrapping_sub(earlier.system))
            + u64::from(self.nice.wrapping_sub(earlier.nice));
        let total = busy + u64::from(self.idle.wrapping_sub(earlier.idle));
        let (busy, total) = (u32::try_from(busy).ok()?, u32::try_from(total).ok()?);
        (total > 0).then(|| f64::from(busy) / f64::from(total))
    }
}

unsafe extern "C" {
    /// Declared here because `libc`'s copy is deprecated in favor of the `mach2` crate.
    fn mach_host_self() -> libc::mach_port_t;
}

/// Reads the machine-wide CPU tick counters (`host_statistics(HOST_CPU_LOAD_INFO)`).
///
/// # Errors
///
/// Returns an error if the kernel call fails.
pub fn cpu_ticks() -> io::Result<CpuTicks> {
    static HOST: OnceLock<libc::mach_port_t> = OnceLock::new();
    // SAFETY: `mach_host_self` takes no arguments and returns a send right to the host port. One
    // is kept for the life of the process, so there's nothing to deallocate.
    let host = *HOST.get_or_init(|| unsafe { mach_host_self() });
    let mut info = libc::host_cpu_load_info { cpu_ticks: [0; 4] };
    let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
    // SAFETY: `info` is a live `host_cpu_load_info`, and `count` is its size in `integer_t`s, as
    // `HOST_CPU_LOAD_INFO` requires; the kernel writes at most `count` integers.
    let rc = unsafe {
        libc::host_statistics(
            host,
            libc::HOST_CPU_LOAD_INFO,
            (&raw mut info).cast::<libc::integer_t>(),
            &raw mut count,
        )
    };
    if rc != libc::KERN_SUCCESS {
        return Err(io::Error::other(format!("host_statistics failed ({rc})")));
    }
    // Indices are CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE and CPU_STATE_NICE.
    let [user, system, idle, nice] = info.cpu_ticks;
    Ok(CpuTicks {
        user,
        system,
        idle,
        nice,
    })
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
    fn own_disk_reads_are_counted() {
        let before = own_disk_read_bytes().unwrap();
        let file = File::open("/etc/hosts").unwrap();
        set_no_cache(&file, true).unwrap();
        io::Read::read_to_end(&mut &file, &mut Vec::new()).unwrap();
        assert!(own_disk_read_bytes().unwrap() >= before);
    }

    #[test]
    fn cpu_load_is_a_fraction() {
        let before = cpu_ticks().unwrap();
        let spin = std::time::Instant::now();
        while spin.elapsed() < std::time::Duration::from_millis(50) {
            std::hint::black_box(0_u64);
        }
        let after = cpu_ticks().unwrap();
        if let Some(busy) = after.busy_fraction_since(&before) {
            assert!((0.0..=1.0).contains(&busy), "{busy}");
        }
        let wrapped = CpuTicks {
            user: 5,
            idle: 5,
            ..CpuTicks::default()
        };
        let earlier = CpuTicks {
            user: u32::MAX - 4,
            idle: u32::MAX - 4,
            ..CpuTicks::default()
        };
        assert_eq!(wrapped.busy_fraction_since(&earlier), Some(0.5));
    }

    #[test]
    fn no_cache_can_be_set_on_a_file() {
        let file = File::open("/etc/hosts").unwrap();
        set_no_cache(&file, true).unwrap();
    }
}
