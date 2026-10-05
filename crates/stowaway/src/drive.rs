//! Finding and describing the external drive (spec §4.3).

use std::collections::HashMap;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::cmd;
use crate::error::{Error, IoContext, Result};
use crate::paths::DriveLayout;

/// What `diskutil info` says about a volume or disk.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct DiskInfo {
    /// Volume UUID (volumes only).
    #[serde(rename = "VolumeUUID")]
    pub volume_uuid: Option<String>,
    /// Volume name.
    pub volume_name: Option<String>,
    /// Mount point.
    pub mount_point: Option<String>,
    /// `apfs`, `hfs`, `exfat`, `msdos`, ...
    pub filesystem_type: Option<String>,
    /// e.g. `APFS` or `Case-sensitive APFS`.
    pub filesystem_name: Option<String>,
    /// Whether the device is internal.
    pub internal: Option<bool>,
    /// `USB`, `Thunderbolt`, `PCI-Express`, `Disk Image`, ...
    pub bus_protocol: Option<String>,
    /// Whether it's an SSD.
    pub solid_state: Option<bool>,
    /// Whole-disk identifier, e.g. `disk5`.
    pub parent_whole_disk: Option<String>,
    /// Physical stores backing an APFS container.
    #[serde(rename = "APFSPhysicalStores", default)]
    pub apfs_physical_stores: Vec<PhysicalStore>,
    /// Device model, for whole disks.
    #[serde(rename = "MediaName")]
    pub media_name: Option<String>,
    /// Device identifier, e.g. `disk5s1`.
    pub device_identifier: Option<String>,
}

/// One physical store of an APFS container.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
pub struct PhysicalStore {
    /// e.g. `disk4s2`.
    #[serde(rename = "APFSPhysicalStore")]
    pub device: String,
}

/// Runs `diskutil info -plist` on a path or device.
///
/// # Errors
///
/// Fails if diskutil fails or its output can't be parsed.
pub fn disk_info(target: &str) -> Result<DiskInfo> {
    let out = cmd::run("diskutil", ["info", "-plist", target])?;
    cmd::parse_plist("diskutil info", &out)
}

impl DiskInfo {
    /// Whether the filesystem is case-sensitive.
    #[must_use]
    pub fn case_sensitive(&self) -> bool {
        self.filesystem_name
            .as_deref()
            .is_some_and(|n| n.to_ascii_lowercase().contains("case-sensitive"))
    }

    /// The physical whole disk behind this volume (for an APFS volume, its container's store).
    #[must_use]
    pub fn physical_whole_disk(&self) -> Option<String> {
        let store = self
            .apfs_physical_stores
            .first()
            .map(|s| s.device.clone())
            .or_else(|| self.parent_whole_disk.clone())?;
        Some(strip_partition(&store))
    }
}

fn strip_partition(device: &str) -> String {
    let after_disk = device.strip_prefix("disk").unwrap_or(device);
    let number: String = after_disk
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    format!("disk{number}")
}

/// Marker written to the drive at `init`, tying `.stowaway/` to one volume UUID.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VolumeMarker {
    /// Format version of the on-drive layout.
    pub format: u32,
    /// The volume's UUID.
    pub volume_uuid: String,
}

/// Current on-drive layout version.
pub const FORMAT_VERSION: u32 = 1;

/// Reads the marker from a mounted drive.
#[must_use]
pub fn read_marker(mount_point: &Path) -> Option<VolumeMarker> {
    let path = mount_point.join(".stowaway/volume.json");
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

/// Writes the marker and creates the machine directory on a drive.
///
/// # Errors
///
/// Fails if the drive isn't writable.
pub fn prepare(layout: &DriveLayout, volume_uuid: &str) -> Result<()> {
    std::fs::create_dir_all(layout.images_dir()).ctx("creating", &layout.images_dir())?;
    std::fs::create_dir_all(layout.trash_dir()).ctx("creating", &layout.trash_dir())?;
    let never_index = layout.root.join(".metadata_never_index");
    if !never_index.exists() {
        std::fs::write(&never_index, b"").ctx("writing", &never_index)?;
    }
    let marker = VolumeMarker {
        format: FORMAT_VERSION,
        volume_uuid: volume_uuid.to_owned(),
    };
    let path = layout.volume_file();
    std::fs::write(&path, serde_json::to_vec_pretty(&marker)?).ctx("writing", &path)
}

/// Finds where the drive with `volume_uuid` is mounted, verifying candidates with diskutil once
/// per mount and caching the answer by device number.
#[derive(Debug, Default)]
pub struct DriveLocator {
    verified: HashMap<(PathBuf, u64), bool>,
}

impl DriveLocator {
    /// Looks for the drive among mounted volumes. `extra_roots` adds places to look besides
    /// `/Volumes` (used by tests that mount disk images elsewhere).
    pub fn locate(&mut self, volume_uuid: &str, extra_roots: &[PathBuf]) -> Option<PathBuf> {
        let mut candidates: Vec<PathBuf> = extra_roots.to_vec();
        if let Ok(entries) = std::fs::read_dir("/Volumes") {
            candidates.extend(entries.filter_map(|e| e.ok().map(|e| e.path())));
        }
        candidates
            .into_iter()
            .find(|mount| self.matches(mount, volume_uuid))
    }

    fn matches(&mut self, mount: &Path, volume_uuid: &str) -> bool {
        let Some(marker) = read_marker(mount) else {
            return false;
        };
        if !marker.volume_uuid.eq_ignore_ascii_case(volume_uuid) {
            return false;
        }
        let Ok(meta) = std::fs::metadata(mount) else {
            return false;
        };
        let key = (mount.to_path_buf(), meta.dev());
        if let Some(&ok) = self.verified.get(&key) {
            return ok;
        }
        let ok = disk_info(&mount.to_string_lossy()).is_ok_and(|info| {
            info.volume_uuid
                .as_deref()
                .is_some_and(|u| u.eq_ignore_ascii_case(volume_uuid))
        });
        self.verified.insert(key, ok);
        ok
    }
}

/// Validates a volume chosen at `init` and returns its info.
///
/// # Errors
///
/// Rejects internal disks and non-APFS filesystems.
pub fn validate_for_init(path: &Path) -> Result<DiskInfo> {
    let info = disk_info(&path.to_string_lossy())?;
    if info.volume_uuid.is_none() {
        return Err(Error::Invalid(format!(
            "{} isn't a mounted volume with a UUID",
            path.display()
        )));
    }
    if info.filesystem_type.as_deref() != Some("apfs") {
        return Err(Error::Invalid(format!(
            "{} is formatted as {}; Stowaway needs an APFS volume. Reformat it as APFS in Disk Utility.",
            path.display(),
            info.filesystem_name
                .as_deref()
                .unwrap_or("an unknown filesystem")
        )));
    }
    if info.mount_point.as_deref() == Some("/")
        || info.mount_point.as_deref() == Some("/System/Volumes/Data")
    {
        return Err(Error::Invalid(
            "that's your internal startup disk; choose an external drive".to_owned(),
        ));
    }
    Ok(info)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_partition_suffixes() {
        assert_eq!(strip_partition("disk4s2"), "disk4");
        assert_eq!(strip_partition("disk12"), "disk12");
    }

    #[test]
    fn parses_diskutil_info() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>VolumeUUID</key><string>ABC-123</string>
<key>VolumeName</key><string>FastSSD</string>
<key>MountPoint</key><string>/Volumes/FastSSD</string>
<key>FilesystemType</key><string>apfs</string>
<key>FilesystemName</key><string>Case-sensitive APFS</string>
<key>BusProtocol</key><string>USB</string>
<key>Internal</key><false/>
<key>APFSPhysicalStores</key><array><dict><key>APFSPhysicalStore</key><string>disk4s2</string></dict></array>
<key>SomethingElse</key><integer>7</integer>
</dict></plist>"#;
        let info: DiskInfo = cmd::parse_plist("diskutil info", xml.as_bytes()).unwrap();
        assert_eq!(info.volume_uuid.as_deref(), Some("ABC-123"));
        assert!(info.case_sensitive());
        assert_eq!(info.physical_whole_disk().as_deref(), Some("disk4"));
        assert_eq!(info.internal, Some(false));
    }

    #[test]
    fn marker_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let layout = DriveLayout::new(dir.path(), "MID");
        prepare(&layout, "UUID-1").unwrap();
        assert_eq!(
            read_marker(dir.path()),
            Some(VolumeMarker {
                format: FORMAT_VERSION,
                volume_uuid: "UUID-1".into()
            })
        );
        assert!(layout.images_dir().is_dir());
    }
}
