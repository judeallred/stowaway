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
    /// Hugging Face downloaded models.
    Huggingface,
}

impl KindId {
    /// Every kind, in display order.
    pub const ALL: [Self; 9] = [
        Self::Node,
        Self::CargoTarget,
        Self::PnpmStore,
        Self::CargoHome,
        Self::XcodeDerivedData,
        Self::GradleHome,
        Self::Go,
        Self::JsCaches,
        Self::Huggingface,
    ];

    /// The declarative description of this kind.
    #[must_use]
    pub const fn spec(self) -> &'static KindSpec {
        match self {
            Self::Node => &NODE,
            Self::CargoTarget => &CARGO_TARGET,
            Self::PnpmStore => &PNPM_STORE,
            Self::CargoHome => &CARGO_HOME,
            Self::XcodeDerivedData => &XCODE_DERIVED_DATA,
            Self::GradleHome => &GRADLE_HOME,
            Self::Go => &GO,
            Self::JsCaches => &JS_CACHES,
            Self::Huggingface => &HUGGINGFACE,
        }
    }

    /// The kebab-case name used in config files and the CLI.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Node => "node",
            Self::CargoTarget => "cargo-target",
            Self::PnpmStore => "pnpm-store",
            Self::CargoHome => "cargo-home",
            Self::XcodeDerivedData => "xcode-derived-data",
            Self::GradleHome => "gradle-home",
            Self::Go => "go",
            Self::JsCaches => "js-caches",
            Self::Huggingface => "huggingface",
        }
    }

    /// Parses the kebab-case name.
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.as_str() == s)
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
    /// Local is discarded; the image is kept.
    ExternalWins,
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

/// The declarative description of a kind.
#[derive(Debug)]
pub struct KindSpec {
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
}

const NODE_MARKERS: &[&str] = &[
    ".package-lock.json",
    ".modules.yaml",
    ".yarn-state.yml",
    ".yarn-integrity",
];

static NODE: KindSpec = KindSpec {
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
};

static CARGO_TARGET: KindSpec = KindSpec {
    label: "Cargo target",
    description: "A Cargo workspace's build output.",
    scope: Scope::Project {
        dir_name: "target",
        manifest: "Cargo.toml",
        lockfiles: &["Cargo.lock"],
        required_marker: Some("CACHEDIR.TAG"),
    },
    policy: ReconnectPolicy::ExternalWins,
    cargo_package_lock: false,
};

static PNPM_STORE: KindSpec = KindSpec {
    label: "pnpm store",
    description: "Packages pnpm shares between all your projects.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: false,
};

static CARGO_HOME: KindSpec = KindSpec {
    label: "Cargo registry",
    description: "Crates and git dependencies Cargo has downloaded.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: true,
};

static XCODE_DERIVED_DATA: KindSpec = KindSpec {
    label: "Xcode DerivedData",
    description: "Xcode's build products and indexes.",
    scope: Scope::Global,
    policy: ReconnectPolicy::ExternalWins,
    cargo_package_lock: false,
};

static GRADLE_HOME: KindSpec = KindSpec {
    label: "Gradle caches",
    description: "Downloaded dependencies and Gradle versions.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: false,
};

static GO: KindSpec = KindSpec {
    label: "Go caches",
    description: "Downloaded modules and Go's build cache.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: false,
};

static JS_CACHES: KindSpec = KindSpec {
    label: "npm/yarn/bun caches",
    description: "Download caches for npm, Yarn and bun.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: false,
};

static HUGGINGFACE: KindSpec = KindSpec {
    label: "Hugging Face models",
    description: "Models downloaded from Hugging Face.",
    scope: Scope::Global,
    policy: ReconnectPolicy::MergeNoClobber,
    cargo_package_lock: false,
};

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
        KindId::Node | KindId::CargoTarget => Vec::new(),
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
