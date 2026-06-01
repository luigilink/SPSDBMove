# Contributing to SPSDBMove

Thanks for your interest in improving **SPSDBMove**! This document explains how
to file issues, propose changes, and get your pull request merged.

## Code of Conduct

This project adopts the [Contributor Covenant](../CODE_OF_CONDUCT.md).
By participating you agree to uphold it.

## How to report a bug

1. Search [existing issues](https://github.com/luigilink/SPSDBMove/issues) first
   to avoid duplicates.
2. If nothing matches, open a new issue using the
   [Bug Report template](https://github.com/luigilink/SPSDBMove/issues/new?template=1_bug_report.yml).
3. Include:
   - Exact command line you ran (redact credentials).
   - SharePoint version (2016 / 2019 / Subscription Edition).
   - SQL Server version of both the source and destination instances.
   - PowerShell version (`$PSVersionTable.PSVersion`).
   - Full error / log output.

## How to request a feature

Use the
[Feature Request template](https://github.com/luigilink/SPSDBMove/issues/new?template=2_feature_request.yml)
and describe the migration scenario the feature would unlock.

## Development setup

```powershell
# Required modules
Install-Module -Name SqlServer       -Scope CurrentUser -Force
Install-Module -Name Pester          -MinimumVersion 5.3.0 -Scope CurrentUser -Force
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force

# Clone
git clone https://github.com/luigilink/SPSDBMove.git
cd SPSDBMove
```

Run the test suite before pushing:

```powershell
Invoke-Pester -Path .\tests -Output Detailed
Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Severity Error,Warning
```

## Pull request workflow

1. Fork the repository and create a topic branch from `main`:
   `git checkout -b feature/short-description`.
2. Make focused commits. Keep one logical change per commit when possible.
3. **Update `CHANGELOG.md`** under an `## [Unreleased]` section describing the
   change. Entries are mandatory for every PR.
4. Make sure `pester` and `code-quality` CI jobs are green.
5. Open the PR against `main` using the
   [PR template](./PULL_REQUEST_TEMPLATE.md). Link the issue it resolves
   (`Fixes #123`).
6. A maintainer will review. Address feedback by pushing additional commits to
   the same branch (no force-push during review, please).

## Coding guidelines

- Target **PowerShell 7.0+** (`pwsh`). The Copy phase uses
  `ForEach-Object -Parallel`, which is not available on Windows
  PowerShell 5.1.
- Every public function uses `[CmdletBinding()]`, comment-based help, and
  parameter validation (`[ValidateNotNullOrEmpty()]`, `[ValidateSet()]`, etc.).
- Destructive operations (`BACKUP`, `RESTORE`, file deletes) must support
  `-WhatIf` / `-Confirm` via `SupportsShouldProcess`.
- Never log credentials, connection strings containing passwords, or full file
  paths that include secrets.
- Use approved PowerShell verbs (`Get-Verb`). Run PSScriptAnalyzer locally
  before pushing.

## Releasing (maintainers)

1. Move the `## [Unreleased]` block in `CHANGELOG.md` to a new
   `## [x.y.z] - YYYY-MM-DD` section.
2. Mirror the same block at the top of `RELEASE-NOTES.md`.
3. Commit and tag: `git tag vX.Y.Z && git push --tags`.
4. The `release.yml` workflow creates the GitHub Release and attaches the
   packaged zip.
