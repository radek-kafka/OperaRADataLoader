# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    On-The-Books (OTB) snapshot query module for the OPERA R&A Data Loader (Task 10).

.DESCRIPTION
    Extracts the forward-looking on-the-books occupancy/revenue forecast from the OHIP
    R&A Data API for a single business date (the SNAPSHOT_DATE) and returns a normalised
    flat [array] of [PSCustomObject] rows ready to hand to SqlWriter\Write-OnTheBooks
    (Write-OTB) which MERGEs into ra.OTB.

    Subject Area : StatisticsForecastSummary
    Operation    : statisticsForecastSummary
    Primary view : forecastSummaryDetails
                   Mandatory filters: resort (_in), consideredDate range (= stay date /
                   CONSIDERED_DATE) over the snapshot horizon.
    Target table : ra.OTB  (alias ra.OnTheBooks)

    Unlike the transactional RES / FIN modules (which chunk a business-date range), OTB is
    a daily SNAPSHOT of the future as it stands on ONE business date:
      - SNAPSHOT_DATE  = the run's business date (set by the loader from -SnapshotDate).
      - CONSIDERED_DATE = a future stay date the row describes (from the response).

    Pipeline (design.md — Queries\OnTheBooks.psm1):
      1. Get-OnTheBooks -Hotel -SnapshotDate -FutureDays is the public entry point.
      2. DateHelper\Get-SnapshotHorizon (HorizonType 'Otb') resolves
         @{ SnapshotDate; ConsideredDateStart; ConsideredDateEnd } from the hotel +
         SnapshotDate (+ FutureDays / otbFutureDays). This is the forward window.
      3. A GraphQL variables set is built with ISO 'YYYY-MM-DD' date filters
         (resort _in, consideredDate _gte/_lte over the horizon). NOTE: request filters
         keep ISO 'YYYY-MM-DD' — they are NOT the compact YYYYMMDD output format.
      4. The request is passed to ApiClient\Invoke-RASubjectArea, which issues the
         GraphQL POST (honouring throttle + backoff) and accumulates the rows into ONE
         flat [array].
      5. Each raw API row is mapped to the OPERA-native ra.OTB column contract
         (RESORT, SNAPSHOT_DATE, CONSIDERED_DATE, MARKET_CODE, ROOM_CATEGORY_LABEL,
         SOURCE_CODE, CHANNEL, NO_ROOMS, TENTATIVE_ROOMS, DEFINITE_ROOMS, ADR_ON_BOOKS,
         REVENUE_ON_BOOKS, revenue/tax columns, ...). Date-only output fields
         (SNAPSHOT_DATE, CONSIDERED_DATE, TRUNC_BEGIN_DATE, TRUNC_END_DATE) are formatted
         with DateHelper\Format-OutputDate (YYYYMMDD).

    Derived measures (design.md):
      - SNAPSHOT_DATE is the run's business date — set HERE from -SnapshotDate for every
        row (the API row carries only the future stay/considered date).
      - TENTATIVE_ROOMS / DEFINITE_ROOMS split NO_ROOMS by the tentative/definite grain
        (RESV_TYPE / RESV_STATUS). A DEDUCED/6/PROSPECT-style status is treated as
        tentative; a DEFINITE/CONFIRMED/ACTUAL-style status (or Group RESV_TYPE 'G') as
        definite. These are computed ONLY when the API does not already supply the value.
      - ADR_ON_BOOKS = ROOM_REVENUE / NO_ROOMS (divide-by-zero guarded); computed ONLY
        when the API omits it — never overwrite an API-supplied value.
      - REVENUE_ON_BOOKS = TOTAL_REVENUE (else ROOM_REVENUE); computed ONLY when omitted.

    Business-date / snapshot-horizon / missing-data behaviour (steering):
      - Business/considered dates are date-only; filters and *_DATE outputs carry no
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
    Logger -Module constant: "OnTheBooks".
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
# GraphQL operation constants (design.md Subject Area -> Query mapping)
# ------------------------------------------------------------------------------
$script:OtbOperation   = 'statisticsForecastSummary'
$script:OtbPrimaryView = 'forecastSummaryDetails'
$script:OtbDefaultFutureDays = 365   # extraction.defaultOtbFutureDays fallback

# ------------------------------------------------------------------------------
# Logging helper — shared Logger when loaded, else Write-Verbose. Never throws.
# ------------------------------------------------------------------------------
function Write-OtbLog {
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
            & $writeLog -Level $Level -Module 'OnTheBooks' -Message $Message -HotelCode $HotelCode -BatchId $BatchId
            return
        }
        catch {
            # A logger failure must never break extraction — fall through to verbose.
        }
    }

    Write-Verbose ("OnTheBooks [{0}] {1}: {2}" -f $Level, $HotelCode, $Message)
}

# ------------------------------------------------------------------------------
# Internal: case-insensitive lookup from a hashtable / PSCustomObject.
# ------------------------------------------------------------------------------
function Get-OtbValue {
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
function ConvertTo-OtbString {
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
function ConvertTo-OtbDecimal {
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
# Internal: normalise a raw API value to a nullable [int] (room/person counts).
# ------------------------------------------------------------------------------
function ConvertTo-OtbInt {
    [CmdletBinding()]
    [OutputType([Nullable[int]])]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    $dec = ConvertTo-OtbDecimal -Value $Value
    if ($null -eq $dec) { return $null }
    try {
        return [int][math]::Round([decimal]$dec, 0, [System.MidpointRounding]::AwayFromZero)
    }
    catch {
        return $null
    }
}

# ------------------------------------------------------------------------------
# Internal: safe divide with divide-by-zero / null guard.
# Returns $null when the denominator is null, zero, or the numerator is null.
# ------------------------------------------------------------------------------
function Get-OtbSafeQuotient {
    [CmdletBinding()]
    [OutputType([Nullable[decimal]])]
    param(
        [Parameter(Position = 0)] [AllowNull()] [Nullable[decimal]] $Numerator,
        [Parameter(Position = 1)] [AllowNull()] [Nullable[decimal]] $Denominator
    )

    if ($null -eq $Numerator) { return $null }
    if ($null -eq $Denominator -or [decimal]$Denominator -eq [decimal]0) { return $null }
    return [decimal]([decimal]$Numerator / [decimal]$Denominator)
}

# ------------------------------------------------------------------------------
# Internal: classify a reservation as tentative vs definite from RESV_STATUS /
# RESV_TYPE (design.md tentative/definite grain). Returns 'Tentative', 'Definite',
# or $null when it cannot be determined (so counts are not forced either way).
# ------------------------------------------------------------------------------
function Get-OtbBookingCertainty {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()] [AllowNull()] [string] $ResvStatus,
        [Parameter()] [AllowNull()] [string] $ResvType
    )

    $status = if ($null -ne $ResvStatus) { $ResvStatus.Trim().ToUpperInvariant() } else { '' }
    $type = if ($null -ne $ResvType) { $ResvType.Trim().ToUpperInvariant() } else { '' }

    # Definite: confirmed/actual/checked-in/departed stays, or a Group ('G') block pickup.
    if ($status -in @('DEFINITE', 'DEF', 'CONFIRMED', 'CONF', 'ACTUAL', 'RESERVED',
            'CHECKED IN', 'CHECKEDIN', 'INHOUSE', 'IN HOUSE', 'DEPARTED', 'CHECKED OUT')) {
        return 'Definite'
    }
    if ($type -eq 'G') { return 'Definite' }

    # Tentative: deduced/prospect/tentative demand and unconfirmed holds.
    if ($status -in @('TENTATIVE', 'TENT', 'DEDUCT', 'DEDUCTED', 'DEDUCED', 'PROSPECT',
            'INQUIRY', 'ENQUIRY', 'WAITLIST', 'WAIT LIST', 'UNCONFIRMED')) {
        return 'Tentative'
    }

    return $null
}

# ------------------------------------------------------------------------------
# Internal: build the OTB GraphQL query string (fields per design.md field map).
# ------------------------------------------------------------------------------
function Get-OtbGraphQlQuery {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Request only the fields we map (avoid over-fetching — design GraphQL rules).
    # stayDate/consideredDate is the CONSIDERED_DATE (future stay date).
    $fields = @(
        'resort', 'stayDate', 'consideredDate', 'eventType',
        'marketCode', 'sourceCode', 'channel', 'rateCode', 'rateCategory',
        'roomCategoryLabel', 'resvType', 'resvStatus', 'country', 'currencyCode',
        'truncBeginDate', 'truncEndDate',
        'arrRooms', 'depRooms', 'noRooms', 'dayUseRooms', 'dayUsePersons',
        'arrPersons', 'depPersons', 'adults', 'children', 'quantity', 'nights',
        'pseudoRoomYn', 'dayUseYn',
        # Derived / count fields (computed locally only when the API omits them).
        'tentativeRooms', 'definiteRooms', 'adrOnBooks', 'revenueOnBooks',
        # Revenue — Gross
        'grossRate', 'roomRevenue', 'foodRevenue', 'otherRevenue', 'totalRevenue', 'nonRevenue',
        # Revenue — Net
        'netRoomRevenue', 'extraRevenue',
        # Tax
        'roomRevenueTax', 'foodRevenueTax', 'otherRevenueTax', 'totalRevenueTax', 'nonRevenueTax'
    ) -join ' '

    $view = $script:OtbPrimaryView
    $op = $script:OtbOperation

    return ("query StatisticsForecastSummary(`$input: StatisticsForecastSummaryQueryArgumentsType!) " +
        "{ $op(input: `$input) { $view { $fields } } }")
}

# ------------------------------------------------------------------------------
# Internal: build the GraphQL variables set for the OTB snapshot horizon.
# Request filters use ISO 'YYYY-MM-DD' (NOT the YYYYMMDD output format). The
# consideredDate range spans the forward window (= stay date = CONSIDERED_DATE).
# ------------------------------------------------------------------------------
function New-OtbHorizonVariables {
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
# Internal: map ONE raw API row to a flat ra.OTB-shaped [PSCustomObject].
# SnapshotDate is passed in (the run's business date); the row supplies the future
# CONSIDERED_DATE (stay date).
# ------------------------------------------------------------------------------
function ConvertTo-OtbRow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)] $Hotel,
        [Parameter(Mandatory)] [datetime] $SnapshotDate,
        [Parameter()] [AllowNull()] [guid] $BatchId = [guid]::Empty
    )

    $resort = ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('resort'))
    if ($null -eq $resort) {
        # Fallback: resort filter is mandatory, so a blank resort in the row is
        # backfilled from the hotel code rather than dropped.
        $resort = ConvertTo-OtbString (Get-OtbValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    }
    $chainCode = ConvertTo-OtbString (Get-OtbValue -Source $Hotel -Names @('ChainCode', 'chainCode'))

    # --- Date fields ---------------------------------------------------------
    # CONSIDERED_DATE is the future stay date from the response (stayDate / consideredDate).
    $consideredDate = Get-OtbValue -Source $Raw -Names @('stayDate', 'consideredDate')
    $truncBegin = Get-OtbValue -Source $Raw -Names @('truncBeginDate')
    $truncEnd = Get-OtbValue -Source $Raw -Names @('truncEndDate')

    # --- Output date formatting via DateHelper (YYYYMMDD) --------------------
    $fmtDate = Get-Command -Name 'Format-OutputDate' -ErrorAction SilentlyContinue
    $formatDate = {
        param($v)
        if ($fmtDate) { return [string](& $fmtDate $v) }
        $dt = $v -as [datetime]; if ($null -eq $dt) { return '' }
        return $dt.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    # --- Dimensions used for derived measures --------------------------------
    $resvType = ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('resvType'))
    $resvStatus = ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('resvStatus'))
    $noRooms = ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('noRooms'))
    $roomRevenue = ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('roomRevenue'))
    $totalRevenue = ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('totalRevenue'))

    # --- TENTATIVE_ROOMS / DEFINITE_ROOMS — derived by RESV_TYPE/RESV_STATUS --
    # Only compute when the API did NOT already supply the value (don't overwrite).
    $tentativeRooms = ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('tentativeRooms'))
    $definiteRooms = ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('definiteRooms'))
    if ($null -eq $tentativeRooms -and $null -eq $definiteRooms -and $null -ne $noRooms) {
        $certainty = Get-OtbBookingCertainty -ResvStatus $resvStatus -ResvType $resvType
        if ($certainty -eq 'Tentative') {
            $tentativeRooms = $noRooms
            $definiteRooms = 0
        }
        elseif ($certainty -eq 'Definite') {
            $tentativeRooms = 0
            $definiteRooms = $noRooms
        }
        # else: certainty unknown — leave both $null rather than guessing.
    }

    # --- ADR_ON_BOOKS = ROOM_REVENUE / NO_ROOMS (divide-by-zero guarded) ------
    # Only compute when the API omits it — never overwrite an API-supplied value.
    $adrOnBooks = ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('adrOnBooks'))
    if ($null -eq $adrOnBooks) {
        $roomsDec = if ($null -ne $noRooms) { [Nullable[decimal]][decimal]$noRooms } else { $null }
        $adrOnBooks = Get-OtbSafeQuotient -Numerator $roomRevenue -Denominator $roomsDec
    }

    # --- REVENUE_ON_BOOKS = TOTAL_REVENUE (else ROOM_REVENUE) -----------------
    $revenueOnBooks = ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('revenueOnBooks'))
    if ($null -eq $revenueOnBooks) {
        $revenueOnBooks = if ($null -ne $totalRevenue) { $totalRevenue } else { $roomRevenue }
    }

    return [PSCustomObject][ordered]@{
        # Identity / join keys
        RESORT              = $resort
        CHAIN_CODE          = $chainCode
        # SNAPSHOT_DATE is the run's business date (set by the loader from -SnapshotDate).
        SNAPSHOT_DATE       = (& $formatDate $SnapshotDate)
        # CONSIDERED_DATE is the future stay date from the response.
        CONSIDERED_DATE     = (& $formatDate $consideredDate)
        # Dimensions
        MARKET_CODE         = (ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('marketCode')))
        SOURCE_CODE         = (ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('sourceCode')))
        CHANNEL             = (ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('channel')))
        RATE_CODE           = (ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('rateCode')))
        RATE_CATEGORY       = (ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('rateCategory')))
        ROOM_CATEGORY_LABEL = (ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('roomCategoryLabel')))
        RESV_TYPE           = $resvType
        EVENT_TYPE          = (ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('eventType')))
        COUNTRY             = (ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('country')))
        CURRENCY_CODE       = (ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('currencyCode', 'currency')))
        # Date range
        TRUNC_BEGIN_DATE    = (& $formatDate $truncBegin)
        TRUNC_END_DATE      = (& $formatDate $truncEnd)
        # Room / occupancy counts
        ARR_ROOMS           = (ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('arrRooms')))
        DEP_ROOMS           = (ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('depRooms')))
        NO_ROOMS            = $noRooms
        DAY_USE_ROOMS       = (ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('dayUseRooms')))
        DAY_USE_PERSONS     = (ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('dayUsePersons')))
        ARR_PERSONS         = (ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('arrPersons')))
        DEP_PERSONS         = (ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('depPersons')))
        ADULTS              = (ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('adults')))
        CHILDREN            = (ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('children')))
        QUANTITY            = (ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('quantity')))
        NIGHTS              = (ConvertTo-OtbInt (Get-OtbValue -Source $Raw -Names @('nights')))
        RESV_STATUS         = $resvStatus
        # Derived on-books measures
        TENTATIVE_ROOMS     = $tentativeRooms
        DEFINITE_ROOMS      = $definiteRooms
        ADR_ON_BOOKS        = $adrOnBooks
        REVENUE_ON_BOOKS    = $revenueOnBooks
        # Block rooms (sourced from ra.BLK — joined downstream; emitted $null here).
        REMAINING_BLOCK_ROOMS = $null
        PICKEDUP_BLOCK_ROOMS  = $null
        # Revenue — Gross (incl. VAT)
        GROSS_RATE          = (ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('grossRate')))
        ROOM_REVENUE        = $roomRevenue
        FOOD_REVENUE        = (ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('foodRevenue')))
        OTHER_REVENUE       = (ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('otherRevenue')))
        TOTAL_REVENUE       = $totalRevenue
        NON_REVENUE         = (ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('nonRevenue')))
        # Revenue — Net (excl. VAT)
        NET_ROOM_REVENUE    = (ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('netRoomRevenue')))
        EXTRA_REVENUE       = (ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('extraRevenue')))
        # Tax amounts
        ROOM_REVENUE_TAX    = (ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('roomRevenueTax')))
        FOOD_REVENUE_TAX    = (ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('foodRevenueTax')))
        OTHER_REVENUE_TAX   = (ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('otherRevenueTax')))
        TOTAL_REVENUE_TAX   = (ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('totalRevenueTax')))
        NON_REVENUE_TAX     = (ConvertTo-OtbDecimal (Get-OtbValue -Source $Raw -Names @('nonRevenueTax')))
        # Flags
        PSEUDO_ROOM_YN      = (ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('pseudoRoomYn')))
        DAY_USE_YN          = (ConvertTo-OtbString (Get-OtbValue -Source $Raw -Names @('dayUseYn')))
        # Audit
        BATCH_ID            = $BatchId
    }
}

# ------------------------------------------------------------------------------
# Public: Get-OnTheBooks
# ------------------------------------------------------------------------------
function Get-OnTheBooks {
    <#
    .SYNOPSIS
        Extracts the On-The-Books (OTB) future forecast snapshot for a hotel as of a single
        business date and returns a normalised flat [array] of ra.OTB-shaped
        [PSCustomObject] rows.

    .DESCRIPTION
        Resolves the forward snapshot horizon via Get-SnapshotHorizon (SnapshotDate,
        ConsideredDateStart, ConsideredDateEnd), builds one ISO-'YYYY-MM-DD'-filtered
        GraphQL variables set (resort _in, consideredDate _gte/_lte over the horizon),
        calls Invoke-RASubjectArea (which accumulates the rows into one array), maps each
        row to the ra.OTB column contract, stamps SNAPSHOT_DATE from -SnapshotDate, formats
        date-only output fields (YYYYMMDD), derives TENTATIVE_ROOMS/DEFINITE_ROOMS by the
        RESV_TYPE/RESV_STATUS grain and ADR_ON_BOOKS/REVENUE_ON_BOOKS (divide-by-zero
        guarded) when the API omits them, and logs the snapshot date, considered-date
        range, and total row count.

    .PARAMETER Hotel
        Hotel configuration (hashtable / PSCustomObject). Recognised keys (case-insensitive):
        HotelCode (RESORT), ChainCode, TimeZoneId, nightAuditHour, otbFutureDays.

    .PARAMETER SnapshotDate
        The run's business date (the SNAPSHOT_DATE stamped on every row). Date component
        only. Optional; when omitted Get-SnapshotHorizon derives it via Get-BusinessDate.

    .PARAMETER FutureDays
        Number of days to look forward from the snapshot date (>= 0). Optional; defaults to
        the hotel's otbFutureDays, then Config.extraction.defaultOtbFutureDays, then 365.

    .PARAMETER Token
        Optional bearer token forwarded to the API layer. When omitted the API layer
        obtains one via Get-OAuthToken.

    .PARAMETER Config
        Optional settings object supplying extraction.defaultOtbFutureDays and api.*
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
        [array] of [PSCustomObject] matching the ra.OTB schema.
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

    $hotelCode = [string](Get-OtbValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    if ([string]::IsNullOrWhiteSpace($hotelCode)) {
        throw 'Get-OnTheBooks: Hotel config is missing a HotelCode.'
    }

    # --- Resolve the forward snapshot horizon (SnapshotDate + considered range) ---
    # Get-SnapshotHorizon requires a [hashtable]; project the hotel into one keyed with
    # the lowercase keys it recognises (hotelCode/timeZoneId/nightAuditHour/otbFutureDays).
    $getHorizon = Get-Command -Name 'Get-SnapshotHorizon' -ErrorAction SilentlyContinue
    if (-not $getHorizon) {
        throw 'Get-OnTheBooks: Get-SnapshotHorizon (DateHelper.psm1) is not available.'
    }

    $horizonHotel = @{ hotelCode = $hotelCode }
    $tz = Get-OtbValue -Source $Hotel -Names @('TimeZoneId', 'timeZoneId')
    if ($null -ne $tz) { $horizonHotel['timeZoneId'] = [string]$tz }
    $nah = Get-OtbValue -Source $Hotel -Names @('NightAuditHour', 'nightAuditHour')
    if ($null -ne $nah) { $horizonHotel['nightAuditHour'] = $nah }
    $otbFuture = Get-OtbValue -Source $Hotel -Names @('OtbFutureDays', 'otbFutureDays')
    if ($null -ne $otbFuture) { $horizonHotel['otbFutureDays'] = $otbFuture }

    # FutureDays priority: parameter > hotel.otbFutureDays (handled by Get-SnapshotHorizon)
    # > Config.extraction.defaultOtbFutureDays > 365. Only supply a default here when the
    # hotel itself did not configure otbFutureDays.
    $effectiveFutureDays = $null
    if ($PSBoundParameters.ContainsKey('FutureDays') -and $null -ne $FutureDays) {
        $effectiveFutureDays = [int]$FutureDays
    }
    elseif (-not $horizonHotel.ContainsKey('otbFutureDays')) {
        $effectiveFutureDays = $script:OtbDefaultFutureDays
        if ($null -ne $Config) {
            $extraction = Get-OtbValue -Source $Config -Names @('extraction')
            $cfgFuture = if ($null -ne $extraction) {
                Get-OtbValue -Source $extraction -Names @('defaultOtbFutureDays', 'otbFutureDays')
            }
            else {
                Get-OtbValue -Source $Config -Names @('defaultOtbFutureDays', 'otbFutureDays')
            }
            $parsed = 0
            if ($null -ne $cfgFuture -and [int]::TryParse([string]$cfgFuture, [ref]$parsed) -and $parsed -ge 0) {
                $effectiveFutureDays = $parsed
            }
        }
    }

    $horizonArgs = @{ Hotel = $horizonHotel; HorizonType = 'Otb' }
    if ($null -ne $SnapshotDate) { $horizonArgs['SnapshotDate'] = [datetime]$SnapshotDate }
    if ($null -ne $effectiveFutureDays) { $horizonArgs['FutureDays'] = $effectiveFutureDays }

    $horizon = & $getHorizon @horizonArgs
    $snapshot = [datetime]$horizon.SnapshotDate
    $consideredStart = [datetime]$horizon.ConsideredDateStart
    $consideredEnd = [datetime]$horizon.ConsideredDateEnd

    Write-OtbLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "SA=StatisticsForecastSummary snapshot={0:yyyy-MM-dd} consideredRange={1:yyyy-MM-dd}..{2:yyyy-MM-dd}" -f `
            $snapshot, $consideredStart, $consideredEnd)

    $query = Get-OtbGraphQlQuery
    $variables = New-OtbHorizonVariables -ResortCode $hotelCode -ConsideredDateStart $consideredStart -ConsideredDateEnd $consideredEnd

    # --- Invoke the API layer (single snapshot request; one flat array) -------
    $invokeReal = Get-Command -Name 'Invoke-RASubjectArea' -ErrorAction SilentlyContinue
    if (-not $SubjectAreaInvoker -and -not $invokeReal) {
        throw 'Get-OnTheBooks: Invoke-RASubjectArea (ApiClient.psm1) is not available and no -SubjectAreaInvoker seam was supplied.'
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $saArgs = @{
        Operation   = $script:OtbOperation
        PrimaryView = $script:OtbPrimaryView
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
                Operation   = $script:OtbOperation
                PrimaryView = $script:OtbPrimaryView
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
        Write-OtbLog -Level ERROR -HotelCode $hotelCode -BatchId $BatchId -Message (
            "snapshot {0:yyyy-MM-dd} consideredRange={1:yyyy-MM-dd}..{2:yyyy-MM-dd} FAILED after {3}ms: {4}" -f `
                $snapshot, $consideredStart, $consideredEnd, $sw.ElapsedMilliseconds, $_.Exception.Message)
        throw
    }
    $sw.Stop()

    # --- Map raw rows -> flat ra.OTB PSCustomObjects -------------------------
    $mapped = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in $rawRows) {
        if ($null -eq $raw) { continue }
        [void]$mapped.Add((ConvertTo-OtbRow -Raw $raw -Hotel $Hotel -SnapshotDate $snapshot -BatchId $BatchId))
    }

    # --- One INFO line: snapshot date, considered range, total row count ------
    Write-OtbLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "OTB snapshot complete: hotel={0} snapshot={1:yyyy-MM-dd} consideredRange={2:yyyy-MM-dd}..{3:yyyy-MM-dd} rows={4} ({5}ms)." -f `
            $hotelCode, $snapshot, $consideredStart, $consideredEnd, $mapped.Count, $sw.ElapsedMilliseconds)

    # Return a real [array] even for 0/1 rows (unary comma prevents pipeline unwrap).
    $flat = [object[]]$mapped.ToArray()
    return , $flat
}

# Design consistency: design.md names the function Get-OTB. Expose it as an alias so
# both the design name and the Task 10 name (Get-OnTheBooks) resolve.
Set-Alias -Name 'Get-OTB' -Value 'Get-OnTheBooks'

# ------------------------------------------------------------------------------
# Exported surface
# ------------------------------------------------------------------------------
Export-ModuleMember -Function @('Get-OnTheBooks') -Alias @('Get-OTB')
