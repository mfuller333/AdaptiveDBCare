SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF SCHEMA_ID(N'DBA') IS NULL
    EXEC('CREATE SCHEMA DBA AUTHORIZATION dbo');
    GO

IF OBJECT_ID('DBA.usp_RebuildIndexesIfBloated','P') IS NULL
    EXEC('CREATE PROCEDURE DBA.usp_RebuildIndexesIfBloated AS RETURN 0;');
    GO
/*****************************************************************************************************************/
/****** Name:        DBA.usp_RebuildIndexesIfBloated                                                        ******/
/****** Purpose:     Rebuild only leaf-level ROWSTORE index partitions that are:                            ******/
/******              1) Bloated by low page density (avg_page_space_used_in_percent), OR                    ******/
/******              2) Likely impacting read-ahead due to short fragment runs (avg_fragment_size_in_pages) ******/
/******                 BUT only when scan evidence exists (dm_db_index_usage_stats).                       ******/
/******                                                                                                     ******/
/******              Includes guardrails to avoid rebuilding indexes that are intentionally sparse          ******/
/******              (very low FILLFACTOR), unless density is extremely poor.                               ******/
/******                                                                                                     ******/
/****** Input:       @Help                       = 1 prints help and examples; 0 runs normally              ******/
/******              @TargetDatabases            = CSV of DBs, or 'ALL_USER_DBS', with optional exclusions  ******/
/******              @Indexes                    = (single-target-db only) CSV of indexes or 'ALL_INDEXES'  ******/
/******              @MinPageDensityPct          = rebuild when avg page density < this (default 70.0)      ******/
/******              @MinPageCount               = skip partitions < this many pages (default 1000)         ******/
/******                                                                                                     ******/
/******              Read-ahead path (tightly gated):                                                       ******/
/******              @MinAvgFragmentSizePages    = avg_fragment_size_in_pages threshold (default 8)         ******/
/******              @ReadAheadMinPageCount      = min page_count for read-ahead checks (default 50000)     ******/
/******              @ReadAheadMinFragPct        = min fragmentation pct for read-ahead checks (default 30) ******/
/******              @ReadAheadMinScanOps        = min scans+lookups since restart (default 1000)           ******/
/******              @ReadAheadLookbackDays      = accept recent last_user_scan (default 7)                 ******/
/******                                                                                                     ******/
/******              Low fill factor avoidance:                                                             ******/
/******              @SkipLowFillFactor          = 1 apply guardrails (default 1)                           ******/
/******              @LowFillFactorThreshold     = treat <= this as intentionally sparse (default 80)       ******/
/******              @LowFillFactorDensitySlackPct = require much worse density for low FF (default 15.0)   ******/
/******              @ReadAheadMinFillFactor     = require FF >= this for read-ahead path (default 90)      ******/
/******                                                                                                     ******/
/******              Online + rebuild options: ONLINE, MAXDOP, SORT_IN_TEMPDB, compression, resumable, etc. ******/
/******                                                                                                     ******/
/****** Output:      1) Messages: STARTING db, per-index progress, COMPLETED db.                            ******/
/******              2) Rows logged to [DBA].[IndexBloatRebuildLog] with reason + fill factor metadata.     ******/
/******                 candidate_reason = DENSITY | READ_AHEAD                                             ******/
/******                 source_fill_factor, fill_factor_guard_applied                                       ******/
/******                                                                                                     ******/
/****** Created by:   Mike Fuller                                                                           ******/
/****** Date Updated: 2026-02-07                                                                            ******/
/****** Version:      3.1.1                                                                       ¯\_(ツ)_/¯******/
/*****************************************************************************************************************/

ALTER PROCEDURE [DBA].[usp_RebuildIndexesIfBloated]
      @Help                         BIT           = 0,
      @TargetDatabases              NVARCHAR(MAX),                  -- REQUIRED: CSV | 'ALL_USER_DBS' | negatives '-DbName'
      @Indexes                      NVARCHAR(MAX) = N'ALL_INDEXES', -- Single DB only. ALL_INDEXES or CSV tokens; supports exclusions with leading '-'
      @MinPageDensityPct            DECIMAL(5,2)  = 70.0,
      @MinPageCount                 INT           = 1000,
      @MinAvgFragmentSizePages      INT           = 8,
      @ReadAheadMinPageCount        INT           = 50000,          -- read-ahead path: only consider large leaf partitions
      @ReadAheadMinFragPct          DECIMAL(5,2)  = 30.0,           -- read-ahead path: avoid trivial fragmentation noise
      @ReadAheadMinScanOps          BIGINT        = 1000,           -- read-ahead path: require scan evidence (since last restart)
      @ReadAheadLookbackDays        INT           = 7,              -- read-ahead path: accept recent last_user_scan 
      @ReadAheadMinFillFactor       TINYINT       = 90,
      @SkipLowFillFactor            BIT           = 1,
      @LowFillFactorThreshold       TINYINT       = 80,
      @LowFillFactorDensitySlackPct DECIMAL(5,2)  = 15.0,
      @UseExistingFillFactor        BIT           = 1,
      @FillFactor                   TINYINT       = NULL,
      @Online                       BIT           = 1,
      @MaxDOP                       INT           = NULL,
      @SortInTempdb                 BIT           = 1,
      @UseCompressionFromSource     BIT           = 1,
      @ForceCompression             NVARCHAR(20)  = NULL,
      @SampleMode                   VARCHAR(16)   = 'SAMPLED',      -- SAMPLED | DETAILED
      @CaptureTrendingSignals       BIT           = 0,              -- if 1 and SampleMode=SAMPLED, auto-upshift to DETAILED
      @LogDatabase                  SYSNAME       = NULL,
      @WaitAtLowPriorityMinutes     INT           = NULL,
      @AbortAfterWait               NVARCHAR(20)  = NULL,           -- NONE | SELF | BLOCKERS
      @Resumable                    BIT           = 0,
      @MaxDurationMinutes           INT           = NULL,
      @DelayMsBetweenCommands       INT           = NULL,
      @WhatIf                       BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Help
    IF @Help = 1
    BEGIN
        SELECT
            param_name, sql_type, default_value, description, example
        FROM (VALUES
             (N'@TargetDatabases',              N'NVARCHAR(MAX)',  N'(required)',      N'CSV list or **ALL_USER_DBS** (exact case). Supports exclusions via -DbName. System DBs and distribution are always excluded.', N'@TargetDatabases = N''ALL_USER_DBS,-DW,-ReportServer'''),
             (N'@Indexes',                      N'NVARCHAR(MAX)',  N'''ALL_INDEXES''', N'Single DB only (not ALL_USER_DBS). ALL_INDEXES or CSV of dbo.IndexName OR dbo.Table.IndexName. Prefix with - to exclude. Brackets ok.', N'@Indexes = N''dbo.IX_BigTable,dbo.BigTable.IX_BigTable_Cold,-dbo.BigTable.IX_BadOne'''),
             (N'@MinPageDensityPct',            N'DECIMAL(5,2)',   N'70.0',            N'Rebuild when avg page density for a leaf partition is below this percent.', N'65.0'),
             (N'@MinPageCount',                 N'INT',            N'1000',            N'Skip tiny partitions below this page count.', N'500'),
             (N'@MinAvgFragmentSizePages',      N'INT',            N'8',               N'Rebuild when dm_db_index_physical_stats avg_fragment_size_in_pages is below this (SSD read-ahead indicator). Set NULL to disable.', N'8'),
             (N'@ReadAheadMinPageCount',        N'INT',            N'50000',           N'Read-ahead path: minimum page_count required to consider avg_fragment_size_in_pages.', N'50000'),
             (N'@ReadAheadMinFragPct',          N'DECIMAL(5,2)',   N'30.0',            N'Read-ahead path: minimum avg_fragmentation_in_percent required to reduce false positives.', N'20.0'),
             (N'@ReadAheadMinScanOps',          N'BIGINT',         N'1000',            N'Read-ahead path: minimum (user_scans + user_lookups) from dm_db_index_usage_stats (since last restart).', N'1000'),
             (N'@ReadAheadLookbackDays',        N'INT',            N'7',               N'Read-ahead path: accept if last_user_scan is within this many days (helps even if scan counts are low).', N'7'),
             (N'@ReadAheadMinFillFactor',       N'TINYINT',        N'90',              N'Read-ahead path only: require FF >= this to reduce churn on intentionally sparse indexes.', N'90'),
             (N'@SkipLowFillFactor',            N'BIT',            N'1',               N'If 1, apply a guard to avoid rebuilding indexes that are intentionally sparse (low fill factor).', N'1'),
             (N'@LowFillFactorThreshold',       N'TINYINT',        N'80',              N'Fill factor <= this is treated as intentionally sparse.', N'80'),
             (N'@LowFillFactorDensitySlackPct', N'DECIMAL(5,2)',   N'15.0',            N'For low-FF indexes, require density < (MinPageDensityPct - slack) to rebuild via density path.', N'15.0'),
             (N'@UseExistingFillFactor',        N'BIT',            N'1',               N'Keep each index''s current fill factor. If 0, use @FillFactor.', N'1'),
             (N'@FillFactor',                   N'TINYINT',        N'NULL',            N'Fill factor when @UseExistingFillFactor = 0. Valid 1 to 100.', N'90'),
             (N'@Online',                       N'BIT',            N'1',               N'Use ONLINE = ON when supported.', N'1'),
             (N'@MaxDOP',                       N'INT',            N'NULL',            N'MAXDOP for rebuilds. If NULL, server default is used.', N'4'),
             (N'@SortInTempdb',                 N'BIT',            N'1',               N'Use SORT_IN_TEMPDB.', N'1'),
             (N'@UseCompressionFromSource',     N'BIT',            N'1',               N'Preserve DATA_COMPRESSION of each partition when supported.', N'1'),
             (N'@ForceCompression',             N'NVARCHAR(20)',   N'NULL',            N'Override compression for rowstore: NONE, ROW, or PAGE (when not preserving).', N'N''ROW'''),
             (N'@SampleMode',                   N'VARCHAR(16)',    N'''SAMPLED''',     N'dm_db_index_physical_stats mode: SAMPLED or DETAILED.', N'''DETAILED'''),
             (N'@CaptureTrendingSignals',       N'BIT',            N'0',               N'If 1 and SampleMode=SAMPLED, auto-upshift to DETAILED to capture row/ghost/forwarded metrics.', N'1'),
             (N'@LogDatabase',                  N'SYSNAME',        N'NULL',            N'Central log DB. If NULL, logs in each target DB.', N'N''UtilityDb'''),
             (N'@WaitAtLowPriorityMinutes',     N'INT',            N'NULL',            N'Optional WAIT_AT_LOW_PRIORITY MAX_DURATION (ONLINE only).', N'5'),
             (N'@AbortAfterWait',               N'NVARCHAR(20)',   N'NULL',            N'ABORT_AFTER_WAIT: NONE, SELF, or BLOCKERS (requires minutes).', N'N''BLOCKERS'''),
             (N'@Resumable',                    N'BIT',            N'0',               N'RESUMABLE = ON for online rebuilds when supported (SQL 2019+).', N'1'),
             (N'@MaxDurationMinutes',           N'INT',            N'NULL',            N'Resumable MAX_DURATION minutes.', N'60'),
             (N'@DelayMsBetweenCommands',       N'INT',            N'NULL',            N'Optional delay between commands in milliseconds.', N'5000'),
             (N'@WhatIf',                       N'BIT',            N'1',               N'Dry run: log/print only.', N'0')
        ) d(param_name, sql_type, default_value, description, example)
        ORDER BY param_name;

        SELECT
            server_version_major = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)),4) AS INT),
            server_version_build = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)),2) AS INT),
            edition              = CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)),
            supports_online      = CASE WHEN CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Enterprise%'
                                           OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Developer%'
                                           OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Evaluation%'
                                        THEN 1 ELSE 0 END,
            supports_compression = CASE
                                      WHEN CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)),4) AS INT) > 13 THEN 1
                                      WHEN CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)),4) AS INT) = 13
                                           AND CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)),2) AS INT) >= 4000 THEN 1
                                      WHEN CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Enterprise%'
                                        OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Developer%'
                                        OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Evaluation%' THEN 1
                                      ELSE 0
                                   END,
            supports_resumable_rebuild = CASE
                                            WHEN CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)),4) AS INT) >= 15
                                                 AND (CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Enterprise%'
                                                   OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Developer%'
                                                   OR CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Evaluation%')
                                            THEN 1 ELSE 0
                                         END;

        RETURN;
    END

    -- Server/Edition capability detection
    DECLARE @verMajor INT           = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)),4) AS INT);
    DECLARE @verBuild INT           = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)),2) AS INT);
    DECLARE @edition  NVARCHAR(128) = CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) COLLATE DATABASE_DEFAULT;

    DECLARE @isEntDevEval BIT = CASE WHEN @edition LIKE '%Enterprise%' OR @edition LIKE '%Developer%' OR @edition LIKE '%Evaluation%' THEN 1 ELSE 0 END;
    DECLARE @supportsOnline BIT = @isEntDevEval;
    DECLARE @supportsCompression BIT = CASE WHEN @verMajor > 13 OR (@verMajor = 13 AND @verBuild >= 4000) OR @isEntDevEval = 1 THEN 1 ELSE 0 END;
    DECLARE @supportsResumableRebuild BIT = CASE WHEN @verMajor >= 15 AND @supportsOnline = 1 THEN 1 ELSE 0 END;

    -- Effective sample mode with seatbelt
    DECLARE @EffectiveSampleMode VARCHAR(16) = @SampleMode;
    IF @CaptureTrendingSignals = 1 AND UPPER(@EffectiveSampleMode) = 'SAMPLED'
        SET @EffectiveSampleMode = 'DETAILED';

    -- validation
    IF @TargetDatabases IS NULL OR LTRIM(RTRIM(@TargetDatabases)) = N''
    BEGIN RAISERROR('@TargetDatabases is required.',16,1); RETURN; END

    IF @MinPageDensityPct IS NULL OR @MinPageDensityPct <= 0 OR @MinPageDensityPct >= 100
    BEGIN RAISERROR('@MinPageDensityPct must be between 0 and 100 (exclusive).',16,1); RETURN; END

    IF @MinPageCount IS NULL OR @MinPageCount <= 0
    BEGIN RAISERROR('@MinPageCount must be a positive integer.',16,1); RETURN; END

    IF @MinAvgFragmentSizePages IS NOT NULL AND @MinAvgFragmentSizePages <= 0
    BEGIN RAISERROR('@MinAvgFragmentSizePages must be NULL or a positive integer.',16,1); RETURN; END

    IF @ReadAheadMinPageCount IS NULL OR @ReadAheadMinPageCount <= 0
    BEGIN RAISERROR('@ReadAheadMinPageCount must be a positive integer.',16,1); RETURN; END

    IF @ReadAheadMinFragPct IS NULL OR @ReadAheadMinFragPct < 0 OR @ReadAheadMinFragPct >= 100
    BEGIN RAISERROR('@ReadAheadMinFragPct must be between 0 and 100.',16,1); RETURN; END

    IF @ReadAheadMinScanOps IS NULL OR @ReadAheadMinScanOps < 0
    BEGIN RAISERROR('@ReadAheadMinScanOps must be >= 0.',16,1); RETURN; END

    IF @ReadAheadLookbackDays IS NULL OR @ReadAheadLookbackDays < 0
    BEGIN RAISERROR('@ReadAheadLookbackDays must be >= 0.',16,1); RETURN; END

    IF @LowFillFactorThreshold NOT BETWEEN 1 AND 100
    BEGIN RAISERROR('@LowFillFactorThreshold must be 1-100.',16,1); RETURN; END

    IF @LowFillFactorDensitySlackPct IS NULL OR @LowFillFactorDensitySlackPct < 0 OR @LowFillFactorDensitySlackPct >= 100
    BEGIN RAISERROR('@LowFillFactorDensitySlackPct must be between 0 and 100.',16,1); RETURN; END

    IF @ReadAheadMinFillFactor NOT BETWEEN 1 AND 100
    BEGIN RAISERROR('@ReadAheadMinFillFactor must be 1-100.',16,1); RETURN; END

    IF @UseExistingFillFactor = 0 AND ( @FillFactor IS NULL OR @FillFactor NOT BETWEEN 1 AND 100 )
    BEGIN RAISERROR('When @UseExistingFillFactor = 0, @FillFactor must be 1-100.',16,1); RETURN; END

    IF @MaxDOP IS NOT NULL AND @MaxDOP NOT BETWEEN 0 AND 32767
    BEGIN RAISERROR('@MaxDOP must be between 0 and 32767.',16,1); RETURN; END

    IF @DelayMsBetweenCommands IS NOT NULL AND @DelayMsBetweenCommands < 0
    BEGIN RAISERROR('@DelayMsBetweenCommands must be >= 0.',16,1); RETURN; END

    IF UPPER(ISNULL(@SampleMode,'')) COLLATE DATABASE_DEFAULT NOT IN (N'SAMPLED' COLLATE DATABASE_DEFAULT,N'DETAILED' COLLATE DATABASE_DEFAULT)
    BEGIN RAISERROR('@SampleMode must be SAMPLED or DETAILED.',16,1); RETURN; END

    IF @WaitAtLowPriorityMinutes IS NOT NULL AND @WaitAtLowPriorityMinutes <= 0
    BEGIN RAISERROR('@WaitAtLowPriorityMinutes must be a positive integer when provided.',16,1); RETURN; END

    IF @WaitAtLowPriorityMinutes IS NOT NULL AND UPPER(ISNULL(@AbortAfterWait,'')) COLLATE DATABASE_DEFAULT NOT IN (N'NONE' COLLATE DATABASE_DEFAULT,N'SELF' COLLATE DATABASE_DEFAULT,N'BLOCKERS' COLLATE DATABASE_DEFAULT)
    BEGIN RAISERROR('@AbortAfterWait must be NONE, SELF, or BLOCKERS when @WaitAtLowPriorityMinutes is set.',16,1); RETURN; END

    IF @Resumable = 1 AND @Online = 0
    BEGIN RAISERROR('RESUMABLE requires @Online = 1.',16,1); RETURN; END

    DECLARE @IncludeOnlineOption BIT = CASE WHEN @Online = 1 AND @supportsOnline = 1 THEN 1 ELSE 0 END;
    IF @IncludeOnlineOption = 0
    BEGIN
        SET @Online = 0;
        SET @WaitAtLowPriorityMinutes = NULL;
        SET @AbortAfterWait = NULL;
    END

    IF @supportsResumableRebuild = 0
    BEGIN
        SET @Resumable = 0;
        SET @MaxDurationMinutes = NULL;
    END

    DECLARE @IncludeDataCompressionOption BIT = CASE WHEN @supportsCompression = 1 THEN 1 ELSE 0 END;
    IF @IncludeDataCompressionOption = 0
    BEGIN
        SET @UseCompressionFromSource = 0;
        SET @ForceCompression = NULL;
    END
    ELSE IF @UseCompressionFromSource = 0 AND UPPER(ISNULL(@ForceCompression,'')) NOT IN ('NONE','ROW','PAGE')
    BEGIN
        RAISERROR('Invalid @ForceCompression for rowstore. Use NONE, ROW, or PAGE.',16,1); RETURN;
    END

    -- Parse targets
    IF OBJECT_ID('tempdb..#includes')       IS NOT NULL DROP TABLE #includes;
    IF OBJECT_ID('tempdb..#excludes')       IS NOT NULL DROP TABLE #excludes;
    IF OBJECT_ID('tempdb..#targets')        IS NOT NULL DROP TABLE #targets;
    IF OBJECT_ID('tempdb..#IndexIncludes')  IS NOT NULL DROP TABLE #IndexIncludes;
    IF OBJECT_ID('tempdb..#IndexExcludes')  IS NOT NULL DROP TABLE #IndexExcludes;

    CREATE TABLE #includes (name SYSNAME NOT NULL PRIMARY KEY);
    CREATE TABLE #excludes (name SYSNAME NOT NULL PRIMARY KEY);
    CREATE TABLE #targets  (db_name SYSNAME NOT NULL PRIMARY KEY);

    -- @Indexes include / exclude filters (single-target DB only)
    CREATE TABLE #IndexIncludes
    (
        schema_name SYSNAME NULL,
        table_name  SYSNAME NULL,
        index_name  SYSNAME NOT NULL
    );

    CREATE TABLE #IndexExcludes
    (
        schema_name SYSNAME NULL,
        table_name  SYSNAME NULL,
        index_name  SYSNAME NOT NULL
    );

    DECLARE @list NVARCHAR(MAX) = @TargetDatabases + N',';
    DECLARE @pos INT, @tok NVARCHAR(4000), @AllUsers BIT = 0;

    WHILE LEN(@list) > 0
    BEGIN
        SET @pos = CHARINDEX(N',', @list);
        SET @tok = LTRIM(RTRIM(SUBSTRING(@list,1,@pos-1)));
        SET @list = SUBSTRING(@list, @pos+1, 2147483647);

        IF @tok = N'' CONTINUE;

        IF @tok COLLATE Latin1_General_CS_AS = N'ALL_USER_DBS'
        BEGIN
            SET @AllUsers = 1;
            CONTINUE;
        END

        IF LEFT(@tok,1) = N'-'
        BEGIN
            SET @tok = LTRIM(RTRIM(SUBSTRING(@tok,2,4000)));
            IF LEN(@tok) > 0 AND NOT EXISTS (SELECT 1 FROM #excludes WHERE name = @tok)
                INSERT #excludes(name) VALUES(@tok);
            CONTINUE;
        END

        IF NOT EXISTS (SELECT 1 FROM #includes WHERE name = @tok)
            INSERT #includes(name) VALUES(@tok);
    END

    IF @AllUsers = 1
    BEGIN
        INSERT #targets(db_name)
        SELECT d.name
        FROM sys.databases AS d
        WHERE 
          d.name NOT IN (N'master',N'model',N'msdb',N'tempdb',N'distribution') AND
          d.state = 0 AND
          d.is_read_only = 0;
    END

    INSERT #targets(db_name)
    SELECT i.name
    FROM #includes AS i
    JOIN sys.databases AS d ON
      d.name = i.name COLLATE DATABASE_DEFAULT
    WHERE 
      d.name NOT IN (N'master',N'model',N'msdb',N'tempdb',N'distribution') AND
      d.state = 0 AND
      d.is_read_only = 0 AND NOT EXISTS (SELECT 1 FROM #targets WHERE db_name = i.name);

    DELETE t
    FROM #targets AS t
    JOIN #excludes AS x ON
         t.db_name = x.name COLLATE DATABASE_DEFAULT;

    IF NOT EXISTS (SELECT 1 FROM #targets)
    BEGIN
        RAISERROR('No valid target databases resolved after parsing @TargetDatabases.',16,1);
        RETURN;
    END
    DECLARE @TargetCount INT = (SELECT COUNT(*) FROM #targets);

    IF @TargetCount > 1
    BEGIN
        IF @Indexes IS NOT NULL AND
           LTRIM(RTRIM(@Indexes)) <> N'' AND
           UPPER(LTRIM(RTRIM(@Indexes))) <> N'ALL_INDEXES'
        BEGIN
            RAISERROR('@Indexes parameter is ignored when more than one target database is selected; using ALL_INDEXES.', 10, 1) WITH NOWAIT;
        END;

        SET @Indexes = N'ALL_INDEXES';
    END;

    DECLARE @idxList NVARCHAR(MAX) = LTRIM(RTRIM(ISNULL(@Indexes, N'')));

    IF @TargetCount = 1 AND @idxList <> N''
    BEGIN
        SET @idxList = @idxList + N',';

        DECLARE
            @idxPos   INT,
            @idxTok   NVARCHAR(4000),
            @isExcl   BIT,
            @raw      NVARCHAR(4000),
            @schema   SYSNAME,
            @table    SYSNAME,
            @index    SYSNAME,
            @dot1     INT,
            @dot2     INT;

        WHILE LEN(@idxList) > 0
        BEGIN
            SET @idxPos = CHARINDEX(N',', @idxList);
            SET @idxTok = LTRIM(RTRIM(SUBSTRING(@idxList, 1, @idxPos-1)));
            SET @idxList = SUBSTRING(@idxList, @idxPos+1, 2147483647);

            IF @idxTok = N'' CONTINUE;

            -- Ignore standalone ALL_INDEXES token (means "no filter")
            IF UPPER(@idxTok) = N'ALL_INDEXES'
                CONTINUE;

            SET @isExcl = CASE WHEN LEFT(@idxTok,1) = N'-' THEN 1 ELSE 0 END;
            IF @isExcl = 1
                SET @idxTok = LTRIM(RTRIM(SUBSTRING(@idxTok,2,4000)));

            IF @idxTok = N'' CONTINUE;

            SET @raw = @idxTok;

            -- Split into up to 3 parts: schema[.table].index
            SET @dot1 = CHARINDEX(N'.', @raw);
            SET @dot2 = CASE WHEN @dot1 > 0 THEN CHARINDEX(N'.', @raw, @dot1+1) ELSE 0 END;

            SET @schema = NULL;
            SET @table  = NULL;
            SET @index  = NULL;

            IF @dot1 = 0
            BEGIN
                -- just index name
                SET @index = @raw;
            END
            ELSE IF @dot2 = 0
            BEGIN
                -- schema.index
                SET @schema = SUBSTRING(@raw, 1, @dot1-1);
                SET @index  = SUBSTRING(@raw, @dot1+1, 4000);
            END
            ELSE
            BEGIN
                -- schema.table.index
                SET @schema = SUBSTRING(@raw, 1, @dot1-1);
                SET @table  = SUBSTRING(@raw, @dot1+1, @dot2-@dot1-1);
                SET @index  = SUBSTRING(@raw, @dot2+1, 4000);
            END;

            -- Strip brackets
            SET @schema = NULLIF(REPLACE(REPLACE(@schema, N'[', N''), N']', N''), N'');
            SET @table  = NULLIF(REPLACE(REPLACE(@table,  N'[', N''), N']', N''), N'');
            SET @index  = NULLIF(REPLACE(REPLACE(@index,  N'[', N''), N']', N''), N'');

            IF @index IS NULL CONTINUE;

            IF @isExcl = 1
            BEGIN
                IF NOT EXISTS (SELECT 1
                               FROM #IndexExcludes
                               WHERE 
                                 schema_name = @schema AND
                                 table_name  = @table AND
                                 index_name  = @index)
                BEGIN
                    INSERT #IndexExcludes(schema_name, table_name, index_name)
                    VALUES(@schema, @table, @index);
                END
            END
            ELSE
            BEGIN
                IF NOT EXISTS (SELECT 1
                               FROM #IndexIncludes
                               WHERE 
                                 schema_name = @schema AND
                                 table_name  = @table AND
                                 index_name  = @index)
                BEGIN
                    INSERT #IndexIncludes(schema_name, table_name, index_name)
                    VALUES(@schema, @table, @index);
                END
            END
        END
    END;
    -- Iterate per target DB
    DECLARE @db SYSNAME;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT db_name FROM #targets ORDER BY db_name;
    OPEN cur;
    FETCH NEXT FROM cur INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @db AND state = 0 AND is_read_only = 0)
        BEGIN
            RAISERROR('Skipping database "%s": not ONLINE and read-write.',10,1,@db) WITH NOWAIT;
            FETCH NEXT FROM cur INTO @db;
            CONTINUE;
        END

        RAISERROR(N'===== STARTING database: [%s] =====', 10, 1, @db) WITH NOWAIT;

        DECLARE @qDb   NVARCHAR(258) = QUOTENAME(@db COLLATE DATABASE_DEFAULT);
        DECLARE @LogDb SYSNAME       = ISNULL(@LogDatabase, @db);
        DECLARE @qLogDb NVARCHAR(258)= QUOTENAME(@LogDb COLLATE DATABASE_DEFAULT);

        /* NEW: capture per-target and per-log collations (used later for cross-db inserts/joins) */
        DECLARE @DbCollation  SYSNAME;
        DECLARE @LogCollation SYSNAME;

        SELECT @DbCollation  = d.collation_name FROM sys.databases AS d WHERE d.name = @db;
        SELECT @LogCollation = d.collation_name FROM sys.databases AS d WHERE d.name = @LogDb;

        IF @DbCollation IS NULL OR @LogCollation IS NULL
        BEGIN
            RAISERROR(N'Skipping database [%s]: could not determine target/log collation.', 10, 1, @db) WITH NOWAIT;
            FETCH NEXT FROM cur INTO @db;
            CONTINUE;
        END

        -- Ensure log table exists for this target's chosen log DB
        DECLARE @ddl NVARCHAR(MAX) =
        N'USE ' + @qLogDb + N';
        IF SCHEMA_ID(N''DBA'') IS NULL EXEC(''CREATE SCHEMA DBA AUTHORIZATION dbo'');

        IF OBJECT_ID(N''[DBA].[IndexBloatRebuildLog]'', N''U'') IS NULL
        BEGIN
            CREATE TABLE [DBA].[IndexBloatRebuildLog]
            (
                [log_id]                  BIGINT IDENTITY(1,1) PRIMARY KEY,
                [run_utc]                 DATETIME2(3)   NOT NULL CONSTRAINT DF_IBRL_run DEFAULT (SYSUTCDATETIME()),
                [database_name]           SYSNAME        NOT NULL,
                [schema_name]             SYSNAME        NOT NULL,
                [table_name]              SYSNAME        NOT NULL,
                [index_name]              SYSNAME        NOT NULL,
                [index_id]                INT            NOT NULL,
                [partition_number]        INT            NOT NULL,
                [page_count]              BIGINT         NOT NULL,
                [page_density_pct]        DECIMAL(6,2)   NOT NULL,
                [fragmentation_pct]       DECIMAL(6,2)   NOT NULL,
                [avg_fragment_size_pages] DECIMAL(18,2)  NULL,
                [candidate_reason]        VARCHAR(20)    NOT NULL CONSTRAINT DF_IBRL_reason DEFAULT (''DENSITY''),
                [source_fill_factor]      INT            NULL,
                [fill_factor_guard_applied] BIT          NOT NULL CONSTRAINT DF_IBRL_ffguard DEFAULT (0),
                [chosen_fill_factor]      INT            NULL,
                [online_on]               BIT            NOT NULL,
                [maxdop_used]             INT            NULL,
                [avg_row_bytes]           DECIMAL(18,2)  NULL,
                [record_count]            BIGINT         NULL,
                [ghost_record_count]      BIGINT         NULL,
                [forwarded_record_count]  BIGINT         NULL,
                [au_total_pages]          BIGINT         NULL,
                [au_used_pages]           BIGINT         NULL,
                [au_data_pages]           BIGINT         NULL,
                [action]                  VARCHAR(20)    NOT NULL,
                [cmd]                     NVARCHAR(MAX)  NOT NULL,
                [status]                  VARCHAR(30)    NOT NULL,
                [error_message]           NVARCHAR(4000) NULL,
                [error_number]            INT            NULL,
                [error_severity]          INT            NULL,
                [error_state]             INT            NULL,
                [error_line]              INT            NULL,
                [error_proc]              NVARCHAR(128)  NULL
            );
        END

        IF OBJECT_ID(N''[DBA].[IndexBloatRebuildLog]'', N''U'') IS NOT NULL
        BEGIN
            IF EXISTS
            (
                SELECT 1
                FROM sys.columns
                WHERE object_id = OBJECT_ID(N''[DBA].[IndexBloatRebuildLog]'')
                    AND name = N''cmd''
                    AND system_type_id = 231
                    AND max_length <> -1
            )
            BEGIN
                ALTER TABLE [DBA].[IndexBloatRebuildLog] ALTER COLUMN cmd NVARCHAR(MAX) NOT NULL;
            END

            IF EXISTS
            (
                SELECT 1
                FROM sys.columns
                WHERE object_id = OBJECT_ID(N''[DBA].[IndexBloatRebuildLog]'')
                    AND name = N''error_message''
                    AND system_type_id = 231
                    AND max_length > 0
                    AND max_length < 8000
            )
            BEGIN
                ALTER TABLE [DBA].[IndexBloatRebuildLog] ALTER COLUMN error_message NVARCHAR(4000) NULL;
            END

            IF EXISTS
            (
                SELECT 1
                FROM sys.columns
                WHERE object_id = OBJECT_ID(N''[DBA].[IndexBloatRebuildLog]'')
                    AND name = N''status''
                    AND system_type_id = 167
                    AND max_length < 30
            )
            BEGIN
                ALTER TABLE [DBA].[IndexBloatRebuildLog] ALTER COLUMN [status] VARCHAR(30) NOT NULL;
            END

            IF EXISTS
            (
                SELECT 1
                FROM sys.columns
                WHERE object_id = OBJECT_ID(N''[DBA].[IndexBloatRebuildLog]'')
                    AND name = N''action''
                    AND system_type_id = 167
                    AND max_length < 20
            )
            BEGIN
                ALTER TABLE [DBA].[IndexBloatRebuildLog] ALTER COLUMN [action] VARCHAR(20) NOT NULL;
            END

            IF EXISTS
            (
                SELECT 1
                FROM sys.columns
                WHERE object_id = OBJECT_ID(N''[DBA].[IndexBloatRebuildLog]'')
                    AND name = N''error_proc''
                    AND system_type_id = 231
                    AND max_length > 0
                    AND max_length < 256
            )
            BEGIN
                ALTER TABLE [DBA].[IndexBloatRebuildLog] ALTER COLUMN error_proc NVARCHAR(128) NULL;
            END

            IF NOT EXISTS
            (
                SELECT 1
                FROM sys.columns
                WHERE object_id = OBJECT_ID(N''[DBA].[IndexBloatRebuildLog]'')
                    AND name = N''avg_fragment_size_pages''
                    AND system_type_id IN (106,108)
            )
            BEGIN
                ALTER TABLE [DBA].[IndexBloatRebuildLog] ADD [avg_fragment_size_pages] DECIMAL(18,2) NULL;
            END

            IF NOT EXISTS
            (
                SELECT 1
                FROM sys.columns
                WHERE object_id = OBJECT_ID(N''[DBA].[IndexBloatRebuildLog]'')
                    AND name = N''candidate_reason''
            )
            BEGIN
                ALTER TABLE [DBA].[IndexBloatRebuildLog]
                    ADD [candidate_reason] VARCHAR(20) NOT NULL
                        CONSTRAINT DF_IBRL_reason DEFAULT (''DENSITY'');
            END

            IF NOT EXISTS
            (
                SELECT 1
                FROM sys.columns
                WHERE object_id = OBJECT_ID(N''[DBA].[IndexBloatRebuildLog]'')
                    AND name = N''source_fill_factor''
            )
            BEGIN
                ALTER TABLE [DBA].[IndexBloatRebuildLog] ADD [source_fill_factor] INT NULL;
            END

            IF NOT EXISTS
            (
                SELECT 1
                FROM sys.columns
                WHERE object_id = OBJECT_ID(N''[DBA].[IndexBloatRebuildLog]'')
                    AND name = N''fill_factor_guard_applied''
            )
            BEGIN
                ALTER TABLE [DBA].[IndexBloatRebuildLog]
                    ADD [fill_factor_guard_applied] BIT NOT NULL
                        CONSTRAINT DF_IBRL_ffguard DEFAULT (0);
            END
        END
        ';
        BEGIN TRY
            EXEC (@ddl);
        END TRY
        BEGIN CATCH
            DECLARE @Err NVARCHAR(255) = ERROR_MESSAGE();
            RAISERROR('Failed to prepare logging table in %s: %s',16,1,@LogDb,@Err);
            RAISERROR(N'===== COMPLETED database (with errors): [%s] =====', 10, 1, @db) WITH NOWAIT;
            FETCH NEXT FROM cur INTO @db;
            CONTINUE;
        END CATCH

        
        --Core per-DB logic with progress
        DECLARE @sql NVARCHAR(MAX) =
        N'USE ' + @qDb + N';
        SET NOCOUNT ON;
        SET XACT_ABORT ON;
        SET DEADLOCK_PRIORITY LOW;

        DECLARE @msg NVARCHAR(4000);

        IF OBJECT_ID(''tempdb..#candidates'') IS NOT NULL DROP TABLE #candidates;
        CREATE TABLE #candidates
        (
            [schema_name]               SYSNAME       NOT NULL,
            [table_name]                SYSNAME       NOT NULL,
            [index_name]                SYSNAME       NOT NULL,
            [index_id]                  INT           NOT NULL,
            [partition_number]          INT           NOT NULL,
            [page_count]                BIGINT        NOT NULL,
            [page_density_pct]          DECIMAL(6,2)  NOT NULL,
            [fragmentation_pct]         DECIMAL(6,2)  NOT NULL,
            [avg_fragment_size_pages]   DECIMAL(18,2) NOT NULL,
            [avg_row_bytes]             DECIMAL(18,2) NOT NULL,
            [record_count]              BIGINT        NOT NULL,
            [ghost_record_count]        BIGINT        NOT NULL,
            [fwd_record_count]          BIGINT        NOT NULL,
            [au_total_pages]            BIGINT        NOT NULL,
            [au_used_pages]             BIGINT        NOT NULL,
            [au_data_pages]             BIGINT        NOT NULL,
            [user_seeks]                BIGINT        NOT NULL,
            [user_scans]                BIGINT        NOT NULL,
            [user_lookups]              BIGINT        NOT NULL,
            [user_updates]              BIGINT        NOT NULL,
            [last_user_seek]            DATETIME      NULL,
            [last_user_scan]            DATETIME      NULL,
            [last_user_lookup]          DATETIME      NULL,
            [compression_desc]          NVARCHAR(60)  NOT NULL,
            [source_fill_factor]        INT           NOT NULL,
            [fill_factor_guard_applied] BIT           NOT NULL,
            [chosen_fill_factor]        INT           NULL,
            [is_partitioned]            BIT           NOT NULL,
            [is_filtered]               BIT           NOT NULL,
            [has_included_lob]          BIT           NOT NULL,
            [has_key_blocker]           BIT           NOT NULL,
            [resumable_supported]       BIT           NOT NULL,
            [candidate_reason]          VARCHAR(20)   NOT NULL,
            [cmd]                       NVARCHAR(MAX) NOT NULL
        );

        DECLARE @mode VARCHAR(16) =
            CASE WHEN UPPER(@pSampleMode COLLATE DATABASE_DEFAULT) = N''DETAILED'' THEN N''DETAILED'' ELSE N''SAMPLED'' END;

        INSERT INTO #candidates
        (
            [schema_name], 
            [table_name], 
            [index_name], 
            [index_id],
            [partition_number], 
            [page_count], 
            [page_density_pct], 
            [fragmentation_pct], 
            [avg_fragment_size_pages],
            [avg_row_bytes], 
            [record_count], 
            [ghost_record_count], 
            [fwd_record_count],
            [au_total_pages], 
            [au_used_pages], 
            [au_data_pages],
            [user_seeks], 
            [user_scans], 
            [user_lookups], 
            [user_updates],
            [last_user_seek], 
            [last_user_scan], 
            [last_user_lookup],
            [compression_desc],
            [source_fill_factor], 
            [fill_factor_guard_applied],
            [chosen_fill_factor],
            [is_partitioned], 
            [is_filtered], 
            [has_included_lob], 
            [has_key_blocker], 
            [resumable_supported],
            [candidate_reason],
            [cmd]
        )
        SELECT
            s.name,
            t.name,
            i.name,
            i.index_id,
            ps.partition_number,
            ps.page_count,
            ps.avg_page_space_used_in_percent,
            ps.avg_fragmentation_in_percent,
            COALESCE(CAST(ps.avg_fragment_size_in_pages AS DECIMAL(18,2)), 0),
            COALESCE(CAST(ps.avg_record_size_in_bytes AS DECIMAL(18,2)), 0),
            COALESCE(ps.record_count, 0),
            COALESCE(ps.ghost_record_count, 0),
            COALESCE(ps.forwarded_record_count, 0),
            COALESCE(SUM(au.total_pages),0),
            COALESCE(SUM(au.used_pages),0),
            COALESCE(SUM(au.data_pages),0),
            COALESCE(us.user_seeks,   0),
            COALESCE(us.user_scans,   0),
            COALESCE(us.user_lookups, 0),
            COALESCE(us.user_updates, 0),
            us.last_user_seek,
            us.last_user_scan,
            us.last_user_lookup,
            p.data_compression_desc,
            ff.source_fill_factor,
            ff.fill_factor_guard_applied,
            CASE WHEN @pUseExistingFillFactor = 1 THEN NULLIF(i.fill_factor,0) ELSE @pFillFactor END,
            CASE WHEN psch.data_space_id IS NULL THEN 0 ELSE 1 END,
            i.has_filter,
            blockers.has_included_lob,
            blockers.has_key_blocker,
            rs.resumable_supported,

            CASE
                WHEN
                (
                    ps.avg_page_space_used_in_percent < @pMinPageDensityPct
                    AND
                    (
                        @pSkipLowFillFactor = 0
                        OR ff.source_fill_factor > @pLowFillFactorThreshold
                        OR ps.avg_page_space_used_in_percent < (@pMinPageDensityPct - @pLowFillFactorDensitySlackPct)
                    )
                )
                THEN ''DENSITY''
                ELSE ''READ_AHEAD''
            END AS candidate_reason,

            (
                N''ALTER INDEX '' + QUOTENAME(i.name) +
                N'' ON '' + QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name) +
                CASE WHEN psch.data_space_id IS NULL
                    THEN N'' REBUILD ''
                    ELSE N'' REBUILD PARTITION = '' + CONVERT(VARCHAR(12), ps.partition_number) + N'' ''
                END +
                N''WITH (SORT_IN_TEMPDB = '' +
                CASE WHEN @pOnline = 1 AND @pResumable = 1 AND rs.resumable_supported = 1
                    THEN N''OFF''
                    ELSE CASE WHEN @pSortInTempdb = 1 THEN N''ON'' ELSE N''OFF'' END
                END +
                CASE WHEN (CASE WHEN @pUseExistingFillFactor = 1 THEN NULLIF(i.fill_factor,0) ELSE @pFillFactor END) IS NOT NULL
                    THEN N'', FILLFACTOR = '' + CONVERT(VARCHAR(4), (CASE WHEN @pUseExistingFillFactor = 1 THEN NULLIF(i.fill_factor,0) ELSE @pFillFactor END))
                    ELSE N'''' END +
                CASE WHEN @pIncludeOnlineOption = 1 AND @pOnline = 1 AND onl.online_supported = 1
                    THEN N'', ONLINE = ON'' +
                            CASE WHEN @pWaitAtLowPriorityMinutes IS NOT NULL
                                THEN N'' (WAIT_AT_LOW_PRIORITY (MAX_DURATION = '' + CONVERT(VARCHAR(4), @pWaitAtLowPriorityMinutes) +
                                    N'' MINUTES, ABORT_AFTER_WAIT = '' + (@pAbortAfterWait COLLATE DATABASE_DEFAULT) + N''))''
                                ELSE N''''
                            END
                    ELSE N''''
                END +
                CASE WHEN @pMaxDOP IS NOT NULL THEN N'', MAXDOP = '' + CONVERT(VARCHAR(5), @pMaxDOP) ELSE N'''' END +
                CASE WHEN @pIncludeDataCompressionOption = 1
                    THEN N'', DATA_COMPRESSION = '' +
                        CASE WHEN @pUseCompressionFromSource = 1 THEN p.data_compression_desc COLLATE DATABASE_DEFAULT
                            ELSE (@pForceCompression COLLATE DATABASE_DEFAULT)
                        END
                    ELSE N''''
                END +
                CASE WHEN @pOnline = 1 AND @pResumable = 1 AND rs.resumable_supported = 1 THEN N'', RESUMABLE = ON'' ELSE N'''' END +
                CASE WHEN @pOnline = 1 AND @pResumable = 1 AND rs.resumable_supported = 1 AND @pMaxDurationMinutes IS NOT NULL
                    THEN N'', MAX_DURATION = '' + CONVERT(VARCHAR(4), @pMaxDurationMinutes) + N'' MINUTES''
                    ELSE N''''
                END +
                N'')''
            ) AS cmd
        FROM sys.indexes AS i
        JOIN sys.tables AS t ON 
           t.object_id = i.object_id
        JOIN sys.schemas AS s ON 
           s.schema_id = t.schema_id
        JOIN sys.partitions AS p ON 
           p.object_id = i.object_id AND 
           p.index_id = i.index_id
        JOIN sys.data_spaces AS ds ON 
           ds.data_space_id = i.data_space_id
        LEFT JOIN sys.partition_schemes AS psch ON 
           psch.data_space_id = ds.data_space_id
        LEFT JOIN sys.dm_db_index_usage_stats AS us ON
            us.database_id = DB_ID() AND
            us.object_id = i.object_id AND
            us.index_id = i.index_id
        JOIN sys.allocation_units AS au ON
            au.container_id = p.hobt_id AND
            au.type IN (1,3)
        CROSS APPLY
        (
            SELECT
                has_included_lob = CASE WHEN EXISTS
                (
                    SELECT 1
                    FROM sys.index_columns ic
                    JOIN sys.columns c ON
                       c.object_id = ic.object_id AND
                       c.column_id = ic.column_id
                    WHERE 
                       ic.object_id = i.object_id AND
                       ic.index_id = i.index_id AND
                       ic.is_included_column = 1 AND
                       (c.max_length = -1 OR c.system_type_id IN (34,35,99,241))
                ) THEN 1 ELSE 0 END,
                has_key_blocker = CASE WHEN EXISTS
                (
                    SELECT 1
                    FROM sys.index_columns ic
                    JOIN sys.columns c ON
                       c.object_id = ic.object_id AND
                       c.column_id = ic.column_id
                    WHERE 
                       ic.object_id = i.object_id AND
                       ic.index_id = i.index_id AND
                       ic.key_ordinal > 0 AND
                       (c.is_computed = 1 OR c.system_type_id = 189)
                ) THEN 1 ELSE 0 END
        ) AS blockers
        CROSS APPLY
        (
            SELECT resumable_supported =
                CASE WHEN i.has_filter = 0 AND blockers.has_included_lob = 0 AND blockers.has_key_blocker = 0 THEN 1 ELSE 0 END
        ) AS rs
        CROSS APPLY
        (
            SELECT
                source_fill_factor =
                    CASE WHEN NULLIF(i.fill_factor,0) IS NULL THEN 100 ELSE i.fill_factor END,
                fill_factor_guard_applied =
                    CASE
                        WHEN @pSkipLowFillFactor = 1
                        AND (CASE WHEN NULLIF(i.fill_factor,0) IS NULL THEN 100 ELSE i.fill_factor END) <= @pLowFillFactorThreshold
                        THEN 1 ELSE 0
                    END
        ) AS ff
        CROSS APPLY
        (
            SELECT online_supported =
                CASE WHEN EXISTS
                (
                    SELECT 1
                    FROM sys.index_columns ic
                    JOIN sys.columns c
                    ON c.object_id = ic.object_id
                    AND c.column_id = ic.column_id
                    WHERE ic.object_id = i.object_id
                    AND ic.index_id  = i.index_id
                    AND (
                           c.system_type_id IN (34, 35, 99) -- image, text, ntext
                        OR c.is_filestream = 1
                    )
                )
                THEN 0 ELSE 1 END
        ) AS onl
        CROSS APPLY sys.dm_db_index_physical_stats(DB_ID(), i.object_id, i.index_id, p.partition_number, @mode) AS ps
        WHERE
            i.index_id > 0 AND
            i.type IN (1,2) AND
            i.is_hypothetical = 0 AND
            i.is_disabled = 0 AND
            ps.index_level = 0 AND
            ps.page_count >= @pMinPageCount AND
            ps.alloc_unit_type_desc = ''IN_ROW_DATA'' AND
            t.is_ms_shipped = 0 AND
            t.is_memory_optimized = 0 AND
            (
                --Path A: density bloat, with low-FF guard 
                (
                    ps.avg_page_space_used_in_percent < @pMinPageDensityPct
                    AND
                    (
                        @pSkipLowFillFactor = 0 OR
                        ff.source_fill_factor > @pLowFillFactorThreshold OR
                        ps.avg_page_space_used_in_percent < (@pMinPageDensityPct - @pLowFillFactorDensitySlackPct)
                    )
                )

                OR

                -- Path B: read-ahead disruption, tightly gated + scan evidence + FF gate 
                (
                    @pMinAvgFragSizePages IS NOT NULL AND
                    ps.page_count >= @pReadAheadMinPageCount AND
                    ps.avg_fragment_size_in_pages < @pMinAvgFragSizePages AND
                    ps.avg_fragmentation_in_percent >= @pReadAheadMinFragPct AND
                    ff.source_fill_factor >= @pReadAheadMinFillFactor AND
                    (
                        (COALESCE(us.user_scans,0) + COALESCE(us.user_lookups,0)) >= @pReadAheadMinScanOps
                        OR
                        (
                            @pReadAheadLookbackDays > 0 AND
                            us.last_user_scan >= DATEADD(DAY, -@pReadAheadLookbackDays, GETDATE())
                        )
                    )
                )
            )
            AND
            (
                NOT EXISTS (SELECT 1 FROM #IndexIncludes)
                OR EXISTS
                (
                    SELECT 1
                    FROM #IndexIncludes AS inc
                    WHERE 
                       (inc.index_name  COLLATE <<DBCOLLATION>>) = (i.name COLLATE <<DBCOLLATION>>) AND
                       (inc.schema_name IS NULL OR (inc.schema_name COLLATE <<DBCOLLATION>>) = (s.name COLLATE <<DBCOLLATION>>)) AND
                       (inc.table_name  IS NULL OR (inc.table_name  COLLATE <<DBCOLLATION>>) = (t.name COLLATE <<DBCOLLATION>>))
                )
            )
            AND NOT EXISTS
            (
                SELECT 1
                FROM #IndexExcludes AS exc
                WHERE 
                   (exc.index_name  COLLATE <<DBCOLLATION>>) = (i.name COLLATE <<DBCOLLATION>>) AND
                   (exc.schema_name IS NULL OR (exc.schema_name COLLATE <<DBCOLLATION>>) = (s.name COLLATE <<DBCOLLATION>>)) AND
                   (exc.table_name  IS NULL OR (exc.table_name  COLLATE <<DBCOLLATION>>) = (t.name COLLATE <<DBCOLLATION>>))
            )
            AND (@pIncludeDataCompressionOption = 1 OR p.data_compression = 0)

        GROUP BY
            s.name, 
            t.name, 
            i.name, 
            i.index_id,
            ps.partition_number, 
            ps.page_count,
            ps.avg_page_space_used_in_percent, 
            ps.avg_fragmentation_in_percent,
            ps.avg_fragment_size_in_pages,
            ps.avg_record_size_in_bytes,
            ps.record_count, 
            ps.ghost_record_count, 
            ps.forwarded_record_count,
            p.data_compression_desc,
            i.fill_factor,
            psch.data_space_id,
            i.has_filter,
            blockers.has_included_lob, 
            blockers.has_key_blocker,
            rs.resumable_supported,
            us.user_seeks, 
            us.user_scans, 
            us.user_lookups, 
            us.user_updates,
            us.last_user_seek, 
            us.last_user_scan, 
            us.last_user_lookup,
            ff.source_fill_factor,
            ff.fill_factor_guard_applied,
            onl.online_supported
        OPTION (RECOMPILE);

        -- Candidate summary 
        DECLARE @candidate_count INT = (SELECT COUNT(*) FROM #candidates);

        IF @candidate_count = 0
        BEGIN
            IF @pWhatIf = 1
                RAISERROR(N''WHATIF: None found (0 candidates) in database: [%s].'', 10, 1, @pDbName) WITH NOWAIT;
            ELSE
                RAISERROR(N''None found (0 candidates) in database: [%s].'', 10, 1, @pDbName) WITH NOWAIT;

            RETURN;
        END

        IF @pWhatIf = 1
        BEGIN
            RAISERROR(
                N''WHATIF: Found %d candidate index partition(s) in database: [%s].'',
                10, 1, @candidate_count, @pDbName
            ) WITH NOWAIT;
        END

        IF OBJECT_ID(''tempdb..#todo'') IS NOT NULL DROP TABLE #todo;
        CREATE TABLE #todo (log_id BIGINT PRIMARY KEY, cmd NVARCHAR(MAX) NOT NULL);

        ;WITH to_log AS
        (
            SELECT
                DB_NAME() AS database_name,
                c.schema_name,
                c.table_name,
                c.index_name,
                c.index_id,
                c.partition_number,
                c.page_count,
                c.page_density_pct,
                c.fragmentation_pct,
                c.avg_fragment_size_pages,
                c.candidate_reason,
                c.source_fill_factor,
                c.fill_factor_guard_applied,
                c.avg_row_bytes,
                c.record_count,
                c.ghost_record_count,
                c.fwd_record_count,
                c.au_total_pages,
                c.au_used_pages,
                c.au_data_pages,
                c.chosen_fill_factor,
                @pOnline AS online_on,
                @pMaxDOP AS maxdop_used,
                CASE WHEN @pWhatIf = 1 THEN ''DRYRUN'' ELSE ''REBUILD'' END AS [action],
                c.cmd AS cmd,
                CASE WHEN @pWhatIf = 1 THEN ''SKIPPED'' ELSE ''PENDING'' END AS [status]
            FROM #candidates AS c
        )
        INSERT INTO ' + @qLogDb + N'.[DBA].[IndexBloatRebuildLog]
        (
            [database_name], 
            [schema_name], 
            [table_name], 
            [index_name], 
            [index_id], 
            [partition_number],
            [page_count], 
            [page_density_pct], 
            [fragmentation_pct], 
            [avg_fragment_size_pages],
            [candidate_reason], 
            [source_fill_factor], 
            [fill_factor_guard_applied],
            [avg_row_bytes], 
            [record_count], 
            [ghost_record_count], 
            [forwarded_record_count],
            [au_total_pages], 
            [au_used_pages], 
            [au_data_pages],
            [chosen_fill_factor], 
            [online_on], 
            [maxdop_used], 
            [action],
            [cmd], 
            [status]
        )
        OUTPUT inserted.log_id, inserted.cmd INTO #todo(log_id, cmd)
        SELECT
            [database_name] COLLATE <<LOGCOLLATION>>,
            [schema_name]   COLLATE <<LOGCOLLATION>>,
            [table_name]    COLLATE <<LOGCOLLATION>>,
            [index_name]    COLLATE <<LOGCOLLATION>>,
            [index_id],
            [partition_number],
            [page_count],
            [page_density_pct],
            [fragmentation_pct],
            [avg_fragment_size_pages],
            [candidate_reason] COLLATE <<LOGCOLLATION>>,
            [source_fill_factor],
            [fill_factor_guard_applied],
            [avg_row_bytes],
            [record_count],
            [ghost_record_count],
            [fwd_record_count],
            [au_total_pages],
            [au_used_pages],
            [au_data_pages],
            [chosen_fill_factor],
            [online_on],
            [maxdop_used],
            [action] COLLATE <<LOGCOLLATION>>,
            [cmd]      COLLATE <<LOGCOLLATION>>,
            [status] COLLATE <<LOGCOLLATION>>
        FROM to_log;

        IF @pWhatIf = 1
        BEGIN
            DECLARE @logged_count INT = (SELECT COUNT(*) FROM #todo);

            RAISERROR(
                N''WHATIF: Found %d candidate index partition(s) in database: [%s].'',
                10, 1, @logged_count, @pDbName
            ) WITH NOWAIT;
        END

        IF OBJECT_ID(''tempdb..#exec'') IS NOT NULL DROP TABLE #exec;
        CREATE TABLE #exec
        (
            [rn]                      INT IDENTITY(1,1) PRIMARY KEY,
            [log_id]                  BIGINT        NOT NULL,
            [cmd]                     NVARCHAR(MAX) NOT NULL,
            [schema_name]             SYSNAME       NOT NULL,
            [table_name]              SYSNAME       NOT NULL,
            [index_name]              SYSNAME       NOT NULL,
            [index_id]                INT           NOT NULL,
            [partition_number]        INT           NOT NULL,
            [page_count]              BIGINT        NOT NULL,
            [page_density_pct]        DECIMAL(6,2)  NOT NULL, 
            [fragmentation_pct]       DECIMAL(6,2)  NOT NULL, 
            [avg_fragment_size_pages] DECIMAL(18,2) NOT NULL,
            [is_partitioned]          BIT           NOT NULL,
            [compression_desc]        NVARCHAR(60)  NOT NULL,
            [chosen_fill_factor]      INT           NULL,
            [candidate_reason]         VARCHAR(20)  NOT NULL
        );

        INSERT #exec
        (
            [log_id], 
            [cmd], 
            [schema_name], 
            [table_name], 
            [index_name], 
            [index_id],
            [partition_number],
            [page_count], 
            [page_density_pct], 
            [fragmentation_pct],      
            [avg_fragment_size_pages],            
            [is_partitioned], 
            [compression_desc], 
            [chosen_fill_factor], 
            [candidate_reason]
        )
        SELECT
            t.log_id,
            t.cmd,
            l.schema_name COLLATE <<LOGCOLLATION>>,
            l.table_name  COLLATE <<LOGCOLLATION>>,
            l.index_name  COLLATE <<LOGCOLLATION>>,
            l.index_id,
            l.partition_number,
            l.page_count,
            c.page_density_pct, 
            c.fragmentation_pct,       
            c.avg_fragment_size_pages,  
            c.is_partitioned,
            c.compression_desc,
            c.chosen_fill_factor,
            l.candidate_reason COLLATE <<LOGCOLLATION>>
        FROM #todo AS t
        JOIN ' + @qLogDb + N'.[DBA].[IndexBloatRebuildLog] AS l ON
            l.log_id = t.log_id
        JOIN #candidates AS c ON
           (c.schema_name COLLATE <<LOGCOLLATION>>) = (l.schema_name COLLATE <<LOGCOLLATION>>) AND
           (c.table_name  COLLATE <<LOGCOLLATION>>) = (l.table_name  COLLATE <<LOGCOLLATION>>) AND
           (c.index_name  COLLATE <<LOGCOLLATION>>) = (l.index_name  COLLATE <<LOGCOLLATION>>) AND
           c.index_id         = l.index_id AND
           c.partition_number = l.partition_number
        ORDER BY 
           l.page_density_pct ASC, 
           l.page_count DESC;

        DECLARE @i INT = 1, @imax INT = (SELECT COUNT(*) FROM #exec);

        DECLARE
            @cmd NVARCHAR(MAX),
            @cmdOffline NVARCHAR(MAX),
            @log_id BIGINT,
            @schema SYSNAME,
            @table SYSNAME,
            @index SYSNAME,
            @idxId INT,
            @part INT,
            @pages BIGINT,
            @density DECIMAL(6,2),
            @frag DECIMAL(6,2),
            @avgFragRun DECIMAL(18,2),   
            @isPart BIT,
            @comp NVARCHAR(60),
            @ff INT,
            @reason VARCHAR(20);

        DECLARE @delay NVARCHAR(16) = NULL;
        IF @pDelayMsBetweenCommands IS NOT NULL
        BEGIN
            SET @delay = RIGHT(''00'' + CONVERT(VARCHAR(2), (@pDelayMsBetweenCommands/3600000) % 24),2) + '':'' 
                    + RIGHT(''00'' + CONVERT(VARCHAR(2), (@pDelayMsBetweenCommands/60000) % 60),2) + '':'' 
                    + RIGHT(''00'' + CONVERT(VARCHAR(2), (@pDelayMsBetweenCommands/1000) % 60),2) + ''.'' 
                    + RIGHT(''000'' + CONVERT(VARCHAR(3), @pDelayMsBetweenCommands % 1000),3);
        END

        WHILE @i <= @imax
        BEGIN
            SELECT
                @cmd = cmd,
                @log_id = log_id,
                @schema = schema_name,
                @table = table_name,
                @index = index_name,
                @idxId = index_id,
                @part = partition_number,
                @pages = page_count,
                @density = page_density_pct,
                @frag = fragmentation_pct,
                @avgFragRun = avg_fragment_size_pages,
                @isPart = is_partitioned,
                @comp = compression_desc,
                @ff = chosen_fill_factor,
                @reason = candidate_reason
            FROM #exec
            WHERE rn = @i;

            -- Build OFFLINE retry command (strip ONLINE + WAIT_AT_LOW_PRIORITY + RESUMABLE + MAX_DURATION) 
            SET @cmdOffline = @cmd;

            -- Remove ONLINE = ON (with or without WAIT_AT_LOW_PRIORITY)
            DECLARE @onlinePos INT = CHARINDEX(N'', ONLINE = ON'', @cmdOffline);
            IF @onlinePos > 0
            BEGIN
                DECLARE @onlineEnd INT = 0;

                -- If ONLINE has a parenthesized WAIT_AT_LOW_PRIORITY clause, remove through the closing 
                IF SUBSTRING(@cmdOffline, @onlinePos + LEN(N'', ONLINE = ON''), 2) = N'' (''
                BEGIN
                    SET @onlineEnd = CHARINDEX(N''))'', @cmdOffline, @onlinePos);
                    IF @onlineEnd > 0
                        SET @cmdOffline = STUFF(@cmdOffline, @onlinePos, (@onlineEnd + 2 - @onlinePos), N'''');
                    ELSE
                        SET @cmdOffline = STUFF(@cmdOffline, @onlinePos, LEN(N'', ONLINE = ON''), N''''); -- safety fallback
                END
                ELSE
                BEGIN
                    SET @cmdOffline = STUFF(@cmdOffline, @onlinePos, LEN(N'', ONLINE = ON''), N'''');
                END
            END

            -- OFFLINE cannot include RESUMABLE / MAX_DURATION
            SET @cmdOffline = REPLACE(@cmdOffline, N'', RESUMABLE = ON'', N'''');

            DECLARE @mdPos INT = CHARINDEX(N'', MAX_DURATION = '', @cmdOffline);
            IF @mdPos > 0
            BEGIN
                DECLARE @mdEnd INT = CHARINDEX(N'' MINUTES'', @cmdOffline, @mdPos);
                IF @mdEnd > 0
                    SET @cmdOffline = STUFF(@cmdOffline, @mdPos, (@mdEnd + LEN(N'' MINUTES'') - @mdPos), N'''');
            END

            -- If RESUMABLE forced SORT_IN_TEMPDB off, restore requested setting for OFFLINE retry
            IF @pSortInTempdb = 1
                SET @cmdOffline = REPLACE(@cmdOffline, N''SORT_IN_TEMPDB = OFF'', N''SORT_IN_TEMPDB = ON'');

            SET @msg = N''Rebuilding ('' + @reason + N'') '' 
                    + QUOTENAME(@schema) + N''.'' + QUOTENAME(@table) + N''.'' + QUOTENAME(@index)
                    + N'' (partition '' + CONVERT(NVARCHAR(12), @part)
                    + N'', pages = '' + CONVERT(NVARCHAR(20), @pages)
                    + N'', density = '' + CONVERT(NVARCHAR(10), @density) + N''%%''
                    + N'', frag = '' + CONVERT(NVARCHAR(10), @frag) + N''%%''
                    + CASE WHEN @reason = ''READ_AHEAD''
                        THEN N'', avg_frag_run = '' + CONVERT(NVARCHAR(20), @avgFragRun) + N'' pages''
                        ELSE N''''
                    END
                    + N'')'';
            ;RAISERROR(@msg, 10, 1) WITH NOWAIT;

            IF @pWhatIf = 0
            BEGIN
                BEGIN TRY
                    UPDATE l
                    SET [status] = ''RUNNING''
                    FROM ' + @qLogDb + N'.[DBA].[IndexBloatRebuildLog] AS l
                    WHERE l.log_id = @log_id;

                    EXEC (@cmd);

                    UPDATE l
                    SET [status] = ''SUCCESS''
                    FROM ' + @qLogDb + N'.[DBA].[IndexBloatRebuildLog] AS l
                    WHERE l.log_id = @log_id;

                    SET @msg = N''SUCCESS  '' + QUOTENAME(@schema) + N''.'' + QUOTENAME(@table) + N''.'' + QUOTENAME(@index)
                             + N'' (partition '' + CONVERT(NVARCHAR(12), @part) + N'')'';
                    ;RAISERROR(@msg, 10, 1) WITH NOWAIT;
                END TRY
                BEGIN CATCH
                    DECLARE @ErrNum INT = ERROR_NUMBER();
                    DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();

                    -- Retry OFFLINE only if we attempted ONLINE and the failure smells like ONLINE not allowed
                    IF (@pOnline = 1 AND @pIncludeOnlineOption = 1)
                       AND (
                            @ErrNum IN (2725, 2726, 2727, 2728, 1943, 1944)
                        OR (
                                (@ErrMsg COLLATE <<DBCOLLATION>>) LIKE (N''%ONLINE%'' COLLATE <<DBCOLLATION>>)
                            AND (
                                   (@ErrMsg COLLATE <<DBCOLLATION>>) LIKE (N''%not allowed%''       COLLATE <<DBCOLLATION>>)
                                OR (@ErrMsg COLLATE <<DBCOLLATION>>) LIKE (N''%not supported%''     COLLATE <<DBCOLLATION>>)
                                OR (@ErrMsg COLLATE <<DBCOLLATION>>) LIKE (N''%does not support%''  COLLATE <<DBCOLLATION>>)
                                OR (@ErrMsg COLLATE <<DBCOLLATION>>) LIKE (N''%cannot%''            COLLATE <<DBCOLLATION>>)
                               )
                            )
                        )
                    BEGIN
                        SET @msg = N''ONLINE not possible (Error '' + CONVERT(NVARCHAR(12), @ErrNum) + N''): ''
                                + LEFT(@ErrMsg, 1500)
                                + N'' | retrying OFFLINE for ''
                                + QUOTENAME(@schema) + N''.'' + QUOTENAME(@table) + N''.'' + QUOTENAME(@index)
                                + N'' (partition '' + CONVERT(NVARCHAR(12), @part) + N'')'';
                        ;RAISERROR(@msg, 10, 1) WITH NOWAIT;

                        BEGIN TRY
                            EXEC (@cmdOffline);

                            UPDATE l
                            SET [status]        = ''SUCCESS_OFFLINE_FALLBACK'',
                                online_on       = 0,
                                cmd             = @cmdOffline,
                                error_message   = NULL,
                                error_number    = NULL,
                                error_severity  = NULL,
                                error_state     = NULL,
                                error_line      = NULL,
                                error_proc      = NULL
                            FROM ' + @qLogDb + N'.[DBA].[IndexBloatRebuildLog] AS l
                            WHERE l.log_id = @log_id;

                            SET @msg = N''SUCCESS  (OFFLINE fallback) '' + QUOTENAME(@schema) + N''.'' + QUOTENAME(@table) + N''.'' + QUOTENAME(@index)
                                     + N'' (partition '' + CONVERT(NVARCHAR(12), @part) + N'')'';
                            ;RAISERROR(@msg, 10, 1) WITH NOWAIT;
                        END TRY
                        BEGIN CATCH
                            DECLARE @ErrNum2 INT = ERROR_NUMBER();
                            DECLARE @ErrMsg2 NVARCHAR(4000) = ERROR_MESSAGE();
                            DECLARE @CombinedErr NVARCHAR(4000);

                            SET @CombinedErr =
                                LEFT(
                                    (N''ONLINE failed (Error '' COLLATE <<DBCOLLATION>>)
                                  + (CONVERT(NVARCHAR(12), @ErrNum) COLLATE <<DBCOLLATION>>)
                                  + (N''): '' COLLATE <<DBCOLLATION>>)
                                  + (@ErrMsg COLLATE <<DBCOLLATION>>)
                                  + (N'' | OFFLINE failed (Error '' COLLATE <<DBCOLLATION>>)
                                  + (CONVERT(NVARCHAR(12), @ErrNum2) COLLATE <<DBCOLLATION>>)
                                  + (N''): '' COLLATE <<DBCOLLATION>>)
                                  + (@ErrMsg2 COLLATE <<DBCOLLATION>>)
                                , 4000);

                            UPDATE l
                            SET [status]       = ''FAILED_OFFLINE_FALLBACK'',
                                online_on      = 0,
                                cmd            = @cmdOffline,
                                error_message  = @CombinedErr,
                                error_number   = @ErrNum2,
                                error_severity = ERROR_SEVERITY(),
                                error_state    = ERROR_STATE(),
                                error_line     = ERROR_LINE(),
                                error_proc     = ERROR_PROCEDURE()
                            FROM ' + @qLogDb + N'.[DBA].[IndexBloatRebuildLog] AS l
                            WHERE l.log_id = @log_id;

                            SET @msg = N''FAILED (OFFLINE fallback) ''
                                  + QUOTENAME(@schema) + N''.'' + QUOTENAME(@table) + N''.'' + QUOTENAME(@index)
                                  + N'' (partition '' + CONVERT(NVARCHAR(12), @part) + N''): ''
                                  + LEFT(@CombinedErr, 1500);
                            RAISERROR(@msg, 10, 1) WITH NOWAIT;
                        END CATCH;
                    END
                    ELSE
                    BEGIN
                        UPDATE l
                        SET [status]       = ''FAILED'',
                            error_message  = LEFT(@ErrMsg, 4000),
                            error_number   = @ErrNum,
                            error_severity = ERROR_SEVERITY(),
                            error_state    = ERROR_STATE(),
                            error_line     = ERROR_LINE(),
                            error_proc     = ERROR_PROCEDURE()
                        FROM ' + @qLogDb + N'.[DBA].[IndexBloatRebuildLog] AS l
                        WHERE l.log_id = @log_id;

                        SET @msg = N''FAILED   '' + QUOTENAME(@schema) + N''.'' + QUOTENAME(@table) + N''.'' + QUOTENAME(@index)
                                 + N'' (partition '' + CONVERT(NVARCHAR(12), @part) + N''): '' + LEFT(@ErrMsg, 1500);
                        ;RAISERROR(@msg, 10, 1) WITH NOWAIT;
                    END
                END CATCH
            END

            IF @delay IS NOT NULL WAITFOR DELAY @delay;
            SET @i += 1;
        END
        ';

        --change collations
        SET @sql = REPLACE(@sql, N'<<DBCOLLATION>>',  @DbCollation);
        SET @sql = REPLACE(@sql, N'<<LOGCOLLATION>>', @LogCollation);

        EXEC sys.sp_executesql
            @sql,
            N'@pDbName SYSNAME,
              @pMinPageDensityPct DECIMAL(5,2),
              @pMinPageCount INT,
              @pMinAvgFragSizePages INT,
              @pUseExistingFillFactor BIT,
              @pFillFactor TINYINT,
              @pReadAheadMinPageCount INT,
              @pReadAheadMinFragPct DECIMAL(5,2),
              @pReadAheadMinScanOps BIGINT,
              @pReadAheadLookbackDays INT,
              @pReadAheadMinFillFactor TINYINT,
              @pSkipLowFillFactor BIT,
              @pLowFillFactorThreshold TINYINT,
              @pLowFillFactorDensitySlackPct DECIMAL(5,2),
              @pOnline BIT,
              @pMaxDOP INT,
              @pSortInTempdb BIT,
              @pUseCompressionFromSource BIT,
              @pForceCompression NVARCHAR(20),
              @pSampleMode VARCHAR(16),
              @pWhatIf BIT,
              @pWaitAtLowPriorityMinutes INT,
              @pAbortAfterWait NVARCHAR(20),
              @pResumable BIT,
              @pMaxDurationMinutes INT,
              @pDelayMsBetweenCommands INT,
              @pIncludeDataCompressionOption BIT,
              @pIncludeOnlineOption BIT',
              @pDbName                       = @db,
              @pMinPageDensityPct            = @MinPageDensityPct,
              @pMinPageCount                 = @MinPageCount,
              @pMinAvgFragSizePages          = @MinAvgFragmentSizePages,
              @pUseExistingFillFactor        = @UseExistingFillFactor,
              @pFillFactor                   = @FillFactor,
              @pReadAheadMinPageCount        = @ReadAheadMinPageCount,
              @pReadAheadMinFragPct          = @ReadAheadMinFragPct,
              @pReadAheadMinScanOps          = @ReadAheadMinScanOps,
              @pReadAheadLookbackDays        = @ReadAheadLookbackDays,
              @pReadAheadMinFillFactor       = @ReadAheadMinFillFactor,
              @pSkipLowFillFactor            = @SkipLowFillFactor,
              @pLowFillFactorThreshold       = @LowFillFactorThreshold,
              @pLowFillFactorDensitySlackPct = @LowFillFactorDensitySlackPct,
              @pOnline                       = @Online,
              @pMaxDOP                       = @MaxDOP,
              @pSortInTempdb                 = @SortInTempdb,
              @pUseCompressionFromSource     = @UseCompressionFromSource,
              @pForceCompression             = @ForceCompression,
              @pSampleMode                   = @EffectiveSampleMode,
              @pWhatIf                       = @WhatIf,
              @pWaitAtLowPriorityMinutes     = @WaitAtLowPriorityMinutes,
              @pAbortAfterWait               = @AbortAfterWait,
              @pResumable                    = @Resumable,
              @pMaxDurationMinutes           = @MaxDurationMinutes,
              @pDelayMsBetweenCommands       = @DelayMsBetweenCommands,
              @pIncludeDataCompressionOption = @IncludeDataCompressionOption,
              @pIncludeOnlineOption          = @IncludeOnlineOption;

        RAISERROR(N'===== COMPLETED database: [%s] =====', 10, 1, @db) WITH NOWAIT;

        FETCH NEXT FROM cur INTO @db;
    END

    CLOSE cur; DEALLOCATE cur;
END