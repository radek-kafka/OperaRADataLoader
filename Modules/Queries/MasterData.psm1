# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Master / Dimension data query module for the OPERA R&A Data Loader (Task 13).

.DESCRIPTION
    Extracts master / dimension code lists from the OHIP R&A Data API and returns a
    normalised flat [array] of [PSCustomObject] rows keyed to the ra.DIM_* / ra.Hotels
    target column contracts (SQL\004_CreateTables_MasterData.sql), ready to hand straight
    to SqlWriter\Write-MasterData -Type <DIM type> -Data <rows>.

    Public entry point:
      Get-MasterData -Hotel -Type [-ChangedSince] [-CurrentRecordsProvider] ...

    -Type values, their Subject Areas, and their target DIM table (design.md):

      TrxCodes        FinancialTransactionCodes  (financialTransactionCodes)  → DIM_TrxCodes
      RoomTypeLabels  InventoryRooms             (inventoryRooms)             → DIM_RoomTypes
      RateCodes       RatesCodeDetails           (ratesCodeDetails)           → DIM_RateCodes
      MarketCodes     ExportMappings             (exportMappings)             → DIM_MarketCodes
      SourceCodes     ExportMappings             (exportMappings)             → DIM_SourceCodes
      Channels        ExportMappings             (exportMappings)             → DIM_Channels
      Hotels          ConfigurationResort        (configurationResort)        → Hotels

    CRITICAL — SourceCodes vs Channels are TWO INDEPENDENT code lists and MUST NOT be
    merged (design.md + SQL\004):
      * SourceCodes = SOURCE OF RESERVATION (booking origin, OPERA SOURCE_CODE).
        *** PRIORITY / REQUIRED *** — always loaded; a missing/empty source list is an
        ERROR and THROWS (fails the type).
      * Channels    = DISTRIBUTION CHANNEL (GDS/OTA/Direct/Web/CRO, OPERA CHANNEL).
        *** OPTIONAL / best-effort *** — a missing/empty channel list is a benign skip
        (logged INFO/WARN, returns an empty array, never throws).
    Each -Type resolves to its own dedicated Subject Area + ExportMappings mapping-type
    discriminator, so source rows can never land in the channel list (or vice-versa).

    ExportMappings-based dimensions (Market / Source / Channel) share one Subject Area
    (exportMappings). Each -Type selects the right code list via a mapping-type
    discriminator passed as a GraphQL filter (mappingType), so the three lists stay
    strictly separate.

    Full refresh vs delta (subtask 2):
      * -ChangedSince omitted  → FULL refresh: no change filter in the request.
      * -ChangedSince supplied → DELTA: an ISO 'YYYY-MM-DD' (or ISO datetime) changed-since
        filter is added to the GraphQL variables so the SA returns only changed codes.

    Change detection (subtask 9):
      An optional -CurrentRecordsProvider scriptblock is invoked with the mapped DIM type
      and the hotel; it returns the current DB rows (e.g. via SqlWriter or a query). The
      module compares current DB rows against the API response and logs INFO/WARN lines
      summarising NEW codes, DESCRIPTION changes, and DEACTIVATIONS (codes present in DB
      but absent / inactive in the API response). This is DETECTION + LOGGING ONLY — the
      SCD Type 2 persistence itself is performed by Write-MasterData.

    FLAG / IS_ACTIVE semantics (SQL\004): FLAG 'N' = active, 'Y' = deleted. Every mapped
    row carries IS_ACTIVE (BIT 1/0) and FLAG ('N'/'Y') derived consistently from the
    source active flag.

    Test seams (unit-testable without network):
      -SubjectAreaInvoker : scriptblock invoked INSTEAD of ApiClient\Invoke-RASubjectArea.
                            Receives a single hashtable of the args this module would have
                            passed (Operation, PrimaryView, Query, Variables, Hotel, Token,
                            Config) and must return an [array] of raw row objects.
      -Invoker / -Sleep   : forwarded to the real Invoke-RASubjectArea when
                            -SubjectAreaInvoker is not supplied.
      -CurrentRecordsProvider : scriptblock returning current DB rows for change detection.

.NOTES
    Logger -Module constant: "MasterData".
#>

# ------------------------------------------------------------------------------
# Best-effort imports. Resolved by name at call time too, so the module still loads
# in isolated unit tests where dependencies may be injected via seams.
# ------------------------------------------------------------------------------
$script:ApiClientPath = Join-Path -Path $PSScriptRoot -ChildPath '..\ApiClient.psm1'
if (Test-Path -LiteralPath $script:ApiClientPath) {
    Import-Module $script:ApiClientPath -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# -Type → Subject Area routing table (design.md). Each entry is fully self-contained
# so a -Type can never accidentally resolve to another type's target/SA.
#   Operation      : GraphQL operation name (camelCase)
#   PrimaryView    : primary view under data.<Operation> whose rows we collect
#   Target         : Write-MasterData -Type value (the ra.DIM_* / ra.Hotels contract)
#   MappingType    : ExportMappings mappingType discriminator (Market/Source/Channel only)
#   Required       : $true → a missing/empty list is an ERROR (throw)
#                    $false → a missing/empty list is a benign skip
# ------------------------------------------------------------------------------
$script:MasterDataRouting = @{
    'TrxCodes'       = @{ Operation = 'financialTransactionCodes'; PrimaryView = 'transactionCodeDetails'; Target = 'DIM_TrxCodes';    MappingType = $null;     Required = $true }
    'RoomTypeLabels' = @{ Operation = 'inventoryRooms';            PrimaryView = 'roomDetails';            Target = 'DIM_RoomTypes';   MappingType = $null;     Required = $true }
    'RateCodes'      = @{ Operation = 'ratesCodeDetails';          PrimaryView = 'rateCodeDetails';        Target = 'DIM_RateCodes';   MappingType = $null;     Required = $true }
    'MarketCodes'    = @{ Operation = 'exportMappings';            PrimaryView = 'exportMappingDetails';   Target = 'DIM_MarketCodes'; MappingType = 'MARKET';  Required = $true }
    'SourceCodes'    = @{ Operation = 'exportMappings';            PrimaryView = 'exportMappingDetails';   Target = 'DIM_SourceCodes'; MappingType = 'SOURCE';  Required = $true }
    'Channels'       = @{ Operation = 'exportMappings';            PrimaryView = 'exportMappingDetails';   Target = 'DIM_Channels';    MappingType = 'CHANNEL'; Required = $false }
    'Hotels'         = @{ Operation = 'configurationResort';       PrimaryView = 'propertyDetails';        Target = 'Hotels';          MappingType = $null;     Required = $true }
}

# ------------------------------------------------------------------------------
# Logging helper — shared Logger when loaded, else Write-Verbose. Never throws.
# ------------------------------------------------------------------------------
function Write-MasterDataLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $Level,

        [Parameter(Mandatory)]
        [string] $Message,

        [Parameter()]
        [string] $HotelCode = '',

        [Parameter()]
        [guid] $BatchId = [guid]::Empty
    )

    $writeLog = Get-Command -Name 'Write-Log' -ErrorAction SilentlyContinue
    if ($writeLog) {
        try {
            & $writeLog -Level $Level -Module 'MasterData' -Message $Message -HotelCode $HotelCode -BatchId $BatchId
            return
        }
        catch {
            # A logger failure must never break extraction — fall through to verbose.
        }
    }

    Write-Verbose ("MasterData [{0}] {1}: {2}" -f $Level, $HotelCode, $Message)
}

# ------------------------------------------------------------------------------
# Internal: case-insensitive lookup from a hashtable / PSCustomObject.
# ------------------------------------------------------------------------------
function Get-MasterDataValue {
    [CmdletBinding()]
    param(
        [Parameter()] $Source,
        [Parameter(Mandatory)] [string[]] $Names
    )

    if ($null -eq $Source) { return $null }

    foreach ($name in $Names) {
        if ($Source -is [System.Collections.IDictionary]) {
            foreach ($key in $Source.Keys) {
                if ([string]$key -ieq $name) { return $Source[$key] }
            }
        }
        else {
            $prop = $Source.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
            if ($prop) { return $prop.Value }
        }
    }
    return $null
}

# ------------------------------------------------------------------------------
# Internal: normalise a raw API value to a trimmed string, or $null for "no value".
# ------------------------------------------------------------------------------
function ConvertTo-MasterDataString {
    [CmdletBinding()]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text.Trim()
}

# ------------------------------------------------------------------------------
# Internal: normalise a raw API value to a nullable [int] (room counts etc.).
# ------------------------------------------------------------------------------
function ConvertTo-MasterDataInt {
    [CmdletBinding()]
    [OutputType([Nullable[int]])]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    if ($Value -is [int] -or $Value -is [long]) { return [int]$Value }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsed = [decimal]0
    if ([decimal]::TryParse($text, [System.Globalization.NumberStyles]::Any,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        try { return [int][math]::Round($parsed, 0, [System.MidpointRounding]::AwayFromZero) } catch { return $null }
    }
    return $null
}

# ------------------------------------------------------------------------------
# Internal: normalise a raw "active" flag to a canonical @{ IsActive; Flag } pair.
#   IsActive : BIT (1 active / 0 inactive)   Flag : 'N' active / 'Y' deleted (SQL\004)
# Accepts Y/N, true/false, 1/0, Active/Inactive, D/deleted. Absent/unknown → active.
# ------------------------------------------------------------------------------
function ConvertTo-MasterDataActive {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    $isActive = $true   # fallback: treat unknown as active (fallback logic)

    $text = ConvertTo-MasterDataString $Value
    if ($null -ne $text) {
        switch -Regex ($text.ToUpperInvariant()) {
            '^(N|NO|FALSE|0|INACTIVE|D|DELETED|Y)$' {
                # A code's "activeYn = N" means inactive; a "deletedFlag = Y" also means gone.
                # Distinguish the two flag domains below via the caller-supplied field name.
                $isActive = $false
            }
            default {
                $isActive = $true
            }
        }
    }

    return @{
        IsActive = if ($isActive) { 1 } else { 0 }
        Flag     = if ($isActive) { 'N' } else { 'Y' }
    }
}

# ------------------------------------------------------------------------------
# Internal: resolve the active state for a raw row, honouring BOTH an activeYn-style
# field (Y = active) and a deletedFlag-style field (Y = deleted). Deleted wins.
# ------------------------------------------------------------------------------
function Resolve-MasterDataActive {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] $Raw
    )

    $isActive = $true

    $activeYn = ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('activeYn', 'active', 'isActive', 'inactiveFlag'))
    if ($null -ne $activeYn) {
        $u = $activeYn.ToUpperInvariant()
        # inactiveFlag semantics are inverted (Y = inactive).
        $inactiveField = ($null -ne (Get-MasterDataValue -Source $Raw -Names @('inactiveFlag')))
        if ($inactiveField) {
            if ($u -in @('Y', 'YES', 'TRUE', '1')) { $isActive = $false }
        }
        else {
            if ($u -in @('N', 'NO', 'FALSE', '0', 'INACTIVE')) { $isActive = $false }
        }
    }

    $deleted = ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('deletedFlag', 'deleted'))
    if ($null -ne $deleted -and $deleted.ToUpperInvariant() -in @('Y', 'YES', 'TRUE', '1', 'D')) {
        $isActive = $false
    }

    return @{
        IsActive = if ($isActive) { 1 } else { 0 }
        Flag     = if ($isActive) { 'N' } else { 'Y' }
    }
}

# ------------------------------------------------------------------------------
# Internal: build the GraphQL query string for a given -Type. Requests ONLY the
# fields the mapper consumes (avoid over-fetching — design GraphQL rules).
# ------------------------------------------------------------------------------
function Get-MasterDataGraphQlQuery {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Type
    )

    $route = $script:MasterDataRouting[$Type]
    $op = $route.Operation
    $view = $route.PrimaryView

    switch ($Type) {
        'TrxCodes' {
            $fields = 'resort trxCode description trxGroup trxSubgroup revenueYn roomRevenueYn packageYn activeYn deletedFlag'
            return ("query FinancialTransactionCodes(`$input: FinancialTransactionCodesQueryArgumentsType!) { $op(input: `$input) { $view { $fields } } }")
        }
        'RoomTypeLabels' {
            $fields = 'resort roomCategory roomCategoryDesc roomClass physicalRooms activeYn deletedFlag'
            return ("query InventoryRooms(`$input: InventoryRoomsQueryArgumentsType!) { $op(input: `$input) { $view { $fields } } }")
        }
        'RateCodes' {
            $fields = 'resort rateCode rateDescription rateCategory rateClass activeYn deletedFlag'
            return ("query RatesCodeDetails(`$input: RatesCodeDetailsQueryArgumentsType!) { $op(input: `$input) { $view { $fields } } }")
        }
        'Hotels' {
            $fields = 'resort chainCode name city countryCode currencyCode timezoneRegion nightAuditHour nightAuditMinute inactiveFlag'
            return ("query ConfigurationResort(`$input: ConfigurationResortQueryArgumentsType!) { $op(input: `$input) { $view { $fields } } }")
        }
        default {
            # ExportMappings-based dimensions (Market / Source / Channel).
            $fields = 'resort code description groupCode mappingType activeYn deletedFlag'
            return ("query ExportMappings(`$input: ExportMappingsQueryArgumentsType!) { $op(input: `$input) { $view { $fields } } }")
        }
    }
}

# ------------------------------------------------------------------------------
# Internal: build the single GraphQL variables set for a -Type.
#   - resort filter is always present (mandatory for every master SA).
#   - ExportMappings dimensions add a mappingType discriminator so Market/Source/Channel
#     resolve to three SEPARATE lists from the one shared SA.
#   - Delta mode (ChangedSince supplied) adds a changed-since filter; full refresh omits it.
# ------------------------------------------------------------------------------
function New-MasterDataVariables {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [string] $ResortCode,
        [Parameter()] [Nullable[datetime]] $ChangedSince
    )

    $route = $script:MasterDataRouting[$Type]

    $input = @{
        resort = @{ _in = @($ResortCode) }
    }

    # ExportMappings mapping-type discriminator keeps Market/Source/Channel separate.
    if ($null -ne $route.MappingType) {
        $input['mappingType'] = @{ _eq = $route.MappingType }
    }

    # Delta filter (subtask 2). Only added when -ChangedSince is supplied → full refresh
    # otherwise. ISO 'YYYY-MM-DD' for the changed-since date.
    if ($null -ne $ChangedSince) {
        $iso = ([datetime]$ChangedSince).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $input['changedSince'] = @{ _gte = $iso }
    }

    return @{ input = $input }
}

# ------------------------------------------------------------------------------
# Internal: map ONE raw API row to a flat DIM/Hotels-shaped [PSCustomObject] keyed to
# the target column contract for the requested -Type.
# ------------------------------------------------------------------------------
function ConvertTo-MasterDataRow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)] $Hotel,
        [Parameter()] [AllowNull()] [guid] $BatchId = [guid]::Empty
    )

    $resort = ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('resort', 'property', 'hotelCode'))
    if ($null -eq $resort) {
        $resort = ConvertTo-MasterDataString (Get-MasterDataValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    }
    $chainCode = ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('chainCode'))
    if ($null -eq $chainCode) {
        $chainCode = ConvertTo-MasterDataString (Get-MasterDataValue -Source $Hotel -Names @('ChainCode', 'chainCode'))
    }

    $active = Resolve-MasterDataActive -Raw $Raw

    switch ($Type) {
        'TrxCodes' {
            $revYn  = ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('revenueYn'))
            $rmYn   = ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('roomRevenueYn'))
            $pkgYn  = ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('packageYn'))
            $norm = { param($v) if ($null -eq $v) { 'N' } elseif ($v.ToUpperInvariant() -in @('Y', 'YES', 'TRUE', '1')) { 'Y' } else { 'N' } }
            return [PSCustomObject][ordered]@{
                RESORT          = $resort
                CHAIN_CODE      = $chainCode
                TRX_CODE        = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('trxCode')))
                TRX_NAME        = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('description', 'trxName')))
                TC_GROUP        = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('trxGroup')))
                TC_SUBGROUP     = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('trxSubgroup', 'trxType')))
                FT_SUBTYPE      = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('ftSubtype')))
                REVENUE_YN      = (& $norm $revYn)
                ROOM_REVENUE_YN = (& $norm $rmYn)
                PACKAGE_YN      = (& $norm $pkgYn)
                IS_ACTIVE       = $active.IsActive
                FLAG            = $active.Flag
                BATCH_ID        = $BatchId
            }
        }
        'RoomTypeLabels' {
            return [PSCustomObject][ordered]@{
                RESORT              = $resort
                CHAIN_CODE          = $chainCode
                ROOM_CATEGORY_LABEL = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('roomCategory', 'roomTypeLabel')))
                DESCRIPTION         = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('roomCategoryDesc', 'description')))
                ROOM_CLASS          = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('roomClass')))
                PHYSICAL_ROOM_COUNT = (ConvertTo-MasterDataInt (Get-MasterDataValue -Source $Raw -Names @('physicalRooms', 'physicalRoomCount')))
                IS_ACTIVE           = $active.IsActive
                FLAG                = $active.Flag
                BATCH_ID            = $BatchId
            }
        }
        'RateCodes' {
            return [PSCustomObject][ordered]@{
                RESORT        = $resort
                CHAIN_CODE    = $chainCode
                CODE          = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('rateCode', 'code')))
                DESCRIPTION   = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('rateDescription', 'description')))
                RATE_CATEGORY = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('rateCategory')))
                RATE_CLASS    = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('rateClass')))
                IS_ACTIVE     = $active.IsActive
                FLAG          = $active.Flag
                BATCH_ID      = $BatchId
            }
        }
        'MarketCodes' {
            return [PSCustomObject][ordered]@{
                RESORT        = $resort
                CHAIN_CODE    = $chainCode
                CODE          = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('code', 'marketCode')))
                DESCRIPTION   = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('description')))
                SEGMENT_GROUP = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('groupCode', 'segmentGroup')))
                IS_ACTIVE     = $active.IsActive
                FLAG          = $active.Flag
                BATCH_ID      = $BatchId
            }
        }
        'SourceCodes' {
            # SOURCE OF RESERVATION — kept strictly separate from Channels.
            return [PSCustomObject][ordered]@{
                RESORT      = $resort
                CHAIN_CODE  = $chainCode
                CODE        = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('code', 'sourceCode')))
                DESCRIPTION = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('description')))
                IS_ACTIVE   = $active.IsActive
                FLAG        = $active.Flag
                BATCH_ID    = $BatchId
            }
        }
        'Channels' {
            # DISTRIBUTION CHANNEL — kept strictly separate from SourceCodes.
            return [PSCustomObject][ordered]@{
                RESORT      = $resort
                CHAIN_CODE  = $chainCode
                CODE        = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('code', 'channel')))
                DESCRIPTION = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('description')))
                IS_ACTIVE   = $active.IsActive
                FLAG        = $active.Flag
                BATCH_ID    = $BatchId
            }
        }
        'Hotels' {
            # ra.Hotels carries no FLAG column (single current row per RESORT).
            return [PSCustomObject][ordered]@{
                RESORT           = $resort
                CHAIN_CODE       = $chainCode
                DISPLAY_NAME     = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('name', 'displayName')))
                CITY             = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('city')))
                COUNTRY          = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('countryCode', 'country')))
                CURRENCY_CODE    = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('currencyCode')))
                TIME_ZONE_ID     = (ConvertTo-MasterDataString (Get-MasterDataValue -Source $Raw -Names @('timezoneRegion', 'timeZoneId')))
                NIGHT_AUDIT_HOUR = (ConvertTo-MasterDataInt (Get-MasterDataValue -Source $Raw -Names @('nightAuditHour')))
                NIGHT_AUDIT_MIN  = (ConvertTo-MasterDataInt (Get-MasterDataValue -Source $Raw -Names @('nightAuditMinute', 'nightAuditMin')))
                IS_ACTIVE        = $active.IsActive
                BATCH_ID         = $BatchId
            }
        }
        default {
            throw ("ConvertTo-MasterDataRow: unsupported -Type '{0}'." -f $Type)
        }
    }
}

# ------------------------------------------------------------------------------
# Internal: detect + log changes between current DB records and the API response.
# Detection + logging ONLY — SCD2 persistence is performed by Write-MasterData.
#   NEW           : code in API response but not in DB.
#   CHANGED       : code in both, DESCRIPTION differs.
#   DEACTIVATED   : code active in DB but absent from the API response, or present but
#                   inactive (IS_ACTIVE = 0) in the response.
# ------------------------------------------------------------------------------
function Write-MasterDataChangeLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Mapped,
        [Parameter()] [AllowNull()] [object[]] $CurrentRecords,
        [Parameter()] [string] $HotelCode = '',
        [Parameter()] [guid] $BatchId = [guid]::Empty
    )

    # Which column holds the natural code for this type.
    $codeColumn = switch ($Type) {
        'TrxCodes'       { 'TRX_CODE' }
        'RoomTypeLabels' { 'ROOM_CATEGORY_LABEL' }
        'Hotels'         { 'RESORT' }
        default          { 'CODE' }
    }

    $getCode = {
        param($row)
        [string](Get-MasterDataValue -Source $row -Names @($codeColumn))
    }
    $getDesc = {
        param($row)
        $names = if ($Type -eq 'TrxCodes') { @('TRX_NAME') } elseif ($Type -eq 'Hotels') { @('DISPLAY_NAME') } else { @('DESCRIPTION') }
        [string](Get-MasterDataValue -Source $row -Names $names)
    }
    $getActive = {
        param($row)
        $v = Get-MasterDataValue -Source $row -Names @('IS_ACTIVE')
        if ($null -eq $v) { return $true }
        return ([string]$v -in @('1', 'True', 'true', 'Y'))
    }

    # Build the current-DB lookup (only ACTIVE current rows count for deactivation).
    $currentByCode = @{}
    foreach ($cur in @($CurrentRecords)) {
        if ($null -eq $cur) { continue }
        $code = (& $getCode $cur)
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        $currentByCode[$code] = $cur
    }

    $newCount = 0; $changedCount = 0; $deactCount = 0
    $apiCodes = @{}

    foreach ($row in @($Mapped)) {
        if ($null -eq $row) { continue }
        $code = (& $getCode $row)
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        $apiCodes[$code] = $true

        if (-not $currentByCode.ContainsKey($code)) {
            $newCount++
            Write-MasterDataLog -Level INFO -HotelCode $HotelCode -BatchId $BatchId -Message (
                "{0} change: NEW code '{1}'." -f $Type, $code)
            continue
        }

        $cur = $currentByCode[$code]
        $newDesc = (& $getDesc $row)
        $oldDesc = (& $getDesc $cur)
        if ([string]$newDesc -ne [string]$oldDesc) {
            $changedCount++
            Write-MasterDataLog -Level INFO -HotelCode $HotelCode -BatchId $BatchId -Message (
                "{0} change: DESCRIPTION changed for code '{1}' ('{2}' -> '{3}')." -f $Type, $code, $oldDesc, $newDesc)
        }

        # Present but flipped inactive in the API response counts as a deactivation.
        if ((& $getActive $cur) -and -not (& $getActive $row)) {
            $deactCount++
            Write-MasterDataLog -Level WARN -HotelCode $HotelCode -BatchId $BatchId -Message (
                "{0} change: DEACTIVATED code '{1}' (inactive in API response)." -f $Type, $code)
        }
    }

    # Codes active in DB but entirely absent from the API response → deactivation.
    foreach ($code in $currentByCode.Keys) {
        if ($apiCodes.ContainsKey($code)) { continue }
        $cur = $currentByCode[$code]
        if (& $getActive $cur) {
            $deactCount++
            Write-MasterDataLog -Level WARN -HotelCode $HotelCode -BatchId $BatchId -Message (
                "{0} change: DEACTIVATED code '{1}' (absent from API response)." -f $Type, $code)
        }
    }

    Write-MasterDataLog -Level INFO -HotelCode $HotelCode -BatchId $BatchId -Message (
        "{0} change detection: {1} new, {2} changed, {3} deactivated." -f $Type, $newCount, $changedCount, $deactCount)
}

# ------------------------------------------------------------------------------
# Public: Get-MasterData
# ------------------------------------------------------------------------------
function Get-MasterData {
    <#
    .SYNOPSIS
        Extracts one master / dimension code list for a hotel and returns a normalised flat
        [array] of [PSCustomObject] rows keyed to the ra.DIM_* / ra.Hotels column contract,
        ready for SqlWriter\Write-MasterData -Type <mapped DIM type> -Data <rows>.

    .DESCRIPTION
        Routes -Type to its dedicated Subject Area (design.md). ExportMappings-based
        dimensions (MarketCodes / SourceCodes / Channels) share the exportMappings SA but
        each selects its own code list via a mappingType discriminator — SourceCodes
        (source of reservation) and Channels (distribution channel) are NEVER merged.

        Full refresh vs delta:
          * -ChangedSince omitted  → full refresh (no change filter in the request).
          * -ChangedSince supplied → delta (ISO 'YYYY-MM-DD' changed-since filter added).

        Missing-data handling:
          * SourceCodes (PRIORITY/required): a missing/empty list THROWS.
          * Channels (OPTIONAL): a missing/empty list is a benign skip (logged, returns @()).
          * All other required types: a missing/empty list throws.

        Change detection: when -CurrentRecordsProvider is supplied it is invoked with the
        mapped DIM type + hotel; the returned DB rows are compared to the API response and
        NEW / DESCRIPTION-changed / DEACTIVATED codes are logged (detection only).

    .PARAMETER Hotel
        Hotel configuration (hashtable / PSCustomObject). Recognised keys (case-insensitive):
        HotelCode (RESORT), ChainCode, GatewayUrl, ApiKey.

    .PARAMETER Type
        Master data list to extract: TrxCodes, RoomTypeLabels, RateCodes, MarketCodes,
        SourceCodes, Channels, or Hotels.

    .PARAMETER ChangedSince
        Optional delta cutoff. When supplied the request filters to codes changed on/after
        this date (ISO 'YYYY-MM-DD'). When omitted a full refresh is performed.

    .PARAMETER Token
        Optional bearer token forwarded to the API layer.

    .PARAMETER Config
        Optional settings object supplying api.* throttle/retry settings.

    .PARAMETER BatchId
        Optional batch GUID stamped on every output row (BATCH_ID) and used in log context.

    .PARAMETER CurrentRecordsProvider
        Optional scriptblock for change detection. Invoked as
        & $CurrentRecordsProvider @{ Type = <mapped DIM type>; Hotel = <hotel> } and must
        return the current DB rows (array) for the type.

    .PARAMETER SubjectAreaInvoker
        Optional test/DI seam invoked INSTEAD of Invoke-RASubjectArea. Receives a single
        hashtable (@{ Operation; PrimaryView; Query; Variables; Hotel; Token; Config }) and
        must return an [array] of raw row objects.

    .PARAMETER Invoker
        Optional HTTP seam forwarded to the real Invoke-RASubjectArea.

    .PARAMETER Sleep
        Optional throttle/backoff seam forwarded to the real Invoke-RASubjectArea.

    .OUTPUTS
        [array] of [PSCustomObject] matching the target DIM / Hotels schema for -Type.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] $Hotel,
        [Parameter(Mandatory)]
        [ValidateSet('TrxCodes', 'RoomTypeLabels', 'RateCodes', 'MarketCodes', 'SourceCodes', 'Channels', 'Hotels')]
        [string] $Type,
        [Parameter()] [Nullable[datetime]] $ChangedSince,
        [Parameter()] [string] $Token,
        [Parameter()] $Config,
        [Parameter()] [guid] $BatchId = [guid]::Empty,
        [Parameter()] [scriptblock] $CurrentRecordsProvider,
        [Parameter()] [scriptblock] $SubjectAreaInvoker,
        [Parameter()] [scriptblock] $Invoker,
        [Parameter()] [scriptblock] $Sleep
    )

    $hotelCode = [string](Get-MasterDataValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    if ([string]::IsNullOrWhiteSpace($hotelCode)) {
        throw 'Get-MasterData: Hotel config is missing a HotelCode.'
    }

    $route = $script:MasterDataRouting[$Type]
    $target = $route.Target
    $required = [bool]$route.Required

    $mode = if ($PSBoundParameters.ContainsKey('ChangedSince') -and $null -ne $ChangedSince) { 'Delta' } else { 'Full' }
    Write-MasterDataLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "Get-MasterData Type={0} SA={1} target=ra.{2} mode={3}{4}" -f `
            $Type, $route.Operation, $target, $mode, ($(if ($mode -eq 'Delta') { (" changedSince={0:yyyy-MM-dd}" -f $ChangedSince) } else { '' })))

    # --- Build the query + single variables set -----------------------------
    $query = Get-MasterDataGraphQlQuery -Type $Type
    $changedSinceArg = if ($mode -eq 'Delta') { [Nullable[datetime]]$ChangedSince } else { $null }
    $variables = New-MasterDataVariables -Type $Type -ResortCode $hotelCode -ChangedSince $changedSinceArg

    # --- Invoke the API layer (single call — master lists are not date-chunked) ---
    $saArgs = @{
        Operation   = $route.Operation
        PrimaryView = $route.PrimaryView
        Query       = $query
        Variables   = $variables
        Hotel       = $Hotel
        Config      = $Config
    }
    if ($PSBoundParameters.ContainsKey('Token') -and -not [string]::IsNullOrWhiteSpace($Token)) {
        $saArgs['Token'] = $Token
    }

    $invokeReal = Get-Command -Name 'Invoke-RASubjectArea' -ErrorAction SilentlyContinue
    if (-not $SubjectAreaInvoker -and -not $invokeReal) {
        throw 'Get-MasterData: Invoke-RASubjectArea (ApiClient.psm1) is not available and no -SubjectAreaInvoker seam was supplied.'
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rawRows = @()
    try {
        if ($SubjectAreaInvoker) {
            $rawRows = @(& $SubjectAreaInvoker $saArgs)
        }
        else {
            $realArgs = @{
                Hotel       = $Hotel
                Operation   = $route.Operation
                PrimaryView = $route.PrimaryView
                Query       = $query
                Variables   = $variables
                Config      = $Config
            }
            if ($saArgs.ContainsKey('Token')) { $realArgs['Token'] = $Token }
            if ($Invoker) { $realArgs['Invoker'] = $Invoker }
            if ($Sleep) { $realArgs['Sleep'] = $Sleep }
            $rawRows = @(& $invokeReal @realArgs)
        }
    }
    catch {
        $sw.Stop()
        Write-MasterDataLog -Level ERROR -HotelCode $hotelCode -BatchId $BatchId -Message (
            "{0} extraction FAILED after {1}ms: {2}" -f $Type, $sw.ElapsedMilliseconds, $_.Exception.Message)
        throw
    }
    $sw.Stop()

    $rawCount = @($rawRows).Count
    Write-MasterDataLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "{0} fetched {1} raw row(s) in {2}ms." -f $Type, $rawCount, $sw.ElapsedMilliseconds)

    # --- Missing-data handling (subtasks 7 & 8) ------------------------------
    if ($rawCount -eq 0) {
        if ($Type -eq 'Channels') {
            # OPTIONAL / best-effort: skip WITHOUT failing the run.
            Write-MasterDataLog -Level WARN -HotelCode $hotelCode -BatchId $BatchId -Message (
                "Channels (distribution channel) list is unavailable/absent — skipping without error (optional dimension).")
            return @()
        }
        if ($required) {
            Write-MasterDataLog -Level ERROR -HotelCode $hotelCode -BatchId $BatchId -Message (
                "{0} list is empty/unavailable — this is a required dimension." -f $Type)
            throw ("Get-MasterData: required master dimension '{0}' returned no rows for hotel '{1}'." -f $Type, $hotelCode)
        }
    }

    # --- Map raw rows -> flat target-shaped PSCustomObjects ------------------
    $mapped = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in $rawRows) {
        if ($null -eq $raw) { continue }
        [void]$mapped.Add((ConvertTo-MasterDataRow -Type $Type -Raw $raw -Hotel $Hotel -BatchId $BatchId))
    }

    # --- Change detection + logging (subtask 9) ------------------------------
    if ($CurrentRecordsProvider) {
        try {
            $current = @(& $CurrentRecordsProvider @{ Type = $target; Hotel = $Hotel })
            Write-MasterDataChangeLog -Type $Type -Mapped $mapped.ToArray() -CurrentRecords $current -HotelCode $hotelCode -BatchId $BatchId
        }
        catch {
            # Change detection is advisory — a provider failure must not fail extraction.
            Write-MasterDataLog -Level WARN -HotelCode $hotelCode -BatchId $BatchId -Message (
                "{0} change detection skipped (CurrentRecordsProvider failed): {1}" -f $Type, $_.Exception.Message)
        }
    }

    Write-MasterDataLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "{0} extraction complete: {1} row(s) mapped to ra.{2} ({3} mode)." -f $Type, $mapped.Count, $target, $mode)

    # Return a real [array]. Unary comma prevents pipeline unwrap of a single-row result;
    # an empty result returns a genuinely empty array (no phantom wrapper element).
    $flat = [object[]]$mapped.ToArray()
    if ($flat.Count -eq 0) { return @() }
    return , $flat
}

# Design consistency: design.md names the function Get-DIM. Expose it as an alias so
# both the design name and the Task 13 name (Get-MasterData) resolve.
Set-Alias -Name 'Get-DIM' -Value 'Get-MasterData'

# ------------------------------------------------------------------------------
# Exported surface
# ------------------------------------------------------------------------------
Export-ModuleMember -Function @('Get-MasterData') -Alias @('Get-DIM')
