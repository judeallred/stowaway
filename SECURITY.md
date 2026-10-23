# Security

Stowaway moves and deletes folders on your Mac, so bugs that could touch the wrong data are
treated as security issues.

## Reporting

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/judeallred/stowaway/security/advisories/new)
rather than in a public issue. Include what you found and, if you can, how to reproduce it.
You'll get a reply within a week.

## What's in scope

- Stowaway deleting, overwriting or exposing data outside the folders it manages.
- Anything on the drive Stowaway stows folders on (which may be shared) that makes Stowaway act outside its store.
- Ways around the App Sandbox or the purchase checks.

## Design

[docs/architecture.md](docs/architecture.md) covers the safety rules: access is limited to
folders the user grants, symlinks are never followed when deleting or copying, paths read from
the drive are validated, operations are serialized, and nothing git tracks is touched. Stowaway
collects no data and makes no network requests of its own.
