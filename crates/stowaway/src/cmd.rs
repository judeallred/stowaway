//! Running external macOS tools (`hdiutil`, `diskutil`, `lsof`, ...).

use std::ffi::OsStr;
use std::process::{Command, Output};

use crate::error::{Error, Result};

/// Runs a command and returns its stdout. Fails if it can't start or exits non-zero.
///
/// # Errors
///
/// Returns [`Error::Command`] with the exit status and stderr.
pub fn run<I, S>(program: &str, args: I) -> Result<Vec<u8>>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = output(program, args)?;
    Ok(output.stdout)
}

/// Like [`run`] but returns stdout as a trimmed string.
///
/// # Errors
///
/// See [`run`].
pub fn run_string<I, S>(program: &str, args: I) -> Result<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    Ok(String::from_utf8_lossy(&run(program, args)?)
        .trim()
        .to_owned())
}

/// Runs a command, returning the full output only if it succeeded.
///
/// # Errors
///
/// See [`run`].
pub fn output<I, S>(program: &str, args: I) -> Result<Output>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let args: Vec<S> = args.into_iter().collect();
    let describe = || {
        let rendered: Vec<String> = args
            .iter()
            .map(|a| a.as_ref().to_string_lossy().into_owned())
            .collect();
        format!("{program} {}", rendered.join(" "))
    };
    let output = Command::new(program)
        .args(&args)
        .output()
        .map_err(|e| Error::Command {
            command: describe(),
            detail: e.to_string(),
        })?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(Error::Command {
            command: describe(),
            detail: format!(
                "{}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        })
    }
}

/// Parses a property list produced by a command.
///
/// # Errors
///
/// Returns [`Error::Parse`] if the bytes aren't a valid plist of the expected shape.
pub fn parse_plist<T: serde::de::DeserializeOwned>(command: &str, bytes: &[u8]) -> Result<T> {
    plist::from_bytes(bytes).map_err(|e| Error::Parse {
        command: command.to_owned(),
        detail: e.to_string(),
    })
}
