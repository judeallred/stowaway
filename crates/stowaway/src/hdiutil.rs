//! Creating, attaching and detaching the per-entry sparse-bundle images (spec §4.1).

use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::cmd;
use crate::error::{Error, IoContext, Result};

/// An image attached to the system.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachedImage {
    /// Path of the image file.
    pub image_path: PathBuf,
    /// The whole-disk device, e.g. `/dev/disk7`, used to detach it.
    pub device: String,
    /// Where its volume is mounted, if it is.
    pub mount_point: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
struct InfoPlist {
    #[serde(default)]
    images: Vec<ImagePlist>,
}

#[derive(Debug, Deserialize)]
struct ImagePlist {
    #[serde(rename = "image-path")]
    image_path: PathBuf,
    #[serde(rename = "system-entities", default)]
    system_entities: Vec<EntityPlist>,
}

#[derive(Debug, Deserialize)]
struct AttachPlist {
    #[serde(rename = "system-entities", default)]
    system_entities: Vec<EntityPlist>,
}

#[derive(Debug, Deserialize)]
struct EntityPlist {
    #[serde(rename = "dev-entry")]
    dev_entry: String,
    #[serde(rename = "mount-point")]
    mount_point: Option<PathBuf>,
}

/// Creates an empty APFS sparse bundle.
///
/// `size_bytes` is the virtual size; a sparse bundle only takes the space actually written.
///
/// # Errors
///
/// Fails if `hdiutil create` fails.
pub fn create(
    image: &Path,
    size_bytes: u64,
    volume_name: &str,
    case_sensitive: bool,
) -> Result<()> {
    if let Some(dir) = image.parent() {
        std::fs::create_dir_all(dir).ctx("creating", dir)?;
    }
    let fs = if case_sensitive {
        "Case-sensitive APFS"
    } else {
        "APFS"
    };
    let size = format!("{}m", (size_bytes / 1_000_000).max(100));
    cmd::run(
        "hdiutil",
        [
            "create".as_ref(),
            "-quiet".as_ref(),
            "-type".as_ref(),
            "SPARSEBUNDLE".as_ref(),
            "-fs".as_ref(),
            fs.as_ref(),
            "-size".as_ref(),
            size.as_ref(),
            "-volname".as_ref(),
            volume_name.as_ref(),
            image.as_os_str(),
        ],
    )?;
    Ok(())
}

/// Attaches `image` and mounts its volume at `mount_point`, which must be an existing directory.
///
/// # Errors
///
/// Fails if `hdiutil attach` fails or reports no mounted volume.
pub fn attach(image: &Path, mount_point: &Path) -> Result<AttachedImage> {
    let out = cmd::run(
        "hdiutil",
        [
            "attach".as_ref(),
            "-plist".as_ref(),
            "-nobrowse".as_ref(),
            "-noautoopen".as_ref(),
            "-owners".as_ref(),
            "on".as_ref(),
            "-mountpoint".as_ref(),
            mount_point.as_os_str(),
            image.as_os_str(),
        ],
    )?;
    let parsed: AttachPlist = cmd::parse_plist("hdiutil attach", &out)?;
    let device = whole_disk(&parsed.system_entities).ok_or_else(|| Error::Parse {
        command: "hdiutil attach".to_owned(),
        detail: "no device in output".to_owned(),
    })?;
    let mounted = parsed
        .system_entities
        .iter()
        .find_map(|e| e.mount_point.clone());
    if mounted.is_none() {
        // Attached but nothing mounted: don't leave a stale device behind.
        let _ignored = detach(&device, true);
        return Err(Error::Command {
            command: format!("hdiutil attach {}", image.display()),
            detail: "the image attached but its volume didn't mount".to_owned(),
        });
    }
    let never_index = mount_point.join(".metadata_never_index");
    if !never_index.exists() {
        std::fs::write(&never_index, b"").ctx("writing", &never_index)?;
    }
    Ok(AttachedImage {
        image_path: image.to_path_buf(),
        device,
        mount_point: mounted,
    })
}

/// How often a plain detach is tried. Right after a large copy, macOS's own services (Spotlight,
/// `fseventsd`) can hold a freshly written volume for a few seconds.
const DETACH_ATTEMPTS: u32 = 10;

/// Detaches an image by its whole-disk device. A plain detach is retried for a few seconds
/// while the device is busy.
///
/// # Errors
///
/// Fails if the device stays busy (and `force` is false) or doesn't exist.
pub fn detach(device: &str, force: bool) -> Result<()> {
    let mut args = vec!["detach", "-quiet"];
    if force {
        args.push("-force");
    }
    args.push(device);
    let mut attempt = 1;
    loop {
        match cmd::run("hdiutil", &args) {
            Ok(_) => return Ok(()),
            Err(e) if force || attempt >= DETACH_ATTEMPTS => return Err(e),
            Err(_) => {
                attempt += 1;
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        }
    }
}

/// Every attached disk image.
///
/// # Errors
///
/// Fails if `hdiutil info` fails.
pub fn attached() -> Result<Vec<AttachedImage>> {
    let out = cmd::run("hdiutil", ["info", "-plist"])?;
    let info: InfoPlist = cmd::parse_plist("hdiutil info", &out)?;
    Ok(info
        .images
        .into_iter()
        .filter_map(|image| {
            let device = whole_disk(&image.system_entities)?;
            let mount_point = image
                .system_entities
                .iter()
                .find_map(|e| e.mount_point.clone());
            Some(AttachedImage {
                image_path: image.image_path,
                device,
                mount_point,
            })
        })
        .collect())
}

fn whole_disk(entities: &[EntityPlist]) -> Option<String> {
    entities
        .iter()
        .map(|e| e.dev_entry.as_str())
        .min_by_key(|d| d.len())
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    const INFO: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>framework</key><string>1</string>
<key>images</key><array>
  <dict>
    <key>image-path</key><string>/Volumes/SSD/.stowaway/M/images/01J.sparsebundle</string>
    <key>system-entities</key><array>
      <dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>/dev/disk7</string></dict>
      <dict><key>content-hint</key><string>Apple_APFS</string><key>dev-entry</key><string>/dev/disk7s1</string></dict>
      <dict><key>content-hint</key><string>41504653</string><key>dev-entry</key><string>/dev/disk8s1</string><key>mount-point</key><string>/Users/me/code/app/node_modules</string></dict>
    </array>
  </dict>
  <dict>
    <key>image-path</key><string>/tmp/stale.sparsebundle</string>
    <key>system-entities</key><array>
      <dict><key>dev-entry</key><string>/dev/disk9</string></dict>
    </array>
  </dict>
</array></dict></plist>"#;

    #[test]
    fn parses_hdiutil_info() {
        let info: InfoPlist = cmd::parse_plist("hdiutil info", INFO.as_bytes()).unwrap();
        assert_eq!(info.images.len(), 2);
        let first = &info.images[0];
        assert_eq!(
            whole_disk(&first.system_entities).as_deref(),
            Some("/dev/disk7")
        );
        assert_eq!(
            first
                .system_entities
                .iter()
                .find_map(|e| e.mount_point.clone()),
            Some(PathBuf::from("/Users/me/code/app/node_modules"))
        );
        assert!(info.images[1].system_entities[0].mount_point.is_none());
    }
}
