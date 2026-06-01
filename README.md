# SPSDBMove

[![Pester](https://github.com/luigilink/SPSDBMove/actions/workflows/pester.yml/badge.svg?branch=main)](https://github.com/luigilink/SPSDBMove/actions/workflows/pester.yml)
[![Release](https://github.com/luigilink/SPSDBMove/actions/workflows/release.yml/badge.svg)](https://github.com/luigilink/SPSDBMove/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)
[![PowerShell 7.0+](https://img.shields.io/badge/PowerShell-7.0%2B-blue.svg)](https://learn.microsoft.com/powershell/)

Backup, copy, and restore **SharePoint SQL databases** across SQL Server
instances — designed for two common scenarios:

- **SharePoint Server 2016 / 2019 → Subscription Edition** migrations.
- **PROD → PRE-PROD** content refreshes.

`SPSDBMove` is a single PowerShell script that orchestrates the three phases
end-to-end (or any phase individually):

1. **Backup** — `BACKUP DATABASE ... WITH COPY_ONLY, COMPRESSION, CHECKSUM` on
   the source instance, written into a per-database folder layout
   (`<root>\<DbName>\FULL\<DbName>_<timestamp>.bak`).
2. **Copy** — parallel file copy of the latest `.bak` per database from the
   source share to the destination share.
3. **Restore** — `RESTORE DATABASE ... WITH REPLACE, RECOVERY` on the
   destination instance, with automatic logical-to-physical file remapping.

Companion project: [luigilink/SPSUpdate](https://github.com/luigilink/SPSUpdate).

---

## Requirements

| Component | Version |
|---|---|
| PowerShell | **7.0 or later** (the Copy phase uses `ForEach-Object -Parallel`) |
| `SqlServer` module | 21.1.18256 or later |
| Source SQL Server | 2016 / 2017 / 2019 / 2022 |
| Destination SQL Server | 2019 / 2022 (SharePoint SE compatible) |
| Account rights | `dbcreator` + `BACKUP DATABASE` on source; `dbcreator` on destination; read/write on both backup shares |

Install the SQL module once:

```powershell
Install-Module -Name SqlServer -Scope CurrentUser -Force
```

## Quick start

`SPSDBMove` is configuration-driven: the job (instances, backup roots,
database list, tuning) lives in a small JSON file; the CLI takes only the
config path, the phase to run, and a couple of runtime flags.

1. Copy the sample config and edit it for your environment:

   ```powershell
   Copy-Item .\scripts\SPSDBMove.sample.json .\scripts\my-refresh.json
   notepad .\scripts\my-refresh.json
   ```

2. Run the full pipeline (backup → copy → restore):

   ```powershell
   .\scripts\SPSDBMove.ps1 -ConfigPath .\scripts\my-refresh.json
   ```

### Run a single phase

```powershell
.\scripts\SPSDBMove.ps1 -ConfigPath .\scripts\my-refresh.json -Action Backup
.\scripts\SPSDBMove.ps1 -ConfigPath .\scripts\my-refresh.json -Action Copy
.\scripts\SPSDBMove.ps1 -ConfigPath .\scripts\my-refresh.json -Action Restore
```

### CLI surface

| Parameter | Purpose |
|---|---|
| `-ConfigPath` (alias `-Path`) | **Required.** Path to the JSON job file. |
| `-Action` | `All` (default), `Backup`, `Copy`, or `Restore`. |
| `-SqlCredential` | Optional `[pscredential]` for SQL auth. Kept on the CLI so secrets stay out of the JSON. |
| `-SkipExisting` | Copy phase only: skip files already at the destination with the same size. |
| `-WhatIf` / `-Confirm` | Standard PowerShell, honored by every destructive operation. |

Everything else (`SourceInstance`, `DestinationInstance`, `SourceBackupRoot`,
`DestinationBackupRoot`, `DataFileDirectory`, `LogFileDirectory`,
`ThrottleLimit`, `OverwriteDestinationDb`,
`Databases`, `ExcludeDatabases`) belongs in
the JSON file. See [`scripts/SPSDBMove.sample.json`](scripts/SPSDBMove.sample.json)
and [Configuration](wiki/Configuration.md).

### Dry-run

`SPSDBMove` honours `-WhatIf` for every destructive operation:

```powershell
.\scripts\SPSDBMove.ps1 -ConfigPath .\scripts\my-refresh.json -WhatIf
```

## Documentation

Full documentation lives in the [wiki](https://github.com/luigilink/SPSDBMove/wiki):

- [Home](wiki/Home.md)
- [Getting Started](wiki/Getting-Started.md)
- [Configuration](wiki/Configuration.md)
- [Usage](wiki/Usage.md)

## Contributing

See [CONTRIBUTING.md](.github/CONTRIBUTING.md). Bug reports and feature
requests use the [issue templates](.github/ISSUE_TEMPLATE).

## Changelog

See [CHANGELOG.md](CHANGELOG.md) and the latest
[release notes](RELEASE-NOTES.md).

## License

[MIT](LICENSE) © 2026 Jean-Cyril Drouhin.
