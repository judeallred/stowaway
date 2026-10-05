//! The `stowaway` binary.
#![forbid(unsafe_code)]

fn main() -> std::process::ExitCode {
    stowaway::cli::main()
}
