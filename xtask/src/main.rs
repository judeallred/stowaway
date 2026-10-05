//! Developer tasks: `cargo xtask ci`, `cargo xtask install-hooks`, `cargo xtask ipc-schema`.
#![forbid(unsafe_code)]
#![expect(
    clippy::print_stderr,
    reason = "xtask is an interactive developer tool that reports progress on stderr"
)]

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let root = workspace_root();
    let result = match args.first().map(String::as_str) {
        Some("ci") => ci(&root),
        Some("install-hooks") => install_hooks(&root),
        Some("ipc-schema") => ipc_schema(&root, args.iter().any(|a| a == "--check")),
        _ => {
            eprintln!("usage: cargo xtask <ci | install-hooks | ipc-schema [--check]>");
            Err("unknown task".to_owned())
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("xtask: {message}");
            ExitCode::FAILURE
        }
    }
}

fn workspace_root() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .map_or_else(|| manifest_dir.clone(), Path::to_path_buf)
}

fn run(root: &Path, program: &str, args: &[&str], envs: &[(&str, &str)]) -> Result<(), String> {
    eprintln!("$ {program} {}", args.join(" "));
    let status = Command::new(program)
        .args(args)
        .envs(envs.iter().copied())
        .current_dir(root)
        .status()
        .map_err(|e| format!("failed to start {program}: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{program} {} failed ({status})", args.join(" ")))
    }
}

fn has_cargo_subcommand(name: &str) -> bool {
    Command::new("cargo")
        .args([name, "--version"])
        .output()
        .is_ok_and(|o| o.status.success())
}

fn ci(root: &Path) -> Result<(), String> {
    let strict = [("RUSTFLAGS", "-D warnings")];
    run(root, "cargo", &["fmt", "--all", "--check"], &[])?;
    run(
        root,
        "cargo",
        &[
            "clippy",
            "--workspace",
            "--all-targets",
            "--all-features",
            "--locked",
            "--",
            "-D",
            "warnings",
        ],
        &[],
    )?;
    if has_cargo_subcommand("nextest") {
        run(
            root,
            "cargo",
            &[
                "nextest",
                "run",
                "--workspace",
                "--all-features",
                "--locked",
            ],
            &strict,
        )?;
    } else {
        eprintln!("note: cargo-nextest not installed; falling back to cargo test");
        run(
            root,
            "cargo",
            &["test", "--workspace", "--all-features", "--locked"],
            &strict,
        )?;
    }
    run(
        root,
        "cargo",
        &["test", "--workspace", "--doc", "--locked"],
        &strict,
    )?;
    run(
        root,
        "cargo",
        &["doc", "--workspace", "--no-deps", "--locked"],
        &[("RUSTDOCFLAGS", "-D warnings")],
    )?;
    for (tool, args) in [
        ("deny", &["deny", "check"][..]),
        ("machete", &["machete"][..]),
    ] {
        if has_cargo_subcommand(tool) {
            run(root, "cargo", args, &[])?;
        } else {
            eprintln!("note: cargo-{tool} not installed; CI will still run it");
        }
    }
    if root.join("macos-app/Package.swift").exists() {
        run(
            root,
            "xcrun",
            &[
                "swift-format",
                "lint",
                "--strict",
                "--recursive",
                "macos-app",
            ],
            &[],
        )?;
        ipc_schema(root, true)?;
        run(
            root,
            "swift",
            &[
                "test",
                "--package-path",
                "macos-app",
                "-Xswiftc",
                "-warnings-as-errors",
            ],
            &[],
        )?;
    }
    eprintln!("all checks passed");
    Ok(())
}

fn install_hooks(root: &Path) -> Result<(), String> {
    run(root, "git", &["config", "core.hooksPath", ".githooks"], &[])?;
    eprintln!("git hooks enabled from .githooks/");
    Ok(())
}

fn ipc_schema(root: &Path, check: bool) -> Result<(), String> {
    let target = root.join("macos-app/Tests/StowawayKitTests/Fixtures/ipc-samples.json");
    let output = Command::new("cargo")
        .args([
            "run",
            "--quiet",
            "--locked",
            "-p",
            "stowaway",
            "--",
            "ipc-samples",
        ])
        .current_dir(root)
        .output()
        .map_err(|e| format!("failed to run stowaway ipc-samples: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "stowaway ipc-samples failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    if check {
        let existing =
            std::fs::read(&target).map_err(|e| format!("cannot read {}: {e}", target.display()))?;
        if existing != output.stdout {
            return Err(format!(
                "{} is out of date; run `cargo xtask ipc-schema`",
                target.display()
            ));
        }
        eprintln!("IPC fixtures are up to date");
    } else {
        std::fs::write(&target, &output.stdout)
            .map_err(|e| format!("cannot write {}: {e}", target.display()))?;
        eprintln!("wrote {}", target.display());
    }
    Ok(())
}
