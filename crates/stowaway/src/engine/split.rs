//! Converting an entry that holds a whole container into one entry per part (spec §4.11).
//!
//! Before containers were split, a Cargo `target/` or `DerivedData` was stowed whole, so the
//! programs built in it left with the drive. Converting one copies each part to its own image and
//! everything else back to this Mac. The old image isn't changed, and the old entry stays
//! registered until a single registry update swaps it for the parts. If the conversion stops
//! before that, recovery deletes the unregistered images and reconcile reattaches the old one.

use std::fs;
use std::path::{Path, PathBuf};

use tracing::warn;

use super::{
    Drive, Engine, EngineEvent, TransferStep, TransferTracker, busy_with, detach_mounted_at,
    new_entry,
};
use crate::error::{Error, IoContext, Result};
use crate::fsutil::{self, Overwrite, Pace};
use crate::idle::{self, Activity};
use crate::kinds;
use crate::registry::{Entry, EntryStatus};

impl Engine {
    /// Mounted entries that hold a whole container, adopted before containers were split.
    /// [`Engine::split_entry`] converts them.
    ///
    /// # Errors
    ///
    /// Fails on a database error.
    pub fn whole_entries(&self) -> Result<Vec<Entry>> {
        Ok(self
            .registry
            .entries()?
            .into_iter()
            .filter(|e| {
                kinds::is_container(e.kind, &e.path)
                    && e.status == EntryStatus::Mounted
                    && idle::is_mount_point(&e.path)
            })
            .collect())
    }

    /// Converts a whole-container entry into one entry per part over the adoption threshold;
    /// everything else in the container (the programs it built) comes back to this Mac. Returns
    /// the new entries.
    ///
    /// # Errors
    ///
    /// [`Error::Busy`] if the folder is in use or changes during a copy; I/O and `hdiutil`
    /// errors. On failure the old entry is kept, and reattached if it was detached.
    pub fn split_entry(&mut self, entry: &Entry) -> Result<Vec<Entry>> {
        let drive = self.require_drive()?;
        if idle::activity(&entry.path, self.config.idle_seconds)? != Activity::Idle {
            return Err(Error::Busy(format!(
                "{} is in use; it will be split once it's idle",
                entry.path.display()
            )));
        }
        let mut parts = Vec::new();
        for part in kinds::managed_folders(entry.kind, &entry.path) {
            if fsutil::allocated_bytes(&part)? >= self.config.min_adopt_bytes {
                parts.push(part);
            }
        }
        let mut made = Vec::new();
        let committed = self
            .prepare_split(&drive, entry, &parts, &mut made)
            .and_then(|()| self.registry.replace(&entry.id, &made));
        if let Err(e) = committed {
            for new in &made {
                let _ignored =
                    self.discard_failed_image(&new.id, &drive.layout.image_path(&new.id));
                let _ignored = self.registry.journal_done(&new.id);
            }
            return Err(e);
        }
        self.finish_split(&drive, entry, &made);
        self.emit(&EngineEvent::EntriesChanged);
        made.iter()
            .map(|new| {
                self.registry
                    .by_id(&new.id)?
                    .ok_or_else(|| Error::Invalid("entry vanished".into()))
            })
            .collect()
    }

    /// Everything before the swap: copies each part to its own image, adding its entry to `made`,
    /// then puts the rest of the container in its place on this Mac with the old image detached.
    fn prepare_split(
        &self,
        drive: &Drive,
        entry: &Entry,
        parts: &[PathBuf],
        made: &mut Vec<Entry>,
    ) -> Result<()> {
        for part in parts {
            let id = ulid::Ulid::generate().to_string().to_ascii_lowercase();
            self.registry
                .journal(&id, "split", "copying", crate::now_unix())?;
            made.push(new_entry(
                &id,
                entry.kind,
                part,
                crate::now_unix(),
                EntryStatus::Local,
            ));
            let mut tracker = TransferTracker::new(self.observer.clone(), &id, part, "adopt");
            let image = drive.layout.image_path(&id);
            let stats = self.copy_into_new_image(drive, &mut tracker, entry.kind, part, &image)?;
            self.record_transfer(tracker, stats)?;
        }
        let products = self.layout.state_dir.join(format!("split-{}", entry.id));
        let brought_back = self.bring_back_products(entry, parts, &products);
        let _ignored = fsutil::remove_tree(&products);
        brought_back
    }

    /// Copies the container, apart from `parts`, to `products`, detaches the old image and moves
    /// the copy into place.
    fn bring_back_products(&self, entry: &Entry, parts: &[PathBuf], products: &Path) -> Result<()> {
        let mut tracker =
            TransferTracker::new(self.observer.clone(), &entry.id, &entry.path, "release");
        fsutil::remove_tree(products)?;
        fs::create_dir_all(products).ctx("creating", products)?;
        tracker.total = fsutil::fingerprint_except(&entry.path, parts)?;
        let stats = self.copy_with_progress(
            &mut tracker,
            &entry.path,
            products,
            Overwrite::Replace,
            parts,
        )?;
        let holders = idle::holders(&[&entry.path])?;
        if !holders.is_empty() {
            return Err(busy_with(&entry.path, &holders));
        }
        tracker.step(TransferStep::Mounting);
        detach_mounted_at(&entry.path);
        if idle::is_mount_point(&entry.path) {
            return Err(Error::Busy(format!(
                "{} couldn't be detached",
                entry.path.display()
            )));
        }
        fsutil::clear_dir_contents(&entry.path)?;
        move_contents(products, &entry.path)?;
        self.record_transfer(tracker, stats)
    }

    /// After the swap: mounts the parts and deletes the old image. Failures are left to
    /// reconcile, which mounts registered entries, and `gc`, which deletes unregistered images.
    fn finish_split(&self, drive: &Drive, entry: &Entry, made: &[Entry]) {
        for new in made {
            if let Err(e) = self.attach_entry(drive, new) {
                warn!(path = %new.path.display(), error = %e, "can't mount a split part yet");
            }
        }
        let old = drive.layout.image_path(&entry.id);
        let trashed = drive
            .layout
            .trash_dir()
            .join(format!("{}.split.sparsebundle", entry.id));
        let deleted = fs::rename(&old, &trashed)
            .ctx("moving", &old)
            .and_then(|()| fsutil::remove_tree(&trashed));
        if let Err(e) = deleted {
            warn!(image = %old.display(), error = %e, "can't delete the old image; gc will");
        }
    }
}

/// Moves everything in `from` into `to` (both on this Mac), then removes `from`.
fn move_contents(from: &Path, to: &Path) -> Result<()> {
    for item in fs::read_dir(from).ctx("reading", from)?.flatten() {
        let dest = to.join(item.file_name());
        if fs::rename(item.path(), &dest).is_err() {
            // Different volumes: fall back to copying.
            fsutil::copy_tree(&item.path(), &dest, Overwrite::Replace, &mut |_| Pace::Go)?;
        }
    }
    fsutil::remove_tree(from)
}
