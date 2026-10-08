//! Installing the agent as a per-user launchd service.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::cmd;
use crate::error::{Error, IoContext, Result};
use crate::paths::Layout;

/// The launchd label.
pub const LABEL: &str = "dev.stowaway.agent";

fn plist_path(layout: &Layout) -> PathBuf {
    layout
        .home
        .join("Library/LaunchAgents")
        .join(format!("{LABEL}.plist"))
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The service definition for `binary`.
#[must_use]
pub fn plist(layout: &Layout, binary: &Path) -> String {
    let mut env = String::from(
        "    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>\n",
    );
    if let Some(custom) = std::env::var_os("STOWAWAY_HOME") {
        env.push_str("    <key>STOWAWAY_HOME</key><string>");
        env.push_str(&escape(&custom.to_string_lossy()));
        env.push_str("</string>\n");
    }
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{binary}</string>
    <string>agent</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>{log}</string>
  <key>EnvironmentVariables</key>
  <dict>
{env}  </dict>
</dict>
</plist>
"#,
        binary = escape(&binary.to_string_lossy()),
        log = escape(&layout.log_path().to_string_lossy()),
    )
}

fn domain() -> Result<String> {
    Ok(format!("gui/{}", cmd::run_string("id", ["-u"])?))
}

/// Writes the plist and (re)starts the agent.
///
/// # Errors
///
/// Fails if the plist can't be written or launchctl refuses it.
pub fn install(layout: &Layout) -> Result<PathBuf> {
    let binary =
        std::env::current_exe().map_err(|e| Error::io("locating", Path::new("stowaway"), e))?;
    let path = plist_path(layout);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).ctx("creating", dir)?;
    }
    std::fs::create_dir_all(&layout.state_dir).ctx("creating", &layout.state_dir)?;
    std::fs::write(&path, plist(layout, &binary)).ctx("writing", &path)?;
    let domain = domain()?;
    let service = format!("{domain}/{LABEL}");
    let _ignored = cmd::run("launchctl", ["bootout", service.as_str()]);
    wait_until_unloaded(&service);
    cmd::run(
        "launchctl",
        [
            OsStr::new("bootstrap"),
            OsStr::new(&domain),
            path.as_os_str(),
        ],
    )?;
    Ok(path)
}

/// Waits for a `bootout` to finish. It returns while the old agent is still exiting (which takes
/// a while mid-transfer), and bootstrapping before then fails with "Input/output error".
fn wait_until_unloaded(service: &str) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while cmd::run("launchctl", ["print", service]).is_ok() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// Starts the installed agent if it isn't running (after `stowaway agent stop`, for example).
///
/// # Errors
///
/// Fails if the agent isn't installed.
pub fn start() -> Result<()> {
    let service = format!("{}/{LABEL}", domain()?);
    cmd::run("launchctl", ["kickstart", service.as_str()]).map(|_| ())
}

/// Stops the agent and removes the plist.
///
/// # Errors
///
/// Fails if the plist can't be removed.
pub fn uninstall(layout: &Layout) -> Result<()> {
    let domain = domain()?;
    let _ignored = cmd::run("launchctl", ["bootout", &format!("{domain}/{LABEL}")]);
    let path = plist_path(layout);
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(Error::io("removing", &path, e)),
    }
}

/// Whether the plist is installed.
#[must_use]
pub fn installed(layout: &Layout) -> bool {
    plist_path(layout).exists()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plist_is_valid_xml_with_agent_argument() {
        let layout = Layout::rooted(Path::new("/Users/me"), Path::new("/Users/me/.stowaway"));
        let text = plist(&layout, Path::new("/opt/homebrew/bin/stowaway"));
        let parsed: plist::Value = plist::from_bytes(text.as_bytes()).unwrap();
        let dict = parsed.as_dictionary().unwrap();
        assert_eq!(dict.get("Label").unwrap().as_string(), Some(LABEL));
        let args = dict.get("ProgramArguments").unwrap().as_array().unwrap();
        assert_eq!(args[1].as_string(), Some("agent"));
        // Adaptive and Standard agents get throttled disk I/O: walking a 600k-file target/ took
        // over 3 minutes instead of 9 seconds. Copies lower their own priority instead.
        assert_eq!(
            dict.get("ProcessType").unwrap().as_string(),
            Some("Interactive")
        );
        // Quitting from the menu bar exits cleanly and must stay stopped; crashes restart.
        let keep_alive = dict.get("KeepAlive").unwrap().as_dictionary().unwrap();
        assert_eq!(
            keep_alive.get("SuccessfulExit").unwrap().as_boolean(),
            Some(false)
        );
    }
}
