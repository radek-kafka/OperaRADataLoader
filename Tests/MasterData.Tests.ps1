# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Unit tests for Modules\Queries\MasterData.psm1 (Task 13).

.DESCRIPTION
    Exercises Get-MasterData entirely through the -SubjectAreaInvoker seam (no network):
      * -Type routing to the correct Subject Area / target DIM table.
      * SourceCodes and Channels map to SEPARATE targets and are never merged.
      * Full vs delta mode (ChangedSince filter absent/present in the request variables).
      * Each of the 7 type mappings' key fields.
      * SourceCodes missing → throws (required dimension).
      * Channels missing → benign skip (no throw, returns empty, logs).
      * Change detection (new / description-changed / deactivated) via -CurrentRecordsProvider.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\Modules\Queries\MasterData.psm1" -Force

    $script:Hotel = @{ HotelCode = 'TEST01'; ChainCode = 'CHAINX'; GatewayUrl = 'https://x'; ApiKey = 'k' }

    # A seam factory that returns a fixed set of raw rows and captures the args it was called with.
    function New-CapturingInvoker {
        param([object[]] $Rows = @())
        $state = [pscustomobject]@{ Args = $null; Rows = $Rows }
        $sb = {
            param($a)
            $script:__capture.Args = $a
            return $script:__capture.Rows
        }.GetNewClosure()
        return [pscustomobject]@{ State = $state; Block = $sb }
    }
}

Describe 'Get-MasterData — Type routing to Subject Area / target' {

    It 'routes each -Type to its dedicated Subject Area operation' {
        $expected = @{
            TrxCodes       = 'financialTransactionCodes'
            RoomTypeLabels = 'inventoryRooms'
            RateCodes      = 'ratesCodeDetails'
            MarketCodes    = 'exportMappings'
            SourceCodes    = 'exportMappings'
            Channels       = 'exportMappings'
            Hotels         = 'configurationResort'
        }
        foreach ($type in $expected.Keys) {
            $captured = $null
            $seam = { param($a) $script:cap = $a; return @([pscustomobject]@{ code = 'X'; sourceCode = 'X'; channel = 'X'; trxCode = 'X'; roomCategory = 'X'; rateCode = 'X'; resort = 'TEST01'; description = 'd'; name = 'n' }) }
            $null = Get-MasterData -Hotel $script:Hotel -Type $type -SubjectAreaInvoker $seam
            $script:cap.Operation | Should -Be $expected[$type] -Because "Type $type must route to $($expected[$type])"
        }
    }

    It 'ExportMappings dimensions share the SA but use distinct mappingType discriminators' {
        $seam = { param($a) $script:cap = $a; return @([pscustomobject]@{ code = 'C'; description = 'd'; resort = 'TEST01' }) }

        $null = Get-MasterData -Hotel $script:Hotel -Type MarketCodes -SubjectAreaInvoker $seam
        $market = $script:cap.Variables.input.mappingType._eq

        $null = Get-MasterData -Hotel $script:Hotel -Type SourceCodes -SubjectAreaInvoker $seam
        $source = $script:cap.Variables.input.mappingType._eq

        $null = Get-MasterData -Hotel $script:Hotel -Type Channels -SubjectAreaInvoker $seam
        $channel = $script:cap.Variables.input.mappingType._eq

        $market  | Should -Be 'MARKET'
        $source  | Should -Be 'SOURCE'
        $channel | Should -Be 'CHANNEL'
        @($market, $source, $channel) | Select-Object -Unique | Should -HaveCount 3
    }
}

Describe 'Get-MasterData — SourceCodes and Channels are SEPARATE (never merged)' {

    It 'maps SourceCodes to a source-shaped row and Channels to a channel-shaped row from the same SA' {
        # Source list rows (booking origin) and channel list rows (distribution) are distinct.
        $sourceSeam = { param($a) return @(
            [pscustomobject]@{ resort = 'TEST01'; code = 'GDS-SRC'; description = 'Travel Agent'; mappingType = 'SOURCE'; activeYn = 'Y' }
        ) }
        $channelSeam = { param($a) return @(
            [pscustomobject]@{ resort = 'TEST01'; code = 'OTA-CH'; description = 'Online Travel Agency'; mappingType = 'CHANNEL'; activeYn = 'Y' }
        ) }

        $src = @(Get-MasterData -Hotel $script:Hotel -Type SourceCodes -SubjectAreaInvoker $sourceSeam)
        $chn = @(Get-MasterData -Hotel $script:Hotel -Type Channels -SubjectAreaInvoker $channelSeam)

        $src | Should -HaveCount 1
        $chn | Should -HaveCount 1
        $src[0].CODE | Should -Be 'GDS-SRC'
        $chn[0].CODE | Should -Be 'OTA-CH'
        # No cross-contamination: source rows never contain channel codes and vice-versa.
        $src[0].CODE | Should -Not -Be $chn[0].CODE
    }
}

Describe 'Get-MasterData — full refresh vs delta mode' {

    It 'omits the changed-since filter for a full refresh (no -ChangedSince)' {
        $seam = { param($a) $script:cap = $a; return @([pscustomobject]@{ resort = 'TEST01'; code = 'C'; description = 'd' }) }
        $null = Get-MasterData -Hotel $script:Hotel -Type MarketCodes -SubjectAreaInvoker $seam
        $script:cap.Variables.input.ContainsKey('changedSince') | Should -BeFalse
    }

    It 'adds an ISO changed-since filter for delta mode (-ChangedSince supplied)' {
        $seam = { param($a) $script:cap = $a; return @([pscustomobject]@{ resort = 'TEST01'; code = 'C'; description = 'd' }) }
        $null = Get-MasterData -Hotel $script:Hotel -Type MarketCodes -ChangedSince ([datetime]'2026-07-30') -SubjectAreaInvoker $seam
        $script:cap.Variables.input.ContainsKey('changedSince') | Should -BeTrue
        $script:cap.Variables.input.changedSince._gte | Should -Be '2026-07-30'
    }
}

Describe 'Get-MasterData — key field mappings for all 7 types' {

    It 'maps TrxCodes key fields to ra.DIM_TrxCodes columns' {
        $seam = { param($a) return @([pscustomobject]@{
            resort = 'TEST01'; trxCode = '1001'; description = 'Room Revenue'; trxGroup = 'ROOM'
            trxSubgroup = '100'; revenueYn = 'Y'; roomRevenueYn = 'Y'; packageYn = 'N'; activeYn = 'Y' }) }
        $r = @(Get-MasterData -Hotel $script:Hotel -Type TrxCodes -SubjectAreaInvoker $seam)[0]
        $r.TRX_CODE        | Should -Be '1001'
        $r.TRX_NAME        | Should -Be 'Room Revenue'
        $r.TC_GROUP        | Should -Be 'ROOM'
        $r.TC_SUBGROUP     | Should -Be '100'
        $r.REVENUE_YN      | Should -Be 'Y'
        $r.ROOM_REVENUE_YN | Should -Be 'Y'
        $r.PACKAGE_YN      | Should -Be 'N'
        $r.IS_ACTIVE       | Should -Be 1
        $r.FLAG            | Should -Be 'N'
    }

    It 'maps RoomTypeLabels key fields to ra.DIM_RoomTypes columns' {
        $seam = { param($a) return @([pscustomobject]@{
            resort = 'TEST01'; roomCategory = 'DB1'; roomCategoryDesc = 'Double'; roomClass = 'STD'
            physicalRooms = '25'; activeYn = 'Y' }) }
        $r = @(Get-MasterData -Hotel $script:Hotel -Type RoomTypeLabels -SubjectAreaInvoker $seam)[0]
        $r.ROOM_CATEGORY_LABEL | Should -Be 'DB1'
        $r.DESCRIPTION         | Should -Be 'Double'
        $r.ROOM_CLASS          | Should -Be 'STD'
        $r.PHYSICAL_ROOM_COUNT | Should -Be 25
        $r.IS_ACTIVE           | Should -Be 1
    }

    It 'maps RateCodes key fields to ra.DIM_RateCodes columns' {
        $seam = { param($a) return @([pscustomobject]@{
            resort = 'TEST01'; rateCode = 'BAR'; rateDescription = 'Best Available'; rateCategory = 'PUBLIC'; activeYn = 'Y' }) }
        $r = @(Get-MasterData -Hotel $script:Hotel -Type RateCodes -SubjectAreaInvoker $seam)[0]
        $r.CODE          | Should -Be 'BAR'
        $r.DESCRIPTION   | Should -Be 'Best Available'
        $r.RATE_CATEGORY | Should -Be 'PUBLIC'
        $r.IS_ACTIVE     | Should -Be 1
    }

    It 'maps MarketCodes key fields to ra.DIM_MarketCodes columns' {
        $seam = { param($a) return @([pscustomobject]@{
            resort = 'TEST01'; code = 'LEIS'; description = 'Leisure'; groupCode = 'TRANSIENT'; activeYn = 'Y' }) }
        $r = @(Get-MasterData -Hotel $script:Hotel -Type MarketCodes -SubjectAreaInvoker $seam)[0]
        $r.CODE          | Should -Be 'LEIS'
        $r.DESCRIPTION   | Should -Be 'Leisure'
        $r.SEGMENT_GROUP | Should -Be 'TRANSIENT'
        $r.IS_ACTIVE     | Should -Be 1
    }

    It 'maps SourceCodes key fields to ra.DIM_SourceCodes columns' {
        $seam = { param($a) return @([pscustomobject]@{
            resort = 'TEST01'; code = 'DIRECT'; description = 'Direct Booking'; activeYn = 'Y' }) }
        $r = @(Get-MasterData -Hotel $script:Hotel -Type SourceCodes -SubjectAreaInvoker $seam)[0]
        $r.CODE        | Should -Be 'DIRECT'
        $r.DESCRIPTION | Should -Be 'Direct Booking'
        $r.IS_ACTIVE   | Should -Be 1
        # No SEGMENT_GROUP on the source contract.
        ($r.PSObject.Properties.Name -contains 'SEGMENT_GROUP') | Should -BeFalse
    }

    It 'maps Channels key fields to ra.DIM_Channels columns' {
        $seam = { param($a) return @([pscustomobject]@{
            resort = 'TEST01'; code = 'WEB'; description = 'Brand Website'; activeYn = 'N' }) }
        $r = @(Get-MasterData -Hotel $script:Hotel -Type Channels -SubjectAreaInvoker $seam)[0]
        $r.CODE        | Should -Be 'WEB'
        $r.DESCRIPTION | Should -Be 'Brand Website'
        # activeYn = N → inactive → FLAG 'Y' (deleted), IS_ACTIVE 0.
        $r.IS_ACTIVE   | Should -Be 0
        $r.FLAG        | Should -Be 'Y'
    }

    It 'maps Hotels key fields to ra.Hotels columns' {
        $seam = { param($a) return @([pscustomobject]@{
            resort = 'TEST01'; chainCode = 'CHAINX'; name = 'Grand Hotel'; city = 'Vienna'; countryCode = 'AT'
            currencyCode = 'EUR'; timezoneRegion = 'Central European Standard Time'; nightAuditHour = '23'; nightAuditMinute = '0' }) }
        $r = @(Get-MasterData -Hotel $script:Hotel -Type Hotels -SubjectAreaInvoker $seam)[0]
        $r.RESORT           | Should -Be 'TEST01'
        $r.DISPLAY_NAME     | Should -Be 'Grand Hotel'
        $r.CITY             | Should -Be 'Vienna'
        $r.COUNTRY          | Should -Be 'AT'
        $r.CURRENCY_CODE    | Should -Be 'EUR'
        $r.TIME_ZONE_ID     | Should -Be 'Central European Standard Time'
        $r.NIGHT_AUDIT_HOUR | Should -Be 23
        $r.NIGHT_AUDIT_MIN  | Should -Be 0
    }
}

Describe 'Get-MasterData — missing-data handling' {

    It 'THROWS when the required SourceCodes list is empty' {
        $seam = { param($a) return @() }
        { Get-MasterData -Hotel $script:Hotel -Type SourceCodes -SubjectAreaInvoker $seam } |
            Should -Throw -ExpectedMessage '*required master dimension*SourceCodes*'
    }

    It 'SKIPS (no throw, empty result) when the optional Channels list is absent' {
        $seam = { param($a) return @() }
        { Get-MasterData -Hotel $script:Hotel -Type Channels -SubjectAreaInvoker $seam | Out-Null } | Should -Not -Throw
        $result = @(Get-MasterData -Hotel $script:Hotel -Type Channels -SubjectAreaInvoker $seam)
        $result.Count | Should -Be 0
    }
}

Describe 'Get-MasterData — change detection via -CurrentRecordsProvider' {

    It 'logs NEW, DESCRIPTION change, and DEACTIVATED codes' {
        # API response: A2 unchanged, A3 description changed, A4 new. A1 (in DB) absent → deactivated.
        $apiSeam = { param($a) return @(
            [pscustomobject]@{ resort = 'TEST01'; code = 'A2'; description = 'Two'; activeYn = 'Y' }
            [pscustomobject]@{ resort = 'TEST01'; code = 'A3'; description = 'Three-NEW'; activeYn = 'Y' }
            [pscustomobject]@{ resort = 'TEST01'; code = 'A4'; description = 'Four'; activeYn = 'Y' }
        ) }
        # Current DB rows (already in target column shape).
        $provider = { param($ctx) return @(
            [pscustomobject]@{ CODE = 'A1'; DESCRIPTION = 'One'; IS_ACTIVE = 1 }
            [pscustomobject]@{ CODE = 'A2'; DESCRIPTION = 'Two'; IS_ACTIVE = 1 }
            [pscustomobject]@{ CODE = 'A3'; DESCRIPTION = 'Three-OLD'; IS_ACTIVE = 1 }
        ) }

        # Write-MasterDataLog falls through to Write-Verbose when no Logger is loaded, so
        # capture verbose output (4>&1) and assert on the change-detection lines.
        $captured = Get-MasterData -Hotel $script:Hotel -Type MarketCodes -SubjectAreaInvoker $apiSeam `
            -CurrentRecordsProvider $provider -Verbose 4>&1

        $joined = (($captured |
            Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
            ForEach-Object { [string]$_.Message }) -join "`n")
        $joined | Should -Match "NEW code 'A4'"
        $joined | Should -Match "DESCRIPTION changed for code 'A3'"
        $joined | Should -Match "DEACTIVATED code 'A1'"
    }
}
