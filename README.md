Show Diff

# AdaptiveDBCare — Multi-Database Index & Statistics Optimization Release

This release of AdaptiveDBCare introduces coordinated, cross-database index-rebuild and statistics-update capabilities, enhanced telemetry, safer sampling, richer logging, and improved operator visibility. It elevates AdaptiveDBCare from single-DB routines into a unified, intelligent maintenance engine for large SQL Server estates.

# DBA.usp_RebuildIndexesIfBloated (v**2.8**, 2026-01-20)

---

Rebuild **only** what’s bloated. This procedure finds leaf-level **rowstore** index partitions whose **avg_page_space_used_in_percent** is below a threshold, then rebuilds just those partitions, optionally **ONLINE**, optionally **RESUMABLE**, respecting (or overriding) **FILLFACTOR** and **DATA_COMPRESSION**, and logs every decision.

> **Works on SQL Server 2014–2025.** ONLINE/RESUMABLE features auto-downgrade based on edition/version (Enterprise/Developer/Evaluation for ONLINE; SQL 2019+ for RESUMABLE). Defaults to safe **WhatIf** mode.

---

## What’s new in 2.8

* **Index targeting for single-DB runs** via `@Indexes`
  Supports:

  * `ALL_INDEXES` (default)
  * CSV tokens: `schema.index` or `schema.table.index` (brackets ok)
  * Exclusions by prefixing `-` (e.g., `-dbo.MyTable.IX_DoNotTouch`)
    If `@TargetDatabases` resolves to **more than one DB** (including `ALL_USER_DBS`), `@Indexes` is **forced to ALL_INDEXES** and a severity 10 message is printed.

* **Collation-safe operation for central logging**
  When `@LogDatabase` is used, the proc captures **target DB collation** and **log DB collation** per iteration and applies explicit `COLLATE` rules during:

  * include/exclude filtering comparisons
  * inserts into the central log table
  * joins between log rows and candidates
    This prevents collation-conflict failures when DBs have different collations.

* **ONLINE-first with OFFLINE fallback (smarter and louder)**
  If an ONLINE rebuild fails for “ONLINE not allowed/supported” reasons (by error number and/or message patterns), the proc:

  * prints the **original ONLINE error** (number + message)
  * retries the rebuild **OFFLINE**
  * logs the final outcome accurately:

    * `SUCCESS` (ONLINE worked)
    * `SUCCESS_OFFLINE_FALLBACK` (OFFLINE saved the day)
    * `FAILED` (non-ONLINE-related failure)
    * `FAILED_OFFLINE_FALLBACK` (both ONLINE and OFFLINE failed)

* **Logging table schema enforcement for older deployments**
  When `[DBA].[IndexBloatRebuildLog]` already exists, v2.8 validates and auto-corrects legacy column definitions that commonly cause retry-path failures (like truncation), enforcing:

  * `cmd` = `NVARCHAR(MAX)`
  * `error_message` = `NVARCHAR(4000)`
  * `status` = `VARCHAR(30)`
  * `action` = `VARCHAR(20)`
  * `error_proc` = `NVARCHAR(128)`

* **OFFLINE command generation tightened**
  OFFLINE fallback builds a clean command that omits ONLINE/RESUMABLE options and constrains compression text (`LEFT(@comp, 60)`) to avoid edge-case formatting issues.

* **Trending signals seatbelt preserved**
  `@CaptureTrendingSignals = 1` auto-upshifts `SAMPLED` to `DETAILED` to ensure reliable row/ghost/forwarded and AU page metrics.

---

## Why this exists

* **Page density pays the rent** especially on SSD/NVMe. Logical fragmentation doesn’t show up on your invoice.
* **Surgical partitions**: touch only the slices that need it; stop hammering every index every time.
* **Receipts or it didn’t happen**: every candidate, command, and result is logged for audit and trending.

---

## Features

* Targets **rowstore** only (clustered & nonclustered), **leaf level**.
* Leaves tiny partitions alone via `@MinPageCount`.
* **Partition-aware**: rebuilds specific partitions only.
* **ONLINE = ON** with optional `WAIT_AT_LOW_PRIORITY (MAX_DURATION, ABORT_AFTER_WAIT)`.
* **RESUMABLE** (SQL 2019+, ONLINE only); auto-disabled at server level when unsupported.
* **Compression**: preserve from source or force `NONE | ROW | PAGE`; auto-disabled if not supported on the server.
* **Fill factor**: preserve per index or set a global `@FillFactor`.
* **MaxDOP**: honor server default when NULL; you can explicitly set `0` (unlimited) or a specific value.
* **SORT_IN_TEMPDB**: ON by default; automatically **OFF** when RESUMABLE is used (engine limitation).
* **Index filtering (single DB only)** via `@Indexes` include/exclude tokens.
* **Full logging** to `[DBA].[IndexBloatRebuildLog]` in a target DB or a central log DB.
* Captures trending signals: `avg_row_bytes`, `record_count`, `ghost_record_count`, `forwarded_record_count`, AU pages (`au_total_pages`, `au_used_pages`, `au_data_pages`).
* Defaults to **WhatIf** (dry run).

---

## Compatibility

* **SQL Server**: 2014–2025
* **ONLINE**: Enterprise, Developer, Evaluation
* **RESUMABLE**: SQL Server 2019+ **and** ONLINE
* **Compression**: auto-detects support; preserves or overrides accordingly

The procedure self-detects edition/version and quietly downgrades options it can’t safely use.

---

## Installation

1. Ensure the `DBA` schema exists (the proc will create it if needed).
2. Deploy the procedure once, typically into a Utility/DBA database for central use.
3. First execution ensures `[DBA].[IndexBloatRebuildLog]` exists **in either the target DB** or a central **Log DB** you choose via `@LogDatabase`.
   If the log table already exists, v2.8 will **enforce compatible column widths** for key text columns used by retries and error logging.

> Deploy once; call it for any user database(s). Choose to log in the target or a central Utility DB.

---

## Parameters

| Parameter                   | Type          |       Default | Notes                                                                                                                                     |
| --------------------------- | ------------- | ------------: | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `@Help`                     | BIT           |             0 | `1` prints help, capabilities, and examples; returns without scanning.                                                                    |
| `@TargetDatabases`          | NVARCHAR(MAX) |  **required** | CSV list or `ALL_USER_DBS` (exact case), with exclusions using `-DbName`. System DBs and `distribution` are always excluded.              |
| `@Indexes`                  | NVARCHAR(MAX) | `ALL_INDEXES` | **Single DB only.** CSV allow/deny list: `schema.index` or `schema.table.index`; exclusions with `-`. Forced to `ALL_INDEXES` when >1 DB. |
| `@MinPageDensityPct`        | DECIMAL(5,2)  |          70.0 | Rebuild when leaf partition density is below this percent.                                                                                |
| `@MinPageCount`             | INT           |          1000 | Skip partitions smaller than this page count.                                                                                             |
| `@UseExistingFillFactor`    | BIT           |             1 | Keep each index’s fill factor.                                                                                                            |
| `@FillFactor`               | TINYINT       |          NULL | Used only when `@UseExistingFillFactor = 0`. (1–100)                                                                                      |
| `@Online`                   | BIT           |             1 | ONLINE when edition supports it; otherwise auto-disabled. Includes OFFLINE fallback on ONLINE-not-allowed failures.                       |
| `@MaxDOP`                   | INT           |          NULL | If NULL, uses server default. May pass `0` or a specific DOP.                                                                             |
| `@SortInTempdb`             | BIT           |             1 | `RESUMABLE=ON` forces this OFF automatically.                                                                                             |
| `@UseCompressionFromSource` | BIT           |             1 | Preserve `DATA_COMPRESSION` per partition when supported.                                                                                 |
| `@ForceCompression`         | NVARCHAR(20)  |          NULL | `NONE`, `ROW`, or `PAGE` when not preserving.                                                                                             |
| `@SampleMode`               | VARCHAR(16)   |     `SAMPLED` | `SAMPLED` or `DETAILED`.                                                                                                                  |
| `@CaptureTrendingSignals`   | BIT           |             0 | If `1` and `SAMPLED`, auto-upshifts to `DETAILED`.                                                                                        |
| `@LogDatabase`              | SYSNAME       |          NULL | If set, logs to this DB instead of the target DB. Collation-safe in v2.8.                                                                 |
| `@WaitAtLowPriorityMinutes` | INT           |          NULL | With ONLINE, enables `WAIT_AT_LOW_PRIORITY (MAX_DURATION)`.                                                                               |
| `@AbortAfterWait`           | NVARCHAR(20)  |          NULL | `NONE`, `SELF`, or `BLOCKERS` (requires minutes).                                                                                         |
| `@Resumable`                | BIT           |             0 | RESUMABLE rebuilds (SQL 2019+, ONLINE required).                                                                                          |
| `@MaxDurationMinutes`       | INT           |          NULL | RESUMABLE `MAX_DURATION`.                                                                                                                 |
| `@DelayMsBetweenCommands`   | INT           |          NULL | Optional wait between rebuild commands (ms).                                                                                              |
| `@WhatIf`                   | BIT           |             1 | Dry run by default.                                                                                                                       |

### Important safeguards

* `@SampleMode` accepts only `SAMPLED` or `DETAILED`.
* `RESUMABLE` requires `@Online = 1` and SQL Server 2019+ (server-level auto-disable when unsupported).
* If ONLINE isn’t supported on the edition, ONLINE options (and related low-priority waits) are disabled.
* If compression isn’t supported, compression options are disabled and only uncompressed partitions are considered.

---

## Quick start

### Help / cheatsheet

```sql
EXEC DBA.usp_RebuildIndexesIfBloated @Help = 1;
```


## Quick start

### Help / cheatsheet

```sql
EXEC DBA.usp_RebuildIndexesIfBloated @Help = 1;
````

### Dry run across all user DBs

```sql
EXEC DBA.usp_RebuildIndexesIfBloated
    @TargetDatabases = N'ALL_USER_DBS',
    @WhatIf          = 1;
```

### All user DBs except DW & SSRS, log centrally, execute

```sql
EXEC DBA.usp_RebuildIndexesIfBloated
    @TargetDatabases = N'ALL_USER_DBS,-DW,-ReportServer,-ReportServerTempDB',
    @LogDatabase     = N'UtilityDb',
    @WhatIf          = 0;
```

### One database, ONLINE with DOP 4

```sql
EXEC DBA.usp_RebuildIndexesIfBloated
    @TargetDatabases = N'YourDb',
    @Online          = 1,
    @MaxDOP          = 4,
    @WhatIf          = 0;
```

### One database, only specific indexes (and exclude one)

```sql
EXEC DBA.usp_RebuildIndexesIfBloated
    @TargetDatabases = N'YourDb',
    @Indexes         = N'dbo.IX_BigTable,dbo.BigTable.IX_BigTable_Cold,-dbo.BigTable.IX_DoNotTouch',
    @WhatIf          = 0;
```

### Force ROW compression

```sql
EXEC DBA.usp_RebuildIndexesIfBloated
    @TargetDatabases          = N'YourDb',
    @UseCompressionFromSource = 0,
    @ForceCompression         = N'ROW',
    @WhatIf                   = 0;
```

### Low-priority wait

```sql
EXEC DBA.usp_RebuildIndexesIfBloated
    @TargetDatabases          = N'YourDb',
    @Online                   = 1,
    @WaitAtLowPriorityMinutes = 5,
    @AbortAfterWait           = N'BLOCKERS',
    @WhatIf                   = 0;
```

### Resumable with MAX_DURATION (SQL 2019+)

```sql
EXEC DBA.usp_RebuildIndexesIfBloated
    @TargetDatabases    = N'YourDb',
    @Online             = 1,
    @Resumable          = 1,
    @MaxDurationMinutes = 60,
    @WhatIf             = 0;
```

---

## Output & logging

* **Messages**: per-DB `STARTING` / per-index rebuild messages / per-DB `COMPLETED`.
* **Log table**: `[DBA].[IndexBloatRebuildLog]` gets one row per candidate/action with:

  * Identity: `database_name, schema_name, table_name, index_name, index_id, partition_number`
  * Metrics: `page_count, page_density_pct, fragmentation_pct, avg_row_bytes, record_count, ghost_record_count, forwarded_record_count`
  * AU pages: `au_total_pages, au_used_pages, au_data_pages`
  * Options: `chosen_fill_factor, online_on, maxdop_used`
  * Action & status: `DRYRUN/REBUILD` and `SKIPPED/PENDING/SUCCESS/FAILED/SUCCESS_OFFLINE_FALLBACK/FAILED_OFFLINE_FALLBACK`
  * `cmd` text and full error metadata on failures
* **Schema hardening**: if the log table is an older deployment, v2.8 enforces key text column widths so retry/error paths don’t fail due to truncation.

---

## Operational notes

* **Central log collation**: if `@LogDatabase` collation differs from a target DB, v2.8 explicitly collates inserts/joins/comparisons so the run doesn’t blow up mid-flight.
* **tempdb/version store**: ONLINE + `SORT_IN_TEMPDB = ON` pushes work to tempdb and version store; RESUMABLE implicitly forces `SORT_IN_TEMPDB = OFF`.
* **Transaction log**: rebuilds are fully logged; ensure primaries/secondaries can keep up.
* **Extent ordering**: if you require strictly ordered allocation, set `@MaxDOP = 1`.

---

## Known limitations

* Rowstore only; columnstore is out of scope.
* Memory-optimized tables are skipped.
* If an ONLINE rebuild fails for reasons unrelated to ONLINE support, no OFFLINE retry is attempted (by design).

---

## Versioning

* **Version**: 2.8
* **Last updated**: 2026-01-20

See the procedure header for exact parameter list and capability checks.

---

## Contributing

Issues and PRs welcome. Please include:

* Exact SQL Server version and edition
* Execution parameters used
* Snippets from `[DBA].[IndexBloatRebuildLog]` for failing cases
* If relevant, `sys.dm_db_index_physical_stats` output for the affected index

---

## License

MIT. Do good things. Rebuild responsibly.

---

## Credit

Created by **Mike Fuller**.

---

# DBA.usp_UpdateStatisticsIfChanged (v**1.3**, 2025-11-16)

From a **single** utility DB, update statistics in one or many target databases **only when they’ve changed** — either by a **threshold %** or using `ALL_CHANGES`. Supports `FULLSCAN`, `DEFAULT`, or `SAMPLED <n>%`. All actions are centrally logged.

> **Works on SQL Server 2014–2025.** Designed to be deployed once in a Utility/DBA DB and run against many user DBs. Defaults to **WhatIf**.

---

## Why this exists

* Stop carpet-bombing stats: touch the ones that moved.
* Keep the story straight: central log shows **what** you updated, **why**, **how**, and **with what sample**.

---

## Features

* Multi-DB orchestration: CSV, **ALL_USER_DBS**, and `-DbName` exclusions; online, read-write DBs only.
* Candidate detection via `sys.dm_db_stats_properties`:

  * `ALL_CHANGES`: any stats with `modification_counter > 0`
  * Threshold mode: `change% >= @ChangeThresholdPercent` (or `rows=0 AND modification>0`)
* Sampling modes: `FULLSCAN`, `DEFAULT`, or `SAMPLED n%`
  *Note: value is rounded to a whole percent for SQL Server 2014.*
* Builds per-object `UPDATE STATISTICS` commands prefixed with `USE <DB>;` for safety.
* Central logging to `[DBA].[UpdateStatsLog]`, including a **run_id** to group a run.
* Defaults to **WhatIf** (log/return only).

---

## Parameters

| Parameter                 | Type          |      Default | Notes                                                                                         |
| ------------------------- | ------------- | -----------: | --------------------------------------------------------------------------------------------- |
| `@Help`                   | BIT           |            0 | `1` prints help and examples; returns.                                                        |
| `@TargetDatabases`        | NVARCHAR(MAX) | **required** | CSV list or **ALL_USER_DBS** (exact case) with `-DbName` exclusions.                          |
| `@ChangeThresholdPercent` | DECIMAL(6,2)  |         NULL | Used when `@ChangeScope IS NULL`. Must be `0–100`.                                            |
| `@ChangeScope`            | VARCHAR(20)   |         NULL | Exact-case token **ALL_CHANGES** to update any stats with changes; otherwise threshold mode.  |
| `@SampleMode`             | VARCHAR(12)   |    `DEFAULT` | Exact-case tokens: **FULLSCAN**, **DEFAULT**, **SAMPLED**.                                    |
| `@SamplePercent`          | DECIMAL(6,2)  |         NULL | Required when `@SampleMode='SAMPLED'`. Range `>0` to `<=100`; rounded to whole % on SQL 2014. |
| `@LogDatabase`            | SYSNAME       |         NULL | Central log DB; defaults to **this** utility DB when NULL.                                    |
| `@WhatIf`                 | BIT           |            1 | `1` = DRYRUN (log/return only); `0` = execute.                                                |

---

## Output & logging

* **Result set**: per run, a summary by object and stats name with `action`, `status`, and counts.
* **Log table**: `[DBA].[UpdateStatsLog]` gets one row per candidate/action with:

  * Identity: `database_name, schema_name, table_name, stats_name, stats_id`
  * Signals: `rows, modification_counter, change_pct, last_updated, rows_sampled`
  * Options & action: `sample_mode, [action] DRYRUN/UPDATE, cmd`
  * Status: `SKIPPED/PENDING/SUCCESS/FAILED`, plus full error metadata
  * `run_id` to correlate a given execution

---

## Quick start

### Help / cheatsheet

```sql
EXEC DBA.usp_UpdateStatisticsIfChanged @Help = 1;
```

### All user DBs except DBA, ALL_CHANGES, SAMPLED 20% (dry run)

```sql
EXEC DBA.usp_UpdateStatisticsIfChanged
    @TargetDatabases        = N'ALL_USER_DBS,-DBA',
    @ChangeScope            = 'ALL_CHANGES',
    @SampleMode             = 'SAMPLED',
    @SamplePercent          = 20,
    @WhatIf                 = 1;
```

### One DB, threshold 20%, DEFAULT (execute)

```sql
EXEC DBA.usp_UpdateStatisticsIfChanged
    @TargetDatabases        = N'DBA',
    @ChangeThresholdPercent = 20,
    @SampleMode             = 'DEFAULT',
    @WhatIf                 = 0;
```

### Two DBs, FULLSCAN (dry run), central log

```sql
EXEC DBA.usp_UpdateStatisticsIfChanged
    @TargetDatabases = N'Orders,Inventory',
    @SampleMode      = 'FULLSCAN',
    @LogDatabase     = N'UtilityDb',
    @WhatIf          = 1;
```

---

## Known limitations

* Relies on `sys.dm_db_stats_properties`; hypothetical indexes are excluded.
* Memory-optimized tables are skipped.
* Sampling granularity on SQL 2014 rounds to whole percent (engine behavior).

---

## Versioning

* **Version**: 1.3
* **Last updated**: 2025-11-16

---

## License

MIT. Go forth and sample responsibly.

---

## Credit

Created by **Mike Fuller**.

```
```
