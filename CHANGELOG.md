# Change log for SPSDBMove

The format is based on and uses the types of changes according to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-01

First tagged release of **SPSDBMove**. Requires **PowerShell 7.0+**.

### Added

- `scripts/SPSDBMove.ps1` — a full **backup + copy + restore** orchestrator:
  - `-Action All | Backup | Copy | Restore` phase selector.
  - `[CmdletBinding(SupportsShouldProcess)]`, comment-based help, `-WhatIf`.
  - Source-side `BACKUP DATABASE ... WITH COPY_ONLY, COMPRESSION, CHECKSUM,
    INIT` writing to the per-database `<root>\<DbName>\FULL\` layout.
  - Destination-side `RESTORE DATABASE` with automatic `RESTORE FILELISTONLY`
    logical-to-physical remapping and optional `WITH REPLACE`.
  - Parallel copy using PowerShell 7+ `ForEach-Object -Parallel` with a
    configurable `ThrottleLimit` and `-SkipExisting`.
  - `-SqlCredential` for SQL authentication; Windows integrated auth by
    default.
  - Configuration-driven CLI: the entire job (instances, backup roots,
    database list, throttling, restore options) lives in a JSON file
    passed via `-ConfigPath`. The CLI surface is limited to `-ConfigPath`,
    `-Action`, `-SqlCredential`, `-SkipExisting`, plus `-WhatIf` /
    `-Confirm`. Unknown JSON keys are rejected so typos surface
    immediately.
  - `BACKUP` / `RESTORE` statements run with `QueryTimeout = 0` (no
    timeout). Multi-TB SharePoint databases can take many hours; any
    arbitrary cap would be a footgun, so SQL Server is left in charge of
    the operation lifetime.
  - Per-database `DestinationName` overrides are the only way to rename a
    database on restore; the JSON schema is intentionally lean.
  - SQL Server system databases (`master`, `model`, `msdb`, `tempdb`) are
    always excluded from every phase, regardless of what the JSON
    `Databases` list contains; a warning is logged when one is filtered
    out.
  - `ExcludeDatabases` JSON key: array of names (or `{Name}` objects) that
    are dropped from the effective list before `Backup`, `Copy`, and
    `Restore` run. Lets operators keep noisy databases in the main
    `Databases` list while skipping them for a specific run.
  - Sample config shipped at `scripts/SPSDBMove.sample.json`.
  - Automatic per-run log file written next to the script under
    `Logs\SPSDBMove.log`.
- `tests/SPSDBMove.Tests.ps1` — Pester 5 smoke tests covering script
  parsing, declared parameters, PSScriptAnalyzer cleanliness, and
  repository structure.
- `wiki/` folder with `Home.md`, `Getting-Started.md`, `Configuration.md`,
  `Usage.md`, published to GitHub Wiki via `.github/workflows/wiki.yml`.
- `README.md` with badges, quick-start examples, CLI surface table, and
  links to the wiki.
- `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1) with a real reporting
  channel (GitHub private security advisory).
- `.github/CONTRIBUTING.md` — contribution guide.
- `.github/PULL_REQUEST_TEMPLATE.md` and `.github/ISSUE_TEMPLATE/*` for
  bug reports, feature requests, documentation requests, and improvement
  requests.
- `.github/workflows/pester.yml` — Pester + PSScriptAnalyzer CI on Linux,
  macOS, and Windows.
- `.github/workflows/release.yml` — tag-triggered (`v*`) GitHub Release
  job that publishes a ZIP containing `scripts/`, `README.md`, `LICENSE`,
  `CHANGELOG.md`, and `RELEASE-NOTES.md`.
