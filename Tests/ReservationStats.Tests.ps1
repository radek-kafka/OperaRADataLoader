# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
    Pester tests for Modules\Queries\ReservationStats.psm1 (Task 8 — RES query module).

    Covers:
      - Date chunking into the correct number of chunks + ISO YYYY-MM-DD request filters.
      - Response -> PSCustomObject mapping of the key ra.RES fields
        (RESV_NAME_ID, MARKET_CODE, ROOM_CATEGORY_LABEL, SOURCE_CODE, CHANNEL, RESORT, ...).
      - Output date formatting: date-only -> YYYYMMDD; datetime -> YYYYMMDD HH:mm:ss.
      - ADR / RevPAR computation incl. divide-by-zero guard and "don't overwrite the
        API-supplied value".
      - Multi-chunk accumulation into a single flat array.
      - Per-chunk row-count / duration logging.

    No live API is contacted: the module's -SubjectAreaInvoker seam returns canned rows
    and records the arguments (Chunks/Variables) it was called with, so the request-filter
    and per-chunk behaviour can be asserted with zero network access.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\Modules\DateHelper.psm1" -Force
    Import-Module "$PSScriptRoot\..\Modules\Queries\ReservationStats.psm1" -Force

    $script:Hotel = @{
        HotelCode  = 'TEST01'
        ChainCode  = 'CHN1'
        TimeZoneId = 'Central European Standard Time'
    }

    # Builds a -SubjectAreaInvoker seam that:
    #   * records every call's args into the returned invoker's captured list
    #     (exposed to the test via $script:Calls), and
    #   * returns the rows produced by $RowFactory for that chunk (keyed by chunk index).
    # A LOCAL $callList is captured by the closure (via GetNewClosure) so it survives
    # regardless of Pester's script-scope handling; $script:Calls is pointed at the same
    # list instance so assertions can read it.
    function New-RecordingInvoker {
        param(
            [scriptblock] $RowFactory = { param($callIndex, $vars) @() }
        )
        $callList = [System.Collections.Generic.List[object]]::new()
        $script:Calls = $callList
        return {
            param($saArgs)
            $idx = $callList.Count
            $callList.Add($saArgs)
            $vars = $saArgs.Chunks[0].Variables
            return @(& $RowFactory $idx $vars)
        }.GetNewClosure()
    }

    # A single fully-populated raw API row (camelCase GraphQL field names).
    function New-RawRow {
        param([hashtable] $Overrides = @{})
        $row = @{
            resort            = 'TEST01'
            businessDate      = '2026-07-30'
            resvNameId        = 'RID-001'
            rateCode          = 'BAR'
            rateCategory      = 'RACK'
            marketCode        = 'LEIS'
            sourceCode        = 'WEB'
            channel           = 'OTA'
            truncBeginDate    = '2026-07-30'
            truncEndDate      = '2026-08-02'
            room              = '101'
            pseudoRoomYn      = 'N'
            roomCategoryLabel = 'DB1'
            resvStatus        = 'CHECKED_OUT'
            quantity          = 1
            adults            = 2
            children          = 0
            stayRooms         = 3
            arrRooms          = 1
            depRooms          = 1
            country           = 'DE'
            nights            = 3
            cancellationDate  = '2026-07-28T14:33:21'
            roomNights        = 3
            revenue           = 600.00
            physicalRooms     = 120
        }
        foreach ($k in $Overrides.Keys) { $row[$k] = $Overrides[$k] }
        return [PSCustomObject]$row
    }
}

Describe 'Get-ReservationStats — date chunking and request filters' {

    It 'splits a 20-day range into 3 chunks with default 7-day chunking' {
        $invoker = New-RecordingInvoker
        $null = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-01-01' -EndDate '2026-01-20' `
            -SubjectAreaInvoker $invoker

        $script:Calls.Count | Should -Be 3
    }

    It 'respects an explicit -ChunkDays value' {
        $invoker = New-RecordingInvoker
        $null = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-01-01' -EndDate '2026-01-10' -ChunkDays 5 `
            -SubjectAreaInvoker $invoker

        $script:Calls.Count | Should -Be 2
    }

    It 'reads transactionalChunkDays from the Config when -ChunkDays is omitted' {
        $invoker = New-RecordingInvoker
        $cfg = @{ extraction = @{ transactionalChunkDays = 10 } }
        $null = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-01-01' -EndDate '2026-01-20' -Config $cfg `
            -SubjectAreaInvoker $invoker

        # 20 days / 10 = 2 chunks.
        $script:Calls.Count | Should -Be 2
    }

    It 'builds ISO YYYY-MM-DD request filters (not the YYYYMMDD output format)' {
        $invoker = New-RecordingInvoker
        $null = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-07-01' -EndDate '2026-07-07' `
            -SubjectAreaInvoker $invoker

        $vars = $script:Calls[0].Chunks[0].Variables
        $vars.input.resort._in | Should -Be @('TEST01')
        $vars.input.businessDate._gte | Should -Be '2026-07-01'
        $vars.input.businessDate._lte | Should -Be '2026-07-07'
        # Explicitly assert ISO dashes are present (NOT compact YYYYMMDD).
        $vars.input.businessDate._gte | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'passes the correct operation and primary view to the API layer' {
        $invoker = New-RecordingInvoker
        $null = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-07-01' -EndDate '2026-07-01' `
            -SubjectAreaInvoker $invoker

        $script:Calls[0].Operation | Should -Be 'statisticsReservationsDaily'
        $script:Calls[0].PrimaryView | Should -Be 'reservationDailyStatisticsDetails'
    }
}

Describe 'Get-ReservationStats — response mapping' {

    It 'maps the key ra.RES fields from the raw API row' {
        $invoker = New-RecordingInvoker -RowFactory { param($i, $v) @(New-RawRow) }
        $rows = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows.Count | Should -Be 1
        $r = $rows[0]
        $r.RESORT              | Should -Be 'TEST01'
        $r.CHAIN_CODE          | Should -Be 'CHN1'
        $r.RESV_NAME_ID        | Should -Be 'RID-001'
        $r.MARKET_CODE         | Should -Be 'LEIS'
        $r.ROOM_CATEGORY_LABEL | Should -Be 'DB1'
        $r.SOURCE_CODE         | Should -Be 'WEB'
        $r.CHANNEL             | Should -Be 'OTA'
        $r.RESV_STATUS         | Should -Be 'CHECKED_OUT'
        $r.NIGHTS              | Should -Be 3
        $r.STAY_ROOMS          | Should -Be 3
    }

    It 'emits $null for missing / empty source values without crashing' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v)
            @(New-RawRow -Overrides @{ sourceCode = ''; channel = $null; marketCode = '   ' })
        }
        $rows = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].SOURCE_CODE | Should -BeNullOrEmpty
        $rows[0].CHANNEL     | Should -BeNullOrEmpty
        $rows[0].MARKET_CODE | Should -BeNullOrEmpty
        # A row that has no source data still maps its identity fields.
        $rows[0].RESV_NAME_ID | Should -Be 'RID-001'
    }

    It 'backfills a blank RESORT from the hotel code (fallback)' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v) @(New-RawRow -Overrides @{ resort = '' })
        }
        $rows = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].RESORT | Should -Be 'TEST01'
    }
}

Describe 'Get-ReservationStats — output date formatting' {

    It 'formats date-only fields as YYYYMMDD' {
        $invoker = New-RecordingInvoker -RowFactory { param($i, $v) @(New-RawRow) }
        $rows = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].BUSINESS_DATE    | Should -Be '20260730'
        $rows[0].TRUNC_BEGIN_DATE | Should -Be '20260730'
        $rows[0].TRUNC_END_DATE   | Should -Be '20260802'
    }

    It 'formats the datetime CANCELLATION_DATE as YYYYMMDD HH:mm:ss' {
        # Use a UTC-agnostic hotel (no timeZoneId) so the wall-clock value is preserved.
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v) @(New-RawRow -Overrides @{ cancellationDate = '2026-05-07 12:33:21' })
        }
        $rows = Get-ReservationStats -Hotel @{ HotelCode = 'TEST01' } `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].CANCELLATION_DATE | Should -Be '20260507 12:33:21'
    }

    It 'renders empty date fields as an empty string' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v) @(New-RawRow -Overrides @{ cancellationDate = $null; truncEndDate = '' })
        }
        $rows = Get-ReservationStats -Hotel @{ HotelCode = 'TEST01' } `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].CANCELLATION_DATE | Should -Be ''
        $rows[0].TRUNC_END_DATE    | Should -Be ''
    }
}

Describe 'Get-ReservationStats — ADR / RevPAR computation' {

    It 'computes ADR = Revenue / RoomNights when the API omits ADR' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v) @(New-RawRow -Overrides @{ revenue = 600; roomNights = 3; adr = $null })
        }
        $rows = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].ADR | Should -Be ([decimal]200)
    }

    It 'computes RevPAR = Revenue / PhysicalRooms when the API omits RevPAR' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v) @(New-RawRow -Overrides @{ revenue = 600; physicalRooms = 120; revPar = $null })
        }
        $rows = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].REVPAR | Should -Be ([decimal]5)
    }

    It 'does NOT overwrite an API-supplied ADR / RevPAR' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v)
            @(New-RawRow -Overrides @{ revenue = 600; roomNights = 3; physicalRooms = 120; adr = 999; revPar = 42 })
        }
        $rows = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].ADR    | Should -Be ([decimal]999)
        $rows[0].REVPAR | Should -Be ([decimal]42)
    }

    It 'guards divide-by-zero: ADR / RevPAR are $null when the denominator is 0' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v)
            @(New-RawRow -Overrides @{ revenue = 600; roomNights = 0; physicalRooms = 0; adr = $null; revPar = $null })
        }
        $rows = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].ADR    | Should -BeNullOrEmpty
        $rows[0].REVPAR | Should -BeNullOrEmpty
    }

    It 'guards missing denominator: ADR is $null when RoomNights is absent' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v)
            @(New-RawRow -Overrides @{ revenue = 600; roomNights = $null; adr = $null })
        }
        $rows = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].ADR | Should -BeNullOrEmpty
    }
}

Describe 'Get-ReservationStats — multi-chunk accumulation' {

    It 'accumulates rows from every chunk into a single flat array' {
        # 20-day range -> 3 default chunks. Return 2 rows per chunk = 6 rows total.
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v)
            @(
                (New-RawRow -Overrides @{ resvNameId = "R$i-A" }),
                (New-RawRow -Overrides @{ resvNameId = "R$i-B" })
            )
        }
        $rows = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-01-01' -EndDate '2026-01-20' `
            -SubjectAreaInvoker $invoker

        $script:Calls.Count | Should -Be 3
        $rows.Count | Should -Be 6
        # The result is one flat array of PSCustomObjects (not nested).
        ($rows | ForEach-Object { $_.RESV_NAME_ID }) | Should -Contain 'R0-A'
        ($rows | ForEach-Object { $_.RESV_NAME_ID }) | Should -Contain 'R2-B'
    }

    It 'returns an empty array (not $null) when no rows are found' {
        $invoker = New-RecordingInvoker -RowFactory { param($i, $v) @() }
        $rows = Get-ReservationStats -Hotel $script:Hotel `
            -StartDate '2026-01-01' -EndDate '2026-01-01' `
            -SubjectAreaInvoker $invoker

        $rows.Count | Should -Be 0
    }
}

Describe 'Get-ReservationStats — per-chunk logging' {

    It 'logs a row-count + duration (ms) line per date chunk per hotel' {
        # Capture Write-Log calls via a GLOBAL Write-Log function. The module's internal
        # Write-ResLog resolves the logger with Get-Command 'Write-Log'; since the module
        # defines no Write-Log of its own, this global shim is what it finds.
        $global:ResTestLogLines = [System.Collections.Generic.List[string]]::new()
        function global:Write-Log {
            param(
                [string] $Level, [string] $Module, [string] $Message,
                [string] $HotelCode, $BatchId
            )
            $global:ResTestLogLines.Add(("{0}|{1}|{2}|{3}" -f $Level, $Module, $HotelCode, $Message))
        }

        try {
            $invoker = New-RecordingInvoker -RowFactory {
                param($i, $v) @((New-RawRow), (New-RawRow))
            }
            $null = Get-ReservationStats -Hotel $script:Hotel `
                -StartDate '2026-01-01' -EndDate '2026-01-20' `
                -SubjectAreaInvoker $invoker
        }
        finally {
            Remove-Item Function:\global:Write-Log -ErrorAction SilentlyContinue
        }

        $chunkLogLines = $global:ResTestLogLines | Where-Object { $_ -match 'fetched \d+ row\(s\) in \d+ms' }
        # 3 chunks -> 3 per-chunk row-count/duration lines.
        @($chunkLogLines).Count | Should -Be 3
        # Each carries the hotel code and INFO level.
        ($chunkLogLines | Where-Object { $_ -match 'TEST01' }).Count | Should -Be 3
        ($chunkLogLines | Where-Object { $_ -match '^INFO\|' }).Count | Should -Be 3
        # Row count is reported (2 rows per chunk).
        ($chunkLogLines | Where-Object { $_ -match 'fetched 2 row' }).Count | Should -Be 3
    }
}
