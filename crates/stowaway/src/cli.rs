//! The `stowaway` command line. This module is where output is printed.
#![expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "the CLI's job is to print; all user-facing output goes through this module"
)]

use std::io::{BufRead, IsTerminal};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use clap::{Parser, Subcommand};

use crate::config::{Config, TransferPriority, Usage};
use crate::engine::{self, AdoptOptions, Engine, EngineLock};
use crate::error::{Error, IoContext, Result};
use crate::ipc::{self, Call};
use crate::kinds::{self, KindId};
use crate::paths::Layout;
use crate::report::{self, format_bytes};
use crate::status::{self, StatusReport};
use crate::{agent, bugreport, launchd, ops};

/// Keep dependency and build caches on an external drive, with automatic local fallback.
#[derive(Debug, Parser)]
#[command(name = "stowaway", version, about, long_about = None)]
pub struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Set up Stowaway with an external drive and folders of projects to watch.
    Init {
        /// The external drive's mount point, e.g. /Volumes/FastSSD.
        #[arg(long)]
        volume: PathBuf,
        /// A folder of projects to watch, e.g. ~/code. Repeat for more.
        #[arg(long = "root", required = true)]
        roots: Vec<PathBuf>,
        /// Personal or work use (asked interactively if omitted).
        #[arg(long, value_enum)]
        usage: Option<Usage>,
        /// Don't install the background agent.
        #[arg(long)]
        no_agent: bool,
    },
    /// Show what's offloaded, the drive's state and performance.
    Status {
        /// Print JSON.
        #[arg(long)]
        json: bool,
    },
    /// Run the drive speed test against the internal disk and the external drive.
    Bench {
        /// Print JSON.
        #[arg(long)]
        json: bool,
        /// A smaller, faster test.
        #[arg(long)]
        quick: bool,
    },
    /// Discover folders to manage and adopt them now.
    Scan {
        /// Only list what would be adopted.
        #[arg(long)]
        dry_run: bool,
    },
    /// Manage a specific folder now (skips the idle and size checks).
    Adopt {
        /// The folder, e.g. `./node_modules`.
        path: PathBuf,
        /// Its kind; inferred from the folder name when possible.
        #[arg(long, value_enum)]
        kind: Option<KindId>,
    },
    /// Turn a managed folder back into a plain local folder.
    Release {
        /// The folder.
        path: PathBuf,
        /// Copy its contents back instead of leaving it empty to be rebuilt.
        #[arg(long)]
        copy: bool,
    },
    /// Empty managed folders under a path (use instead of `rm -rf node_modules`).
    Clean {
        /// Where to clean; defaults to the current folder.
        path: Option<PathBuf>,
    },
    /// Rebuild bloated images to reclaim space on the drive.
    Compact {
        /// Limit to folders under this path.
        path: Option<PathBuf>,
        /// Rebuild even if not bloated.
        #[arg(long)]
        force: bool,
    },
    /// Check for problems; with --fix, repair what can be repaired.
    Doctor {
        /// Reconcile mounts and retry failed entries.
        #[arg(long)]
        fix: bool,
    },
    /// Delete images whose projects are gone.
    Gc {
        /// Only list what would be deleted.
        #[arg(long)]
        dry_run: bool,
    },
    /// List, add or remove watched folders.
    Roots {
        #[command(subcommand)]
        action: RootsAction,
    },
    /// Detach all images and eject the drive.
    Eject,
    /// Make every managed folder a plain local folder again, without copying anything back.
    /// The folders are empty until rebuilt; everything stays on the drive until `attach`.
    Detach,
    /// Attach the drive's folders again after `detach`.
    Attach,
    /// Stop adopting new folders (drive handling continues).
    Pause,
    /// Resume adopting new folders.
    Resume,
    /// Show or set offload transfer priority: background pauses transfers while your disk is busy,
    /// normal doesn't.
    Priority {
        /// The new priority; omit to show the current one.
        #[arg(value_enum)]
        priority: Option<TransferPriority>,
    },
    /// Run or manage the background agent.
    Agent {
        #[command(subcommand)]
        action: Option<AgentAction>,
    },
    /// Return every folder to normal, delete the images and remove the agent.
    Uninstall {
        /// Copy contents back to the Mac instead of leaving folders empty.
        #[arg(long)]
        copy: bool,
    },
    /// Record personal or work use, or a purchased license.
    License {
        #[command(subcommand)]
        action: LicenseAction,
    },
    /// Open a new GitHub issue with diagnostics filled in, to review and submit.
    BugReport {
        /// Print the report instead of opening GitHub.
        #[arg(long)]
        print: bool,
    },
    /// Print sample IPC messages (used to test the menu bar app).
    #[command(hide = true)]
    IpcSamples,
}

#[derive(Debug, Subcommand)]
enum RootsAction {
    /// List watched folders.
    List,
    /// Add a watched folder.
    Add {
        /// The folder.
        path: PathBuf,
        /// Only preview what would be offloaded.
        #[arg(long)]
        dry_run: bool,
    },
    /// Stop watching a folder and release its managed folders.
    Remove {
        /// The folder.
        path: PathBuf,
        /// Copy contents back to the Mac.
        #[arg(long)]
        copy: bool,
    },
}

#[derive(Debug, Subcommand)]
enum AgentAction {
    /// Run in the foreground (this is what launchd runs).
    Run,
    /// Install and start the launchd service.
    Install,
    /// Start the installed agent; it reattaches the images.
    Start,
    /// Detach every image, so folders use their local contents, and stop the agent until it's
    /// started again.
    Stop,
    /// Stop and remove the launchd service.
    Uninstall,
}

#[derive(Debug, Subcommand)]
enum LicenseAction {
    /// Show what's recorded.
    Show,
    /// You use Stowaway for personal or noncommercial work (free).
    Personal,
    /// You use Stowaway for work (a license is needed after the 30-day trial).
    Work,
    /// Record a purchased license.
    Purchased {
        /// Order ID from your receipt.
        #[arg(long)]
        order: String,
        /// Who the license is for, e.g. your company.
        #[arg(long)]
        licensee: Option<String>,
    },
}

/// Parses arguments and runs the command.
#[must_use]
pub fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli.command) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("stowaway: {e}");
            ExitCode::FAILURE
        }
    }
}

const LOCK_WAIT: Duration = Duration::from_secs(30);

fn locked_engine(layout: &Layout) -> Result<(EngineLock, Engine)> {
    let lock = EngineLock::acquire(layout, LOCK_WAIT)?;
    let mut engine = Engine::open(layout.clone())?;
    engine.set_observer(Some(std::sync::Arc::new(progress_printer)));
    Ok((lock, engine))
}

fn progress_printer(event: &engine::EngineEvent) {
    if !std::io::stderr().is_terminal() {
        return;
    }
    if let engine::EngineEvent::TransferProgress {
        path,
        bytes,
        total_bytes,
        elapsed_seconds,
        waiting_for_disk,
        step,
        ..
    } = event
    {
        if *step != engine::TransferStep::Copying {
            eprint!("\r\x1b[K  {}: {}…", path.display(), step.describe());
            return;
        }
        let rate = report::bytes_f64(*bytes) / 1_000_000.0 / elapsed_seconds.max(0.001);
        let speed = if *waiting_for_disk {
            "paused while the disk is busy".to_owned()
        } else {
            report::format_rate(rate)
        };
        eprint!(
            "\r\x1b[K  copying {} — {} of {} · {speed}",
            path.display(),
            format_bytes(*bytes),
            format_bytes(*total_bytes),
        );
    } else if matches!(
        event,
        engine::EngineEvent::TransferDone { .. } | engine::EngineEvent::TransferAborted { .. }
    ) {
        eprintln!();
    }
}

fn tell_agent(layout: &Layout) {
    let _ignored = ipc::call(&layout.socket_path(), Call::Refresh, Duration::from_secs(2));
}

#[expect(
    clippy::too_many_lines,
    reason = "a flat dispatch over subcommands reads best in one place"
)]
fn run(command: Command) -> Result<()> {
    let layout = Layout::from_env()?;
    match command {
        Command::Init {
            volume,
            roots,
            usage,
            no_agent,
        } => init(&layout, &volume, &roots, usage, no_agent),
        Command::Status { json } => {
            let report = fetch_status(&layout)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", report::status(&report));
                print_license_footer(&report);
            }
            Ok(())
        }
        Command::Bench { json, quick } => {
            let mut engine = Engine::open(layout)?;
            if !json {
                eprintln!("Running the speed test on your internal disk and the external drive…");
            }
            let bench = ops::bench(&mut engine, quick)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&bench)?);
            } else {
                print!("{}", report::bench_table(&bench));
            }
            Ok(())
        }
        Command::Scan { dry_run } => {
            let (_lock, mut engine) = locked_engine(&layout)?;
            if dry_run {
                for c in engine.discover()? {
                    let state = if c.exists { "adopt" } else { "pre-adopt" };
                    println!("{state:<10} {:<18} {}", c.kind.as_str(), c.path.display());
                }
                return Ok(());
            }
            engine.reconcile()?;
            for (candidate, outcome) in engine.auto_adopt()? {
                match outcome {
                    Ok(entry) => println!("adopted   {}", entry.path.display()),
                    Err(Error::Busy(why)) => {
                        println!("waiting   {} ({why})", candidate.path.display());
                    }
                    Err(e) => println!("skipped   {} ({e})", candidate.path.display()),
                }
            }
            tell_agent(&layout);
            Ok(())
        }
        Command::Adopt { path, kind } => {
            let (_lock, mut engine) = locked_engine(&layout)?;
            let path = layout.expand(&path);
            let kind = kind.map_or_else(|| infer_kind(&engine.config, &path), Ok)?;
            let opts = AdoptOptions { force: true };
            // A Cargo `target/` or DerivedData is stowed one build folder at a time, so the
            // programs it builds stay on this Mac.
            let paths = kinds::managed_folders(kind, &path);
            if paths.is_empty() {
                return Err(Error::Invalid(format!(
                    "{} has no build folders yet; build once, then try again",
                    path.display()
                )));
            }
            for path in paths {
                let entry = engine.adopt(&path, kind, opts)?;
                println!(
                    "{} is now stored on the drive ({}).",
                    entry.path.display(),
                    format_bytes(entry.used_bytes)
                );
            }
            tell_agent(&layout);
            Ok(())
        }
        Command::Release { path, copy } => {
            let (_lock, mut engine) = locked_engine(&layout)?;
            let path = layout.expand(&path);
            engine.release(&path, copy)?;
            println!("{} is a plain local folder again.", path.display());
            tell_agent(&layout);
            Ok(())
        }
        Command::Clean { path } => {
            let (_lock, mut engine) = locked_engine(&layout)?;
            let path = layout.expand(&path.unwrap_or_else(|| PathBuf::from(".")));
            let cleaned = engine.clean(&path)?;
            if cleaned.is_empty() {
                println!("No managed folders under {}.", path.display());
            }
            for p in cleaned {
                println!("emptied {}", p.display());
            }
            Ok(())
        }
        Command::Compact { path, force } => {
            let (_lock, mut engine) = locked_engine(&layout)?;
            let path = path.map(|p| layout.expand(&p));
            let reclaimed = engine.compact(path.as_deref(), force)?;
            println!("Reclaimed {} on the drive.", format_bytes(reclaimed));
            Ok(())
        }
        Command::BugReport { print } => bug_report(&layout, print),
        Command::Doctor { fix } => {
            let (_lock, mut engine) = locked_engine(&layout)?;
            let problems = ops::doctor(&mut engine, fix)?;
            if !ipc::agent_running(&layout.socket_path()) {
                println!("• The background agent isn't running.\n  → run `stowaway agent install`");
            }
            if problems.is_empty() {
                println!("No problems found.");
            }
            for p in problems {
                println!("• {}", p.message);
                if let Some(hint) = p.hint {
                    println!("  → {hint}");
                }
            }
            tell_agent(&layout);
            Ok(())
        }
        Command::Gc { dry_run } => {
            let (_lock, mut engine) = locked_engine(&layout)?;
            let removed = engine.gc(dry_run)?;
            let verb = if dry_run { "would delete" } else { "deleted" };
            if removed.is_empty() {
                println!("Nothing to clean up.");
            }
            for p in removed {
                println!("{verb} {}", p.display());
            }
            Ok(())
        }
        Command::Roots { action } => roots(&layout, action),
        Command::Eject => {
            if ipc::agent_running(&layout.socket_path()) {
                ipc::call(&layout.socket_path(), Call::Eject, Duration::from_secs(120))?;
            } else {
                let (_lock, mut engine) = locked_engine(&layout)?;
                engine.eject()?;
            }
            println!("The drive was ejected. You can unplug it.");
            Ok(())
        }
        Command::Detach | Command::Attach => {
            let detach = matches!(command, Command::Detach);
            let call = if detach { Call::Detach } else { Call::Attach };
            if ipc::agent_running(&layout.socket_path()) {
                ipc::call(&layout.socket_path(), call, Duration::from_secs(120))?;
            } else {
                let (_lock, mut engine) = locked_engine(&layout)?;
                if detach {
                    engine.detach()?;
                } else {
                    engine.attach()?;
                }
            }
            println!(
                "{}",
                if detach {
                    "Detached: your folders are plain local folders. Run `stowaway attach` to use the drive again."
                } else {
                    "Attached: your folders are on the drive again."
                }
            );
            Ok(())
        }
        Command::Pause | Command::Resume => {
            let paused = matches!(command, Command::Pause);
            let (_lock, mut engine) = locked_engine(&layout)?;
            ops::set_paused(&mut engine, paused)?;
            println!(
                "Auto-adoption {}.",
                if paused { "paused" } else { "resumed" }
            );
            Ok(())
        }
        Command::Priority { priority } => {
            let priority = match priority {
                Some(priority) => {
                    ops::set_transfer_priority(&layout, priority)?;
                    priority
                }
                None => Config::load_required(&layout)?.transfer_priority,
            };
            println!(
                "Offload transfer priority: {}.",
                match priority {
                    TransferPriority::Background =>
                        "background (transfers pause while your disk is busy)",
                    TransferPriority::Normal => "normal (transfers never pause)",
                }
            );
            Ok(())
        }
        Command::Agent { action } => match action.unwrap_or(AgentAction::Run) {
            AgentAction::Run => agent::run(&layout),
            AgentAction::Install => {
                let path = launchd::install(&layout)?;
                println!("Agent installed ({}).", path.display());
                Ok(())
            }
            AgentAction::Start => {
                launchd::start()?;
                println!("Agent started.");
                Ok(())
            }
            AgentAction::Stop => {
                ipc::call(&layout.socket_path(), Call::Quit, Duration::from_mins(3))?;
                println!("Agent stopped. Folders use their local contents until it starts again.");
                Ok(())
            }
            AgentAction::Uninstall => {
                launchd::uninstall(&layout)?;
                println!("Agent removed.");
                Ok(())
            }
        },
        Command::Uninstall { copy } => {
            launchd::uninstall(&layout)?;
            let (_lock, mut engine) = locked_engine(&layout)?;
            for entry in engine.registry.entries()? {
                engine.release(&entry.path, copy)?;
                println!("released {}", entry.path.display());
            }
            println!(
                "Stowaway is uninstalled. Your settings remain in {} and {}; delete them if you like.",
                layout.config_file.display(),
                layout.state_dir.display()
            );
            Ok(())
        }
        Command::License { action } => license(&layout, action),
        Command::IpcSamples => {
            for sample in ipc::samples() {
                println!("{}", serde_json::to_string(&sample)?);
            }
            Ok(())
        }
    }
}

fn init(
    layout: &Layout,
    volume: &Path,
    roots: &[PathBuf],
    usage: Option<Usage>,
    no_agent: bool,
) -> Result<()> {
    let config = engine::init(layout, &layout.expand(volume), roots)?;
    let usage = match usage {
        Some(usage) => Some(usage),
        None if std::io::stdin().is_terminal() => ask_usage(),
        None => None,
    };
    let lock = EngineLock::acquire(layout, LOCK_WAIT)?;
    let mut engine = Engine::open(layout.clone())?;
    if let Some(usage) = usage {
        ops::set_usage(&mut engine, usage)?;
        if usage == Usage::Work {
            println!(
                "Thanks! Work use includes a 30-day trial; after that, please expense a license: see LICENSE-COMMERCIAL.md."
            );
        }
    }
    println!(
        "Stowaway is set up with {} and is watching:",
        config.volume_name.as_deref().unwrap_or("your drive")
    );
    for root in &config.roots {
        println!("  {}", root.display());
    }
    let found = engine.discover()?;
    println!("Found {} folders to manage.", found.len());
    if no_agent {
        println!(
            "Run `stowaway scan` to adopt them, and `stowaway agent install` to keep things automatic."
        );
    } else {
        drop(engine);
        drop(lock);
        launchd::install(layout)?;
        println!("The background agent is running and will adopt them as they go idle.");
    }
    Ok(())
}

fn ask_usage() -> Option<Usage> {
    eprint!("Will you use Stowaway for personal projects or for work? [p/w] ");
    let mut answer = String::new();
    std::io::stdin().lock().read_line(&mut answer).ok()?;
    match answer.trim().to_ascii_lowercase().chars().next() {
        Some('p') => Some(Usage::Personal),
        Some('w') => Some(Usage::Work),
        _ => None,
    }
}

fn roots(layout: &Layout, action: RootsAction) -> Result<()> {
    match action {
        RootsAction::List => {
            let report = fetch_status(layout)?;
            if report.roots.is_empty() {
                println!("No watched folders. Add one with `stowaway roots add <folder>`.");
            }
            for root in report.roots {
                println!(
                    "{}  ({} managed, {} offloaded){}",
                    root.path.display(),
                    root.entries,
                    format_bytes(root.offloaded_bytes),
                    if root.exists { "" } else { "  — missing" }
                );
            }
            Ok(())
        }
        RootsAction::Add { path, dry_run } => {
            let (_lock, mut engine) = locked_engine(layout)?;
            let preview = ops::roots_add(&mut engine, &path, dry_run)?;
            println!(
                "Found {} projects; {} can be offloaded{}.",
                preview.projects,
                format_bytes(preview.offloadable_bytes),
                if dry_run { "" } else { " as they go idle" }
            );
            tell_agent(layout);
            Ok(())
        }
        RootsAction::Remove { path, copy } => {
            let (_lock, mut engine) = locked_engine(layout)?;
            let released = ops::roots_remove(&mut engine, &path, copy)?;
            println!(
                "Stopped watching {} and released {} folders.",
                path.display(),
                released.len()
            );
            tell_agent(layout);
            Ok(())
        }
    }
}

fn license(layout: &Layout, action: LicenseAction) -> Result<()> {
    let (_lock, mut engine) = locked_engine(layout)?;
    match action {
        LicenseAction::Show => {
            let l = &engine.config.licensing;
            println!(
                "Usage: {}",
                match l.usage {
                    Some(Usage::Personal) => "personal (free)",
                    Some(Usage::Work) => "work",
                    None => "not set",
                }
            );
            if let Some(order) = &l.order_id {
                println!(
                    "License: order {order}{}",
                    l.licensee
                        .as_deref()
                        .map(|n| format!(" for {n}"))
                        .unwrap_or_default()
                );
            }
        }
        LicenseAction::Personal => {
            ops::set_usage(&mut engine, Usage::Personal)?;
            println!("Recorded personal use. Enjoy Stowaway!");
        }
        LicenseAction::Work => {
            ops::set_usage(&mut engine, Usage::Work)?;
            println!(
                "Recorded work use: 30-day trial, then please expense a license (LICENSE-COMMERCIAL.md)."
            );
        }
        LicenseAction::Purchased { order, licensee } => {
            ops::record_license(&mut engine, &order, licensee.as_deref())?;
            println!("Thank you for supporting independent software!");
        }
    }
    Ok(())
}

fn fetch_status(layout: &Layout) -> Result<StatusReport> {
    if let Ok(Some(value)) = ipc::call(&layout.socket_path(), Call::Status, Duration::from_secs(5))
        && let Ok(report) = serde_json::from_value::<StatusReport>(value)
    {
        return Ok(report);
    }
    let mut engine = Engine::open(layout.clone())?;
    let mut report = status::build(&mut engine)?;
    // A busy agent can miss the timeout, but it's running if it accepts connections.
    report.agent_running = std::os::unix::net::UnixStream::connect(layout.socket_path()).is_ok();
    Ok(report)
}

fn bug_report(layout: &Layout, print: bool) -> Result<()> {
    let status = fetch_status(layout).map_err(|e| e.to_string());
    let report = bugreport::build(layout, status.as_ref().map_err(String::as_str));
    if print {
        print!("{}", report.body);
        return Ok(());
    }
    let saved = layout.state_dir.join("bug-report.md");
    std::fs::write(&saved, &report.body).ctx("writing", &saved)?;
    crate::cmd::run("open", [&report.url])?;
    println!(
        "Opened a new GitHub issue in your browser with diagnostics filled in. Describe what \
         happened, review what's included, then submit it."
    );
    if report.url_log_lines < bugreport::LOG_LINES {
        println!(
            "Only the last {} log lines fit in the link; the full report is in {}.",
            report.url_log_lines,
            saved.display()
        );
    }
    Ok(())
}

fn print_license_footer(report: &StatusReport) {
    if report.license_reminder && std::io::stdout().is_terminal() {
        println!("\nUsing this at work? Expense a license → see LICENSE-COMMERCIAL.md");
    }
}

fn infer_kind(config: &Config, path: &Path) -> Result<KindId> {
    if let Some(kind) = path
        .file_name()
        .and_then(|n| n.to_str())
        .and_then(KindId::for_folder_name)
    {
        return Ok(kind);
    }
    config
        .globals
        .iter()
        .find(|(_, paths)| paths.iter().any(|p| p == path))
        .map(|(kind, _)| *kind)
        .ok_or_else(|| {
            Error::Invalid(format!(
                "can't tell what kind of folder {} is; pass --kind",
                path.display()
            ))
        })
}
