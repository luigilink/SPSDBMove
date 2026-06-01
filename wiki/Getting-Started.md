# Getting Started

This page walks you through your first `SPSDBMove` run.

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| PowerShell 7.0 or later (`pwsh`) | Required — the Copy phase uses `ForEach-Object -Parallel`, which is not available on Windows PowerShell 5.1. |
| `SqlServer` PowerShell module | `Install-Module SqlServer -Scope CurrentUser`. The script will warn if missing. |
| Source SQL Server account | Must have `BACKUP DATABASE` on the databases to move (typically `db_backupoperator` or `sysadmin`). |
| Destination SQL Server account | Must have `dbcreator` (or `sysadmin`) to create restored databases. |
| Two file shares (or one) | A folder reachable by the source SQL service account for **write** and by the destination SQL service account for **read**. The script copies between them when they are different. |
| Free disk space | At least 1.5x the size of the largest content database on each share. |

## 2. Install

```powershell
git clone https://github.com/luigilink/SPSDBMove.git
cd SPSDBMove
```

Optionally trust the script for the session:

```powershell
Unblock-File .\scripts\SPSDBMove.ps1
```

## 3. Plan the folder layout

`SPSDBMove` uses a fixed per-database folder layout on both backup roots:

```text
\\sqlprod01\Backup\SPSDBMove\
   |-- SP_Content_Intranet\
   |     `-- FULL\
   |           `-- SP_Content_Intranet_20260528_143012.bak
   |-- SP_Content_Projects\
   |     `-- FULL\
   |           `-- SP_Content_Projects_20260528_143019.bak
```

The destination share mirrors that layout after the `Copy` phase.

## 4. Write your config

`SPSDBMove` is driven by a JSON job file. Start from the sample:

```powershell
Copy-Item .\scripts\SPSDBMove.sample.json .\scripts\my-refresh.json
notepad .\scripts\my-refresh.json
```

Set at least `SourceInstance`, `DestinationInstance`, `SourceBackupRoot`,
`DestinationBackupRoot`, and the `Databases` array. The other keys have
sensible defaults — see [Configuration](Configuration.md) for the full
schema.

## 5. First run (dry-run)

Always start with `-WhatIf` to verify what the script will do:

```powershell
.\scripts\SPSDBMove.ps1 -ConfigPath .\scripts\my-refresh.json -WhatIf
```

Remove `-WhatIf` to execute for real. To run only one phase:

```powershell
.\scripts\SPSDBMove.ps1 -ConfigPath .\scripts\my-refresh.json -Action Backup
```

## 6. Inspect logs

Each run prints timestamped lines to the console and also appends them to a
log file alongside the script:

```text
scripts\Logs\SPSDBMove.log
```

The `Logs` folder is created automatically on first run.

## Next steps

- Read [Configuration](Configuration.md) to learn every parameter.
- Read [Usage](Usage.md) for the migration and refresh recipes.
