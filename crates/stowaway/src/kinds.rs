//! The kinds of folders Stowaway manages, each described declaratively (spec §4.8).

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Identifies a kind of managed folder.
#[derive(
    Debug,
    Clone,
    Copy,
    PartialEq,
    Eq,
    Hash,
    PartialOrd,
    Ord,
    Serialize,
    Deserialize,
    clap::ValueEnum,
)]
#[serde(rename_all = "kebab-case")]
pub enum KindId {
    /// A project's `node_modules`.
    Node,
    /// A Cargo workspace's `target/`.
    CargoTarget,
    /// A Next.js project's `.next/`.
    Next,
    /// A Python project's `.venv/`.
    Venv,
    /// pnpm's global content-addressable store.
    PnpmStore,
    /// `$CARGO_HOME/registry` and `$CARGO_HOME/git`.
    CargoHome,
    /// Xcode's `DerivedData`.
    XcodeDerivedData,
    /// Gradle's caches and wrapper distributions.
    GradleHome,
    /// Go's module and build caches.
    Go,
    /// npm, yarn and bun global caches.
    JsCaches,
    /// Packages `npx` has downloaded to run.
    Npx,
    /// Hugging Face downloaded models.
    Huggingface,
}

impl KindId {
    /// Every kind, in display order.
    pub const ALL: [Self; 12] = [
        Self::Node,
        Self::CargoTarget,
        Self::Next,
        Self::Venv,
        Self::PnpmStore,
        Self::CargoHome,
        Self::XcodeDerivedData,
        Self::GradleHome,
        Self::Go,
        Self::JsCaches,
        Self::Npx,
        Self::Huggingface,
    ];

    /// The declarative description of this kind.
    #[must_use]
    pub const fn spec(self) -> &'static KindSpec {
        match self {
            Self::Node => &NODE,
            Self::CargoTarget => &CARGO_TARGET,
            Self::Next => &NEXT,
            Self::Venv => &VENV,
            Self::PnpmStore => &PNPM_STORE,
            Self::CargoHome => &CARGO_HOME,
            Self::XcodeDerivedData => &XCODE_DERIVED_DATA,
            Self::GradleHome => &GRADLE_HOME,
            Self::Go => &GO,
            Self::JsCaches => &JS_CACHES,
            Self::Npx => &NPX,
            Self::Huggingface => &HUGGINGFACE,
        }
    }

    /// The kebab-case name used in config files and the CLI.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        self.spec().name
    }

    /// Parses the kebab-case name.
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.as_str() == s)
    }

    /// The project kind whose managed folder has this name, e.g. `node_modules`.
    #[must_use]
    pub fn for_folder_name(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|k| matches!(k.spec().scope, Scope::Project { dir_name, .. } if dir_name == name))
    }
}

impl std::fmt::Display for KindId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// What to do with a non-empty local fallback folder when the drive comes back (spec §4.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReconnectPolicy {
    /// Local replaces the image if it contains one of these "install finished" markers;
    /// otherwise local is discarded.
    LocalWinsIfComplete(&'static [&'static str]),
    /// Local files are copied over the image's, and the image's other files are kept. For build
    /// folders whose build records stay local (spec §4.11): everything built while the drive was
    /// away is kept, so no record points at an output that's gone.
    MergeLocalWins,
    /// Files missing from the image are copied in; nothing in the image is overwritten.
    MergeNoClobber,
}

/// Whether a kind lives inside projects or is a single machine-wide folder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// One folder per project, found by scanning the roots.
    Project {
        /// The managed folder's name, e.g. `node_modules`.
        dir_name: &'static str,
        /// A file that must sit next to it, e.g. `package.json`.
        manifest: &'static str,
        /// Files next to the manifest that allow pre-adopting a folder that doesn't exist yet.
        lockfiles: &'static [&'static str],
        /// A file that must exist inside an existing folder before it's adopted.
        required_marker: Option<&'static str>,
    },
    /// Machine-wide caches at locations resolved during `init`.
    Global,
}

/// How a container of build output is stowed one part at a time, leaving its products (the
/// programs and apps you run) on this Mac (spec §4.11).
#[derive(Debug)]
pub struct Split {
    /// Folder names the parts end with. A managed folder with any other name is a whole
    /// container, as adopted before containers were split.
    pub part_names: &'static [&'static str],
    /// Finds a container's existing parts.
    pub find_parts: fn(&Path) -> Vec<PathBuf>,
    /// Parts to pre-adopt in a container that doesn't exist yet, relative to it: where the
    /// first build puts most of its output.
    pub pre_adopt: &'static [&'static str],
}

impl Split {
    fn is_part(&self, path: &Path) -> bool {
        path.file_name()
            .is_some_and(|n| self.part_names.iter().any(|p| n == *p))
    }
}

/// The declarative description of a kind.
#[derive(Debug)]
pub struct KindSpec {
    /// The kebab-case name used in config files and the CLI.
    pub name: &'static str,
    /// Human-readable name.
    pub label: &'static str,
    /// One sentence saying what the folder holds, for the folders window.
    pub description: &'static str,
    /// Project or global.
    pub scope: Scope,
    /// Reconnect behavior.
    pub policy: ReconnectPolicy,
    /// Hold Cargo's package-cache lock while changing this kind.
    pub cargo_package_lock: bool,
    /// Set for a container that's stowed one part at a time.
    pub split: Option<Split>,
}

const NODE_MARKERS: &[&str] = &[
    ".package-lock.json",
    ".modules.yaml",
    ".yarn-state.yml",
    ".yarn-integrity",
];

static NODE: KindSpec = KindSpec {
    name: "node",
    label: "node_modules",
    description: "A project's installed packages.",
    scope: Scope::Project {
        dir_name: "node_modules",
        manifest: "package.json",
        lockfiles: &[
            "package-lock.json",
            "yarn.lock",
            "pnpm-lock.yaml",
            "bun.lock",
            "bun.lockb",
        ],
        required_marker: None,
    },
    policy: ReconnectPolicy::LocalWinsIfComplete(NODE_MARKERS),
    cargo_package_lock: false,
    split: None,
};

static CARGO_TARGET: KindSpec = KindSpec {
    name: "cargo-target",
    label: "Cargo build files",
    description: "Compiled dependencies and caches from a Cargo build. The programs it builds stay on this Mac.",
    scope: Scope::Project {
        dir_name: "target",
        manifest: "Cargo.toml",
        lockfiles: &["Cargo.lock"],
        required_marker: Some("CACHEDIR.TAG"),
    },
    policy: ReconnectPolicy::MergeLocalWins,
    cargo_package_lock: false,
    split: Some(Split {
        part_names: CARGO_PARTS,
        find_parts: cargo_parts,
        pre_adopt: &["debug/deps", "debug/incremental"],
    }),
};

static NEXT: KindSpec = KindSpec {
    name: "next",
    label: "Next.js build files",
    description: "A Next.js project's build output and build cache.",
    scope: Scope::Project {
        dir_name: ".next",
        manifest: "package.json",
        lockfiles: &[
            "next.config.js",
            "next.config.mjs",
            "next.config.cjs",
            "next.config.ts",
            "next.config.mts",
        ],
        required_marker: None,
    },
    // A production build made while the drive was away is kept; a dev-server cache isn't.
    policy: ReconnectPolicy::LocalWinsIfComplete(&["BUILD_ID"]),
    cargo_package_lock: false,
    split: None,
};

static VENV: KindSpec = KindSpec {
    name: "venv",
    label: "Python virtualenv",
    description: "A Python project's virtual environment and installed packages.",
    scope: Scope::Project {
        dir_name: ".venv",
        manifest: "pyproject.toml",
        // Never pre-adopted: uv refuses to create a venv in a folder that isn't empty, and a
        // mounted image always holds volume metadata.
        lockfiles: &[],
        required_marker: Some("pyvenv.cfg"),
    },
    policy: ReconnectPolicy::LocalWinsIfComplete(&["pyvenv.cfg"]),
    cargo_package_lock: false,
    split: None,
};

static PNPM_STORE: KindSpec = KindSpec {
    name: "pnpm-store",
    label: "pnpm store",
    description: "Packages pnpm shares between all your projects.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: false,
    split: None,
};

static CARGO_HOME: KindSpec = KindSpec {
    name: "cargo-home",
    label: "Cargo registry",
    description: "Crates and git dependencies Cargo has downloaded.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: true,
    split: None,
};

static XCODE_DERIVED_DATA: KindSpec = KindSpec {
    name: "xcode-derived-data",
    label: "Xcode DerivedData",
    description: "Xcode's build intermediates and indexes. Built apps stay on this Mac.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeLocalWins,
    cargo_package_lock: false,
    split: Some(Split {
        part_names: &[
            "Intermediates.noindex",
            "Index.noindex",
            "SourcePackages",
            "ModuleCache.noindex",
        ],
        find_parts: xcode_parts,
        pre_adopt: &[],
    }),
};

static GRADLE_HOME: KindSpec = KindSpec {
    name: "gradle-home",
    label: "Gradle caches",
    description: "Downloaded dependencies and Gradle versions.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: false,
    split: None,
};

static GO: KindSpec = KindSpec {
    name: "go",
    label: "Go caches",
    description: "Downloaded modules and Go's build cache.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: false,
    split: None,
};

static JS_CACHES: KindSpec = KindSpec {
    name: "js-caches",
    label: "npm/yarn/bun caches",
    description: "Download caches for npm, Yarn and bun.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: false,
    split: None,
};

static NPX: KindSpec = KindSpec {
    name: "npx",
    label: "npx packages",
    description: "Packages npx has downloaded to run.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: false,
    split: None,
};

static HUGGINGFACE: KindSpec = KindSpec {
    name: "huggingface",
    label: "Hugging Face models",
    description: "Models downloaded from Hugging Face.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: false,
    split: None,
};

/// Subfolders of a Cargo profile folder (`target/debug`, `target/release`, ...) that hold build
/// intermediates. `.fingerprint` stays local: Cargo rebuilds anything whose outputs are missing
/// or older than their inputs, so it doesn't need to travel with them.
const CARGO_PARTS: &[&str] = &["deps", "incremental", "build"];
/// Subfolders of an Xcode project's `DerivedData` folder that hold intermediates and caches;
/// `Build/Products` (the built apps) stays local.
const XCODE_PROJECT_PARTS: &[&str] = &[
    "Build/Intermediates.noindex",
    "Index.noindex",
    "SourcePackages",
];
/// `DerivedData`'s own shared cache.
const XCODE_SHARED_PARTS: &[&str] = &["ModuleCache.noindex"];

/// The folders to manage for a `kind` folder at `path`.
///
/// That's the folder itself, or, for a container that splits, its parts (spec §4.11). A
/// container that doesn't exist yet gets the parts its first build fills.
#[must_use]
pub fn managed_folders(kind: KindId, path: &Path) -> Vec<PathBuf> {
    match &kind.spec().split {
        Some(split) if !split.is_part(path) => {
            if is_real_dir(path) {
                (split.find_parts)(path)
            } else {
                split.pre_adopt.iter().map(|p| path.join(p)).collect()
            }
        }
        _ => vec![path.to_path_buf()],
    }
}

/// Whether `path`, managed as `kind`, is one part of a container that splits.
#[must_use]
pub fn is_part(kind: KindId, path: &Path) -> bool {
    kind.spec()
        .split
        .as_ref()
        .is_some_and(|split| split.is_part(path))
}

/// Whether `path`, managed as `kind`, is a whole container of a kind that splits rather than one
/// of its parts. Whole containers were adopted before splitting existed and are converted.
#[must_use]
pub fn is_container(kind: KindId, path: &Path) -> bool {
    kind.spec()
        .split
        .as_ref()
        .is_some_and(|split| !split.is_part(path))
}

/// The project folder that a project-scoped managed folder belongs to: the folder holding
/// `node_modules`, or holding the `target/` a part sits in. `None` for global kinds.
#[must_use]
pub fn project_dir(kind: KindId, path: &Path) -> Option<&Path> {
    let Scope::Project { dir_name, .. } = kind.spec().scope else {
        return None;
    };
    path.ancestors()
        .find(|a| a.file_name().is_some_and(|n| n == dir_name))
        .and_then(Path::parent)
}

/// Whether a file or folder named `name` can change what discovery finds: some project kind's
/// folder, manifest, lockfile or marker.
#[must_use]
pub fn affects_discovery(name: &str) -> bool {
    KindId::ALL.into_iter().any(|kind| match kind.spec().scope {
        Scope::Project {
            dir_name,
            manifest,
            lockfiles,
            required_marker,
        } => {
            name == dir_name
                || name == manifest
                || lockfiles.contains(&name)
                || required_marker == Some(name)
        }
        Scope::Global => false,
    })
}

/// The build folders in every Cargo profile folder: any folder with a `deps/` inside, found up
/// to two levels below `target/` so cross-compile (`target/<triple>/release`) and tool-specific
/// target folders (`target/rust-analyzer/debug`) count too.
fn cargo_parts(target: &Path) -> Vec<PathBuf> {
    fn profiles(dir: &Path, depth: usize, found: &mut Vec<PathBuf>) {
        for child in subdirs(dir) {
            if child.join("deps").is_dir() {
                found.push(child);
            } else if depth < 2 {
                profiles(&child, depth + 1, found);
            }
        }
    }
    let mut found = Vec::new();
    profiles(target, 0, &mut found);
    found
        .iter()
        .flat_map(|profile| existing(profile, CARGO_PARTS))
        .collect()
}

/// `DerivedData`'s shared module cache, plus each project's intermediates, index and packages.
fn xcode_parts(derived_data: &Path) -> Vec<PathBuf> {
    let mut parts = existing(derived_data, XCODE_SHARED_PARTS);
    for project in subdirs(derived_data) {
        if !XCODE_SHARED_PARTS.iter().any(|p| project.ends_with(p)) {
            parts.extend(existing(&project, XCODE_PROJECT_PARTS));
        }
    }
    parts
}

/// Whether `path` is a folder and not a symlink to one.
#[must_use]
pub fn is_real_dir(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|m| m.is_dir())
}

/// Real (non-symlink) subfolders, skipping hidden ones.
pub(crate) fn subdirs(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut dirs: Vec<PathBuf> = entries
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
        .map(|e| e.path())
        .collect();
    dirs.sort();
    dirs
}

fn existing(dir: &Path, names: &[&str]) -> Vec<PathBuf> {
    names
        .iter()
        .map(|name| dir.join(name))
        .filter(|p| p.is_dir())
        .collect()
}

/// Looks up environment variables and runs tool queries while resolving global cache locations.
pub trait Environment {
    /// An environment variable.
    fn var(&self, name: &str) -> Option<String>;
    /// Runs a tool and returns its trimmed stdout, or `None` if it isn't installed or fails.
    fn query(&self, program: &str, args: &[&str]) -> Option<String>;
}

/// The real process environment.
#[derive(Debug, Default, Clone, Copy)]
pub struct ProcessEnvironment;

impl Environment for ProcessEnvironment {
    fn var(&self, name: &str) -> Option<String> {
        std::env::var(name).ok().filter(|v| !v.is_empty())
    }

    fn query(&self, program: &str, args: &[&str]) -> Option<String> {
        crate::cmd::run_string(program, args)
            .ok()
            .filter(|s| !s.is_empty())
    }
}

/// Candidate locations for a global kind, existing or not. `init` keeps those that exist.
#[must_use]
pub fn global_locations(kind: KindId, home: &Path, env: &dyn Environment) -> Vec<PathBuf> {
    let from_var = |name: &str, default: &str| {
        env.var(name)
            .map_or_else(|| home.join(default), PathBuf::from)
    };
    match kind {
        KindId::Node | KindId::CargoTarget | KindId::Next | KindId::Venv => Vec::new(),
        KindId::PnpmStore => {
            let store = env
                .query("pnpm", &["store", "path"])
                .map(PathBuf::from)
                .map_or_else(
                    || home.join("Library/pnpm/store"),
                    |p| unversioned_pnpm_store(&p),
                );
            vec![store]
        }
        KindId::CargoHome => {
            let cargo_home = from_var("CARGO_HOME", ".cargo");
            vec![cargo_home.join("registry"), cargo_home.join("git")]
        }
        KindId::XcodeDerivedData => {
            let custom = env.query(
                "defaults",
                &["read", "com.apple.dt.Xcode", "IDECustomDerivedDataLocation"],
            );
            vec![custom.map_or_else(
                || home.join("Library/Developer/Xcode/DerivedData"),
                PathBuf::from,
            )]
        }
        KindId::GradleHome => {
            let gradle = from_var("GRADLE_USER_HOME", ".gradle");
            vec![gradle.join("caches"), gradle.join("wrapper/dists")]
        }
        KindId::Go => {
            let modcache = env
                .query("go", &["env", "GOMODCACHE"])
                .map_or_else(|| home.join("go/pkg/mod"), PathBuf::from);
            let buildcache = env
                .query("go", &["env", "GOCACHE"])
                .map_or_else(|| home.join("Library/Caches/go-build"), PathBuf::from);
            vec![modcache, buildcache]
        }
        KindId::JsCaches => vec![
            home.join(".npm/_cacache"),
            home.join("Library/Caches/Yarn"),
            home.join(".yarn/berry/cache"),
            home.join(".bun/install/cache"),
        ],
        KindId::Npx => vec![home.join(".npm/_npx")],
        KindId::Huggingface => {
            let hf_home = from_var("HF_HOME", ".cache/huggingface");
            vec![hf_home.join("hub")]
        }
    }
}

/// `pnpm store path` returns `.../store/v10`; different pnpm versions share the parent.
fn unversioned_pnpm_store(path: &Path) -> PathBuf {
    let versioned = path.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
        n.len() > 1 && n.starts_with('v') && n[1..].chars().all(|c| c.is_ascii_digit())
    });
    if versioned {
        path.parent()
            .map_or_else(|| path.to_path_buf(), Path::to_path_buf)
    } else {
        path.to_path_buf()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    struct FakeEnv {
        vars: HashMap<&'static str, &'static str>,
        queries: HashMap<&'static str, &'static str>,
    }

    impl Environment for FakeEnv {
        fn var(&self, name: &str) -> Option<String> {
            self.vars.get(name).map(|s| (*s).to_owned())
        }
        fn query(&self, program: &str, args: &[&str]) -> Option<String> {
            let key = format!("{program} {}", args.join(" "));
            self.queries.get(key.as_str()).map(|s| (*s).to_owned())
        }
    }

    fn empty_env() -> FakeEnv {
        FakeEnv {
            vars: HashMap::new(),
            queries: HashMap::new(),
        }
    }

    #[test]
    fn names_round_trip() {
        for kind in KindId::ALL {
            assert_eq!(KindId::parse(kind.as_str()), Some(kind));
            let json = serde_json::to_string(&kind).unwrap();
            assert_eq!(json, format!("\"{}\"", kind.as_str()));
        }
    }

    #[test]
    fn pnpm_store_drops_version_folder() {
        let env = FakeEnv {
            vars: HashMap::new(),
            queries: HashMap::from([("pnpm store path", "/Users/me/Library/pnpm/store/v10")]),
        };
        assert_eq!(
            global_locations(KindId::PnpmStore, Path::new("/Users/me"), &env),
            vec![PathBuf::from("/Users/me/Library/pnpm/store")]
        );
    }

    #[test]
    fn cargo_home_respects_env() {
        let env = FakeEnv {
            vars: HashMap::from([("CARGO_HOME", "/opt/cargo")]),
            queries: HashMap::new(),
        };
        assert_eq!(
            global_locations(KindId::CargoHome, Path::new("/Users/me"), &env),
            vec![
                PathBuf::from("/opt/cargo/registry"),
                PathBuf::from("/opt/cargo/git")
            ]
        );
    }

    fn mkdirs(root: &Path, dirs: &[&str]) {
        for dir in dirs {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
    }

    fn relative(root: &Path, paths: &[PathBuf]) -> Vec<String> {
        paths
            .iter()
            .map(|p| p.strip_prefix(root).unwrap().display().to_string())
            .collect()
    }

    #[test]
    fn cargo_parts_are_intermediates_in_every_profile() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target");
        mkdirs(
            &target,
            &[
                "debug/deps",
                "debug/incremental",
                "debug/build",
                "debug/.fingerprint",
                "debug/examples",
                "release/deps",
                "release/build",
                "aarch64-apple-darwin/release/deps",
                "rust-analyzer/debug/deps",
                "doc/arbvark",
                "tmp",
            ],
        );
        std::fs::write(target.join("debug/arbvark"), "binary").unwrap();
        assert_eq!(
            relative(dir.path(), &managed_folders(KindId::CargoTarget, &target)),
            vec![
                "target/aarch64-apple-darwin/release/deps",
                "target/debug/deps",
                "target/debug/incremental",
                "target/debug/build",
                "target/release/deps",
                "target/release/build",
                "target/rust-analyzer/debug/deps",
            ]
        );
    }

    #[test]
    fn xcode_parts_leave_products_local() {
        let dir = tempfile::tempdir().unwrap();
        let dd = dir.path().join("DerivedData");
        mkdirs(
            &dd,
            &[
                "ModuleCache.noindex",
                "App-abc/Build/Intermediates.noindex",
                "App-abc/Build/Products/Debug",
                "App-abc/Index.noindex",
                "App-abc/SourcePackages",
            ],
        );
        assert_eq!(
            relative(dir.path(), &managed_folders(KindId::XcodeDerivedData, &dd)),
            vec![
                "DerivedData/ModuleCache.noindex",
                "DerivedData/App-abc/Build/Intermediates.noindex",
                "DerivedData/App-abc/Index.noindex",
                "DerivedData/App-abc/SourcePackages",
            ]
        );
    }

    #[test]
    fn containers_and_projects() {
        let part = Path::new("/code/app/target/debug/deps");
        let whole = Path::new("/code/app/target");
        assert!(is_container(KindId::CargoTarget, whole));
        assert!(!is_container(KindId::CargoTarget, part));
        assert!(!is_container(
            KindId::Node,
            Path::new("/code/web/node_modules")
        ));
        assert_eq!(managed_folders(KindId::CargoTarget, part), vec![part]);
        assert_eq!(
            managed_folders(KindId::CargoTarget, Path::new("/nonexistent/target")),
            vec![
                PathBuf::from("/nonexistent/target/debug/deps"),
                PathBuf::from("/nonexistent/target/debug/incremental")
            ]
        );
        assert_eq!(
            project_dir(KindId::CargoTarget, part),
            Some(Path::new("/code/app"))
        );
        assert_eq!(
            project_dir(KindId::CargoTarget, whole),
            Some(Path::new("/code/app"))
        );
        assert_eq!(
            project_dir(KindId::Node, Path::new("/code/web/node_modules")),
            Some(Path::new("/code/web"))
        );
        assert_eq!(
            project_dir(KindId::CargoHome, Path::new("/x/registry")),
            None
        );
        let dd = Path::new("/Users/me/Library/Developer/Xcode/DerivedData");
        assert!(is_container(KindId::XcodeDerivedData, dd));
        assert!(!is_container(
            KindId::XcodeDerivedData,
            &dd.join("App-abc/Index.noindex")
        ));
    }

    #[test]
    fn folder_names_identify_kinds() {
        assert_eq!(KindId::for_folder_name("target"), Some(KindId::CargoTarget));
        assert_eq!(KindId::for_folder_name(".venv"), Some(KindId::Venv));
        assert_eq!(KindId::for_folder_name("registry"), None);
        for name in [
            "node_modules",
            "yarn.lock",
            "CACHEDIR.TAG",
            "next.config.ts",
            "pyvenv.cfg",
        ] {
            assert!(affects_discovery(name), "{name}");
        }
        assert!(!affects_discovery("README.md"));
    }

    #[test]
    fn defaults_without_tools() {
        let home = Path::new("/Users/me");
        assert_eq!(
            global_locations(KindId::Huggingface, home, &empty_env()),
            vec![PathBuf::from("/Users/me/.cache/huggingface/hub")]
        );
        assert_eq!(
            global_locations(KindId::Go, home, &empty_env()),
            vec![
                PathBuf::from("/Users/me/go/pkg/mod"),
                PathBuf::from("/Users/me/Library/Caches/go-build")
            ]
        );
        assert!(global_locations(KindId::Node, home, &empty_env()).is_empty());
    }
}
