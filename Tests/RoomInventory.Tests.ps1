# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

BeforeAll {
    # DateHelper supplies Get-DateRangeChunks + Format-OutputDate (resolved by name at
    # call time inside the module). Import it first so the real helpers are present.
    Import-Module "$PSScriptRoot\..\Modules\DateHelper.psm1" -Force
    Import-Module "$PSScriptRoot\..\Modules\Queries\RoomInventory.psm1" -Force

    $script:Hotel = @{ HotelCode = 'TEST01'; ChainCode = 'CHN'; TimeZoneId = 'Central European Standard Time' }

    # Build a SubjectAreaInvoker that branches on the operation and RECORDS the args each
    # sub-query passed (so tests can assert chunking + ISO filters). The recorder list is
    # captured by closure (NOT $script:) because the invoker executes inside the module's
    # scope, where a test-scope $script: variable would not resolve.
    $script:MakeInvoker = {
        param([object[]] $RmnRows, [object[]] $OooRows)
        $recorder = [System.Collections.Generic.List[object]]::new()
        $invoker = {
            param($SaArgs)
            $recorder.Add($SaArgs)
            switch ($SaArgs.Operation) {
                'inventoryRooms' { return $RmnRows }
                'statisticsManagersReport' { return $OooRows }
                default { return @() }
            }
        }.GetNewClosure()
        # Return both the invoker and its recorder so callers can inspect the calls made.
        return [PSCustomObject]@{ Invoker = $invoker; Calls = $recorder }
    }
}

Describe 'RoomInventory — OOO date chunking + ISO filters' {

    It 'splits a 20-day range into 3 seven-day chunks and uses ISO YYYY-MM-DD filters' {
        $h = & $script:MakeInvoker @() @()
        $null = Get-OOO -Hotel $script:Hotel -StartDate '2026-01-01' -EndDate '2026-01-20' `
            -ChunkDays 7 -SubjectAreaInvoker $h.Invoker

        $oooCalls = @($h.Calls | Where-Object { $_.Operation -eq 'statisticsManagersReport' })
        $oooCalls.Count | Should -Be 3

        # First chunk businessDate filter is ISO, inclusive [2026-01-01, 2026-01-07].
        $firstVars = @($oooCalls[0].Chunks)[0].Variables
        $firstVars.input.businessDate._gte | Should -Be '2026-01-01'
        $firstVars.input.businessDate._lte | Should -Be '2026-01-07'
        $firstVars.input.resort._in[0] | Should -Be 'TEST01'
    }

    It 'yields a single chunk for a one-day range' {
        $h = & $script:MakeInvoker @() @()
        $null = Get-OOO -Hotel $script:Hotel -StartDate '2026-03-10' -EndDate '2026-03-10' `
            -SubjectAreaInvoker $h.Invoker
        $oooCalls = @($h.Calls | Where-Object { $_.Operation -eq 'statisticsManagersReport' })
        $oooCalls.Count | Should -Be 1
        $vars = @($oooCalls[0].Chunks)[0].Variables
        $vars.input.businessDate._gte | Should -Be '2026-03-10'
        $vars.input.businessDate._lte | Should -Be '2026-03-10'
    }
}

Describe 'RoomInventory — OOO mapping' {

    It 'maps InventoryDate->BUSINESS_DATE (YYYYMMDD), OutOfOrder->OOO_ROOMS, OutOfService->OS_ROOMS, ROOM_CLASS' {
        $raw = @(
            [PSCustomObject]@{
                resort = 'TEST01'; businessDate = '2026-07-30'; roomClass = 'STD'
                oooRooms = 3; osRooms = 2; availRoom = 40; physicalBeds = 50; oooBeds = 3; osBeds = 2
            }
        )
        $h = & $script:MakeInvoker @() $raw
        $rows = @(Get-OOO -Hotel $script:Hotel -StartDate '2026-07-30' -EndDate '2026-07-30' -SubjectAreaInvoker $h.Invoker)

        $rows.Count | Should -Be 1
        $row = $rows[0]
        $row.BUSINESS_DATE | Should -Be '20260730'   # InventoryDate formatted YYYYMMDD
        $row.ROOM_CLASS | Should -Be 'STD'
        $row.OOO_ROOMS | Should -Be 3                # OutOfOrder
        $row.OS_ROOMS | Should -Be 2                 # OutOfService
        $row.PHYSICAL_BEDS | Should -Be 50
        $row.RESORT | Should -Be 'TEST01'
        $row.CHAIN_CODE | Should -Be 'CHN'
    }

    It 'backfills a blank RESORT from the hotel code and keeps missing counts as $null' {
        $raw = @([PSCustomObject]@{ businessDate = '2026-07-30'; roomClass = 'DLX' })  # no resort, no counts
        $h = & $script:MakeInvoker @() $raw
        $rows = @(Get-OOO -Hotel $script:Hotel -StartDate '2026-07-30' -EndDate '2026-07-30' -SubjectAreaInvoker $h.Invoker)

        $rows[0].RESORT | Should -Be 'TEST01'
        $rows[0].OOO_ROOMS | Should -BeNullOrEmpty
        $rows[0].OS_ROOMS | Should -BeNullOrEmpty
        # AVAIL_ROOM cannot be computed without operands -> stays $null.
        $rows[0].AVAIL_ROOM | Should -BeNullOrEmpty
    }
}

Describe 'RoomInventory — RMN mapping' {

    It 'maps ROOM, roomCategoryLabel->ROOM_CATEGORY_LABEL (RoomTypeLabel), ROOM_CLASS, ROOM_STATUS' {
        $raw = @(
            [PSCustomObject]@{ resort = 'TEST01'; room = '101'; roomCategoryLabel = 'KING'; roomClass = 'STD'; roomStatus = 'OO' }
        )
        $h = & $script:MakeInvoker $raw @()
        $rows = @(Get-RMN -Hotel $script:Hotel -SubjectAreaInvoker $h.Invoker)

        $rows.Count | Should -Be 1
        $rows[0].ROOM | Should -Be '101'
        $rows[0].ROOM_CATEGORY_LABEL | Should -Be 'KING'   # RoomTypeLabel
        $rows[0].ROOM_CLASS | Should -Be 'STD'
        $rows[0].ROOM_STATUS | Should -Be 'OO'
        $rows[0].RESORT | Should -Be 'TEST01'
    }

    It 'fetches RMN as a single static request (no date chunking)' {
        $h = & $script:MakeInvoker @([PSCustomObject]@{ resort = 'TEST01'; room = '1' }) @()
        $null = Get-RMN -Hotel $script:Hotel -SubjectAreaInvoker $h.Invoker
        $rmnCalls = @($h.Calls | Where-Object { $_.Operation -eq 'inventoryRooms' })
        $rmnCalls.Count | Should -Be 1
        # RMN request carries only the resort filter — no businessDate range.
        $vars = @($rmnCalls[0].Chunks)[0].Variables
        $vars.input.ContainsKey('businessDate') | Should -BeFalse
        $vars.input.resort._in[0] | Should -Be 'TEST01'
    }
}

Describe 'RoomInventory — AvailableRooms computation' {

    It 'computes AVAIL_ROOM = PhysicalRooms - OutOfOrder - OutOfService when the API omits it' {
        $raw = @([PSCustomObject]@{ resort = 'TEST01'; businessDate = '2026-07-30'; roomClass = 'STD'; physicalBeds = 50; oooRooms = 3; osRooms = 2 })
        $h = & $script:MakeInvoker @() $raw
        $rows = @(Get-OOO -Hotel $script:Hotel -StartDate '2026-07-30' -EndDate '2026-07-30' -SubjectAreaInvoker $h.Invoker)
        $rows[0].AVAIL_ROOM | Should -Be 45   # 50 - 3 - 2
    }

    It 'does NOT overwrite an API-supplied AVAIL_ROOM' {
        $raw = @([PSCustomObject]@{ resort = 'TEST01'; businessDate = '2026-07-30'; roomClass = 'STD'; physicalBeds = 50; oooRooms = 3; osRooms = 2; availRoom = 41 })
        $h = & $script:MakeInvoker @() $raw
        $rows = @(Get-OOO -Hotel $script:Hotel -StartDate '2026-07-30' -EndDate '2026-07-30' -SubjectAreaInvoker $h.Invoker)
        $rows[0].AVAIL_ROOM | Should -Be 41   # API value preserved, not recomputed to 45
    }

    It 'null-guards: leaves AVAIL_ROOM $null when an operand is missing' {
        $raw = @([PSCustomObject]@{ resort = 'TEST01'; businessDate = '2026-07-30'; roomClass = 'STD'; oooRooms = 3; osRooms = 2 })  # no physicalBeds
        $h = & $script:MakeInvoker @() $raw
        $rows = @(Get-OOO -Hotel $script:Hotel -StartDate '2026-07-30' -EndDate '2026-07-30' -SubjectAreaInvoker $h.Invoker)
        $rows[0].AVAIL_ROOM | Should -BeNullOrEmpty
    }
}

Describe 'RoomInventory — historical + future in a single call' {

    It 'chunks a range crossing today (past + future) uniformly without special-casing' {
        $today = [datetime]::UtcNow.Date
        $start = $today.AddDays(-10)   # historical (actuals)
        $end = $today.AddDays(10)      # future (forecast)

        # Emit one row per queried chunk (echo the chunk's businessDate filter back as a
        # row) so accumulation across chunks — and uniform treatment of the whole range,
        # past + future — is observable in the returned row count. A 21-day inclusive range
        # at 7 days/chunk yields 3 chunks, hence 3 rows.
        $invoker = {
            param($SaArgs)
            $bd = @($SaArgs.Chunks)[0].Variables.input.businessDate._gte
            return @([PSCustomObject]@{ resort = 'TEST01'; businessDate = $bd; roomClass = 'STD'; physicalBeds = 10; oooRooms = 1; osRooms = 1 })
        }
        # Assign the result first, THEN @()-wrap: Get-OOO returns via the unary-comma
        # idiom (return , $flat), which nests if piped straight into @(...).
        $result = Get-OOO -Hotel $script:Hotel -StartDate $start -EndDate $end -ChunkDays 7 -SubjectAreaInvoker $invoker
        $rows = @($result)

        # 3 chunks, uniform query, accumulated into one flat array crossing today.
        $rows.Count | Should -Be 3
        # The first and last chunk BUSINESS_DATE span the historical..future window.
        $firstDate = @($rows | Sort-Object BUSINESS_DATE)[0].BUSINESS_DATE
        $lastDate = @($rows | Sort-Object BUSINESS_DATE)[-1].BUSINESS_DATE
        $firstDate | Should -Be ($start.ToString('yyyyMMdd'))
    }
}

Describe 'RoomInventory — Get-RoomInventory return shape (RMN + OOO)' {

    It 'returns a hashtable with RMN and OOO arrays populated from both sub-queries' {
        $rmn = @([PSCustomObject]@{ resort = 'TEST01'; room = '101'; roomCategoryLabel = 'KING'; roomClass = 'STD'; roomStatus = 'CL' })
        $ooo = @([PSCustomObject]@{ resort = 'TEST01'; businessDate = '2026-07-30'; roomClass = 'STD'; physicalBeds = 50; oooRooms = 3; osRooms = 2 })
        $h = & $script:MakeInvoker $rmn $ooo

        $result = Get-RoomInventory -Hotel $script:Hotel -StartDate '2026-07-30' -EndDate '2026-07-30' -SubjectAreaInvoker $h.Invoker

        $result | Should -BeOfType [hashtable]
        $result.ContainsKey('RMN') | Should -BeTrue
        $result.ContainsKey('OOO') | Should -BeTrue
        @($result.RMN).Count | Should -Be 1
        @($result.OOO).Count | Should -Be 1
        @($result.RMN)[0].ROOM | Should -Be '101'
        @($result.OOO)[0].BUSINESS_DATE | Should -Be '20260730'
        @($result.OOO)[0].AVAIL_ROOM | Should -Be 45
    }

    It 'returns arrays even when a sub-query yields a single row (no pipeline unwrap)' {
        $rmn = @([PSCustomObject]@{ resort = 'TEST01'; room = '101' })
        $ooo = @([PSCustomObject]@{ resort = 'TEST01'; businessDate = '2026-07-30'; roomClass = 'STD' })
        $h = & $script:MakeInvoker $rmn $ooo
        $result = Get-RoomInventory -Hotel $script:Hotel -StartDate '2026-07-30' -EndDate '2026-07-30' -SubjectAreaInvoker $h.Invoker

        # A single-element array must still be an array (Object[]), not a bare object.
        $result.RMN -is [array] | Should -BeTrue
        $result.OOO -is [array] | Should -BeTrue
    }
}
