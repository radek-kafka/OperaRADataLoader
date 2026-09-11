# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Pester tests for Modules\Queries\BlockReservations.psm1 (Task 11).

.DESCRIPTION
    Exercises Get-BlockReservations end-to-end via the -SubjectAreaInvoker seam (no
    network). Covers:
      - Snapshot-horizon range + ISO 'YYYY-MM-DD' request filters (resort _in,
        consideredDate _gte/_lte) using HorizonType 'Block' / blockFutureDays.
      - Response -> PSCustomObject mapping of the key ra.BLK fields.
      - SNAPSHOT_DATE stamped from -SnapshotDate; CONSIDERED_DATE from the response.
      - ROOMS_REMAINING computation (contracted - pickedup) + don't-overwrite an
        API-supplied value.
      - IS_PAST_CUTOFF computation (past / on / after cutoff) + single WARN carrying the
        count.
      - YYYYMMDD formatting of date-only output fields.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\Modules\DateHelper.psm1" -Force
    Import-Module "$PSScriptRoot\..\Modules\Queries\BlockReservations.psm1" -Force

    $script:Hotel = @{
        HotelCode       = 'TEST01'
        ChainCode       = 'CHAIN1'
        blockFutureDays = 180
    }

    # A capturing seam: records the args it was handed and returns canned raw rows.
    function New-CapturingInvoker {
        param([object[]] $Rows)
        $captured = [ordered]@{ Args = $null }
        # The real Invoke-RASubjectArea returns a flat [array] of raw rows; the module
        # wraps the seam result in @(...). Return the rows via the pipeline (Write-Output)
        # so each row is emitted individually and @(...) collects them back into a flat
        # array (a unary-comma wrapper here would nest the rows one level too deep).
        $sb = {
            param($saArgs)
            $captured.Args = $saArgs
            Write-Output -InputObject ([object[]]$Rows) -NoEnumerate:$false
        }.GetNewClosure()
        return [PSCustomObject]@{ Invoker = $sb; Captured = $captured }
    }
}

Describe 'Get-BlockReservations' {

    Context 'Snapshot horizon + ISO request filters' {

        It 'builds a consideredDate range over the block future horizon with ISO YYYY-MM-DD filters' {
            $cap = New-CapturingInvoker -Rows @()
            $null = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -FutureDays 180 -SubjectAreaInvoker $cap.Invoker

            $saArgs = $cap.Captured.Args
            $saArgs.Operation   | Should -Be 'bookingsBlock'
            $saArgs.PrimaryView | Should -Be 'blockDetails'

            $vars = @($saArgs.Chunks)[0].Variables
            $vars.input.resort._in         | Should -Be @('TEST01')
            $vars.input.consideredDate._gte | Should -Be '2026-07-30'
            $vars.input.consideredDate._lte | Should -Be '2027-01-26'   # 2026-07-30 + 180 days
        }

        It 'falls back to hotel blockFutureDays when -FutureDays is not supplied' {
            $cap = New-CapturingInvoker -Rows @()
            $null = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -SubjectAreaInvoker $cap.Invoker

            $vars = @($cap.Captured.Args.Chunks)[0].Variables
            $vars.input.consideredDate._gte | Should -Be '2026-07-30'
            $vars.input.consideredDate._lte | Should -Be '2027-01-26'   # +180 from hotel config
        }
    }

    Context 'Response -> ra.BLK mapping' {

        It 'maps the key block fields to OPERA-native columns' {
            $raw = [PSCustomObject]@{
                resort            = 'TEST01'
                blockIdDate       = '2026-08-15'
                blockCode         = 'GRP100'
                blockName         = 'Summer Conference'
                roomCategoryLabel = 'KING'
                marketCode        = 'GRP'
                sourceCode        = 'WEB'
                rateCode          = 'CONF'
                rateCategory      = 'GROUP'
                cutoffDate        = '2026-08-01'
                blockedRooms      = 50
                pickedUpRooms     = 20
                roomRevenue       = 12500.50
                totalRevenue      = 15000.75
            }
            $cap = New-CapturingInvoker -Rows @($raw)
            $rows = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -FutureDays 180 -SubjectAreaInvoker $cap.Invoker

            $rows.Count | Should -Be 1
            $r = $rows[0]
            $r.RESORT              | Should -Be 'TEST01'
            $r.CHAIN_CODE          | Should -Be 'CHAIN1'
            $r.BLOCK_CODE          | Should -Be 'GRP100'
            $r.BLOCK_NAME          | Should -Be 'Summer Conference'
            $r.ROOM_CATEGORY_LABEL | Should -Be 'KING'
            $r.MARKET_CODE         | Should -Be 'GRP'
            $r.SOURCE_CODE         | Should -Be 'WEB'
            $r.RATE_CODE           | Should -Be 'CONF'
            $r.RATE_CATEGORY       | Should -Be 'GROUP'
            $r.ROOMS_CONTRACTED    | Should -Be 50
            $r.ROOMS_PICKEDUP      | Should -Be 20
            $r.ROOM_REVENUE        | Should -Be ([decimal]12500.50)
            $r.TOTAL_REVENUE       | Should -Be ([decimal]15000.75)
        }

        It 'stamps SNAPSHOT_DATE from -SnapshotDate and CONSIDERED_DATE from the response, formatted YYYYMMDD' {
            $raw = [PSCustomObject]@{
                resort = 'TEST01'; blockCode = 'B1'; blockIdDate = '2026-08-15'; cutoffDate = '2026-08-10'
                blockedRooms = 10; pickedUpRooms = 3
            }
            $cap = New-CapturingInvoker -Rows @($raw)
            $rows = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -FutureDays 180 -SubjectAreaInvoker $cap.Invoker

            $rows[0].SNAPSHOT_DATE   | Should -Be '20260730'   # from -SnapshotDate
            $rows[0].CONSIDERED_DATE | Should -Be '20260815'   # from response blockIdDate
            $rows[0].CUTOFF_DATE     | Should -Be '20260810'
        }

        It 'backfills a blank RESORT from the hotel code (fallback)' {
            $raw = [PSCustomObject]@{ resort = ''; blockCode = 'B1'; blockIdDate = '2026-08-15'; blockedRooms = 5; pickedUpRooms = 1 }
            $cap = New-CapturingInvoker -Rows @($raw)
            $rows = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -FutureDays 180 -SubjectAreaInvoker $cap.Invoker
            $rows[0].RESORT | Should -Be 'TEST01'
        }
    }

    Context 'ROOMS_REMAINING computation' {

        It 'computes ROOMS_REMAINING = ROOMS_CONTRACTED - ROOMS_PICKEDUP when the API omits it' {
            $raw = [PSCustomObject]@{ resort = 'TEST01'; blockCode = 'B1'; blockIdDate = '2026-08-15'; blockedRooms = 50; pickedUpRooms = 20 }
            $cap = New-CapturingInvoker -Rows @($raw)
            $rows = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -FutureDays 180 -SubjectAreaInvoker $cap.Invoker
            $rows[0].ROOMS_REMAINING | Should -Be 30
        }

        It 'does not overwrite an API-supplied ROOMS_REMAINING value' {
            $raw = [PSCustomObject]@{ resort = 'TEST01'; blockCode = 'B1'; blockIdDate = '2026-08-15'; blockedRooms = 50; pickedUpRooms = 20; roomsRemaining = 99 }
            $cap = New-CapturingInvoker -Rows @($raw)
            $rows = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -FutureDays 180 -SubjectAreaInvoker $cap.Invoker
            $rows[0].ROOMS_REMAINING | Should -Be 99
        }

        It 'leaves ROOMS_REMAINING null when an operand is missing (null-guard)' {
            $raw = [PSCustomObject]@{ resort = 'TEST01'; blockCode = 'B1'; blockIdDate = '2026-08-15'; blockedRooms = 50 }
            $cap = New-CapturingInvoker -Rows @($raw)
            $rows = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -FutureDays 180 -SubjectAreaInvoker $cap.Invoker
            $rows[0].ROOMS_REMAINING | Should -BeNullOrEmpty
        }
    }

    Context 'IS_PAST_CUTOFF computation' {

        It 'sets IS_PAST_CUTOFF = 1 when CUTOFF_DATE is before SNAPSHOT_DATE' {
            $raw = [PSCustomObject]@{ resort = 'TEST01'; blockCode = 'B1'; blockIdDate = '2026-08-15'; cutoffDate = '2026-07-01'; blockedRooms = 10; pickedUpRooms = 2 }
            $cap = New-CapturingInvoker -Rows @($raw)
            $rows = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -FutureDays 180 -SubjectAreaInvoker $cap.Invoker
            $rows[0].IS_PAST_CUTOFF | Should -Be 1
        }

        It 'sets IS_PAST_CUTOFF = 0 when CUTOFF_DATE equals SNAPSHOT_DATE (on cutoff)' {
            $raw = [PSCustomObject]@{ resort = 'TEST01'; blockCode = 'B1'; blockIdDate = '2026-08-15'; cutoffDate = '2026-07-30'; blockedRooms = 10; pickedUpRooms = 2 }
            $cap = New-CapturingInvoker -Rows @($raw)
            $rows = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -FutureDays 180 -SubjectAreaInvoker $cap.Invoker
            $rows[0].IS_PAST_CUTOFF | Should -Be 0
        }

        It 'sets IS_PAST_CUTOFF = 0 when CUTOFF_DATE is after SNAPSHOT_DATE' {
            $raw = [PSCustomObject]@{ resort = 'TEST01'; blockCode = 'B1'; blockIdDate = '2026-08-15'; cutoffDate = '2026-08-10'; blockedRooms = 10; pickedUpRooms = 2 }
            $cap = New-CapturingInvoker -Rows @($raw)
            $rows = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -FutureDays 180 -SubjectAreaInvoker $cap.Invoker
            $rows[0].IS_PAST_CUTOFF | Should -Be 0
        }

        It 'emits a single WARN carrying the past-cutoff count when any rows are past cutoff' {
            $rawRows = @(
                [PSCustomObject]@{ resort = 'TEST01'; blockCode = 'B1'; blockIdDate = '2026-08-15'; cutoffDate = '2026-07-01'; blockedRooms = 10; pickedUpRooms = 2 }
                [PSCustomObject]@{ resort = 'TEST01'; blockCode = 'B2'; blockIdDate = '2026-08-16'; cutoffDate = '2026-07-02'; blockedRooms = 8;  pickedUpRooms = 1 }
                [PSCustomObject]@{ resort = 'TEST01'; blockCode = 'B3'; blockIdDate = '2026-08-17'; cutoffDate = '2026-08-20'; blockedRooms = 5;  pickedUpRooms = 0 }
            )
            $cap = New-CapturingInvoker -Rows $rawRows

            $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("_blk_warn_{0}.txt" -f ([guid]::NewGuid())))
            try {
                Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                    -FutureDays 180 -SubjectAreaInvoker $cap.Invoker -Verbose 4>$tmp | Out-Null
                $log = Get-Content -LiteralPath $tmp -Raw
            }
            finally {
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
            }

            # Two of the three rows are past cutoff.
            $warnLine = @($log -split "`n" | Where-Object { $_ -match 'WARN' -and $_ -match 'past cutoff' })
            $warnLine.Count | Should -Be 1
            $warnLine[0]    | Should -Match '2 block row\(s\) are past cutoff'
        }

        It 'emits no past-cutoff WARN when no rows are past cutoff' {
            $raw = [PSCustomObject]@{ resort = 'TEST01'; blockCode = 'B1'; blockIdDate = '2026-08-15'; cutoffDate = '2026-08-10'; blockedRooms = 10; pickedUpRooms = 2 }
            $cap = New-CapturingInvoker -Rows @($raw)

            $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("_blk_nowarn_{0}.txt" -f ([guid]::NewGuid())))
            try {
                Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                    -FutureDays 180 -SubjectAreaInvoker $cap.Invoker -Verbose 4>$tmp | Out-Null
                $log = Get-Content -LiteralPath $tmp -Raw
            }
            finally {
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
            }

            $warnLine = @($log -split "`n" | Where-Object { $_ -match 'WARN' -and $_ -match 'past cutoff' })
            $warnLine.Count | Should -Be 0
        }
    }

    Context 'Return contract' {

        It 'returns an array even for a single row' {
            $raw = [PSCustomObject]@{ resort = 'TEST01'; blockCode = 'B1'; blockIdDate = '2026-08-15'; blockedRooms = 5; pickedUpRooms = 1 }
            $cap = New-CapturingInvoker -Rows @($raw)
            $rows = Get-BlockReservations -Hotel $script:Hotel -SnapshotDate ([datetime]'2026-07-30') `
                -FutureDays 180 -SubjectAreaInvoker $cap.Invoker
            , $rows | Should -BeOfType [System.Object[]]
        }

        It 'exposes the Get-BLK alias' {
            (Get-Alias -Name 'Get-BLK').ResolvedCommandName | Should -Be 'Get-BlockReservations'
        }
    }
}
