# Configuration

`SPSDBMove` is configuration-driven: the **job** (instances, backup roots,
database list, tuning) is described by a JSON file. The CLI surface is
deliberately tiny.

## CLI parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-ConfigPath` (alias `-Path`) | **yes** | — | Path to the JSON job file (see schema below). |
| `-Action` | no | `All` | One of `All`, `Backup`, `Copy`, `Restore`. |
| `-SqlCredential` | no | — | `[pscredential]` for SQL authentication. Kept on the CLI so secrets stay out of the JSON. Omit for Windows integrated auth. |
| `-SkipExisting` | no (`Copy` only) | `$false` | Skip files that already exist at the destination with the same size. |
| `-WhatIf` / `-Confirm` | no | — | Standard PowerShell support; suppresses all destructive SQL and file operations. |

## JSON configuration file

A sample lives at [`scripts/SPSDBMove.sample.json`](../scripts/SPSDBMove.sample.json).
Copy it next to the script (or somewhere checked in alongside your runbook)
and edit it.

### Schema

| Key | Required | Default | Description |
|---|---|---|---|
| `SourceInstance` | for `Backup`, `All` | — | SQL Server instance to back up *from* (e.g. `SQLPROD01\\SHAREPOINT`). |
| `DestinationInstance` | for `Restore`, `All` | — | SQL Server instance to restore *to*. |
| `SourceBackupRoot` | for `Backup`, `Copy`, `All` | — | UNC or local folder where the source `.bak` files live (or will be written). |
| `DestinationBackupRoot` | for `Copy`, `Restore`, `All` | — | UNC or local folder the destination instance reads from. |
| `DataFileDirectory` | no | SQL default | Target folder for `.mdf` / `.ndf` files on the destination instance. |
| `LogFileDirectory` | no | SQL default | Target folder for `.ldf` files on the destination instance. |
| `ThrottleLimit` | no | `4` | Parallelism for the `Copy` phase (`ForEach-Object -Parallel`). Range `1..64`. |
| `OverwriteDestinationDb` | no | `true` | Adds `WITH REPLACE` to the restore. |
| `Databases` | for `Backup`, `Restore`, `All` | `[]` | Array of database descriptors (see below). |
| `ExcludeDatabases` | no | `[]` | Names to drop from the effective database list (see below). System databases (`master`, `model`, `msdb`, `tempdb`) are always excluded and do not need to be listed here. |

Unknown top-level keys fail with an explicit error so typos surface
immediately. There is no merging with CLI flags — what is in the file is
what the script will run.

`Invoke-Sqlcmd` is always called with `QueryTimeout = 0` (no timeout) so
that long-running `BACKUP` / `RESTORE` operations on multi-TB content
databases are never cut short by the script. SQL Server itself remains in
control of the operation's lifetime.

### `Databases` entries

Each entry is either a bare string (database name) or an object with a
mandatory `Name` and an optional `DestinationName` override:

```json
"Databases": [
  "SP_Content_Intranet",
  { "Name": "SP_Content_Projects" },
  { "Name": "SP_Content_HR", "DestinationName": "SP_Content_HR_PREP_FRESH" }
]
```

When `DestinationName` is omitted, the database is restored under its
original name. To rename multiple databases consistently, set
`DestinationName` per entry.

### `ExcludeDatabases` entries

Each entry is either a bare string or an object with a mandatory `Name`.
Matching is case-insensitive against the source database name (the `Name`
field, not `DestinationName`). Excluded entries are dropped from the
effective list **before** any phase runs, so the same exclusion applies to
`Backup`, `Copy`, and `Restore`.

```json
"ExcludeDatabases": [
  "SP_Content_Legacy",
  { "Name": "SP_Content_Decommissioned" }
]
```

SQL Server system databases (`master`, `model`, `msdb`, `tempdb`) are
always excluded — listing them in `Databases` is a no-op and a warning is
logged. This prevents accidental cross-instance system-database restores,
which would corrupt the destination engine.

### Full example

```json
{
  "SourceInstance":            "SQLPROD01\\SHAREPOINT",
  "DestinationInstance":       "SQLPREP01\\SHAREPOINT",
  "SourceBackupRoot":          "\\\\sqlprod01\\Backup\\SPSDBMove",
  "DestinationBackupRoot":     "\\\\sqlprep01\\Backup\\SPSDBMove",
  "DataFileDirectory":         "E:\\MSSQL\\DATA",
  "LogFileDirectory":          "F:\\MSSQL\\LOG",
  "ThrottleLimit":             6,
  "OverwriteDestinationDb":    true,
  "Databases": [
    { "Name": "SP_Content_Intranet" },
    { "Name": "SP_Content_Projects" },
    { "Name": "SP_Content_HR", "DestinationName": "SP_Content_HR_PREP_FRESH" }
  ],
  "ExcludeDatabases": [
    "SP_Content_Legacy"
  ]
}
```

## Service-account requirements (summary)

| Account | Right | On |
|---|---|---|
| Source SQL service | Write | `SourceBackupRoot` |
| Destination SQL service | Read | `DestinationBackupRoot` |
| Account running the script | Read+Write | both roots (for the `Copy` phase) |
| Account running the script | `BACKUP DATABASE` | source databases |
| Account running the script | `dbcreator` / `RESTORE DATABASE` | destination instance |
