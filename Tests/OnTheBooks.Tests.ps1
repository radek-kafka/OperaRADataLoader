# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

BeforeAll {
    Import-Module "$PSScriptRoot\..\Modules\DateHelper.psm1" -Force
    Import-Module "$PSScriptRoot\..\Modules\Queries\OnTheBooks.psm1" -Force

    $script:Hotel = @{
        HotelCode  = 'HOTEL1'
        ChainCode  = 'CHN'
        TimeZoneId = 'Central European Standard Time'
        otbFutureDays = 365
    }
    $script:Snapshot = [datetime]::new(2026, 7, 30, 0, 0, 0, [System.DateTimeKind]::Unspecified)

    # A minimal raw forecast-summary row as the API would return it.
    $script:MakeRawRow = {
        param([hashtable] $Overrides = @{})
        $row = @{
            resort            = 'HOTEL1'
            stayDate          = '2026-08-15'
            marketCode        = 'CORP'
            sourceCode        = 'WEB'
            channel           = 'GDS'
            rateCode          = 'BAR'
            rateCategory      = 'RACK'
            roomCategoryLabel = 'KING'
            resvType          = 'R'
            resvStatus        = 'DEFINITE'
            truncBeginDate    = '2026-08-15'
            truncEndDate      = '2026-08-16'
            noRooms           = 10
            roomRevenue       = 2000
            totalRevenue      = 2500
        }
        foreach ($k in $Overrides.Keys) { $row[$k] = $Overrides[$k] }
        return $row
    }
}

Describe 'Get-OnTheBooks — snapshot horizon + ISO request filters' {

    It 'derives ConsideredDateStart/End from the snapshot horizon and passes ISO filters' {
        $captured = $null
        $seam = {
            param($a)
            $script:capturedArgs = $a
            @()
        }
        # Use a script-scoped capture the seam can write to.
        $script:capturedArgs = $null

        $null = Get-OnTheBooks -Hotel $script:Hotel -SnapshotDate $script:Snapshot `
            -FutureDays 30 -SubjectAreaInvoker $seam

        $script:capturedArgs | Should -Not -BeNullOrEmpty
        $script:capturedArgs.Operation | Should -Be 'statisticsForecastSummary'
        $script:capturedArgs.PrimaryView | Should -Be 'forecastSummaryDetails'

        $vars = $script:capturedArgs.Chunks[0].Variables
        $vars.input.resort._in | Should -Contain 'HOTEL1'
        # Horizon: start = snapshot (2026-07-30), end = snapshot + 30 days (2026-08-29).
        $vars.input.consideredDate._gte | Should -Be '2026-07-30'
        $vars.input.consideredDate._lte | Should -Be '2026-08-29'
    }
}

Describe 'Get-OnTheBooks — response -> PSCustomObject mapping' {

    It 'maps the listed key fields to the ra.OTB column contract' {
        $raw = & $script:MakeRawRow
        $seam = { param($a) @($raw) }.GetNewClosure()

        $rows = @(Get-OnTheBooks -Hotel $script:Hotel -SnapshotDate $script:Snapshot -SubjectAreaInvoker $seam)
        $rows.Count | Should -Be 1
        $r = $rows[0]

        $r.RESORT | Should -Be 'HOTEL1'
        $r.MARKET_CODE | Should -Be 'CORP'
        $r.ROOM_CATEGORY_LABEL | Should -Be 'KING'
        $r.SOURCE_CODE | Should -Be 'WEB'
        $r.CHANNEL | Should -Be 'GDS'
        $r.NO_ROOMS | Should -Be 10
        # RevenueOnBooks falls back to TOTAL_REVENUE.
        $r.REVENUE_ON_BOOKS | Should -Be 2500
    }

    it 'backfills a blank RESORT from the hotel code (fallback, never crash)' {
        $raw = & $script:MakeRawRow @{ resort = '' }
        $seam = { param($a) @($raw) }.GetNewClosure()

        $rows = @(Get-OnTheBooks -Hotel $script:Hotel -SnapshotDate $script:Snapshot -SubjectAreaInvoker $seam)
        $rows[0].RESORT | Should -Be 'HOTEL1'
    }
}

Describe 'Get-OnTheBooks — SNAPSHOT_DATE from -SnapshotDate, CONSIDERED_DATE from response' {

    It 'stamps SNAPSHOT_DATE from -SnapshotDate and CONSIDERED_DATE from the row stay date' {
        $raw = & $script:MakeRawRow @{ stayDate = '2026-08-15' }
        $seam = { param($a) @($raw) }.GetNewClosure()

        $rows = @(Get-OnTheBooks -Hotel $script:Hotel -SnapshotDate $script:Snapshot -SubjectAreaInvoker $seam)
        $r = $rows[0]
        $r.SNAPSHOT_DATE | Should -Be '20260730'    # from -SnapshotDate
        $r.CONSIDERED_DATE | Should -Be '20260815'  # from response stayDate
    }
}

Describe 'Get-OnTheBooks — YYYYMMDD output formatting' {

    It 'formats date-only fields as YYYYMMDD' {
        $raw = & $script:MakeRawRow @{ stayDate = '2026-08-15'; truncBeginDate = '2026-08-15'; truncEndDate = '2026-08-16' }
        $seam = { param($a) @($raw) }.GetNewClosure()

        $rows = @(Get-OnTheBooks -Hotel $script:Hotel -SnapshotDate $script:Snapshot -SubjectAreaInvoker $seam)
        $r = $rows[0]
        $r.SNAPSHOT_DATE | Should -Be '20260730'
        $r.CONSIDERED_DATE | Should -Be '20260815'
        $r.TRUNC_BEGIN_DATE | Should -Be '20260815'
        $r.TRUNC_END_DATE | Should -Be '20260816'
    }
}

Describe 'Get-OnTheBooks — ADR_ON_BOOKS derivation' {

    It 'computes ADR_ON_BOOKS = ROOM_REVENUE / NO_ROOMS when the API omits it' {
        $raw = & $script:MakeRawRow @{ roomRevenue = 2000; noRooms = 10 }  # no adrOnBooks
        $seam = { param($a) @($raw) }.GetNewClosure()

        $rows = @(Get-OnTheBooks -Hotel $script:Hotel -SnapshotDate $script:Snapshot -SubjectAreaInvoker $seam)
        $rows[0].ADR_ON_BOOKS | Should -Be 200
    }

    It 'guards divide-by-zero: NO_ROOMS = 0 yields $null ADR_ON_BOOKS' {
        $raw = & $script:MakeRawRow @{ roomRevenue = 2000; noRooms = 0 }
        $seam = { param($a) @($raw) }.GetNewClosure()

        $rows = @(Get-OnTheBooks -Hotel $script:Hotel -SnapshotDate $script:Snapshot -SubjectAreaInvoker $seam)
        $rows[0].ADR_ON_BOOKS | Should -BeNullOrEmpty
    }

    It 'does not overwrite an API-supplied ADR_ON_BOOKS' {
        $raw = & $script:MakeRawRow @{ roomRevenue = 2000; noRooms = 10; adrOnBooks = 175.50 }
        $seam = { param($a) @($raw) }.GetNewClosure()

        $rows = @(Get-OnTheBooks -Hotel $script:Hotel -SnapshotDate $script:Snapshot -SubjectAreaInvoker $seam)
        $rows[0].ADR_ON_BOOKS | Should -Be 175.50
    }
}

Describe 'Get-OnTheBooks — TENTATIVE/DEFINITE split' {

    It 'assigns NO_ROOMS to DEFINITE_ROOMS for a definite status' {
        $raw = & $script:MakeRawRow @{ resvStatus = 'DEFINITE'; noRooms = 10 }
        $seam = { param($a) @($raw) }.GetNewClosure()
        $rows = @(Get-OnTheBooks -Hotel $script:Hotel -SnapshotDate $script:Snapshot -SubjectAreaInvoker $seam)
        $rows[0].DEFINITE_ROOMS | Should -Be 10
        $rows[0].TENTATIVE_ROOMS | Should -Be 0
    }

    It 'assigns NO_ROOMS to TENTATIVE_ROOMS for a tentative status' {
        $raw = & $script:MakeRawRow @{ resvStatus = 'DEDUCED'; noRooms = 7 }
        $seam = { param($a) @($raw) }.GetNewClosure()
        $rows = @(Get-OnTheBooks -Hotel $script:Hotel -SnapshotDate $script:Snapshot -SubjectAreaInvoker $seam)
        $rows[0].TENTATIVE_ROOMS | Should -Be 7
        $rows[0].DEFINITE_ROOMS | Should -Be 0
    }
}

Describe 'Get-OnTheBooks — logging' {

    It 'logs one INFO line with snapshot date, considered range, and row count' {
        # Shim Write-Log in the session scope; the module resolves it via Get-Command.
        $script:LogLines = [System.Collections.Generic.List[string]]::new()
        function global:Write-Log {
            param($Level, $Module, $Message, $HotelCode, $BatchId)
            $script:LogLines.Add(("{0}|{1}|{2}|{3}" -f $Level, $Module, $HotelCode, $Message))
        }

        try {
            $raw = & $script:MakeRawRow
            $seam = { param($a) @($raw, $raw) }.GetNewClosure()  # 2 rows
            $null = Get-OnTheBooks -Hotel $script:Hotel -SnapshotDate $script:Snapshot -FutureDays 30 -SubjectAreaInvoker $seam

            # Wrap the single-match filter with @(...) before indexing [0].
            $complete = @($script:LogLines | Where-Object { $_ -match 'OTB snapshot complete' })
            $complete.Count | Should -BeGreaterThan 0
            $line = $complete[0]
            $line | Should -Match 'OnTheBooks'
            $line | Should -Match 'snapshot=2026-07-30'
            $line | Should -Match 'consideredRange=2026-07-30\.\.2026-08-29'
            $line | Should -Match 'rows=2'
        }
        finally {
            Remove-Item -Path function:\Write-Log -ErrorAction SilentlyContinue
        }
    }
}
