# SPSDBMove Wiki

Welcome to the **SPSDBMove** documentation.

`SPSDBMove` is a PowerShell tool that backs up, copies, and restores SharePoint
SQL databases between SQL Server instances. It is designed for two main
scenarios:

- **SharePoint Server 2016 / 2019 → Subscription Edition** migrations.
- **PROD → PRE-PROD** database refreshes.

## Pages

- [Getting Started](Getting-Started.md) — prerequisites and a 5-minute first run.
- [Configuration](Configuration.md) — every parameter explained, plus the JSON
  configuration file format.
- [Usage](Usage.md) — recipes for the typical migration and refresh workflows.

## Project links

- Source code: <https://github.com/luigilink/SPSDBMove>
- Issues: <https://github.com/luigilink/SPSDBMove/issues>
- Discussions: <https://github.com/luigilink/SPSDBMove/discussions>
- Companion project: [`luigilink/SPSUpdate`](https://github.com/luigilink/SPSUpdate)

## How `SPSDBMove` works

```text
+----------------+        +----------------+        +----------------+
|  Source SQL    |        |   File copy    |        |  Destination   |
|  (PROD / 2019) |        |   (parallel)   |        |  SQL (SE/PREP) |
|                |        |                |        |                |
|  BACKUP -->----+--bak-->+----copy------->+--bak-->+----RESTORE     |
+----------------+        +----------------+        +----------------+
        |                                                    |
        | COPY_ONLY, COMPRESSION, CHECKSUM                   | REPLACE, RECOVERY
        | per-DB folder: <root>\<DbName>\FULL\               | logical->physical remap
```

The three phases are independent — run them together with `-Action All` or
individually with `-Action Backup | Copy | Restore`.
