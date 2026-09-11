# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Reservation Statistics (RES) query module for the OPERA R&A Data Loader (Task 8).

.DESCRIPTION
    Extracts daily reservation statistics from the OHIP R&A Data API and returns a
    normalised flat [array] of [PSCustomObject] rows ready to hand to
    SqlWriter\Write-ReservationStats (Write-RES) which MERGEs into ra.RES.

    Subject Area : StatisticsReservationsDaily
    Operation    : statisticsReservationsDaily
    Primary view : reservationDailyStatisticsDetails
                   Mandatory filters: resort (_in), businessDate range (_gte/_lte)
    Target table : ra.RES  (alias ra.ReservationStats)

    Pipeline (design.md — Queries\ReservationStats.psm1):
      1. Get-ReservationStats -Hotel -StartDate -EndDate is the public entry point.
      2. The [StartDate, EndDate] business-date range is split into chunks of
         transactionalChunkDays (default 7) via DateHelper\Get-DateRangeChunks. This is
         the primary volume control — the R&A API has no cursor/offset pagination
         (REQ-011).
      3. Per chunk a GraphQL variables set is built with ISO 'YYYY-MM-DD' date filters
         (resort _in, businessDate _gte/_lte). NOTE: request filters keep ISO
         'YYYY-MM-DD' — they are NOT the compact YYYYMMDD output format.
      4. All chunks are passed to ApiClient\Invoke-RASubjectArea, which issues one
         GraphQL POST per chunk (honouring throttle + backoff) and accumulates every
         chunk's rows into ONE flat [array].
      5. Each raw API row is mapped to the OPERA-native ra.RES column contract
         (RESORT, BUSINESS_DATE, RESV_NAME_ID, MARKET_CODE, ROOM_CATEGORY_LABEL,
         SOURCE_CODE, CHANNEL, ...). Output date fields are formatted with
         DateHelper\Format-OutputDate (YYYYMMDD) / Format-OutputDateTime
         (YYYYMMDD HH:mm:ss). ADR / RevPAR are computed only when the API did not
         already supply them (divide-by-zero guarded).

    Business-date / time-zone / missing-data behaviour (steering):
      - Business dates are date-only; date filters and BUSINESS_DATE/TRUNC_* outputs
        carry no time-of-day.
      - CANCELLATION_DATE carries a time component; when the hotel has a timeZoneId the
        value is normalised to hotel-local wall-clock via DateHelper before formatting so
        cross-time-zone runs are consistent.
      - Missing / empty source values are emitted as $null consistently and never crash
        the mapper (fallback logic).

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
    Logger -Module constant: "ReservationStats".
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
$script:ResOperation   = 'statisticsReservationsDaily'
$script:ResPrimaryView = 'reservationDailyStatisticsDetails'
$script:ResDefaultChunkDays = 7   # extraction.transactionalChunkDays fallback

# ------------------------------------------------------------------------------
# Logging helper — shared Logger when loaded, else Write-Verbose. Never throws.
# ------------------------------------------------------------------------------
function Write-ResLog {
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
            & $writeLog -Level $Level -Module 'ReservationStats' -Message $Message -HotelCode $HotelCode -BatchId $BatchId
            return
        }
        catch {
            # A logger failure must never break extraction — fall through to verbose.
        }
    }

    Write-Verbose ("ReservationStats [{0}] {1}: {2}" -f $Level, $HotelCode, $Message)
}

# ------------------------------------------------------------------------------
# Internal: case-insensitive lookup from a hashtable / PSCustomObject.
# ------------------------------------------------------------------------------
function Get-ResValue {
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
function ConvertTo-ResString {
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
function ConvertTo-ResDecimal {
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
# Internal: normalise a raw API value to a nullable [int] (occupancy counts).
# ------------------------------------------------------------------------------
function ConvertTo-ResInt {
    [CmdletBinding()]
    [OutputType([Nullable[int]])]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    $dec = ConvertTo-ResDecimal -Value $Value
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
function Get-ResSafeQuotient {
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
# Internal: build the RES GraphQL query string (fields per design.md field map).
# ------------------------------------------------------------------------------
function Get-ResGraphQlQuery {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Request only the fields we map (avoid over-fetching — design GraphQL rules).
    $fields = @(
        'resort', 'businessDate', 'resvNameId', 'rateCode', 'rateCategory',
        'marketCode', 'sourceCode', 'channel', 'truncBeginDate', 'truncEndDate',
        'room', 'pseudoRoomYn', 'roomCategoryLabel', 'resvStatus', 'quantity',
        'adults', 'children', 'stayRooms', 'stayPersons', 'stayAdults', 'stayChildren',
        'arrRooms', 'arrPersons', 'depRooms', 'depPersons', 'dayUseRooms', 'dayUsePersons',
        'noShowRooms', 'noShowPersons', 'houseUseYn', 'complimentaryYn', 'walkinYn',
        'cancellationDate', 'country', 'nights',
        # Revenue / derived measures (computed locally only if the API omits them).
        'roomNights', 'revenue', 'physicalRooms', 'adr', 'revPar'
    ) -join ' '

    $view = $script:ResPrimaryView
    $op = $script:ResOperation

    return ("query StatisticsReservationsDaily(`$input: StatisticsReservationsDailyQueryArgumentsType!) " +
        "{ $op(input: `$input) { $view { $fields } } }")
}

# ------------------------------------------------------------------------------
# Internal: build one GraphQL variables set for a single date chunk.
# Request filters use ISO 'YYYY-MM-DD' (NOT the YYYYMMDD output format).
# ------------------------------------------------------------------------------
function New-ResChunkVariables {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $ResortCode,
        [Parameter(Mandatory)] [datetime] $ChunkStart,
        [Parameter(Mandatory)] [datetime] $ChunkEnd
    )

    $iso = [System.Globalization.CultureInfo]::InvariantCulture
    $startIso = $ChunkStart.ToString('yyyy-MM-dd', $iso)
    $endIso = $ChunkEnd.ToString('yyyy-MM-dd', $iso)

    return @{
        input = @{
            resort       = @{ _in = @($ResortCode) }
            businessDate = @{ _gte = $startIso; _lte = $endIso }
        }
    }
}

# ------------------------------------------------------------------------------
# Internal: map ONE raw API row to a flat ra.RES-shaped [PSCustomObject].
# ------------------------------------------------------------------------------
function ConvertTo-ResRow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)] $Hotel,
        [Parameter()] [AllowNull()] [guid] $BatchId = [guid]::Empty
    )

    $resort = ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('resort'))
    if ($null -eq $resort) {
        # Fallback: resort filter is mandatory, so a blank resort in the row is
        # backfilled from the hotel code rather than dropped.
        $resort = ConvertTo-ResString (Get-ResValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    }
    $chainCode = ConvertTo-ResString (Get-ResValue -Source $Hotel -Names @('ChainCode', 'chainCode'))
    $timeZoneId = ConvertTo-ResString (Get-ResValue -Source $Hotel -Names @('TimeZoneId', 'timeZoneId'))

    # --- Date fields ---------------------------------------------------------
    $businessDate = Get-ResValue -Source $Raw -Names @('businessDate')
    $truncBegin = Get-ResValue -Source $Raw -Names @('truncBeginDate')
    $truncEnd = Get-ResValue -Source $Raw -Names @('truncEndDate')
    $cancellation = Get-ResValue -Source $Raw -Names @('cancellationDate')

    # CANCELLATION_DATE carries a time component. Normalise to hotel-local wall-clock
    # when a time zone is configured so cross-TZ runs format consistently (steering).
    if ($null -ne (ConvertTo-ResString $cancellation) -and -not [string]::IsNullOrWhiteSpace($timeZoneId)) {
        $convertLocal = Get-Command -Name 'Convert-ToLocal' -ErrorAction SilentlyContinue
        if ($convertLocal) {
            $parsedCancel = $cancellation -as [datetime]
            if ($null -ne $parsedCancel) {
                try {
                    $cancellation = & $convertLocal -UtcDateTime $parsedCancel -TimeZoneId $timeZoneId
                }
                catch {
                    # Leave the original value; formatting still succeeds. Never crash.
                }
            }
        }
    }

    # --- Output date formatting via DateHelper (YYYYMMDD / YYYYMMDD HH:mm:ss) --
    $fmtDate = Get-Command -Name 'Format-OutputDate' -ErrorAction SilentlyContinue
    $fmtDateTime = Get-Command -Name 'Format-OutputDateTime' -ErrorAction SilentlyContinue
    $formatDate = {
        param($v)
        if ($fmtDate) { return [string](& $fmtDate $v) }
        $dt = $v -as [datetime]; if ($null -eq $dt) { return '' }
        return $dt.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $formatDateTime = {
        param($v)
        if ($fmtDateTime) { return [string](& $fmtDateTime $v) }
        $dt = $v -as [datetime]; if ($null -eq $dt) { return '' }
        return $dt.ToString('yyyyMMdd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    # --- Revenue / derived measures ------------------------------------------
    $roomNights = ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('roomNights'))
    $revenue = ConvertTo-ResDecimal (Get-ResValue -Source $Raw -Names @('revenue'))
    $physicalRooms = ConvertTo-ResDecimal (Get-ResValue -Source $Raw -Names @('physicalRooms'))

    # Only compute when the API did NOT already supply the value (don't overwrite).
    $adr = ConvertTo-ResDecimal (Get-ResValue -Source $Raw -Names @('adr'))
    if ($null -eq $adr) {
        $rn = if ($null -ne $roomNights) { [Nullable[decimal]][decimal]$roomNights } else { $null }
        $adr = Get-ResSafeQuotient -Numerator $revenue -Denominator $rn
    }
    $revpar = ConvertTo-ResDecimal (Get-ResValue -Source $Raw -Names @('revPar', 'revpar'))
    if ($null -eq $revpar) {
        $revpar = Get-ResSafeQuotient -Numerator $revenue -Denominator $physicalRooms
    }

    return [PSCustomObject][ordered]@{
        # Identity / join keys
        RESORT              = $resort
        CHAIN_CODE          = $chainCode
        BUSINESS_DATE       = (& $formatDate $businessDate)
        RESV_NAME_ID        = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('resvNameId')))
        # Rate / market dimensions
        RATE_CODE           = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('rateCode')))
        RATE_CATEGORY       = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('rateCategory')))
        MARKET_CODE         = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('marketCode')))
        SOURCE_CODE         = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('sourceCode')))
        CHANNEL             = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('channel')))
        # Reservation details
        ROOM                = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('room')))
        PSEUDO_ROOM_YN      = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('pseudoRoomYn')))
        ROOM_CATEGORY_LABEL = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('roomCategoryLabel')))
        RESV_STATUS         = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('resvStatus')))
        QUANTITY            = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('quantity')))
        TRUNC_BEGIN_DATE    = (& $formatDate $truncBegin)
        TRUNC_END_DATE      = (& $formatDate $truncEnd)
        COUNTRY             = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('country')))
        NIGHTS              = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('nights')))
        # Occupancy counts
        ADULTS              = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('adults')))
        CHILDREN            = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('children')))
        STAY_ROOMS          = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('stayRooms')))
        STAY_PERSONS        = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('stayPersons')))
        STAY_ADULTS         = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('stayAdults')))
        STAY_CHILDREN       = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('stayChildren')))
        ARR_ROOMS           = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('arrRooms')))
        ARR_PERSONS         = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('arrPersons')))
        DEP_ROOMS           = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('depRooms')))
        DEP_PERSONS         = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('depPersons')))
        DAY_USE_ROOMS       = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('dayUseRooms')))
        DAY_USE_PERSONS     = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('dayUsePersons')))
        NO_SHOW_ROOMS       = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('noShowRooms')))
        NO_SHOW_PERSONS     = (ConvertTo-ResInt (Get-ResValue -Source $Raw -Names @('noShowPersons')))
        # Derived measures
        ROOM_NIGHTS         = $roomNights
        REVENUE             = $revenue
        ADR                 = $adr
        REVPAR              = $revpar
        # Flags
        HOUSE_USE_YN        = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('houseUseYn')))
        COMPLIMENTARY_YN    = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('complimentaryYn')))
        WALKIN_YN           = (ConvertTo-ResString (Get-ResValue -Source $Raw -Names @('walkinYn')))
        CANCELLATION_DATE   = (& $formatDateTime $cancellation)
        # Audit
        BATCH_ID            = $BatchId
    }
}

# ------------------------------------------------------------------------------
# Public: Get-ReservationStats
# ------------------------------------------------------------------------------
function Get-ReservationStats {
    <#
    .SYNOPSIS
        Extracts daily reservation statistics (RES actuals) for a hotel over a business-date
        range and returns a normalised flat [array] of ra.RES-shaped [PSCustomObject] rows.

    .DESCRIPTION
        Splits [StartDate, EndDate] into transactionalChunkDays chunks (default 7) via
        Get-DateRangeChunks, builds one ISO-'YYYY-MM-DD'-filtered GraphQL variables set
        per chunk, calls Invoke-RASubjectArea (which accumulates all chunks into one
        array), maps each row to the ra.RES column contract, formats output dates
        (YYYYMMDD / YYYYMMDD HH:mm:ss), and computes ADR / RevPAR when the API omits them
        (divide-by-zero guarded). Row count + elapsed ms are logged per chunk per hotel.

    .PARAMETER Hotel
        Hotel configuration (hashtable / PSCustomObject). Recognised keys (case-insensitive):
        HotelCode (RESORT), ChainCode, TimeZoneId, GatewayUrl, ApiKey.

    .PARAMETER StartDate
        Inclusive start business date. Date component only.

    .PARAMETER EndDate
        Inclusive end business date. Date component only. Must be >= StartDate.

    .PARAMETER ChunkDays
        Max days per chunk. Optional; defaults to Config.extraction.transactionalChunkDays,
        else 7.

    .PARAMETER Token
        Optional bearer token forwarded to the API layer. When omitted the API layer
        obtains one via Get-OAuthToken.

    .PARAMETER Config
        Optional settings object (root settings.json or sub-objects) supplying
        extraction.transactionalChunkDays and api.* throttle/retry settings.

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
        [array] of [PSCustomObject] matching the ra.RES schema.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] $Hotel,
        [Parameter(Mandatory)] [datetime] $StartDate,
        [Parameter(Mandatory)] [datetime] $EndDate,
        [Parameter()] [ValidateRange(1, [int]::MaxValue)] [int] $ChunkDays,
        [Parameter()] [string] $Token,
        [Parameter()] $Config,
        [Parameter()] [guid] $BatchId = [guid]::Empty,
        [Parameter()] [scriptblock] $SubjectAreaInvoker,
        [Parameter()] [scriptblock] $Invoker,
        [Parameter()] [scriptblock] $Sleep
    )

    $hotelCode = [string](Get-ResValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    if ([string]::IsNullOrWhiteSpace($hotelCode)) {
        throw 'Get-ReservationStats: Hotel config is missing a HotelCode.'
    }

    $rangeStart = [datetime]::SpecifyKind($StartDate.Date, [System.DateTimeKind]::Unspecified)
    $rangeEnd = [datetime]::SpecifyKind($EndDate.Date, [System.DateTimeKind]::Unspecified)
    if ($rangeStart -gt $rangeEnd) {
        throw ("Get-ReservationStats: StartDate ({0:yyyy-MM-dd}) must be on or before EndDate ({1:yyyy-MM-dd})." -f $rangeStart, $rangeEnd)
    }

    # --- Resolve chunk size (parameter > config > default 7) -----------------
    $effectiveChunkDays = $script:ResDefaultChunkDays
    if ($PSBoundParameters.ContainsKey('ChunkDays')) {
        $effectiveChunkDays = $ChunkDays
    }
    elseif ($null -ne $Config) {
        $extraction = Get-ResValue -Source $Config -Names @('extraction')
        $cfgChunk = if ($null -ne $extraction) {
            Get-ResValue -Source $extraction -Names @('transactionalChunkDays')
        }
        else {
            Get-ResValue -Source $Config -Names @('transactionalChunkDays')
        }
        $parsed = 0
        if ($null -ne $cfgChunk -and [int]::TryParse([string]$cfgChunk, [ref]$parsed) -and $parsed -ge 1) {
            $effectiveChunkDays = $parsed
        }
    }

    # --- Build the date chunks (primary volume control — REQ-011) ------------
    $getChunks = Get-Command -Name 'Get-DateRangeChunks' -ErrorAction SilentlyContinue
    if (-not $getChunks) {
        throw 'Get-ReservationStats: Get-DateRangeChunks (DateHelper.psm1) is not available.'
    }
    $chunks = @(& $getChunks -StartDate $rangeStart -EndDate $rangeEnd -ChunkDays $effectiveChunkDays)

    Write-ResLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "SA=StatisticsReservationsDaily range={0:yyyy-MM-dd}..{1:yyyy-MM-dd} chunkDays={2} chunks={3}" -f `
            $rangeStart, $rangeEnd, $effectiveChunkDays, $chunks.Count)

    $query = Get-ResGraphQlQuery

    # --- Build one chunk-variable set per chunk (ISO YYYY-MM-DD filters) ------
    # Each element is @{ Variables = <hashtable>; Start; End } so we can:
    #   a) hand the Variables to Invoke-RASubjectArea (which accepts .Variables), and
    #   b) log/attribute per-chunk row counts and durations back to the source range.
    $chunkInputs = foreach ($chunk in $chunks) {
        [PSCustomObject]@{
            Start     = $chunk.Start
            End       = $chunk.End
            Variables = (New-ResChunkVariables -ResortCode $hotelCode -ChunkStart $chunk.Start -ChunkEnd $chunk.End)
        }
    }
    $chunkInputs = @($chunkInputs)

    # --- Invoke the API layer per chunk so we can log row-count + duration ----
    # We iterate chunk-by-chunk (rather than one bulk Invoke-RASubjectArea over all
    # chunks) so each chunk's row count and elapsed time can be logged individually,
    # while still ACCUMULATING every chunk's rows into a single flat array — matching
    # the multi-chunk accumulation contract.
    $rawRows = [System.Collections.Generic.List[object]]::new()

    $invokeReal = Get-Command -Name 'Invoke-RASubjectArea' -ErrorAction SilentlyContinue
    if (-not $SubjectAreaInvoker -and -not $invokeReal) {
        throw 'Get-ReservationStats: Invoke-RASubjectArea (ApiClient.psm1) is not available and no -SubjectAreaInvoker seam was supplied.'
    }

    $chunkNo = 0
    foreach ($ci in $chunkInputs) {
        $chunkNo++
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        $saArgs = @{
            Operation   = $script:ResOperation
            PrimaryView = $script:ResPrimaryView
            Query       = $query
            Chunks      = @(@{ Variables = $ci.Variables })
            Hotel       = $Hotel
            Config      = $Config
        }
        if ($PSBoundParameters.ContainsKey('Token') -and -not [string]::IsNullOrWhiteSpace($Token)) {
            $saArgs['Token'] = $Token
        }

        $chunkRows = @()
        try {
            if ($SubjectAreaInvoker) {
                $chunkRows = @(& $SubjectAreaInvoker $saArgs)
            }
            else {
                $realArgs = @{
                    Hotel       = $Hotel
                    Operation   = $script:ResOperation
                    PrimaryView = $script:ResPrimaryView
                    Query       = $query
                    Chunks      = @(@{ Variables = $ci.Variables })
                    Config      = $Config
                }
                if ($saArgs.ContainsKey('Token')) { $realArgs['Token'] = $Token }
                if ($Invoker) { $realArgs['Invoker'] = $Invoker }
                if ($Sleep) { $realArgs['Sleep'] = $Sleep }
                $chunkRows = @(& $invokeReal @realArgs)
            }
        }
        catch {
            $sw.Stop()
            Write-ResLog -Level ERROR -HotelCode $hotelCode -BatchId $BatchId -Message (
                "chunk {0}/{1} {2:yyyy-MM-dd}..{3:yyyy-MM-dd} FAILED after {4}ms: {5}" -f `
                    $chunkNo, $chunkInputs.Count, $ci.Start, $ci.End, $sw.ElapsedMilliseconds, $_.Exception.Message)
            throw
        }

        $sw.Stop()
        foreach ($r in $chunkRows) { [void]$rawRows.Add($r) }

        # Log row count + duration per date chunk per hotel (subtask 6).
        Write-ResLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
            "chunk {0}/{1} {2:yyyy-MM-dd}..{3:yyyy-MM-dd} fetched {4} row(s) in {5}ms" -f `
                $chunkNo, $chunkInputs.Count, $ci.Start, $ci.End, @($chunkRows).Count, $sw.ElapsedMilliseconds)
    }

    # --- Map raw rows -> flat ra.RES PSCustomObjects -------------------------
    $mapped = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in $rawRows) {
        if ($null -eq $raw) { continue }
        [void]$mapped.Add((ConvertTo-ResRow -Raw $raw -Hotel $Hotel -BatchId $BatchId))
    }

    Write-ResLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "RES extraction complete: {0} row(s) across {1} chunk(s)." -f $mapped.Count, $chunkInputs.Count)

    # Return a real [array] even for 0/1 rows (unary comma prevents pipeline unwrap).
    $flat = [object[]]$mapped.ToArray()
    return , $flat
}

# Design consistency: design.md names the function Get-RES. Expose it as an alias so
# both the design name and the Task 8 name (Get-ReservationStats) resolve.
Set-Alias -Name 'Get-RES' -Value 'Get-ReservationStats'

# ------------------------------------------------------------------------------
# Exported surface
# ------------------------------------------------------------------------------
Export-ModuleMember -Function @('Get-ReservationStats') -Alias @('Get-RES')
