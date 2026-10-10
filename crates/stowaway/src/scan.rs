//! Discovering folders to manage under the watched roots (spec §4.4).

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use globset::GlobSet;

use crate::kinds::{self, KindId, Scope};

/// A folder that could be managed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    /// Its kind.
    pub kind: KindId,
    /// The folder path (may not exist yet).
    pub path: PathBuf,
    /// Whether the folder already exists. If not, it can be pre-adopted.
    pub exists: bool,
}

/// What to look for.
#[derive(Debug)]
pub struct ScanOptions<'a> {
    /// Enabled project kinds.
    pub kinds: &'a [KindId],
    /// Paths never to touch.
    pub exclude: &'a GlobSet,
    /// `CARGO_TARGET_DIR` is set globally, so per-project targets aren't used.
    pub cargo_target_dir_set: bool,
    /// How deep below each root to look.
    pub max_depth: usize,
}

/// Marker file that excludes a folder and everything under it.
pub const IGNORE_MARKER: &str = ".stowaway-ignore";

/// Folders under the home folder where coding agents keep their worktrees, scanned like roots
/// whenever they exist: Cursor's and the Codex app's.
pub const AGENT_WORKTREE_DIRS: &[&str] = &[".cursor/worktrees", ".codex/worktrees"];

/// Hidden folders inside a project that hold whole checkouts, each scanned as its own project
/// tree even though the scan otherwise skips hidden folders: Claude Code's worktrees.
const IN_PROJECT_CHECKOUT_DIRS: &[&str] = &[".claude/worktrees"];

/// Finds candidates under `root`.
#[must_use]
pub fn scan(root: &Path, opts: &ScanOptions<'_>) -> Vec<Candidate> {
    let mut out = Vec::new();
    let Ok(meta) = fs::metadata(root) else {
        return out;
    };
    visit(root, meta.dev(), 0, false, opts, &mut out);
    out
}

fn visit(
    dir: &Path,
    root_dev: u64,
    depth: usize,
    node_ancestor: bool,
    opts: &ScanOptions<'_>,
    out: &mut Vec<Candidate>,
) {
    if opts.exclude.is_match(dir) || dir.join(IGNORE_MARKER).exists() {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut subdirs = Vec::new();
    let mut names = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if let Ok(ft) = entry.file_type()
            && ft.is_dir()
        {
            subdirs.push(name.clone());
        }
        names.push(name);
    }
    let has = |name: &str| names.iter().any(|n| n == name);
    let mut children_have_node_ancestor = node_ancestor;
    let mut skip = vec![".git"];

    for &kind in opts.kinds {
        let Scope::Project {
            dir_name,
            manifest,
            lockfiles,
            required_marker,
        } = kind.spec().scope
        else {
            continue;
        };
        if !has(manifest) {
            continue;
        }
        skip.push(dir_name);
        let path = dir.join(dir_name);
        let exists = subdirs.iter().any(|d| d == dir_name);
        // A symlink or file in the folder's place is left alone.
        if has(dir_name) && !exists {
            continue;
        }
        let eligible = match kind {
            KindId::Node => !node_ancestor,
            KindId::CargoTarget => !opts.cargo_target_dir_set && !cargo_target_redirected(dir),
            _ => true,
        };
        if kind == KindId::Node && exists {
            children_have_node_ancestor = true;
        }
        if !eligible || opts.exclude.is_match(&path) {
            continue;
        }
        let candidate = if exists {
            required_marker.is_none_or(|m| path.join(m).exists())
        } else {
            lockfiles.iter().any(|l| has(l))
        };
        if !candidate {
            continue;
        }
        out.extend(
            kinds::managed_folders(kind, &path)
                .into_iter()
                .filter(|p| !opts.exclude.is_match(p))
                .map(|path| Candidate {
                    kind,
                    exists: kinds::is_real_dir(&path),
                    path,
                }),
        );
    }

    if depth >= opts.max_depth {
        return;
    }
    for name in subdirs {
        if name.starts_with('.') || skip.contains(&name.as_str()) || name == "node_modules" {
            continue;
        }
        let child = dir.join(&name);
        if is_local_dir(&child, root_dev) {
            visit(
                &child,
                root_dev,
                depth + 1,
                children_have_node_ancestor,
                opts,
                out,
            );
        }
    }
    // Each checkout is a separate project, so this one's `node_modules` isn't its ancestor.
    for checkouts in IN_PROJECT_CHECKOUT_DIRS.iter().map(|d| dir.join(d)) {
        if is_local_dir(&checkouts, root_dev) && !opts.exclude.is_match(&checkouts) {
            for checkout in kinds::subdirs(&checkouts) {
                if is_local_dir(&checkout, root_dev) {
                    visit(&checkout, root_dev, depth + 1, false, opts, out);
                }
            }
        }
    }
}

/// Whether `path` is a real folder on the root's filesystem; symlinks, mounted images and other
/// volumes are skipped.
fn is_local_dir(path: &Path, root_dev: u64) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_dir() && m.dev() == root_dev)
}

/// Whether a `.cargo/config.toml` in `dir` or any ancestor sets `target-dir`.
fn cargo_target_redirected(dir: &Path) -> bool {
    dir.ancestors().any(|d| {
        ["config.toml", "config"].iter().any(|name| {
            fs::read_to_string(d.join(".cargo").join(name)).is_ok_and(|text| {
                text.lines()
                    .any(|l| l.trim_start().starts_with("target-dir"))
            })
        })
    })
}

/// Whether git tracks any files inside `dir` (e.g. a committed `node_modules`).
#[must_use]
pub fn has_tracked_files(dir: &Path) -> bool {
    let (Some(parent), Some(name)) = (dir.parent(), dir.file_name()) else {
        return false;
    };
    crate::cmd::output(
        "git",
        [
            "-C".as_ref(),
            parent.as_os_str(),
            "ls-files".as_ref(),
            "-z".as_ref(),
            "--".as_ref(),
            name,
        ],
    )
    .is_ok_and(|o| !o.stdout.is_empty())
}

#[cfg(test)]
mod tests {
    use globset::GlobSetBuilder;

    use super::*;

    fn touch(path: &Path) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "").unwrap();
    }

    fn opts(exclude: &GlobSet) -> ScanOptions<'_> {
        ScanOptions {
            kinds: &[KindId::Node, KindId::CargoTarget],
            exclude,
            cargo_target_dir_set: false,
            max_depth: 6,
        }
    }

    fn found(root: &Path, exclude: &GlobSet) -> Vec<(KindId, String, bool)> {
        let mut v: Vec<_> = scan(root, &opts(exclude))
            .into_iter()
            .map(|c| {
                (
                    c.kind,
                    c.path.strip_prefix(root).unwrap().display().to_string(),
                    c.exists,
                )
            })
            .collect();
        v.sort();
        v
    }

    #[test]
    fn finds_projects_and_respects_rules() {
        let root = tempfile::tempdir().unwrap();
        let r = root.path();
        // Existing node_modules.
        touch(&r.join("web/package.json"));
        touch(&r.join("web/node_modules/react/index.js"));
        // Workspace member with its own node_modules: stays local.
        touch(&r.join("web/packages/ui/package.json"));
        touch(&r.join("web/packages/ui/node_modules/x/index.js"));
        // New project with a lockfile: pre-adoptable.
        touch(&r.join("fresh/package.json"));
        touch(&r.join("fresh/pnpm-lock.yaml"));
        // No lockfile, no node_modules: nothing.
        touch(&r.join("lib/package.json"));
        // Cargo: target with CACHEDIR.TAG, and a fixture without Cargo.lock.
        touch(&r.join("rs/Cargo.toml"));
        touch(&r.join("rs/Cargo.lock"));
        touch(&r.join("rs/target/CACHEDIR.TAG"));
        touch(&r.join("rs/target/debug/deps/libx.rlib"));
        touch(&r.join("rs/target/debug/rs"));
        // A Cargo project that hasn't been built yet: its first build's folders are pre-adopted.
        touch(&r.join("new-rs/Cargo.toml"));
        touch(&r.join("new-rs/Cargo.lock"));
        touch(&r.join("rs/tests/fixture/Cargo.toml"));
        // A symlinked node_modules, as some worktrees have: left alone.
        touch(&r.join("linked/package.json"));
        touch(&r.join("linked/package-lock.json"));
        std::os::unix::fs::symlink(r.join("web/node_modules"), r.join("linked/node_modules"))
            .unwrap();
        // Excluded and ignored.
        touch(&r.join("ignored/.stowaway-ignore"));
        touch(&r.join("ignored/package.json"));
        touch(&r.join("ignored/package-lock.json"));

        let none = GlobSetBuilder::new().build().unwrap();
        assert_eq!(
            found(r, &none),
            vec![
                (KindId::Node, "fresh/node_modules".into(), false),
                (KindId::Node, "web/node_modules".into(), true),
                (
                    KindId::CargoTarget,
                    "new-rs/target/debug/deps".into(),
                    false
                ),
                (
                    KindId::CargoTarget,
                    "new-rs/target/debug/incremental".into(),
                    false
                ),
                (KindId::CargoTarget, "rs/target/debug/deps".into(), true),
            ]
        );
    }

    #[test]
    fn finds_next_and_venv_folders() {
        let root = tempfile::tempdir().unwrap();
        let r = root.path();
        // Built Next.js app, and one only configured: pre-adoptable.
        touch(&r.join("site/package.json"));
        touch(&r.join("site/.next/BUILD_ID"));
        touch(&r.join("fresh-site/package.json"));
        touch(&r.join("fresh-site/next.config.mjs"));
        // A venv, a folder that isn't one, and a project without a venv yet: never pre-adopted.
        touch(&r.join("py/pyproject.toml"));
        touch(&r.join("py/.venv/pyvenv.cfg"));
        touch(&r.join("not-venv/pyproject.toml"));
        touch(&r.join("not-venv/.venv/notes.txt"));
        touch(&r.join("new-py/pyproject.toml"));
        touch(&r.join("new-py/uv.lock"));
        let none = GlobSetBuilder::new().build().unwrap();
        let opts = ScanOptions {
            kinds: &[KindId::Next, KindId::Venv],
            exclude: &none,
            cargo_target_dir_set: false,
            max_depth: 6,
        };
        let mut v: Vec<_> = scan(r, &opts)
            .into_iter()
            .map(|c| {
                (
                    c.kind,
                    c.path.strip_prefix(r).unwrap().display().to_string(),
                    c.exists,
                )
            })
            .collect();
        v.sort();
        assert_eq!(
            v,
            vec![
                (KindId::Next, "fresh-site/.next".into(), false),
                (KindId::Next, "site/.next".into(), true),
                (KindId::Venv, "py/.venv".into(), true),
            ]
        );
    }

    #[test]
    fn claude_worktrees_are_separate_projects() {
        let root = tempfile::tempdir().unwrap();
        let r = root.path();
        touch(&r.join("web/package.json"));
        touch(&r.join("web/node_modules/react/index.js"));
        touch(&r.join("web/.claude/worktrees/fix/package.json"));
        touch(&r.join("web/.claude/worktrees/fix/node_modules/react/index.js"));
        touch(&r.join("web/.claude/settings/package.json"));
        touch(&r.join("web/.claude/settings/package-lock.json"));
        let none = GlobSetBuilder::new().build().unwrap();
        assert_eq!(
            found(r, &none),
            vec![
                (
                    KindId::Node,
                    "web/.claude/worktrees/fix/node_modules".into(),
                    true
                ),
                (KindId::Node, "web/node_modules".into(), true),
            ]
        );
    }

    #[test]
    fn target_dir_redirect_and_excludes() {
        let root = tempfile::tempdir().unwrap();
        let r = root.path();
        touch(&r.join("a/Cargo.toml"));
        touch(&r.join("a/Cargo.lock"));
        fs::create_dir_all(r.join("a/.cargo")).unwrap();
        fs::write(
            r.join("a/.cargo/config.toml"),
            "[build]\ntarget-dir = \"/tmp/t\"\n",
        )
        .unwrap();
        touch(&r.join("b/package.json"));
        touch(&r.join("b/yarn.lock"));
        let mut builder = GlobSetBuilder::new();
        builder.add(globset::Glob::new(&format!("{}/b/**", r.display())).unwrap());
        assert!(found(r, &builder.build().unwrap()).is_empty());
    }

    #[test]
    fn tracked_folders_are_detected() {
        let repo = tempfile::tempdir().unwrap();
        let r = repo.path();
        crate::cmd::run("git", ["-C", &r.to_string_lossy(), "init", "-q"]).unwrap();
        touch(&r.join("node_modules/dep/index.js"));
        touch(&r.join("other/file"));
        assert!(!has_tracked_files(&r.join("node_modules")));
        crate::cmd::run("git", ["-C", &r.to_string_lossy(), "add", "node_modules"]).unwrap();
        assert!(has_tracked_files(&r.join("node_modules")));
        assert!(!has_tracked_files(&r.join("other")));
    }
}
