# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Block Reservations (BLK) snapshot query module for the OPERA R&A Data Loader (Task 11).

.DESCRIPTION
    Extracts the forward-looking group-block picture (contracted / picked-up / remaining
    rooms per block per future stay date) from the OHIP R&A Data API for a single business
    date (the SNAPSHOT_DATE) and returns a normalised flat [array] of [PSCustomObject] rows
    ready to hand to SqlWriter\Write-BlockReservations (Write-BLK) which MERGEs into ra.BLK.

    Subject Area : BookingsBlock
    Operation    : bookingsBlock
    Primary view : blockDetails
                   Mandatory filters: resort (_in), consideredDate range (= block stay /
                   grid date / CONSIDERED_DATE) over the snapshot horizon.
    Target table : ra.BLK  (alias ra.BlockReservations)

    Like OTB (and unlike the transactional RES / FIN modules which chunk a business-date
    range), BLK is a daily SNAPSHOT of the future as it stands on ONE business date:
      - SNAPSHOT_DATE   = the run's business date (set by the loader from -SnapshotDate).
      - CONSIDERED_DATE = a future block stay/grid date the row describes (from the response,
                          GraphQL field blockIdDate).

    Pipeline (design.md — Queries\BlockReservations.psm1):
      1. Get-BlockReservations -Hotel -SnapshotDate -FutureDays is the public entry point.
      2. DateHelper\Get-SnapshotHorizon (HorizonType 'Block') resolves
         @{ SnapshotDate; ConsideredDateStart; ConsideredDateEnd } from the hotel +
         SnapshotDate (+ FutureDays / blockFutureDays). This is the forward window.
      3. A GraphQL variables set is built with ISO 'YYYY-MM-DD' date filters
         (resort _in, consideredDate _gte/_lte over the horizon). NOTE: request filters
         keep ISO 'YYYY-MM-DD' — they are NOT the compact YYYYMMDD output format.
      4. The request is passed to ApiClient\Invoke-RASubjectArea, which issues the
         GraphQL POST (honouring throttle + backoff) and accumulates the rows into ONE
         flat [array].
      5. Each raw API row is mapped to the OPERA-native ra.BLK column contract
         (RESORT, CHAIN_CODE, SNAPSHOT_DATE, CONSIDERED_DATE, BLOCK_CODE, BLOCK_NAME,
         ROOM_CATEGORY_LABEL, MARKET_CODE, SOURCE_CODE, RATE_CODE, RATE_CATEGORY,
         CUTOFF_DATE, IS_PAST_CUTOFF, ROOMS_CONTRACTED, ROOMS_PICKEDUP, ROOMS_REMAINING,
         revenue/tax columns, BATCH_ID). Date-only output fields (SNAPSHOT_DATE,
         CONSIDERED_DATE, CUTOFF_DATE) are formatted with DateHelper\Format-OutputDate
         (YYYYMMDD).

    Derived measures (design.md / field-mapping.md):
      - SNAPSHOT_DATE is the run's business date — set HERE from -SnapshotDate for every
        row (the API row carries only the future block stay/considered date).
      - ROOMS_REMAINING = ROOMS_CONTRACTED - ROOMS_PICKEDUP. Computed ONLY when the API
        omits it (null-guarded); an API-supplied value is never overwritten.
      - IS_PAST_CUTOFF = 1 when the raw CUTOFF_DATE (date-only) < SNAPSHOT_DATE (date-only),
        else 0. Computed HERE from the RAW dates BEFORE output formatting so it is correct
        before persistence. NOTE: SqlWriter\Write-BLK also computes IS_PAST_CUTOFF
        defensively; computing it here keeps the two in agreement. A single WARN carrying
        the count of past-cutoff rows is emitted when that count > 0.

    Business-date / snapshot-horizon / missing-data behaviour (steering):
      - Business/considered/cutoff dates are date-only; filters and *_DATE outputs carry no
        time-of-day.
      - Missing / empty source values are emitted as $null consistently and never crash
        the mapper (fallback logic). A blank RESORT in a row is backfilled from the hotel
        code (the resort filter is mandatory).

    Test seam (unit-testable without network):
      -SubjectAreaInvoker : a scriptblock invoked INSTEAD of the real
                            ApiClient\Invoke-RASubjectArea. It receives a single
                            hashtable of the arguments this module would have passed
                            (Operation, PrimaryView, Query, Chunks, Hotel, Token, Config)
                            and must return an [array] of raw row objects. When omitted
                            the real Invoke-RASubjectArea is used.
      -Invoker / -Sleep   : forwarded to the real Invoke-RASubjectArea (HTTP + throttle
                            seams) when -SubjectAreaInvoker is not supplied.

.NOTES
    Logger -Module constant: "BlockReservations".
#>

# ------------------------------------------------------------------------------
# Best-effort imports. Resolved by name at call time too, so the module still loads
# in isolated unit tests where dependencies may be injected via seams.
# ------------------------------------------------------------------------------
$script:DateHelperPath = Join-Path -Path $PSScriptRoot -ChildPath '..\DateHelper.psm1'
$script:ApiClientPath = Join-Path -Path $PSScriptRoot -ChildPath '..\ApiClient.psm1'
foreach ($dep in @($script:DateHelperPath, $script:ApiClientPath)) {
    if (Test-Path -LiteralPath $dep) {
        Import-Module $dep -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------------------
# GraphQL operation constants (design.md Subject Area -> Query mapping).
# BLK | BookingsBlock | bookingsBlock | blockDetails -> ra.BLK.
# ------------------------------------------------------------------------------
$script:BlkOperation   = 'bookingsBlock'
$script:BlkPrimaryView = 'blockDetails'
$script:BlkDefaultFutureDays = 180   # extraction.defaultBlockFutureDays fallback

# ------------------------------------------------------------------------------
# Logging helper — shared Logger when loaded, else Write-Verbose. Never throws.
# ------------------------------------------------------------------------------
function Write-BlkLog {
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
            & $writeLog -Level $Level -Module 'BlockReservations' -Message $Message -HotelCode $HotelCode -BatchId $BatchId
            return
        }
        catch {
            # A logger failure must never break extraction — fall through to verbose.
        }
    }

    Write-Verbose ("BlockReservations [{0}] {1}: {2}" -f $Level, $HotelCode, $Message)
}

# ------------------------------------------------------------------------------
# Internal: case-insensitive lookup from a hashtable / PSCustomObject.
# ------------------------------------------------------------------------------
function Get-BlkValue {
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
function ConvertTo-BlkString {
    [CmdletBinding()]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text.Trim()
}

# ------------------------------------------------------------------------------
# Internal: normalise a raw API value to a nullable [decimal] (numeric measures).
# Returns $null for null/empty/non-numeric so downstream maths can guard cleanly.
# ------------------------------------------------------------------------------
function ConvertTo-BlkDecimal {
    [CmdletBinding()]
    [OutputType([Nullable[decimal]])]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    if ($Value -is [decimal]) { return [decimal]$Value }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [int] -or $Value -is [long]) {
        return [decimal]$Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsed = [decimal]0
    if ([decimal]::TryParse($text, [System.Globalization.NumberStyles]::Any,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    if ([decimal]::TryParse($text, [System.Globalization.NumberStyles]::Any,
            [System.Globalization.CultureInfo]::CurrentCulture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

# ------------------------------------------------------------------------------
# Internal: normalise a raw API value to a nullable [int] (room counts).
# ------------------------------------------------------------------------------
function ConvertTo-BlkInt {
    [CmdletBinding()]
    [OutputType([Nullable[int]])]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    $dec = ConvertTo-BlkDecimal -Value $Value
    if ($null -eq $dec) { return $null }
    try {
        return [int][math]::Round([decimal]$dec, 0, [System.MidpointRounding]::AwayFromZero)
    }
    catch {
        return $null
    }
}

# ------------------------------------------------------------------------------
# Internal: coerce a raw value to a date-only [datetime], or $null for "no value".
# Used to compare CUTOFF_DATE vs SNAPSHOT_DATE for IS_PAST_CUTOFF on the RAW dates
# (before output formatting). Uses DateHelper's parsing rules when available.
# ------------------------------------------------------------------------------
function ConvertTo-BlkDate {
    [CmdletBinding()]
    [OutputType([Nullable[datetime]])]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    if ($Value -is [datetime]) { return [datetime]([datetime]$Value).Date }
    if ($Value -is [System.DateTimeOffset]) { return ([System.DateTimeOffset]$Value).DateTime.Date }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed.Date
    }
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::CurrentCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed.Date
    }
    return $null
}

# ------------------------------------------------------------------------------
# Internal: build the BLK GraphQL query string (fields per design.md field map).
# ------------------------------------------------------------------------------
function Get-BlkGraphQlQuery {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Request only the fields we map (avoid over-fetching — design GraphQL rules).
    # blockIdDate is the CONSIDERED_DATE (future block stay/grid date).
    $fields = @(
        'resort', 'blockIdDate', 'blockCode', 'blockName',
        'roomCategoryLabel', 'marketCode', 'sourceCode', 'rateCode', 'rateCategory',
        'cutoffDate',
        'blockedRooms', 'pickedUpRooms', 'roomsRemaining',
        # Revenue — Gross
        'roomRevenue', 'foodRevenue', 'otherRevenue', 'totalRevenue', 'nonRevenue',
        # Revenue — Net
        'netRoomRevenue', 'netFoodRevenue', 'netOtherRevenue', 'netTotalRevenue',
        # Tax
        'roomRevenueTax', 'foodRevenueTax', 'otherRevenueTax', 'totalRevenueTax'
    ) -join ' '

    $view = $script:BlkPrimaryView
    $op = $script:BlkOperation

    return ("query BookingsBlock(`$input: BookingsBlockQueryArgumentsType!) " +
        "{ $op(input: `$input) { $view { $fields } } }")
}

# ------------------------------------------------------------------------------
# Internal: build the GraphQL variables set for the BLK snapshot horizon.
# Request filters use ISO 'YYYY-MM-DD' (NOT the YYYYMMDD output format). The
# consideredDate range spans the forward window (= block stay/grid date =
# CONSIDERED_DATE = blockIdDate).
# ------------------------------------------------------------------------------
function New-BlkHorizonVariables {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $ResortCode,
        [Parameter(Mandatory)] [datetime] $ConsideredDateStart,
        [Parameter(Mandatory)] [datetime] $ConsideredDateEnd
    )

    $iso = [System.Globalization.CultureInfo]::InvariantCulture
    $startIso = $ConsideredDateStart.ToString('yyyy-MM-dd', $iso)
    $endIso = $ConsideredDateEnd.ToString('yyyy-MM-dd', $iso)

    return @{
        input = @{
            resort         = @{ _in = @($ResortCode) }
            consideredDate = @{ _gte = $startIso; _lte = $endIso }
        }
    }
}

# ------------------------------------------------------------------------------
# Internal: map ONE raw API row to a flat ra.BLK-shaped [PSCustomObject].
# SnapshotDate is passed in (the run's business date, date-only); the row supplies the
# future CONSIDERED_DATE (block stay/grid date). Emits a PastCutoff flag on the object
# so the caller can total a single WARN. The returned SNAPSHOT_DATE/CONSIDERED_DATE/
# CUTOFF_DATE are YYYYMMDD-formatted; IS_PAST_CUTOFF is computed from the RAW dates.
# ------------------------------------------------------------------------------
function ConvertTo-BlkRow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)] $Hotel,
        [Parameter(Mandatory)] [datetime] $SnapshotDate,
        [Parameter()] [AllowNull()] [guid] $BatchId = [guid]::Empty
    )

    $resort = ConvertTo-BlkString (Get-BlkValue -Source $Raw -Names @('resort'))
    if ($null -eq $resort) {
        # Fallback: resort filter is mandatory, so a blank resort in the row is
        # backfilled from the hotel code rather than dropped.
        $resort = ConvertTo-BlkString (Get-BlkValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    }
    $chainCode = ConvertTo-BlkString (Get-BlkValue -Source $Hotel -Names @('ChainCode', 'chainCode'))

    # --- Date fields (RAW, date-only) ----------------------------------------
    # CONSIDERED_DATE is the future block stay/grid date from the response (blockIdDate).
    $consideredRaw = Get-BlkValue -Source $Raw -Names @('blockIdDate', 'consideredDate', 'stayDate')
    $cutoffRaw = Get-BlkValue -Source $Raw -Names @('cutoffDate')

    $snapshotDateOnly = $SnapshotDate.Date
    $cutoffDateOnly = ConvertTo-BlkDate $cutoffRaw

    # --- IS_PAST_CUTOFF — computed from RAW dates BEFORE formatting -----------
    # 1 when CUTOFF_DATE (date-only) is strictly before SNAPSHOT_DATE (date-only), else 0.
    $isPastCutoff = 0
    if ($null -ne $cutoffDateOnly -and $cutoffDateOnly -lt $snapshotDateOnly) {
        $isPastCutoff = 1
    }

    # --- Output date formatting via DateHelper (YYYYMMDD) --------------------
    $fmtDate = Get-Command -Name 'Format-OutputDate' -ErrorAction SilentlyContinue
    $formatDate = {
        param($v)
        if ($fmtDate) { return [string](& $fmtDate $v) }
        $dt = $v -as [datetime]; if ($null -eq $dt) { return '' }
        return $dt.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    # --- Room counts ---------------------------------------------------------
    $roomsContracted = ConvertTo-BlkInt (Get-BlkValue -Source $Raw -Names @('blockedRooms', 'roomsContracted'))
    $roomsPickedUp = ConvertTo-BlkInt (Get-BlkValue -Source $Raw -Names @('pickedUpRooms', 'roomsPickedUp'))

    # --- ROOMS_REMAINING = ROOMS_CONTRACTED - ROOMS_PICKEDUP ------------------
    # Only compute when the API omits it — never overwrite an API-supplied value.
    # Null-guarded: compute only when both operands are present.
    $roomsRemaining = ConvertTo-BlkInt (Get-BlkValue -Source $Raw -Names @('roomsRemaining', 'remainingRooms'))
    if ($null -eq $roomsRemaining -and $null -ne $roomsContracted -and $null -ne $roomsPickedUp) {
        $roomsRemaining = [int]$roomsContracted - [int]$roomsPickedUp
    }

    $row = [PSCustomObject][ordered]@{
        # Identity / join keys
        RESORT              = $resort
        CHAIN_CODE          = $chainCode
        # SNAPSHOT_DATE is the run's business date (set by the loader from -SnapshotDate).
        SNAPSHOT_DATE       = (& $formatDate $snapshotDateOnly)
        # CONSIDERED_DATE is the future block stay/grid date from the response.
        CONSIDERED_DATE     = (& $formatDate $consideredRaw)
        # Block header
        BLOCK_CODE          = (ConvertTo-BlkString (Get-BlkValue -Source $Raw -Names @('blockCode')))
        BLOCK_NAME          = (ConvertTo-BlkString (Get-BlkValue -Source $Raw -Names @('blockName')))
        ROOM_CATEGORY_LABEL = (ConvertTo-BlkString (Get-BlkValue -Source $Raw -Names @('roomCategoryLabel')))
        MARKET_CODE         = (ConvertTo-BlkString (Get-BlkValue -Source $Raw -Names @('marketCode')))
        SOURCE_CODE         = (ConvertTo-BlkString (Get-BlkValue -Source $Raw -Names @('sourceCode')))
        RATE_CODE           = (ConvertTo-BlkString (Get-BlkValue -Source $Raw -Names @('rateCode')))
        RATE_CATEGORY       = (ConvertTo-BlkString (Get-BlkValue -Source $Raw -Names @('rateCategory')))
        CUTOFF_DATE         = (& $formatDate $cutoffRaw)
        IS_PAST_CUTOFF      = $isPastCutoff
        # Room counts
        ROOMS_CONTRACTED    = $roomsContracted
        ROOMS_PICKEDUP      = $roomsPickedUp
        ROOMS_REMAINING     = $roomsRemaining
        # Revenue — Gross (incl. VAT)
        ROOM_REVENUE        = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('roomRevenue')))
        FOOD_REVENUE        = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('foodRevenue')))
        OTHER_REVENUE       = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('otherRevenue')))
        TOTAL_REVENUE       = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('totalRevenue')))
        NON_REVENUE         = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('nonRevenue')))
        # Revenue — Net (excl. VAT)
        NET_ROOM_REVENUE    = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('netRoomRevenue')))
        NET_FOOD_REVENUE    = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('netFoodRevenue')))
        NET_OTHER_REVENUE   = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('netOtherRevenue')))
        NET_TOTAL_REVENUE   = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('netTotalRevenue')))
        # Tax amounts
        ROOM_REVENUE_TAX    = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('roomRevenueTax')))
        FOOD_REVENUE_TAX    = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('foodRevenueTax')))
        OTHER_REVENUE_TAX   = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('otherRevenueTax')))
        TOTAL_REVENUE_TAX   = (ConvertTo-BlkDecimal (Get-BlkValue -Source $Raw -Names @('totalRevenueTax')))
        # Audit
        BATCH_ID            = $BatchId
    }

    return $row
}

# ------------------------------------------------------------------------------
# Public: Get-BlockReservations
# ------------------------------------------------------------------------------
function Get-BlockReservations {
    <#
    .SYNOPSIS
        Extracts the Block Reservations (BLK) future snapshot for a hotel as of a single
        business date and returns a normalised flat [array] of ra.BLK-shaped
        [PSCustomObject] rows.

    .DESCRIPTION
        Resolves the forward snapshot horizon via Get-SnapshotHorizon (HorizonType 'Block';
        SnapshotDate, ConsideredDateStart, ConsideredDateEnd), builds one
        ISO-'YYYY-MM-DD'-filtered GraphQL variables set (resort _in, consideredDate
        _gte/_lte over the horizon), calls Invoke-RASubjectArea (which accumulates the rows
        into one array), maps each row to the ra.BLK column contract, stamps SNAPSHOT_DATE
        from -SnapshotDate, formats date-only output fields (YYYYMMDD), computes
        ROOMS_REMAINING = ROOMS_CONTRACTED - ROOMS_PICKEDUP (null-guarded) when the API omits
        it, computes IS_PAST_CUTOFF (CUTOFF_DATE < SNAPSHOT_DATE) from the raw dates, and
        logs the snapshot date, considered-date range, total row count, and — when > 0 — a
        single WARN with the past-cutoff row count.

    .PARAMETER Hotel
        Hotel configuration (hashtable / PSCustomObject). Recognised keys (case-insensitive):
        HotelCode (RESORT), ChainCode, TimeZoneId, nightAuditHour, blockFutureDays.

    .PARAMETER SnapshotDate
        The run's business date (the SNAPSHOT_DATE stamped on every row). Date component
        only. Optional; when omitted Get-SnapshotHorizon derives it via Get-BusinessDate.

    .PARAMETER FutureDays
        Number of days to look forward from the snapshot date (>= 0). Optional; defaults to
        the hotel's blockFutureDays, then Config.extraction.defaultBlockFutureDays, then 180.

    .PARAMETER Token
        Optional bearer token forwarded to the API layer. When omitted the API layer
        obtains one via Get-OAuthToken.

    .PARAMETER Config
        Optional settings object supplying extraction.defaultBlockFutureDays and api.*
        throttle/retry settings.

    .PARAMETER BatchId
        Optional batch GUID stamped on every output row (BATCH_ID) and used in log context.

    .PARAMETER SubjectAreaInvoker
        Optional test/DI seam invoked INSTEAD of Invoke-RASubjectArea. Receives a single
        hashtable (@{ Operation; PrimaryView; Query; Chunks; Hotel; Token; Config }) and
        must return an [array] of raw row objects. Enables unit testing without network.

    .PARAMETER Invoker
        Optional HTTP seam forwarded to the real Invoke-RASubjectArea.

    .PARAMETER Sleep
        Optional throttle/backoff seam forwarded to the real Invoke-RASubjectArea.

    .OUTPUTS
        [array] of [PSCustomObject] matching the ra.BLK schema.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] $Hotel,
        [Parameter()] [AllowNull()] [Nullable[datetime]] $SnapshotDate = $null,
        [Parameter()] [ValidateRange(0, [int]::MaxValue)] [Nullable[int]] $FutureDays = $null,
        [Parameter()] [string] $Token,
        [Parameter()] $Config,
        [Parameter()] [guid] $BatchId = [guid]::Empty,
        [Parameter()] [scriptblock] $SubjectAreaInvoker,
        [Parameter()] [scriptblock] $Invoker,
        [Parameter()] [scriptblock] $Sleep
    )

    $hotelCode = [string](Get-BlkValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    if ([string]::IsNullOrWhiteSpace($hotelCode)) {
        throw 'Get-BlockReservations: Hotel config is missing a HotelCode.'
    }

    # --- Resolve the forward snapshot horizon (SnapshotDate + considered range) ---
    # Get-SnapshotHorizon requires a [hashtable]; project the hotel into one keyed with
    # the lowercase keys it recognises (hotelCode/timeZoneId/nightAuditHour/blockFutureDays).
    $getHorizon = Get-Command -Name 'Get-SnapshotHorizon' -ErrorAction SilentlyContinue
    if (-not $getHorizon) {
        throw 'Get-BlockReservations: Get-SnapshotHorizon (DateHelper.psm1) is not available.'
    }

    $horizonHotel = @{ hotelCode = $hotelCode }
    $tz = Get-BlkValue -Source $Hotel -Names @('TimeZoneId', 'timeZoneId')
    if ($null -ne $tz) { $horizonHotel['timeZoneId'] = [string]$tz }
    $nah = Get-BlkValue -Source $Hotel -Names @('NightAuditHour', 'nightAuditHour')
    if ($null -ne $nah) { $horizonHotel['nightAuditHour'] = $nah }
    $blockFuture = Get-BlkValue -Source $Hotel -Names @('BlockFutureDays', 'blockFutureDays')
    if ($null -ne $blockFuture) { $horizonHotel['blockFutureDays'] = $blockFuture }

    # FutureDays priority: parameter > hotel.blockFutureDays (handled by Get-SnapshotHorizon)
    # > Config.extraction.defaultBlockFutureDays > 180. Only supply a default here when the
    # hotel itself did not configure blockFutureDays.
    $effectiveFutureDays = $null
    if ($PSBoundParameters.ContainsKey('FutureDays') -and $null -ne $FutureDays) {
        $effectiveFutureDays = [int]$FutureDays
    }
    elseif (-not $horizonHotel.ContainsKey('blockFutureDays')) {
        $effectiveFutureDays = $script:BlkDefaultFutureDays
        if ($null -ne $Config) {
            $extraction = Get-BlkValue -Source $Config -Names @('extraction')
            $cfgFuture = if ($null -ne $extraction) {
                Get-BlkValue -Source $extraction -Names @('defaultBlockFutureDays', 'blockFutureDays')
            }
            else {
                Get-BlkValue -Source $Config -Names @('defaultBlockFutureDays', 'blockFutureDays')
            }
            $parsed = 0
            if ($null -ne $cfgFuture -and [int]::TryParse([string]$cfgFuture, [ref]$parsed) -and $parsed -ge 0) {
                $effectiveFutureDays = $parsed
            }
        }
    }

    $horizonArgs = @{ Hotel = $horizonHotel; HorizonType = 'Block' }
    if ($null -ne $SnapshotDate) { $horizonArgs['SnapshotDate'] = [datetime]$SnapshotDate }
    if ($null -ne $effectiveFutureDays) { $horizonArgs['FutureDays'] = $effectiveFutureDays }

    $horizon = & $getHorizon @horizonArgs
    $snapshot = [datetime]$horizon.SnapshotDate
    $consideredStart = [datetime]$horizon.ConsideredDateStart
    $consideredEnd = [datetime]$horizon.ConsideredDateEnd

    Write-BlkLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "SA=BookingsBlock snapshot={0:yyyy-MM-dd} consideredRange={1:yyyy-MM-dd}..{2:yyyy-MM-dd}" -f `
            $snapshot, $consideredStart, $consideredEnd)

    $query = Get-BlkGraphQlQuery
    $variables = New-BlkHorizonVariables -ResortCode $hotelCode -ConsideredDateStart $consideredStart -ConsideredDateEnd $consideredEnd

    # --- Invoke the API layer (single snapshot request; one flat array) -------
    $invokeReal = Get-Command -Name 'Invoke-RASubjectArea' -ErrorAction SilentlyContinue
    if (-not $SubjectAreaInvoker -and -not $invokeReal) {
        throw 'Get-BlockReservations: Invoke-RASubjectArea (ApiClient.psm1) is not available and no -SubjectAreaInvoker seam was supplied.'
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $saArgs = @{
        Operation   = $script:BlkOperation
        PrimaryView = $script:BlkPrimaryView
        Query       = $query
        Chunks      = @(@{ Variables = $variables })
        Hotel       = $Hotel
        Config      = $Config
    }
    if ($PSBoundParameters.ContainsKey('Token') -and -not [string]::IsNullOrWhiteSpace($Token)) {
        $saArgs['Token'] = $Token
    }

    $rawRows = @()
    try {
        if ($SubjectAreaInvoker) {
            $rawRows = @(& $SubjectAreaInvoker $saArgs)
        }
        else {
            $realArgs = @{
                Hotel       = $Hotel
                Operation   = $script:BlkOperation
                PrimaryView = $script:BlkPrimaryView
                Query       = $query
                Chunks      = @(@{ Variables = $variables })
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
        Write-BlkLog -Level ERROR -HotelCode $hotelCode -BatchId $BatchId -Message (
            "snapshot {0:yyyy-MM-dd} consideredRange={1:yyyy-MM-dd}..{2:yyyy-MM-dd} FAILED after {3}ms: {4}" -f `
                $snapshot, $consideredStart, $consideredEnd, $sw.ElapsedMilliseconds, $_.Exception.Message)
        throw
    }
    $sw.Stop()

    # --- Map raw rows -> flat ra.BLK PSCustomObjects -------------------------
    $mapped = [System.Collections.Generic.List[object]]::new()
    $pastCutoffCount = 0
    foreach ($raw in $rawRows) {
        if ($null -eq $raw) { continue }
        $row = ConvertTo-BlkRow -Raw $raw -Hotel $Hotel -SnapshotDate $snapshot -BatchId $BatchId
        if ($row.IS_PAST_CUTOFF -eq 1) { $pastCutoffCount++ }
        [void]$mapped.Add($row)
    }

    # --- Single WARN carrying the past-cutoff row count (only when > 0) -------
    if ($pastCutoffCount -gt 0) {
        Write-BlkLog -Level WARN -HotelCode $hotelCode -BatchId $BatchId -Message (
            "{0} block row(s) are past cutoff (CUTOFF_DATE < SNAPSHOT_DATE {1:yyyy-MM-dd}); IS_PAST_CUTOFF=1 set." -f `
                $pastCutoffCount, $snapshot)
    }

    # --- One INFO line: snapshot date, considered range, total row count ------
    Write-BlkLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "BLK snapshot complete: hotel={0} snapshot={1:yyyy-MM-dd} consideredRange={2:yyyy-MM-dd}..{3:yyyy-MM-dd} rows={4} pastCutoff={5} ({6}ms)." -f `
            $hotelCode, $snapshot, $consideredStart, $consideredEnd, $mapped.Count, $pastCutoffCount, $sw.ElapsedMilliseconds)

    # Return a real [array] even for 0/1 rows (unary comma prevents pipeline unwrap).
    $flat = [object[]]$mapped.ToArray()
    return , $flat
}

# Design consistency: design.md names the function Get-BLK. Expose it as an alias so
# both the design name (Get-BLK) and the Task 11 name (Get-BlockReservations) resolve.
Set-Alias -Name 'Get-BLK' -Value 'Get-BlockReservations'

# ------------------------------------------------------------------------------
# Exported surface
# ------------------------------------------------------------------------------
Export-ModuleMember -Function @('Get-BlockReservations') -Alias @('Get-BLK')
