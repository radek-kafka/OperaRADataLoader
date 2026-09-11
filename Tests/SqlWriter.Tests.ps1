# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Pester tests for Modules\SqlWriter.psm1.

.DESCRIPTION
    All tests use the module's TEST SEAM (-SqlExecutor / -BulkCopy /
    -CurrentVersionLookup) so no live SQL Server is required. A shared fake executor
    records every (Sql, Params) pair; assertions inspect the recorded statements to
    verify:
      * Initialize-Database runs the five DDL scripts in numeric order.
      * OTB snapshot accumulation is INSERT-ONLY (no WHEN MATCHED UPDATE).
      * IS_LATE_POSTING and IS_PAST_CUTOFF flag computation.
      * SCD2 expire-and-insert on change vs no-op when unchanged.
      * SourceCodes REQUIRED vs Channels OPTIONAL handling; the two never mix.
      * staging → MERGE column mapping stamps audit columns and maps every column.
    A live-SQL smoke test is skipped automatically when no server is reachable.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\Modules\SqlWriter.psm1" -Force
    $script:BatchId = [guid]'11111111-1111-1111-1111-111111111111'

    # Factory for a recording executor. $Recorder is a List we push @{Sql;Params} into.
    # $QueryResponders maps a predicate over Sql to a canned rowset for -AsQuery calls.
    function New-RecordingExecutor {
        param(
            [System.Collections.Generic.List[object]] $Recorder,
            [scriptblock] $QueryHandler
        )
        return {
            param($Sql, $Params)
            $Recorder.Add([pscustomobject]@{ Sql = $Sql; Params = $Params })
            if ($Sql -match 'MERGE ') { return 0 }
            if ($Sql -match '^\s*SELECT' -and $null -ne $QueryHandler) {
                return (& $QueryHandler $Sql $Params)
            }
            if ($Sql -match '^\s*SELECT') { return @() }
            return 1
        }.GetNewClosure()
    }
}

Describe 'Get-SqlWriterTableSpec / column contract' {
    It 'maps RES to ra.RES with the documented natural key' {
        $spec = Get-SqlWriterTableSpec -Table 'RES'
        $spec.Target | Should -Be 'ra.RES'
        $spec.NaturalKey | Should -Be @('RESORT', 'BUSINESS_DATE', 'RESV_NAME_ID', 'MARKET_CODE', 'ROOM_CATEGORY_LABEL')
    }
    It 'maps FIN natural key to RESORT+BUSINESS_DATE+TRX_NO+TRAN_ACTION_ID' {
        (Get-SqlWriterTableSpec -Table 'FIN').NaturalKey | Should -Be @('RESORT', 'BUSINESS_DATE', 'TRX_NO', 'TRAN_ACTION_ID')
    }
    It 'includes SNAPSHOT_DATE in the OTB natural key (accumulation)' {
        (Get-SqlWriterTableSpec -Table 'OTB').NaturalKey | Should -Contain 'SNAPSHOT_DATE'
    }
    It 'DIM_SourceCodes and DIM_Channels resolve to independent tables' {
        (Get-SqlWriterTableSpec -Table 'DIM_SourceCodes').Target | Should -Be 'ra.DIM_SourceCodes'
        (Get-SqlWriterTableSpec -Table 'DIM_Channels').Target    | Should -Be 'ra.DIM_Channels'
    }
}

Describe 'Initialize-Database' {
    It 'executes the five DDL scripts in numeric order (001..005)' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $result = Initialize-Database -SqlExecutor $exec

        $result.Scripts.Count | Should -Be 5
        $result.Scripts[0] | Should -BeLike '001_*'
        $result.Scripts[1] | Should -BeLike '002_*'
        $result.Scripts[2] | Should -BeLike '003_*'
        $result.Scripts[3] | Should -BeLike '004_*'
        $result.Scripts[4] | Should -BeLike '005_*'
        $result.BatchesExecuted | Should -BeGreaterThan 5   # multiple GO batches per file
    }

    It 'splits scripts on standalone GO separators' {
        $sql = "SELECT 1`nGO`nSELECT 2`nGO`nSELECT 3"
        $batches = Split-SqlBatches -Script $sql
        $batches.Count | Should -Be 3
    }
}

Describe 'Column mapping (staging -> MERGE)' {
    It 'New-MergeStatement maps every column and keys on the natural key' {
        $spec = Get-SqlWriterTableSpec -Table 'RMN'
        $all = @($spec.Columns) + @($spec.Audit)
        $sql = New-MergeStatement -Target $spec.Target -Staging '#stg_x' -NaturalKey $spec.NaturalKey -AllColumns $all
        $sql | Should -Match 'MERGE \[ra\]\.\[RMN\] AS tgt'
        $sql | Should -Match 'ON \(tgt\.\[RESORT\] = src\.\[RESORT\] AND tgt\.\[ROOM\] = src\.\[ROOM\]\)'
        $sql | Should -Match 'WHEN MATCHED THEN UPDATE SET'
        $sql | Should -Match '\[BATCH_ID\]'
        $sql | Should -Match 'OUTPUT \$action'
    }

    It 'stamps BATCH_ID / LOADED_AT / LOADED_BY on staged rows' {
        $row = ConvertTo-StagingRow -Record ([pscustomobject]@{ RESORT = 'H1'; ROOM = '101' }) `
            -Columns (Get-SqlWriterTableSpec -Table 'RMN').Columns `
            -BatchId $script:BatchId -LoadedBy 'tester' -LoadedAt ([datetime]'2026-01-01')
        $row.BATCH_ID | Should -Be $script:BatchId
        $row.LOADED_BY | Should -Be 'tester'
        $row.PSObject.Properties.Name | Should -Contain 'ROOM_CATEGORY_LABEL'
    }

    It 'Write-RES bulk-copies the mapped columns then MERGEs on natural key' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $capture = [System.Collections.Generic.List[object]]::new()
        $bulk = { param($Table, $Rows, $Cols) $Cols | ForEach-Object { $capture.Add($_) }; return $Rows.Count }.GetNewClosure()

        $data = @([pscustomobject]@{ RESORT = 'H1'; BUSINESS_DATE = '20260730'; RESV_NAME_ID = 'R1'; MARKET_CODE = 'CORP'; ROOM_CATEGORY_LABEL = 'DB1'; REVENUE = 100 })
        $res = Write-RES -Data $data -BatchId $script:BatchId -SqlExecutor $exec -BulkCopy $bulk

        $res.RowsStaged | Should -Be 1
        $capture | Should -Contain 'BATCH_ID'
        $capture | Should -Contain 'REVENUE'
        ($rec | Where-Object { $_.Sql -match 'MERGE \[ra\]\.\[RES\]' }).Count | Should -Be 1
    }
}

Describe 'IS_LATE_POSTING computation (Write-FIN)' {
    It 'flags a posting after the business date as late' {
        Get-IsLatePosting -PostingDate '20260731' -BusinessDate '20260730' | Should -Be 1
    }
    It 'does not flag a same-day posting' {
        Get-IsLatePosting -PostingDate '20260730' -BusinessDate '20260730' | Should -Be 0
    }
    It 'does not flag an on-time (earlier) posting' {
        Get-IsLatePosting -PostingDate '20260729' -BusinessDate '20260730' | Should -Be 0
    }
    It 'Write-FIN computes IS_LATE_POSTING during mapping' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $finRows = [System.Collections.Generic.List[object]]::new()
        $bulk = { param($t, $rows, $c) $rows | ForEach-Object { $finRows.Add($_) }; return $rows.Count }.GetNewClosure()

        $data = @(
            [pscustomobject]@{ RESORT = 'H1'; BUSINESS_DATE = '20260730'; TRX_NO = 'T1'; TRAN_ACTION_ID = 'A1'; TRX_CODE = '1000'; POSTING_DATE = '20260801'; TRX_DATE = '20260801' },
            [pscustomobject]@{ RESORT = 'H1'; BUSINESS_DATE = '20260730'; TRX_NO = 'T2'; TRAN_ACTION_ID = 'A1'; TRX_CODE = '1000'; POSTING_DATE = '20260730'; TRX_DATE = '20260730' }
        )
        $null = Write-FIN -Data $data -BatchId $script:BatchId -SqlExecutor $exec -BulkCopy $bulk
        ($finRows | Where-Object { $_.TRX_NO -eq 'T1' }).IS_LATE_POSTING | Should -Be 1
        ($finRows | Where-Object { $_.TRX_NO -eq 'T2' }).IS_LATE_POSTING | Should -Be 0
    }
}

Describe 'IS_PAST_CUTOFF computation (Write-BLK)' {
    It 'flags a block whose cutoff is before the snapshot date' {
        Get-IsPastCutoff -CutoffDate '20260729' -SnapshotDate '20260730' | Should -Be 1
    }
    It 'does not flag a block whose cutoff is on/after the snapshot date' {
        Get-IsPastCutoff -CutoffDate '20260730' -SnapshotDate '20260730' | Should -Be 0
        Get-IsPastCutoff -CutoffDate '20260731' -SnapshotDate '20260730' | Should -Be 0
    }
    It 'Write-BLK computes IS_PAST_CUTOFF during mapping' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $blkRows = [System.Collections.Generic.List[object]]::new()
        $bulk = { param($t, $rows, $c) $rows | ForEach-Object { $blkRows.Add($_) }; return $rows.Count }.GetNewClosure()

        $data = @(
            [pscustomobject]@{ RESORT = 'H1'; SNAPSHOT_DATE = '20260730'; BLOCK_CODE = 'B1'; CONSIDERED_DATE = '20260810'; ROOM_CATEGORY_LABEL = 'DB1'; CUTOFF_DATE = '20260720' },
            [pscustomobject]@{ RESORT = 'H1'; SNAPSHOT_DATE = '20260730'; BLOCK_CODE = 'B2'; CONSIDERED_DATE = '20260810'; ROOM_CATEGORY_LABEL = 'DB1'; CUTOFF_DATE = '20260805' }
        )
        $null = Write-BLK -Data $data -BatchId $script:BatchId -SqlExecutor $exec -BulkCopy $bulk
        ($blkRows | Where-Object { $_.BLOCK_CODE -eq 'B1' }).IS_PAST_CUTOFF | Should -Be 1
        ($blkRows | Where-Object { $_.BLOCK_CODE -eq 'B2' }).IS_PAST_CUTOFF | Should -Be 0
    }
}

Describe 'OTB / BLK snapshot accumulation (insert-only)' {
    It 'Write-OTB issues an INSERT-ONLY MERGE (no WHEN MATCHED UPDATE)' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $bulk = { param($t, $rows, $c) return $rows.Count }

        $data = @([pscustomobject]@{ RESORT = 'H1'; SNAPSHOT_DATE = '20260730'; CONSIDERED_DATE = '20260810'; MARKET_CODE = 'CORP'; ROOM_CATEGORY_LABEL = 'DB1'; SOURCE_CODE = 'WEB'; CHANNEL = 'DIRECT'; RATE_CODE = 'BAR'; RESV_TYPE = 'R'; NO_ROOMS = 5 })
        $null = Write-OTB -Data $data -BatchId $script:BatchId -SqlExecutor $exec -BulkCopy $bulk

        $merge = ($rec | Where-Object { $_.Sql -match 'MERGE \[ra\]\.\[OTB\]' }).Sql
        $merge | Should -Not -BeNullOrEmpty
        $merge | Should -Not -BeLike '*WHEN MATCHED THEN UPDATE*'
        $merge | Should -BeLike '*WHEN NOT MATCHED BY TARGET THEN*'
    }

    It 'Write-BLK is also insert-only so prior snapshots are preserved' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $bulk = { param($t, $rows, $c) return $rows.Count }
        $data = @([pscustomobject]@{ RESORT = 'H1'; SNAPSHOT_DATE = '20260730'; BLOCK_CODE = 'B1'; CONSIDERED_DATE = '20260810'; ROOM_CATEGORY_LABEL = 'DB1'; CUTOFF_DATE = '20260720' })
        $null = Write-BLK -Data $data -BatchId $script:BatchId -SqlExecutor $exec -BulkCopy $bulk
        (($rec | Where-Object { $_.Sql -match 'MERGE \[ra\]\.\[BLK\]' }).Sql) | Should -Not -BeLike '*WHEN MATCHED THEN UPDATE*'
    }
}

Describe 'SCD Type 2 (Write-DIM)' {
    It 'inserts a new current version for a brand-new code' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $lookup = { param($resort, $code) return $null }   # no current row exists

        $data = @([pscustomobject]@{ RESORT = 'H1'; CODE = 'CORP'; DESCRIPTION = 'Corporate'; SEGMENT_GROUP = 'BUS'; IS_ACTIVE = 1; FLAG = 'N' })
        $r = Write-DIM -Type 'DIM_MarketCodes' -Data $data -BatchId $script:BatchId -SqlExecutor $exec -CurrentVersionLookup $lookup

        $r.Inserted | Should -Be 1
        $r.Updated | Should -Be 0
        $r.Unchanged | Should -Be 0
        $insert = ($rec | Where-Object { $_.Sql -match 'INSERT INTO' }).Sql
        $insert | Should -BeLike '*[VALID_FROM]*'
        $insert | Should -BeLike '*[IS_CURRENT]*'
    }

    It 'expires the current row and inserts a new version when a tracked column changes' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $current = [pscustomobject]@{ RESORT = 'H1'; CODE = 'CORP'; CHAIN_CODE = $null; DESCRIPTION = 'Corporate'; SEGMENT_GROUP = 'BUS'; IS_ACTIVE = 1; FLAG = 'N' }
        $lookup = { param($resort, $code) return $current }.GetNewClosure()

        $data = @([pscustomobject]@{ RESORT = 'H1'; CODE = 'CORP'; DESCRIPTION = 'Corporate Renamed'; SEGMENT_GROUP = 'BUS'; IS_ACTIVE = 1; FLAG = 'N' })
        $r = Write-DIM -Type 'DIM_MarketCodes' -Data $data -BatchId $script:BatchId -SqlExecutor $exec -CurrentVersionLookup $lookup

        $r.Updated | Should -Be 1
        $r.Inserted | Should -Be 1
        ($rec | Where-Object { $_.Sql -match 'UPDATE .* SET VALID_TO' -and $_.Sql -match 'IS_CURRENT = 0' }).Count | Should -Be 1
        ($rec | Where-Object { $_.Sql -match 'INSERT INTO' }).Count | Should -Be 1
    }

    It 'is a no-op when nothing tracked changed (avoids churn)' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $current = [pscustomobject]@{ RESORT = 'H1'; CODE = 'CORP'; CHAIN_CODE = $null; DESCRIPTION = 'Corporate'; SEGMENT_GROUP = 'BUS'; IS_ACTIVE = 1; FLAG = 'N' }
        $lookup = { param($resort, $code) return $current }.GetNewClosure()

        $data = @([pscustomobject]@{ RESORT = 'H1'; CODE = 'CORP'; DESCRIPTION = 'Corporate'; SEGMENT_GROUP = 'BUS'; IS_ACTIVE = 1; FLAG = 'N' })
        $r = Write-DIM -Type 'DIM_MarketCodes' -Data $data -BatchId $script:BatchId -SqlExecutor $exec -CurrentVersionLookup $lookup

        $r.Unchanged | Should -Be 1
        $r.Inserted | Should -Be 0
        $r.Updated | Should -Be 0
        ($rec | Where-Object { $_.Sql -match 'INSERT INTO|UPDATE ' }).Count | Should -Be 0
    }

    It 'Get-Scd2Action treats NULL and empty string as equal' {
        $cur = [pscustomobject]@{ DESCRIPTION = '' }
        $inc = [pscustomobject]@{ DESCRIPTION = $null }
        Get-Scd2Action -TrackedColumns @('DESCRIPTION') -Incoming $inc -Current $cur | Should -Be 'None'
    }
}

Describe 'SourceCodes required vs Channels optional (independent lists)' {
    It 'writes DIM_SourceCodes (required) to ra.DIM_SourceCodes only' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $lookup = { param($r, $c) return $null }

        $data = @([pscustomobject]@{ RESORT = 'H1'; CODE = 'GDS'; DESCRIPTION = 'GDS Source'; IS_ACTIVE = 1; FLAG = 'N' })
        $r = Write-DIM -Type 'DIM_SourceCodes' -Data $data -BatchId $script:BatchId -SqlExecutor $exec -CurrentVersionLookup $lookup

        $r.Inserted | Should -Be 1
        ($rec | Where-Object { $_.Sql -match 'ra\.\[DIM_SourceCodes\]|ra\]\.\[DIM_SourceCodes' -or $_.Sql -match '\[ra\]\.\[DIM_SourceCodes\]' }).Count | Should -BeGreaterThan 0
        ($rec | Where-Object { $_.Sql -match 'DIM_Channels' }).Count | Should -Be 0
    }

    It 'treats an empty DIM_Channels payload as a benign no-op (optional)' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $r = Write-DIM -Type 'DIM_Channels' -Data @() -BatchId $script:BatchId -SqlExecutor $exec

        $r.Inserted | Should -Be 0
        $rec.Count | Should -Be 0
    }
}

Describe 'ra.Hotels single-current-row upsert' {
    It 'inserts when the resort is new' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $lookup = { param($r, $c) return $null }
        $data = @([pscustomobject]@{ RESORT = 'H1'; DISPLAY_NAME = 'Hotel One'; CITY = 'Vienna'; IS_ACTIVE = 1 })
        $r = Write-DIM -Type 'Hotels' -Data $data -BatchId $script:BatchId -SqlExecutor $exec -CurrentVersionLookup $lookup
        $r.Inserted | Should -Be 1
        ($rec | Where-Object { $_.Sql -match 'INSERT INTO' }).Count | Should -Be 1
    }

    It 'updates the existing row in place when a tracked column changes (no versioning)' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $current = [pscustomobject]@{ RESORT = 'H1'; CHAIN_CODE = $null; DISPLAY_NAME = 'Hotel One'; CITY = 'Vienna'; COUNTRY = $null; CURRENCY_CODE = $null; TIME_ZONE_ID = $null; NIGHT_AUDIT_HOUR = $null; NIGHT_AUDIT_MIN = $null; IS_ACTIVE = 1 }
        $lookup = { param($r, $c) return $current }.GetNewClosure()
        $data = @([pscustomobject]@{ RESORT = 'H1'; DISPLAY_NAME = 'Hotel One Renamed'; CITY = 'Vienna'; IS_ACTIVE = 1 })
        $r = Write-DIM -Type 'Hotels' -Data $data -BatchId $script:BatchId -SqlExecutor $exec -CurrentVersionLookup $lookup
        $r.Updated | Should -Be 1
        ($rec | Where-Object { $_.Sql -match 'UPDATE .* SET' -and $_.Sql -notmatch 'VALID_TO' }).Count | Should -Be 1
    }
}

Describe 'Write-LoadLog (DDL-accurate dbo.LoadLog contract)' {
    It 'inserts a Running row on Start using the real DDL columns' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $batch = Write-LoadLog -Action 'Start' -HotelCode 'H1' -Mode 'Delta' -QueryType 'ReservationStats' -SqlExecutor $exec
        $batch | Should -BeOfType [guid]
        $insert = ($rec | Where-Object { $_.Sql -match 'INSERT INTO dbo.LoadLog' }).Sql
        $insert | Should -BeLike '*StartTime*'
        $insert | Should -BeLike '*[Status]*'
        $insert | Should -Not -BeLike '*StartedAt*'   # NOT the Logger proposed column
    }

    It 'updates the row on Complete with EndTime / [RowCount] and terminal status' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $null = Write-LoadLog -Action 'Complete' -BatchId ([guid]'22222222-2222-2222-2222-222222222222') -HotelCode 'H1' -QueryType 'ReservationStats' `
            -Status 'Success' -RowCount 24 -RowsInserted 20 -RowsUpdated 4 -SqlExecutor $exec
        $update = ($rec | Where-Object { $_.Sql -match 'UPDATE dbo.LoadLog' }).Sql
        $update | Should -BeLike '*EndTime*'
        $update | Should -BeLike '*[RowCount]*'
        $update | Should -Not -BeLike '*DurationMs*'   # DurationSeconds is computed in DDL
    }

    It 'accepts the -LogEntry hashtable form' {
        $rec = [System.Collections.Generic.List[object]]::new()
        $exec = New-RecordingExecutor -Recorder $rec
        $batch = Write-LoadLog -LogEntry @{ Action = 'Start'; HotelCode = 'H1'; QueryType = 'FinancialTx'; Mode = 'Full' } -SqlExecutor $exec
        $batch | Should -BeOfType [guid]
        ($rec | Where-Object { $_.Sql -match 'INSERT INTO dbo.LoadLog' }).Count | Should -Be 1
    }
}

Describe 'Transaction rollback on MERGE failure (seam)' {
    It 'rethrows and logs ERROR when the executor throws during MERGE' {
        $throwingExec = {
            param($Sql, $Params)
            if ($Sql -match 'MERGE ') { throw 'boom' }
            return 1
        }
        $bulk = { param($t, $rows, $c) return $rows.Count }
        $data = @([pscustomobject]@{ RESORT = 'H1'; ROOM = '101'; ROOM_CATEGORY_LABEL = 'DB1' })
        { Write-RMN -Data $data -BatchId $script:BatchId -SqlExecutor $throwingExec -BulkCopy $bulk } | Should -Throw
    }
}
