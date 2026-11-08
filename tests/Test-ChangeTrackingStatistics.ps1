[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ServerInstance
)

$ErrorActionPreference = 'Stop'
$databaseName = 'AdaptiveDBCare_CT_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$procedurePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\usp_UpdateStatisticsIfChanged.sql'))
$created = $false

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw 'sqlcmd is required for this SQL Server integration test.'
}

function Invoke-TestSql {
    param(
        [Parameter(Mandatory = $true)] [string] $Database,
        [string] $Query,
        [string] $InputFile
    )

    $arguments = @('-S', $ServerInstance, '-E', '-b', '-l', '10', '-t', '120', '-d', $Database)
    if ($InputFile) {
        $arguments += @('-i', $InputFile)
    }
    else {
        $arguments += @('-Q', $Query)
    }

    $result = & sqlcmd @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SQL integration step failed: $($result -join [Environment]::NewLine)"
    }
}

try {
    Invoke-TestSql -Database 'master' -Query @"
IF DB_ID(N'$databaseName') IS NOT NULL
    THROW 51000, 'Disposable test database already exists.', 1;
CREATE DATABASE [$databaseName];
"@
    $created = $true
    Invoke-TestSql -Database $databaseName -InputFile $procedurePath

    Invoke-TestSql -Database $databaseName -Query @"
ALTER DATABASE [$databaseName]
    SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);
CREATE TABLE dbo.Tracked
(
    Id int NOT NULL CONSTRAINT PK_Tracked PRIMARY KEY,
    Payload nvarchar(100) NOT NULL
);
ALTER TABLE dbo.Tracked ENABLE CHANGE_TRACKING
    WITH (TRACK_COLUMNS_UPDATED = ON);
INSERT dbo.Tracked (Id, Payload)
SELECT TOP (100)
    ROW_NUMBER() OVER (ORDER BY a.object_id, b.object_id), N'initial'
FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b;
IF NOT EXISTS
(
    SELECT 1
    FROM sys.internal_tables AS it
    JOIN sys.stats AS st ON st.object_id = it.object_id
    OUTER APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp
    WHERE it.internal_type = 209
      AND it.parent_object_id = OBJECT_ID(N'dbo.Tracked')
      AND sp.last_updated IS NULL
)
    THROW 51001, 'Expected an uninitialized Change Tracking statistic.', 1;
"@

    Invoke-TestSql -Database $databaseName -Query @"
DECLARE @before_id bigint = ISNULL((SELECT MAX(log_id) FROM DBA.UpdateStatsLog), 0);
EXEC DBA.usp_UpdateStatisticsIfChanged
    @TargetDatabases = N'$databaseName',
    @ChangeThresholdPercent = 20,
    @WhatIf = 1;
IF NOT EXISTS
(
    SELECT 1
    FROM DBA.UpdateStatsLog AS log_row
    JOIN sys.internal_tables AS it ON it.name = log_row.table_name
    WHERE log_row.log_id > @before_id
      AND it.internal_type = 209
      AND it.parent_object_id = OBJECT_ID(N'dbo.Tracked')
      AND log_row.stats_id = 0
      AND log_row.stats_name = N'ALL'
      AND log_row.[action] = 'DRYRUN'
      AND log_row.[status] = 'SKIPPED'
)
    THROW 51002, 'Dry run omitted the uninitialized Change Tracking table.', 1;
IF EXISTS
(
    SELECT 1
    FROM sys.internal_tables AS it
    JOIN sys.stats AS st ON st.object_id = it.object_id
    OUTER APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp
    WHERE it.internal_type = 209
      AND it.parent_object_id = OBJECT_ID(N'dbo.Tracked')
      AND sp.last_updated IS NOT NULL
)
    THROW 51003, 'Dry run unexpectedly updated statistics.', 1;
"@

    Invoke-TestSql -Database $databaseName -Query @"
DECLARE @before_id bigint = ISNULL((SELECT MAX(log_id) FROM DBA.UpdateStatsLog), 0);
EXEC DBA.usp_UpdateStatisticsIfChanged
    @TargetDatabases = N'$databaseName',
    @ChangeThresholdPercent = 20,
    @WhatIf = 0;
IF NOT EXISTS
(
    SELECT 1
    FROM DBA.UpdateStatsLog AS log_row
    JOIN sys.internal_tables AS it ON it.name = log_row.table_name
    WHERE log_row.log_id > @before_id
      AND it.internal_type = 209
      AND it.parent_object_id = OBJECT_ID(N'dbo.Tracked')
      AND log_row.stats_id = 0
      AND log_row.[action] = 'UPDATE'
      AND log_row.[status] = 'SUCCESS'
)
    THROW 51004, 'Initial Change Tracking update did not succeed.', 1;
IF NOT EXISTS
(
    SELECT 1
    FROM sys.internal_tables AS it
    JOIN sys.stats AS st ON st.object_id = it.object_id
    OUTER APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp
    WHERE it.internal_type = 209
      AND it.parent_object_id = OBJECT_ID(N'dbo.Tracked')
      AND sp.last_updated IS NOT NULL
      AND sp.modification_counter = 0
)
    THROW 51005, 'Initial Change Tracking statistics were not initialized.', 1;
"@

    Invoke-TestSql -Database $databaseName -Query @"
UPDATE dbo.Tracked SET Payload = N'changed' WHERE Id <= 30;
DECLARE @before_id bigint = ISNULL((SELECT MAX(log_id) FROM DBA.UpdateStatsLog), 0);
EXEC DBA.usp_UpdateStatisticsIfChanged
    @TargetDatabases = N'$databaseName',
    @ChangeThresholdPercent = 20,
    @SampleMode = 'SAMPLED',
    @SamplePercent = 10,
    @WhatIf = 0;
IF NOT EXISTS
(
    SELECT 1
    FROM DBA.UpdateStatsLog AS log_row
    JOIN sys.internal_tables AS it ON it.name = log_row.table_name
    WHERE log_row.log_id > @before_id
      AND it.internal_type = 209
      AND it.parent_object_id = OBJECT_ID(N'dbo.Tracked')
      AND log_row.stats_id = 0
      AND log_row.change_pct >= 20
      AND log_row.[status] = 'SUCCESS'
      AND log_row.cmd LIKE N'% WITH SAMPLE 10 PERCENT'
)
    THROW 51006, 'Thresholded sampled Change Tracking update did not succeed.', 1;
"@

    Invoke-TestSql -Database $databaseName -Query @"
UPDATE dbo.Tracked SET Payload = N'fullscan' WHERE Id BETWEEN 40 AND 49;
DECLARE @before_id bigint = ISNULL((SELECT MAX(log_id) FROM DBA.UpdateStatsLog), 0);
EXEC DBA.usp_UpdateStatisticsIfChanged
    @TargetDatabases = N'$databaseName',
    @ChangeScope = 'ALL_CHANGES',
    @SampleMode = 'FULLSCAN',
    @WhatIf = 0;
IF NOT EXISTS
(
    SELECT 1
    FROM DBA.UpdateStatsLog AS log_row
    JOIN sys.internal_tables AS it ON it.name = log_row.table_name
    WHERE log_row.log_id > @before_id
      AND it.internal_type = 209
      AND it.parent_object_id = OBJECT_ID(N'dbo.Tracked')
      AND log_row.stats_id = 0
      AND log_row.[status] = 'SUCCESS'
      AND log_row.cmd LIKE N'% WITH FULLSCAN'
)
    THROW 51007, 'Fullscan Change Tracking update did not succeed.', 1;
"@

    Write-Output "PASS: Change Tracking statistics on $ServerInstance"
}
finally {
    if ($created) {
        Invoke-TestSql -Database 'master' -Query @"
IF DB_ID(N'$databaseName') IS NOT NULL
BEGIN
    ALTER DATABASE [$databaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$databaseName];
END;
IF DB_ID(N'$databaseName') IS NOT NULL
    THROW 51008, 'Disposable test database was not removed.', 1;
"@
    }
}
