//! Bug reports, opened as prefilled GitHub issues.
//!
//! A report is a Markdown description of the user's setup and recent log. Nothing is sent
//! automatically: the user reviews the issue in their browser and submits it themselves.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use crate::cmd;
use crate::paths::Layout;
use crate::report;
use crate::status::StatusReport;

/// GitHub's page for filing a new issue on this project.
pub const NEW_ISSUE_URL: &str = concat!(env!("CARGO_PKG_REPOSITORY"), "/issues/new");
/// GitHub refuses new-issue links much longer than this, so the log is trimmed to fit.
const MAX_URL_LEN: usize = 8000;
/// How many log lines a report starts with before trimming.
pub const LOG_LINES: usize = 200;
/// Only the end of the log is read; it can grow large.
const LOG_TAIL_BYTES: u64 = 256 * 1024;

/// A bug report's text, and the link that opens it as a new GitHub issue.
#[derive(Debug)]
pub struct BugReport {
    /// The full report, with `log_lines` lines of the log.
    pub body: String,
    /// The new-issue link. Its body may hold fewer log lines than `body` so the link fits.
    pub url: String,
    /// How many log lines made it into the link.
    pub url_log_lines: usize,
}

/// Builds a report from the current status (or why it couldn't be read) and the agent's log.
#[must_use]
pub fn build(layout: &Layout, status: Result<&StatusReport, &str>) -> BugReport {
    let system = system_lines(status.ok());
    let status_text = match status {
        Ok(report) => report::status(report),
        Err(error) => format!("Couldn't read the status: {error}\n"),
    };
    let log = log_tail(&layout.log_path(), LOG_LINES);
    let body = |lines: usize| {
        redact(
            &compose(&system, &status_text, tail(&log, lines)),
            &layout.home,
        )
    };

    let mut lines = log.len();
    let url = loop {
        let url = issue_url(&body(lines));
        if url.len() <= MAX_URL_LEN || lines == 0 {
            break url;
        }
        lines /= 2;
    };
    BugReport {
        body: body(log.len()),
        url,
        url_log_lines: lines,
    }
}

/// The new-issue link for a report body.
#[must_use]
pub fn issue_url(body: &str) -> String {
    format!("{NEW_ISSUE_URL}?labels=bug&body={}", percent_encode(body))
}

fn compose(system: &[String], status: &str, log: &[String]) -> String {
    let system = format!("- {}\n", system.join("\n- "));
    let log = if log.is_empty() {
        "\nNo log lines included.\n".to_owned()
    } else {
        format!(
            "\n<details><summary>Recent log ({} lines)</summary>\n\n```\n{}\n```\n\n</details>\n",
            log.len(),
            log.join("\n")
        )
    };
    format!(
        "**What happened?**\n\n<!-- What went wrong, and what did you expect instead? -->\n\n\
         **How can we reproduce it?**\n\n1. \n\n---\n\n### Diagnostics\n\n{system}\n\
         <details><summary>Status</summary>\n\n```\n{status}```\n\n</details>\n{log}"
    )
}

fn system_lines(status: Option<&StatusReport>) -> Vec<String> {
    let probe = |program: &str, args: &[&str]| {
        cmd::run_string(program, args).unwrap_or_else(|_| "unknown".to_owned())
    };
    let mut lines = vec![
        format!("Stowaway {}", env!("CARGO_PKG_VERSION")),
        format!(
            "macOS {} ({})",
            probe("sw_vers", &["-productVersion"]),
            probe("sw_vers", &["-buildVersion"])
        ),
        format!(
            "Mac: {} ({})",
            probe("sysctl", &["-n", "hw.model"]),
            std::env::consts::ARCH
        ),
    ];
    if let Some(report) = status {
        lines.push(format!(
            "Agent: {}",
            if report.agent_running {
                "running"
            } else {
                "not running"
            }
        ));
    }
    lines
}

/// The last `count` lines of the log, or none if it can't be read.
fn log_tail(path: &Path, count: usize) -> Vec<String> {
    let Ok(mut file) = File::open(path) else {
        return Vec::new();
    };
    let len = file.metadata().map(|m| m.len()).unwrap_or_default();
    if file
        .seek(SeekFrom::Start(len.saturating_sub(LOG_TAIL_BYTES)))
        .is_err()
    {
        return Vec::new();
    }
    let mut bytes = Vec::new();
    if file.read_to_end(&mut bytes).is_err() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&bytes);
    let lines: Vec<String> = text.lines().map(str::to_owned).collect();
    tail(&lines, count).to_vec()
}

fn tail(lines: &[String], count: usize) -> &[String] {
    lines
        .get(lines.len().saturating_sub(count)..)
        .unwrap_or_default()
}

/// Shows the home folder as `~`, so the report doesn't carry the user's account name.
fn redact(text: &str, home: &Path) -> String {
    let home = home.to_string_lossy();
    if home.len() <= 1 {
        return text.to_owned();
    }
    text.replace(home.as_ref(), "~")
}

fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len() * 3);
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            out.push(char::from(byte));
        } else {
            out.push('%');
            for nibble in [byte >> 4, byte & 0xF] {
                let digit = char::from_digit(u32::from(nibble), 16).unwrap_or('0');
                out.push(digit.to_ascii_uppercase());
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_encoding_keeps_only_unreserved_characters() {
        assert_eq!(percent_encode("a-b_c.d~e"), "a-b_c.d~e");
        assert_eq!(percent_encode("a b/c\n"), "a%20b%2Fc%0A");
        assert_eq!(percent_encode("é"), "%C3%A9");
    }

    #[test]
    fn home_is_shown_as_tilde() {
        let home = Path::new("/Users/someone");
        assert_eq!(
            redact("/Users/someone/code/app and /Users/someone", home),
            "~/code/app and ~"
        );
        assert_eq!(redact("/Users/x", Path::new("/")), "/Users/x");
    }

    #[test]
    fn long_logs_are_trimmed_to_fit_the_link() {
        let dir = tempfile::tempdir().unwrap();
        let layout = Layout::rooted(dir.path(), dir.path());
        let line = "2026-10-10T03:20:02Z INFO transfer step path=/somewhere op=reconnect";
        std::fs::write(layout.log_path(), format!("{line}\n").repeat(500)).unwrap();

        let report = build(&layout, Err("no database"));

        assert!(report.url.len() <= MAX_URL_LEN, "{}", report.url.len());
        assert!(report.url_log_lines > 0 && report.url_log_lines < LOG_LINES);
        assert!(report.url.starts_with(NEW_ISSUE_URL));
        assert_eq!(
            report.body.matches("transfer step").count(),
            LOG_LINES,
            "the full report keeps every line"
        );
        assert!(
            report
                .body
                .contains("Couldn't read the status: no database")
        );
    }

    #[test]
    fn a_missing_log_still_makes_a_report() {
        let dir = tempfile::tempdir().unwrap();
        let layout = Layout::rooted(dir.path(), dir.path());
        let report = build(&layout, Err("no database"));
        assert!(report.body.contains("No log lines included."));
        assert_eq!(report.url_log_lines, 0);
    }
}
