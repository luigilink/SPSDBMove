# Usage

Recipes for the two main `SPSDBMove` scenarios.

> All examples assume the `SqlServer` PowerShell module is installed and that
> the account running the script has the rights described in
> [Configuration](Configuration.md).
>
> `SPSDBMove` reads its job (instances, backup roots, database list, tuning)
> from a JSON file passed via `-ConfigPath`. The CLI itself only carries
> `-Action`, `-SqlCredential`, `-SkipExisting`, and the standard `-WhatIf` /
> `-Confirm`.

## Scenario 1 — PROD → PRE-PROD content refresh

Goal: copy a list of SharePoint content databases from the production farm
into the pre-production farm without disturbing the running backup chain on
PROD (`COPY_ONLY` backup).

`config\preprod-refresh.json`:

```json
{
  "SourceInstance":        "SQLPROD01\\SHAREPOINT",
  "DestinationInstance":   "SQLPREP01\\SHAREPOINT",
  "SourceBackupRoot":      "\\\\sqlprod01\\Backup\\SPSDBMove",
  "DestinationBackupRoot": "\\\\sqlprep01\\Backup\\SPSDBMove",
  "DataFileDirectory":     "E:\\MSSQL\\DATA",
  "LogFileDirectory":      "F:\\MSSQL\\LOG",
  "ThrottleLimit":         6,
  "Databases": [
    "SP_Content_Intranet",
    "SP_Content_Projects",
    "SP_Content_HR"
  ]
}
```

Run the full pipeline:

```powershell
.\scripts\SPSDBMove.ps1 -ConfigPath .\config\preprod-refresh.json
```

After the script completes, attach the restored databases in SharePoint
Central Administration (or via `Mount-SPContentDatabase`) on the pre-prod farm.

## Scenario 2 — SP2019 → Subscription Edition migration

Run the three phases at different times — typically backup overnight, copy
during a maintenance window, and restore right before the SE farm comes up.
A single config file describes the whole wave; `-Action` selects the phase.

```powershell
# T-0: backup (run from / against the SP2019 SQL instance)
.\scripts\SPSDBMove.ps1 -ConfigPath .\config\migration-wave-1.json -Action Backup

# T+2h: copy (run from a hop with access to both shares)
.\scripts\SPSDBMove.ps1 -ConfigPath .\config\migration-wave-1.json -Action Copy -SkipExisting

# T+4h: restore (run from / against the SE SQL instance)
.\scripts\SPSDBMove.ps1 -ConfigPath .\config\migration-wave-1.json -Action Restore
```

## Scenario 3 — Dry-run before a real migration

```powershell
.\scripts\SPSDBMove.ps1 -ConfigPath .\config\migration-wave-1.json -WhatIf
```

`-WhatIf` enumerates every `BACKUP`, `Copy-Item`, and `RESTORE` operation
without performing any of them.

## Scenario 4 — Renaming on restore

To restore a backup under a different name on the destination (useful when
refreshing a single DB without overwriting the live copy), use a per-entry
`DestinationName` in the `Databases` array:

```json
{
  "Databases": [
    { "Name": "SP_Content_HR",    "DestinationName": "SP_Content_HR_FRESH" },
    { "Name": "SP_Content_Legal", "DestinationName": "SP_Content_Legal_PILOT" }
  ]
}
```

`SP_Content_HR` is restored as `SP_Content_HR_FRESH` (with its data/log
files renamed accordingly), and `SP_Content_Legal` as
`SP_Content_Legal_PILOT`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Cannot open backup device ... Operating system error 5 (Access is denied.)` | The **source SQL service account** does not have write access to `SourceBackupRoot`, or the **destination SQL service account** does not have read access to `DestinationBackupRoot`. |
| `RESTORE detected an error on page ... ` | Backup was corrupted in transit; rerun with `-Action Copy -SkipExisting:$false` to force a fresh copy. |
| `Exclusive access could not be obtained because the database is in use` | Drop existing connections to the destination DB (`ALTER DATABASE ... SET SINGLE_USER WITH ROLLBACK IMMEDIATE`) or temporarily detach it. |
| Restore succeeds but SharePoint won't mount | Verify the SQL collation matches (`Latin1_General_CI_AS_KS_WS` for SharePoint) and that the database compat level is supported by the destination SQL version. |
