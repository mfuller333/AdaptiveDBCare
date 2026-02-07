# AdaptiveDBCare — Multi-Database Index & Statistics Optimization Release

This release of **AdaptiveDBCare** introduces coordinated, cross-database index rebuild and statistics update capabilities, enhanced telemetry, safer sampling, richer logging, and improved operator visibility. It elevates AdaptiveDBCare from single-database routines into a unified, intelligent maintenance engine for large SQL Server estates.

---

# DBA.usp_RebuildIndexesIfBloated

**Version:** **3.1.1**
**Last updated:** **2026-02-07**

---

## What this procedure does

Rebuild **only** what’s bloated — and only what is truly harmful to SSD read-ahead.

This procedure scans **leaf-level rowstore** index **partitions** and flags a partition as a rebuild candidate when **one (or both)** of these conditions are true:

* **Low page density**
  `avg_page_space_used_in_percent < @MinPageDensityPct`
* **Poor extent continuity**
  `avg_fragment_size_in_pages < @MinAvgFragmentSizePages`
  This is the metric that correlates to **read-ahead effectiveness** on SSD/NVMe.

It then rebuilds **just those partitions**, optionally **ONLINE**, optionally **RESUMABLE**, respecting (or overriding) **FILLFACTOR** and **DATA_COMPRESSION**, and logs every decision.

> **Works on SQL Server 2014–2025.** ONLINE/RESUMABLE features auto-downgrade based on edition and version (Enterprise/Developer/Evaluation for ONLINE; SQL 2019+ for RESUMABLE). Defaults to safe **WhatIf** mode.

---

## Understanding the signals

### Page density

`avg_page_space_used_in_percent` is the **actual fullness** of leaf pages. Low density means you’re hauling more pages through:

* buffer pool
* storage
* read-ahead
* scans

Even on SSD, that translates to real cost: more logical reads, more memory pressure, more I/O work.

### Read-ahead and extent continuity

`avg_fragment_size_in_pages` is the “how long are the contiguous runs?” signal.

On SSD, **sequential is still cheaper than random**, and SQL Server’s read-ahead performs best when it can pull **longer runs**. Very small fragment sizes mean scans turn into a pile of tiny read requests and the engine can’t read ahead efficiently.

That said: read-ahead fragmentation only matters when an object is **large** and actually **scanned** — which is why the READ_AHEAD path is gated.

---

## READ_AHEAD path is a gated rule set

**Important clarification (v3.1):** the **READ_AHEAD** path is a **multi-factor gated rule-set**, not a single threshold.

A partition is treated as a read-ahead candidate only when **all** of the following gates are satisfied:

* `page_count >= @ReadAheadMinPageCount` (default **50000**)
  *Why:* small objects don’t benefit meaningfully from read-ahead tuning.
* `avg_fragment_size_in_pages < @MinAvgFragmentSizePages` (default **8**)
  *Why:* fragment runs shorter than an extent are the “read-ahead is falling apart” signal.
* `avg_fragmentation_in_percent >= @ReadAheadMinFragPct` (default **30**)
  *Why:* avoids noise / false positives on low-frag objects.
* Fill factor gate: `source_fill_factor >= @ReadAheadMinFillFactor` (default **90**)
  *Why:* prevents churn on indexes that are intentionally sparse.
* Scan evidence (at least one must be true):

  * `(user_scans + user_lookups) >= @ReadAheadMinScanOps` (default **1000**)
    **OR**
  * `last_user_scan` within `@ReadAheadLookbackDays` (default **7**)
    *Why:* if nothing is scanning it, read-ahead quality is irrelevant.

> Note: scan evidence uses `sys.dm_db_index_usage_stats`, which resets when SQL Server restarts. That’s a feature, not a bug: it keeps the gating tied to *recent* reality.

---

## Low fill factor avoidance

Low fill factor is often intentional (write-heavy OLTP, split control, hot ranges).

Density-based rebuilds avoid rebuilding low fill factor indexes (intentional free space) unless density is **extremely** poor.

This prevents rebuilding “sparse by design” objects and immediately reintroducing the same free space the next time writes hit.

---

## What’s new in 3.1.1

This is a **non-breaking patch release** focused on correctness and operator clarity.

* **Zero-candidate paths are handled cleanly**

  * When a database has no candidates, the procedure short-circuits safely with clear messages (especially helpful in Agent history).
* **Message formatting hardened**

  * Correct `RAISERROR … WITH NOWAIT` formatting to avoid edge-case failures during progress output.
* **Read-ahead gating enforced consistently**

  * Ensures the READ_AHEAD path cannot trigger unless **every** gate is satisfied (no “partial gate leakage”).
* **Candidate reason is always populated**

  * Logged `candidate_reason` is consistently `DENSITY` or `READ_AHEAD`.

No breaking changes intended.

---

## What’s new in 3.1

* **Read-ahead path is now tightly gated (fewer false positives)**
  The read-ahead signal (`avg_fragment_size_in_pages`) is now *only* allowed to trigger rebuilds when the partition is large enough and there is real scan evidence.

  New read-ahead guardrail parameters:

  * `@ReadAheadMinPageCount` (default **50000**)
  * `@ReadAheadMinFragPct` (default **30.0**)
  * `@ReadAheadMinScanOps` (default **1000**)
  * `@ReadAheadLookbackDays` (default **7**)
  * `@ReadAheadMinFillFactor` (default **90**)

* **Low fill factor avoidance (stop rebuilding “sparse by design”)**
  Density-based rebuilds now avoid rebuilding indexes with low fill factor (intentional free space) unless density is **extremely** poor.

  New low-FF parameters:

  * `@SkipLowFillFactor` (default **1**)
  * `@LowFillFactorThreshold` (default **80**)
  * `@LowFillFactorDensitySlackPct` (default **15.0**)

* **New logged decision signals**
  The log table now records *why* a partition was selected, and the fill factor context that influenced the decision:

  * `candidate_reason` = `DENSITY` | `READ_AHEAD`
  * `source_fill_factor`
  * `fill_factor_guard_applied`

* **Clearer default logging behavior**
  If you **do not** specify `@LogDatabase`, the procedure will create/maintain a log table **in each target database**.

  * Default (`@LogDatabase = NULL`): each target DB gets its own `[DBA].[IndexBloatRebuildLog]`
  * Central logging (`@LogDatabase = N'UtilityDb'`): one log table in the specified DB, recording rows for all targets

* **Collation-safe central logging**
  Per-target and per-log database collations are captured and applied so cross-database inserts/joins do not fail on collation conflicts.

Existing automation continues to work as-is, but with stricter rebuild gating (by design).

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

* Candidate detection supports **two independent signals**:

  * low density (`avg_page_space_used_in_percent`)
  * low avg fragment size (`avg_fragment_size_in_pages`) for SSD read-ahead (**now tightly gated**)

* **Read-ahead path guardrails** (v3.1):

  * minimum size: `@ReadAheadMinPageCount`
  * minimum fragmentation: `@ReadAheadMinFragPct`
  * fill factor gate: `@ReadAheadMinFillFactor`
  * scan evidence: `@ReadAheadMinScanOps` **or** recent `last_user_scan` within `@ReadAheadLookbackDays`

* **Low fill factor guardrails** (v3.1):

  * avoid rebuilding low-FF indexes unless density is far worse than the normal threshold

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

* Defaults to **WhatIf** (dry run).

---

## Signals and telemetry captured

### Logged signals in `[DBA].[IndexBloatRebuildLog]`

These are persisted for auditing/trending:

* Partition identity + size:

  * `database_name`, `schema_name`, `table_name`, `index_name`, `index_id`, `partition_number`
  * `page_count`

* Bloat / fragmentation signals:

  * `page_density_pct` (from `avg_page_space_used_in_percent`)
  * `fragmentation_pct` (from `avg_fragmentation_in_percent`)
  * `avg_fragment_size_pages` (from `avg_fragment_size_in_pages`)

* Decision signals (newer / emphasized in v3.1):

  * `candidate_reason` (`DENSITY` | `READ_AHEAD`)
  * `source_fill_factor`
  * `fill_factor_guard_applied`
  * `chosen_fill_factor`

* Row + allocation signals:

  * `avg_row_bytes`
  * `record_count`
  * `ghost_record_count`
  * `forwarded_record_count`
  * `au_total_pages`, `au_used_pages`, `au_data_pages`

* Execution options and outcomes:

  * `online_on`, `maxdop_used`
  * `action`, `status`, full `cmd`
  * error metadata (`error_message`, `error_number`, `error_severity`, `error_state`, `error_line`, `error_proc`)

### Usage signals used for gating (captured during evaluation)

These are collected from `sys.dm_db_index_usage_stats` to qualify read-ahead candidates (scan evidence). They influence selection but are **not persisted** to the log table in v3.1:

* `user_seeks`, `user_scans`, `user_lookups`, `user_updates`
* `last_user_seek`, `last_user_scan`, `last_user_lookup`

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
3. First execution ensures `[DBA].[IndexBloatRebuildLog]` exists:

   * **Default behavior (important):** if `@LogDatabase` is **NULL** (default), the procedure creates/uses the log table **inside each target database**.
   * If `@LogDatabase` is specified, the procedure creates/uses the log table in that **single central database**.

If the log table already exists, the procedure upgrades it as needed and enforces compatible column widths to prevent retry and error-path failures.

> Deploy once. Run anywhere. Log centrally or locally.

---

## Parameters

| Parameter                       | Type          | Default       | Notes                                                                                                                                                                 |
| ------------------------------- | ------------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@Help`                         | BIT           | 0             | `1` prints help, capabilities, and examples; returns without scanning.                                                                                                |
| `@TargetDatabases`              | NVARCHAR(MAX) | **required**  | CSV list or `ALL_USER_DBS` with exclusions using `-DbName`. System DBs and `distribution` are always excluded.                                                        |
| `@Indexes`                      | NVARCHAR(MAX) | `ALL_INDEXES` | **Single DB only.** CSV allow/deny list using `schema.index` or `schema.table.index`; exclusions with `-`. Forced to `ALL_INDEXES` when more than one DB is targeted. |
| `@MinPageDensityPct`            | DECIMAL(5,2)  | 70.0          | Rebuild when leaf partition density is below this percent.                                                                                                            |
| `@MinPageCount`                 | INT           | 1000          | Skip partitions smaller than this page count.                                                                                                                         |
| `@MinAvgFragmentSizePages`      | INT           | 8             | Rebuild when `avg_fragment_size_in_pages` drops below this value (SSD read-ahead indicator). Set NULL to disable. Internally passed as `@pMinAvgFragSizePages`.       |
| `@ReadAheadMinPageCount`        | INT           | 50000         | Read-ahead path: minimum `page_count` to consider the read-ahead signal.                                                                                              |
| `@ReadAheadMinFragPct`          | DECIMAL(5,2)  | 30.0          | Read-ahead path: minimum fragmentation percent to reduce noise.                                                                                                       |
| `@ReadAheadMinScanOps`          | BIGINT        | 1000          | Read-ahead path: minimum scans+lookups since restart.                                                                                                                 |
| `@ReadAheadLookbackDays`        | INT           | 7             | Read-ahead path: accept if `last_user_scan` is within this many days.                                                                                                 |
| `@ReadAheadMinFillFactor`       | TINYINT       | 90            | Read-ahead path: require fill factor >= this to reduce churn on sparse indexes.                                                                                       |
| `@SkipLowFillFactor`            | BIT           | 1             | If 1, avoids rebuilding low fill factor indexes unless density is **much worse**.                                                                                     |
| `@LowFillFactorThreshold`       | TINYINT       | 80            | Fill factor <= this is treated as intentionally sparse.                                                                                                               |
| `@LowFillFactorDensitySlackPct` | DECIMAL(5,2)  | 15.0          | For low-FF indexes, require density < (`@MinPageDensityPct - slack`) to rebuild via density path.                                                                     |
| `@UseExistingFillFactor`        | BIT           | 1             | Preserve each index’s fill factor.                                                                                                                                    |
| `@FillFactor`                   | TINYINT       | NULL          | Used only when `@UseExistingFillFactor = 0`. Valid range 1–100.                                                                                                       |
| `@Online`                       | BIT           | 1             | ONLINE when supported; OFFLINE fallback when not.                                                                                                                     |
| `@MaxDOP`                       | INT           | NULL          | NULL uses server default; `0` or explicit values allowed.                                                                                                             |
| `@SortInTempdb`                 | BIT           | 1             | Automatically forced OFF when RESUMABLE is enabled.                                                                                                                   |
| `@UseCompressionFromSource`     | BIT           | 1             | Preserve partition compression when supported.                                                                                                                        |
| `@ForceCompression`             | NVARCHAR(20)  | NULL          | `NONE`, `ROW`, or `PAGE` when not preserving.                                                                                                                         |
| `@SampleMode`                   | VARCHAR(16)   | `SAMPLED`     | `SAMPLED` or `DETAILED`.                                                                                                                                              |
| `@CaptureTrendingSignals`       | BIT           | 0             | If `1` and `SAMPLED`, auto-upshifts to `DETAILED`.                                                                                                                    |
| `@LogDatabase`                  | SYSNAME       | NULL          | **If NULL (default), log table is created/used in each target DB.** If set, logs centrally in the specified DB.                                                       |
| `@WaitAtLowPriorityMinutes`     | INT           | NULL          | Enables `WAIT_AT_LOW_PRIORITY (MAX_DURATION)`.                                                                                                                        |
| `@AbortAfterWait`               | NVARCHAR(20)  | NULL          | `NONE`, `SELF`, or `BLOCKERS`.                                                                                                                                        |
| `@Resumable`                    | BIT           | 0             | SQL Server 2019+; requires ONLINE.                                                                                                                                    |
| `@MaxDurationMinutes`           | INT           | NULL          | RESUMABLE `MAX_DURATION`.                                                                                                                                             |
| `@DelayMsBetweenCommands`       | INT           | NULL          | Optional delay between rebuilds in milliseconds.                                                                                                                      |
| `@WhatIf`                       | BIT           | 1             | Dry run by default.                                                                                                                                                   |

---

## Important safeguards

* `@SampleMode` accepts only `SAMPLED` or `DETAILED`.
* RESUMABLE requires ONLINE and SQL Server 2019+.
* ONLINE options are auto-disabled when unsupported.
* Compression options are auto-disabled when unsupported.
* When compression is unsupported, only uncompressed partitions are considered.
* `@MinAvgFragmentSizePages` can be set to NULL to disable the SSD read-ahead trigger.
* Read-ahead candidates must pass minimum size + fragmentation + scan evidence + fill factor gates (v3.1).
* Low fill factor guardrails reduce rebuild churn on intentionally sparse indexes (v3.1).

---

## Quick start

### Help / cheatsheet

```sql
EXEC DBA.usp_RebuildIndexesIfBloated @Help = 1;
```

### Dry run across all user databases (logs in each DB by default)

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
  * per-index rebuild progress (includes candidate reason)

* **Log table**: `[DBA].[IndexBloatRebuildLog]`

  * **Default behavior:** if `@LogDatabase` is NULL, the log table is created/used in **each target database**
  * Central logging: specify `@LogDatabase` to log all targets into one DB

  Captures:

  * Identity: database, schema, table, index, partition
  * Metrics: density, fragmentation, avg fragment size, row/ghost/forwarded counts, AU pages
  * Decision: `candidate_reason`, `source_fill_factor`, `fill_factor_guard_applied`
  * Options used: chosen fill factor, ONLINE, MAXDOP, command text
  * Status/action: DRYRUN / execution statuses, plus error metadata

* **Schema hardening**: legacy deployments are auto-corrected for text column widths, and log schema is upgraded when missing columns.

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

* **Version**: 3.1.1
* **Last updated**: 2026-02-07

---

## Credit

Created by **Mike Fuller**.

MIT licensed. Rebuild responsibly.

---

# DBA.usp_UpdateStatisticsIfChanged

**Version:** **1.3**
**Last updated:** **2025-11-16**

From a **single** utility DB, update statistics in one or many target databases **only when they’ve changed** — either by a **threshold %** or using `ALL_CHANGES`. Supports `FULLSCAN`, `DEFAULT`, or `SAMPLED <n>%`. All actions are centrally logged.

> **Works on SQL Server 2014–2025.** Designed to be deployed once in a Utility/DBA DB and run against many user DBs. Defaults to **WhatIf**.

---

## What “changed” means

This procedure uses `sys.dm_db_stats_properties` to determine whether a statistic has moved enough to justify an update.

Two modes exist:

* **ALL_CHANGES**

  * Updates any statistic where `modification_counter > 0`
  * Best when you want “touch anything that moved” behavior without guessing a threshold
* **Threshold mode**

  * Updates when `change% >= @ChangeThresholdPercent`
  * Useful when you want fewer updates and clearer control

Edge case handling:

* stats where `rows = 0 AND modification_counter > 0` are still candidates (prevents “stale empty table stats” traps).

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
