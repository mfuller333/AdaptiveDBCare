---

# AdaptiveDBCare — Multi-Database Index & Statistics Optimization Release

This release of AdaptiveDBCare introduces coordinated, cross-database index rebuild and statistics update capabilities, enhanced telemetry, safer sampling, richer logging, and improved operator visibility. It elevates AdaptiveDBCare from single-database routines into a unified, intelligent maintenance engine for large SQL Server estates.

---

# DBA.usp_RebuildIndexesIfBloated (v**2.9**, 2026-01-20)

---

Rebuild **only** what’s bloated. This procedure finds leaf-level **rowstore** index partitions whose **avg_page_space_used_in_percent** is below a threshold, then rebuilds just those partitions, optionally **ONLINE**, optionally **RESUMABLE**, respecting (or overriding) **FILLFACTOR** and **DATA_COMPRESSION**, and logs every decision.

> **Works on SQL Server 2014–2025.** ONLINE/RESUMABLE features auto-downgrade based on edition and version (Enterprise/Developer/Evaluation for ONLINE; SQL 2019+ for RESUMABLE). Defaults to safe **WhatIf** mode.

---

## What’s new in 2.9

* **Compression override honored during OFFLINE fallback**
  In v2.8, if an ONLINE rebuild failed and the procedure retried OFFLINE, the OFFLINE command always reused the partition’s existing compression.
  In v2.9, OFFLINE fallback now fully honors the caller’s intent:

  * `@UseCompressionFromSource = 1` → preserves partition compression
  * `@UseCompressionFromSource = 0` + `@ForceCompression = NONE | ROW | PAGE` → applies the forced compression even during OFFLINE fallback

  ONLINE success and OFFLINE fallback now produce **identical compression outcomes**.

* **OFFLINE fallback command logic aligned with ONLINE**
  OFFLINE rebuild commands now follow the same decision path as ONLINE rebuilds for:

  * compression source vs override
  * fill factor selection
  * `MAXDOP`
  * `SORT_IN_TEMPDB`

  This eliminates behavioral drift between first attempt and retry.

* **Documentation clarity around compression support**
  The feature and safeguard sections now explicitly document that when compression is unsupported at the server level, compression options are disabled and only uncompressed partitions are eligible.

No breaking changes. No behavioral regressions. Existing automation continues to work as-is.

---

## Why this exists

* **Page density pays the rent** especially on SSD and NVMe. Logical fragmentation does not show up on your invoice.
* **Surgical partitions**: touch only the slices that need it; stop hammering every index every time.
* **Receipts or it didn’t happen**: every candidate, command, and outcome is logged for audit, tuning, and trending.

---

## Features

* Targets **rowstore** indexes only (clustered and nonclustered), **leaf level**.
* Skips tiny partitions via `@MinPageCount`.
* **Partition-aware**: rebuilds only affected partitions, not entire indexes.
* **ONLINE = ON** when supported, with optional `WAIT_AT_LOW_PRIORITY (MAX_DURATION, ABORT_AFTER_WAIT)`.
* **OFFLINE fallback** when ONLINE is not allowed or supported.
* **RESUMABLE** rebuilds (SQL Server 2019+, ONLINE only); auto-disabled when unsupported.
* **Compression control**:

  * preserve from source, or
  * force `NONE`, `ROW`, or `PAGE`
  * auto-disabled if unsupported on the server
* **Fill factor**:

  * preserve per index, or
  * enforce a global `@FillFactor`
* **MaxDOP**:

  * NULL honors server default
  * `0` allows unlimited
  * explicit values supported
* **SORT_IN_TEMPDB**:

  * ON by default
  * automatically OFF when RESUMABLE is used (engine limitation)
* **Index filtering (single DB only)** via `@Indexes` include and exclude tokens.
* **Central or per-DB logging** to `[DBA].[IndexBloatRebuildLog]`.
* Captures trending signals:

  * `avg_row_bytes`
  * `record_count`
  * `ghost_record_count`
  * `forwarded_record_count`
  * allocation unit pages (`au_total_pages`, `au_used_pages`, `au_data_pages`)
* Defaults to **WhatIf** (dry run).

---

## Compatibility

* **SQL Server**: 2014–2025
* **ONLINE rebuilds**: Enterprise, Developer, Evaluation
* **RESUMABLE rebuilds**: SQL Server 2019+ and ONLINE
* **Compression**: auto-detected per server and edition

The procedure self-detects engine capabilities and quietly disables unsafe options.

---

## Installation

1. Ensure the `DBA` schema exists (created automatically if missing).
2. Deploy the procedure once, typically into a Utility or DBA database.
3. First execution ensures `[DBA].[IndexBloatRebuildLog]` exists in either:

   * the target database, or
   * a central log database specified via `@LogDatabase`.

If the log table already exists, v2.9 enforces compatible column widths to prevent retry and error-path failures.

> Deploy once. Run anywhere. Log centrally or locally.

---

## Parameters

| Parameter                   | Type          | Default       | Notes                                                                                                                                                                 |
| --------------------------- | ------------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@Help`                     | BIT           | 0             | `1` prints help, capabilities, and examples; returns without scanning.                                                                                                |
| `@TargetDatabases`          | NVARCHAR(MAX) | **required**  | CSV list or `ALL_USER_DBS` with exclusions using `-DbName`. System DBs and `distribution` are always excluded.                                                        |
| `@Indexes`                  | NVARCHAR(MAX) | `ALL_INDEXES` | **Single DB only.** CSV allow/deny list using `schema.index` or `schema.table.index`; exclusions with `-`. Forced to `ALL_INDEXES` when more than one DB is targeted. |
| `@MinPageDensityPct`        | DECIMAL(5,2)  | 70.0          | Rebuild when leaf partition density is below this percent.                                                                                                            |
| `@MinPageCount`             | INT           | 1000          | Skip partitions smaller than this page count.                                                                                                                         |
| `@UseExistingFillFactor`    | BIT           | 1             | Preserve each index’s fill factor.                                                                                                                                    |
| `@FillFactor`               | TINYINT       | NULL          | Used only when `@UseExistingFillFactor = 0`. Valid range 1–100.                                                                                                       |
| `@Online`                   | BIT           | 1             | ONLINE when supported; OFFLINE fallback when not.                                                                                                                     |
| `@MaxDOP`                   | INT           | NULL          | NULL uses server default; `0` or explicit values allowed.                                                                                                             |
| `@SortInTempdb`             | BIT           | 1             | Automatically forced OFF when RESUMABLE is enabled.                                                                                                                   |
| `@UseCompressionFromSource` | BIT           | 1             | Preserve partition compression when supported.                                                                                                                        |
| `@ForceCompression`         | NVARCHAR(20)  | NULL          | `NONE`, `ROW`, or `PAGE` when not preserving.                                                                                                                         |
| `@SampleMode`               | VARCHAR(16)   | `SAMPLED`     | `SAMPLED` or `DETAILED`.                                                                                                                                              |
| `@CaptureTrendingSignals`   | BIT           | 0             | If `1` and `SAMPLED`, auto-upshifts to `DETAILED`.                                                                                                                    |
| `@LogDatabase`              | SYSNAME       | NULL          | Central log DB; defaults to target DB when NULL.                                                                                                                      |
| `@WaitAtLowPriorityMinutes` | INT           | NULL          | Enables `WAIT_AT_LOW_PRIORITY (MAX_DURATION)`.                                                                                                                        |
| `@AbortAfterWait`           | NVARCHAR(20)  | NULL          | `NONE`, `SELF`, or `BLOCKERS`.                                                                                                                                        |
| `@Resumable`                | BIT           | 0             | SQL Server 2019+; requires ONLINE.                                                                                                                                    |
| `@MaxDurationMinutes`       | INT           | NULL          | RESUMABLE `MAX_DURATION`.                                                                                                                                             |
| `@DelayMsBetweenCommands`   | INT           | NULL          | Optional delay between rebuilds in milliseconds.                                                                                                                      |
| `@WhatIf`                   | BIT           | 1             | Dry run by default.                                                                                                                                                   |

---

## Important safeguards

* `@SampleMode` accepts only `SAMPLED` or `DETAILED`.
* RESUMABLE requires ONLINE and SQL Server 2019+.
* ONLINE options are auto-disabled when unsupported.
* Compression options are auto-disabled when unsupported.
* When compression is unsupported, only uncompressed partitions are considered.

---

## Quick start

### Help / cheatsheet

```sql
EXEC DBA.usp_RebuildIndexesIfBloated @Help = 1;
```

### Dry run across all user databases

```sql
EXEC DBA.usp_RebuildIndexesIfBloated
    @TargetDatabases = N'ALL_USER_DBS',
    @WhatIf          = 1;
```

### All user DBs except DW and SSRS, central log, execute

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

### One database, specific indexes only

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

### Resumable rebuild with MAX_DURATION (SQL 2019+)

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

* **Messages**:

  * per-DB STARTING and COMPLETED
  * per-index rebuild progress

* **Log table**: `[DBA].[IndexBloatRebuildLog]`

  * Identity: database, schema, table, index, partition
  * Metrics: density, fragmentation, row and ghost counts, AU pages
  * Options used: fill factor, ONLINE, MAXDOP
  * Action and status:

    * `DRYRUN`
    * `SUCCESS`
    * `FAILED`
    * `SUCCESS_OFFLINE_FALLBACK`
    * `FAILED_OFFLINE_FALLBACK`
  * Full command text and error metadata

* **Schema hardening**: legacy deployments are auto-corrected for text column widths.

---

## Operational notes

* Central log collation is handled explicitly to avoid runtime failures.
* ONLINE rebuilds consume version store and tempdb.
* All rebuilds are fully logged; plan log space accordingly.
* For strict extent ordering, use `@MaxDOP = 1`.

---

## Known limitations

* Rowstore only; columnstore excluded.
* Memory-optimized tables are skipped.
* OFFLINE fallback triggers only for ONLINE-not-supported failures by design.

---

## Versioning

* **Version**: 2.9
* **Last updated**: 2026-01-20

---

## Credit

Created by **Mike Fuller**.

MIT licensed. Rebuild responsibly.

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
