# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
    Pester tests for Modules\Queries\FinancialTransactions.psm1 (Task 9 — FIN query module).

    Covers:
      - Date chunking into the correct number of chunks + ISO YYYY-MM-DD request filters.
      - Correct operation / primary view passed to the API layer.
      - Response -> PSCustomObject mapping of the key ra.FIN fields
        (RESV_NAME_ID, TRX_CODE, FT_SUBTYPE, POSTING_DATE, TRX_NO, TRAN_ACTION_ID, ...).
      - PostingDateLocal (TRX_DATE) vs PostingDateUtc (TRX_DATE_UTC) conversion via a
        known timeZoneId offset.
      - Output date formatting: date-only -> YYYYMMDD; datetime -> YYYYMMDD HH:mm:ss.
      - IS_LATE_POSTING computation (late / same-day / early) and the WARN-with-count
        emitted only when late postings exist.
      - Multi-chunk accumulation into a single flat array.

    No live API is contacted: the module's -SubjectAreaInvoker seam returns canned rows
    and records the arguments (Chunks/Variables) it was called with, so the request-filter
    and per-chunk behaviour can be asserted with zero network access.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\Modules\DateHelper.psm1" -Force
    Import-Module "$PSScriptRoot\..\Modules\Queries\FinancialTransactions.psm1" -Force

    # CEST is UTC+2 in July, so a local 10:00 posting -> 08:00 UTC.
    $script:Hotel = @{
        HotelCode  = 'TEST01'
        ChainCode  = 'CHN1'
        TimeZoneId = 'Central European Standard Time'
    }

    # Builds a -SubjectAreaInvoker seam that records every call's args and returns the
    # rows produced by $RowFactory for that chunk (keyed by chunk index). A LOCAL
    # $callList is captured via GetNewClosure so it survives Pester scope handling;
    # $script:Calls points at the same instance so assertions can read it.
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
    function New-RawFinRow {
        param([hashtable] $Overrides = @{})
        $row = @{
            resort             = 'TEST01'
            businessDate       = '2026-07-30'
            resvNameId         = 'RID-001'
            originalResvNameId = 'RID-000'
            rateCode           = 'BAR'
            sourceCode         = 'WEB'
            marketCode         = 'LEIS'
            ftSubtype          = 'C'
            tcGroup            = 'ROOM'
            tcSubgroup         = 'ROOMREV'
            trxCode            = '1000'
            trxNo              = 'TRX-555'
            tranActionId       = 'TA-777'
            trxNoAddedBy       = 'TRX-554'
            trxDate            = '2026-07-30 10:00:00'
            netAmount          = 100.00
            grossAmount        = 119.00
            trxAmount          = 119.00
            postedAmount       = 119.00
            revenueAmt         = 100.00
            quantity           = 1
            pricePerUnit       = 119.00
            exchangeRate       = 1
            currencyCode       = 'EUR'
            indRevenueGp       = 'Y'
            passerByName       = $null
        }
        foreach ($k in $Overrides.Keys) { $row[$k] = $Overrides[$k] }
        return [PSCustomObject]$row
    }
}

Describe 'Get-FinancialTransactions — date chunking and request filters' {

    It 'splits a 20-day range into 3 chunks with default 7-day chunking' {
        $invoker = New-RecordingInvoker
        $null = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-01-01' -EndDate '2026-01-20' `
            -SubjectAreaInvoker $invoker

        $script:Calls.Count | Should -Be 3
    }

    It 'respects an explicit -ChunkDays value' {
        $invoker = New-RecordingInvoker
        $null = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-01-01' -EndDate '2026-01-10' -ChunkDays 5 `
            -SubjectAreaInvoker $invoker

        $script:Calls.Count | Should -Be 2
    }

    It 'reads transactionalChunkDays from the Config when -ChunkDays is omitted' {
        $invoker = New-RecordingInvoker
        $cfg = @{ extraction = @{ transactionalChunkDays = 10 } }
        $null = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-01-01' -EndDate '2026-01-20' -Config $cfg `
            -SubjectAreaInvoker $invoker

        # 20 days / 10 = 2 chunks.
        $script:Calls.Count | Should -Be 2
    }

    It 'builds ISO YYYY-MM-DD request filters (not the YYYYMMDD output format)' {
        $invoker = New-RecordingInvoker
        $null = Get-FinancialTransactions -Hotel $script:Hotel `
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
        $null = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-07-01' -EndDate '2026-07-01' `
            -SubjectAreaInvoker $invoker

        $script:Calls[0].Operation | Should -Be 'financialTransactionDetails'
        $script:Calls[0].PrimaryView | Should -Be 'financialTransactionDetails'
    }
}

Describe 'Get-FinancialTransactions — response mapping' {

    It 'maps the key ra.FIN fields from the raw API row' {
        $invoker = New-RecordingInvoker -RowFactory { param($i, $v) @(New-RawFinRow) }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows.Count | Should -Be 1
        $r = $rows[0]
        $r.RESORT          | Should -Be 'TEST01'
        $r.CHAIN_CODE      | Should -Be 'CHN1'
        $r.RESV_NAME_ID    | Should -Be 'RID-001'
        $r.ORIGINAL_RESV   | Should -Be 'RID-000'
        $r.TRX_NO          | Should -Be 'TRX-555'
        $r.TRAN_ACTION_ID  | Should -Be 'TA-777'
        $r.TRX_NO_ADDED_BY | Should -Be 'TRX-554'
        $r.TRX_CODE        | Should -Be '1000'
        $r.TC_GROUP        | Should -Be 'ROOM'
        $r.FT_SUBTYPE      | Should -Be 'C'
        $r.MARKET_CODE     | Should -Be 'LEIS'
        $r.SOURCE_CODE     | Should -Be 'WEB'
        $r.CURRENCY        | Should -Be 'EUR'
        $r.IND_REVENUE_GP  | Should -Be 'Y'
        $r.NET_AMOUNT      | Should -Be ([decimal]100.00)
        $r.GROSS_AMOUNT    | Should -Be ([decimal]119.00)
    }

    It 'projects POSTING_DATE (date-only) from the posting datetime' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v) @(New-RawFinRow -Overrides @{ trxDate = '2026-07-30 10:00:00' })
        }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].POSTING_DATE | Should -Be '20260730'
    }

    It 'emits $null for missing / empty source values without crashing' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v)
            @(New-RawFinRow -Overrides @{ sourceCode = ''; marketCode = '   '; passerByName = $null })
        }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].SOURCE_CODE    | Should -BeNullOrEmpty
        $rows[0].MARKET_CODE    | Should -BeNullOrEmpty
        $rows[0].PASSER_BY_NAME | Should -BeNullOrEmpty
        # A row with no source data still maps its identity fields.
        $rows[0].TRX_NO | Should -Be 'TRX-555'
    }

    It 'backfills a blank RESORT from the hotel code (fallback)' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v) @(New-RawFinRow -Overrides @{ resort = '' })
        }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].RESORT | Should -Be 'TEST01'
    }

    It 'sets COSTCENTER / ACCOUNT to $null (not in this SA)' {
        $invoker = New-RecordingInvoker -RowFactory { param($i, $v) @(New-RawFinRow) }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].COSTCENTER | Should -BeNullOrEmpty
        $rows[0].ACCOUNT    | Should -BeNullOrEmpty
    }
}

Describe 'Get-FinancialTransactions — PostingDateLocal vs PostingDateUtc' {

    It 'converts TRX_DATE (hotel local) to TRX_DATE_UTC via the timeZoneId offset' {
        # CEST (UTC+2 in July): local 10:00 -> 08:00 UTC.
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v) @(New-RawFinRow -Overrides @{ trxDate = '2026-07-30 10:00:00' })
        }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].TRX_DATE     | Should -Be '20260730 10:00:00'
        $rows[0].TRX_DATE_UTC | Should -Be '20260730 08:00:00'
    }

    It 'falls back to the local value for TRX_DATE_UTC when no timeZoneId is configured' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v) @(New-RawFinRow -Overrides @{ trxDate = '2026-07-30 10:00:00' })
        }
        $rows = Get-FinancialTransactions -Hotel @{ HotelCode = 'TEST01' } `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].TRX_DATE     | Should -Be '20260730 10:00:00'
        $rows[0].TRX_DATE_UTC | Should -Be '20260730 10:00:00'
    }
}

Describe 'Get-FinancialTransactions — output date formatting' {

    It 'formats BUSINESS_DATE / POSTING_DATE as YYYYMMDD' {
        $invoker = New-RecordingInvoker -RowFactory { param($i, $v) @(New-RawFinRow) }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].BUSINESS_DATE | Should -Be '20260730'
        $rows[0].POSTING_DATE  | Should -Be '20260730'
    }

    It 'formats the datetime TRX_DATE / TRX_DATE_UTC as YYYYMMDD HH:mm:ss' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v) @(New-RawFinRow -Overrides @{ trxDate = '2026-05-07 12:33:21' })
        }
        # No timeZoneId so the wall-clock value is preserved for both fields.
        $rows = Get-FinancialTransactions -Hotel @{ HotelCode = 'TEST01' } `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].TRX_DATE     | Should -Be '20260507 12:33:21'
        $rows[0].TRX_DATE_UTC | Should -Be '20260507 12:33:21'
    }

    It 'renders empty date fields as an empty string' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v) @(New-RawFinRow -Overrides @{ trxDate = $null })
        }
        $rows = Get-FinancialTransactions -Hotel @{ HotelCode = 'TEST01' } `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].TRX_DATE     | Should -Be ''
        $rows[0].TRX_DATE_UTC | Should -Be ''
        $rows[0].POSTING_DATE | Should -Be ''
    }
}

Describe 'Get-FinancialTransactions — IS_LATE_POSTING computation' {

    It 'flags a late posting (TRX_DATE > BUSINESS_DATE) as 1' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v)
            @(New-RawFinRow -Overrides @{ businessDate = '2026-07-30'; trxDate = '2026-07-31 09:00:00' })
        }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-31' `
            -SubjectAreaInvoker $invoker

        $rows[0].IS_LATE_POSTING | Should -Be 1
    }

    It 'flags a same-day posting as 0' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v)
            @(New-RawFinRow -Overrides @{ businessDate = '2026-07-30'; trxDate = '2026-07-30 23:59:00' })
        }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-07-30' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].IS_LATE_POSTING | Should -Be 0
    }

    It 'flags an early posting (before the business date) as 0' {
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v)
            @(New-RawFinRow -Overrides @{ businessDate = '2026-07-30'; trxDate = '2026-07-29 09:00:00' })
        }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-07-29' -EndDate '2026-07-30' `
            -SubjectAreaInvoker $invoker

        $rows[0].IS_LATE_POSTING | Should -Be 0
    }

    It 'emits a single WARN carrying the late-posting count when late postings exist' {
        $global:FinTestLogLines = [System.Collections.Generic.List[string]]::new()
        function global:Write-Log {
            param(
                [string] $Level, [string] $Module, [string] $Message,
                [string] $HotelCode, $BatchId
            )
            $global:FinTestLogLines.Add(("{0}|{1}|{2}|{3}" -f $Level, $Module, $HotelCode, $Message))
        }

        try {
            $invoker = New-RecordingInvoker -RowFactory {
                param($i, $v)
                @(
                    (New-RawFinRow -Overrides @{ businessDate = '2026-07-30'; trxDate = '2026-07-31 09:00:00'; trxNo = 'L1' }),
                    (New-RawFinRow -Overrides @{ businessDate = '2026-07-30'; trxDate = '2026-08-01 09:00:00'; trxNo = 'L2' }),
                    (New-RawFinRow -Overrides @{ businessDate = '2026-07-30'; trxDate = '2026-07-30 09:00:00'; trxNo = 'OK' })
                )
            }
            $null = Get-FinancialTransactions -Hotel $script:Hotel `
                -StartDate '2026-07-30' -EndDate '2026-07-30' `
                -SubjectAreaInvoker $invoker
        }
        finally {
            Remove-Item Function:\global:Write-Log -ErrorAction SilentlyContinue
        }

        $warnLines = $global:FinTestLogLines | Where-Object { $_ -match '^WARN\|' -and $_ -match 'late posting' }
        @($warnLines).Count | Should -Be 1
        # The count (2 late of 3) is present in the WARN message.
        @($warnLines)[0] | Should -Match '\b2 late posting'
        @($warnLines)[0] | Should -Match 'TEST01'
    }

    It 'emits NO late-posting WARN when there are no late postings' {
        $global:FinTestLogLines = [System.Collections.Generic.List[string]]::new()
        function global:Write-Log {
            param(
                [string] $Level, [string] $Module, [string] $Message,
                [string] $HotelCode, $BatchId
            )
            $global:FinTestLogLines.Add(("{0}|{1}|{2}|{3}" -f $Level, $Module, $HotelCode, $Message))
        }

        try {
            $invoker = New-RecordingInvoker -RowFactory {
                param($i, $v)
                @(New-RawFinRow -Overrides @{ businessDate = '2026-07-30'; trxDate = '2026-07-30 09:00:00' })
            }
            $null = Get-FinancialTransactions -Hotel $script:Hotel `
                -StartDate '2026-07-30' -EndDate '2026-07-30' `
                -SubjectAreaInvoker $invoker
        }
        finally {
            Remove-Item Function:\global:Write-Log -ErrorAction SilentlyContinue
        }

        $warnLines = $global:FinTestLogLines | Where-Object { $_ -match '^WARN\|' -and $_ -match 'late posting' }
        @($warnLines).Count | Should -Be 0
    }
}

Describe 'Get-FinancialTransactions — multi-chunk accumulation' {

    It 'accumulates rows from every chunk into a single flat array' {
        # 20-day range -> 3 default chunks. Return 2 rows per chunk = 6 rows total.
        $invoker = New-RecordingInvoker -RowFactory {
            param($i, $v)
            @(
                (New-RawFinRow -Overrides @{ trxNo = "T$i-A" }),
                (New-RawFinRow -Overrides @{ trxNo = "T$i-B" })
            )
        }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-01-01' -EndDate '2026-01-20' `
            -SubjectAreaInvoker $invoker

        $script:Calls.Count | Should -Be 3
        $rows.Count | Should -Be 6
        ($rows | ForEach-Object { $_.TRX_NO }) | Should -Contain 'T0-A'
        ($rows | ForEach-Object { $_.TRX_NO }) | Should -Contain 'T2-B'
    }

    It 'returns an empty array (not $null) when no rows are found' {
        $invoker = New-RecordingInvoker -RowFactory { param($i, $v) @() }
        $rows = Get-FinancialTransactions -Hotel $script:Hotel `
            -StartDate '2026-01-01' -EndDate '2026-01-01' `
            -SubjectAreaInvoker $invoker

        $rows.Count | Should -Be 0
    }
}

Describe 'Get-FinancialTransactions — per-chunk logging' {

    It 'logs a row-count + duration (ms) line per date chunk per hotel' {
        $global:FinTestLogLines = [System.Collections.Generic.List[string]]::new()
        function global:Write-Log {
            param(
                [string] $Level, [string] $Module, [string] $Message,
                [string] $HotelCode, $BatchId
            )
            $global:FinTestLogLines.Add(("{0}|{1}|{2}|{3}" -f $Level, $Module, $HotelCode, $Message))
        }

        try {
            $invoker = New-RecordingInvoker -RowFactory {
                param($i, $v) @((New-RawFinRow), (New-RawFinRow))
            }
            $null = Get-FinancialTransactions -Hotel $script:Hotel `
                -StartDate '2026-01-01' -EndDate '2026-01-20' `
                -SubjectAreaInvoker $invoker
        }
        finally {
            Remove-Item Function:\global:Write-Log -ErrorAction SilentlyContinue
        }

        $chunkLogLines = $global:FinTestLogLines | Where-Object { $_ -match 'fetched \d+ row\(s\) in \d+ms' }
        @($chunkLogLines).Count | Should -Be 3
        ($chunkLogLines | Where-Object { $_ -match 'TEST01' }).Count | Should -Be 3
        ($chunkLogLines | Where-Object { $_ -match '^INFO\|' }).Count | Should -Be 3
    }
}
