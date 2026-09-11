# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Business date and time zone utilities for the OPERA R&A Data Loader.

.DESCRIPTION
    Provides helpers for resolving hotel business dates (accounting for the night
    audit cutover and per-hotel time zone) and for converting between UTC and hotel
    local time.

    All time zone conversions use [TimeZoneInfo]::FindSystemTimeZoneById so that
    daylight-saving-time (DST) transitions are handled by the platform rather than by
    manual offset arithmetic.

    Get-SnapshotHorizon derives the forward-looking window (snapshot date +
    considered-date start/end) used by the OTB and Block snapshot query modules.
#>

function Get-BusinessDate {
    <#
    .SYNOPSIS
        Resolves a hotel's previous (last fully-closed) business date.

    .DESCRIPTION
        A hotel's operational day is closed by the night audit, which runs at the
        hotel-local hour given by the hotel's 'nightAuditHour' (0-23). The night audit
        rolls the property's "current" business date forward. This function returns the
        LAST FULLY-CLOSED business date — the previous business date — which is the
        correct default target for actuals extraction when no explicit date range is
        supplied (REQ-004, REQ-014).

        Resolution logic:
          1. Convert the reference instant (default: current UTC 'now') to the hotel's
             local time using the hotel's timeZoneId.
          2. Determine the property's current (still-open) business date:
               - If the hotel-local time-of-day is at or after nightAuditHour, the night
                 audit for the prior day has already run, so the current business date has
                 rolled to today's local calendar date.
               - If the hotel-local time-of-day is before nightAuditHour, the roll has not
                 yet happened, so the current business date is still the previous local
                 calendar date.
          3. Return the current business date minus one day — the last fully-closed
             business day — as a date-only [datetime] (time = 00:00).

        When nightAuditHour = 0 (midnight cutover), the current business date always
        equals today's local calendar date, so this returns local yesterday — matching
        wall-clock-midnight behaviour.

    .PARAMETER Hotel
        Hotel configuration hashtable. Recognised keys:
          timeZoneId     [string] A TimeZoneInfo id resolvable by
                                  [TimeZoneInfo]::FindSystemTimeZoneById (required).
          nightAuditHour [int]    Night audit cutover hour, 0-23. If absent/null,
                                  falls back to 0 (midnight).
          hotelCode      [string] Optional, used only for verbose logging context.

    .PARAMETER ReferenceDate
        The reference instant. Optional; defaults to the current UTC time. The value's
        DateTimeKind is honoured: Utc is used as-is, Local is converted to UTC, and
        Unspecified is treated as UTC (the loader operates in UTC).

    .OUTPUTS
        [datetime] The previous business date, date-only (time component 00:00:00).

    .EXAMPLE
        $hotel = @{ hotelCode = 'HOTEL1'; timeZoneId = 'Central European Standard Time'; nightAuditHour = 23 }
        Get-BusinessDate -Hotel $hotel

    .EXAMPLE
        Get-BusinessDate -Hotel @{ timeZoneId = 'US Eastern Standard Time'; nightAuditHour = 0 } -ReferenceDate ([datetime]::UtcNow)
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Hotel,

        [Parameter()]
        [datetime] $ReferenceDate = [datetime]::UtcNow
    )

    $hotelCode = if ($Hotel.ContainsKey('hotelCode') -and $Hotel['hotelCode']) { [string]$Hotel['hotelCode'] } else { '<unknown>' }

    # --- Resolve the time zone id (required) -----------------------------------
    $timeZoneId = if ($Hotel.ContainsKey('timeZoneId')) { $Hotel['timeZoneId'] } else { $null }
    if ([string]::IsNullOrWhiteSpace([string]$timeZoneId)) {
        throw "Get-BusinessDate: hotel '$hotelCode' is missing a 'timeZoneId'. A valid time zone id is required to resolve the business date."
    }

    try {
        $timeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById([string]$timeZoneId)
    }
    catch {
        throw "Get-BusinessDate: hotel '$hotelCode' has an unrecognised timeZoneId '$timeZoneId'. $($_.Exception.Message)"
    }

    # --- Resolve the night audit cutover hour (fallback to midnight) -----------
    $nightAuditHour = 0
    if ($Hotel.ContainsKey('nightAuditHour') -and $null -ne $Hotel['nightAuditHour']) {
        $parsedHour = 0
        if (-not [int]::TryParse([string]$Hotel['nightAuditHour'], [ref]$parsedHour) -or $parsedHour -lt 0 -or $parsedHour -gt 23) {
            throw "Get-BusinessDate: hotel '$hotelCode' has an invalid 'nightAuditHour' value '$($Hotel['nightAuditHour'])'. Expected an integer 0-23."
        }
        $nightAuditHour = $parsedHour
    }
    else {
        Write-Verbose "Get-BusinessDate: hotel '$hotelCode' has no 'nightAuditHour'; falling back to midnight (0)."
    }

    try {
        # --- Normalise the reference instant to UTC ----------------------------
        # Honour the supplied DateTimeKind. Unspecified is treated as UTC because the
        # loader operates in UTC; TimeZoneInfo.ConvertTimeFromUtc requires a UTC/Unspecified
        # source kind, so coerce explicitly.
        $referenceUtc = switch ($ReferenceDate.Kind) {
            ([System.DateTimeKind]::Utc)   { $ReferenceDate }
            ([System.DateTimeKind]::Local) { $ReferenceDate.ToUniversalTime() }
            default                        { [datetime]::SpecifyKind($ReferenceDate, [System.DateTimeKind]::Utc) }
        }

        # --- Convert to hotel local time (DST-aware via TimeZoneInfo) ----------
        $localNow = [System.TimeZoneInfo]::ConvertTimeFromUtc($referenceUtc, $timeZone)

        # --- Determine the property's current (still-open) business date -------
        # Before the night audit hour, the day has not yet rolled, so the current
        # business date is still the previous local calendar day.
        $currentBusinessDate = $localNow.Date
        if ($localNow.Hour -lt $nightAuditHour) {
            $currentBusinessDate = $currentBusinessDate.AddDays(-1)
        }

        # --- The last fully-closed business day is the previous business date --
        $businessDate = $currentBusinessDate.AddDays(-1)

        Write-Verbose ("Get-BusinessDate: hotel '{0}' tz='{1}' nightAuditHour={2} referenceUtc={3:yyyy-MM-dd HH:mm:ss}Z localNow={4:yyyy-MM-dd HH:mm:ss} -> businessDate={5:yyyy-MM-dd}" -f `
            $hotelCode, $timeZone.Id, $nightAuditHour, $referenceUtc, $localNow, $businessDate)

        # Return a date-only value (time = 00:00, Unspecified kind — a business date has no time-of-day).
        return [datetime]::SpecifyKind($businessDate.Date, [System.DateTimeKind]::Unspecified)
    }
    catch {
        throw "Get-BusinessDate: failed to resolve business date for hotel '$hotelCode'. $($_.Exception.Message)"
    }
}

function ConvertTo-DateHelperDateTime {
    <#
    .SYNOPSIS
        Internal helper: coerces a flexible input value into a [datetime], or returns
        $null when the input represents "no value".

    .DESCRIPTION
        Accepts [datetime], $null, [DBNull] (SQL null), empty/whitespace strings, and
        parseable date/datetime strings. Strings are parsed using the invariant culture
        with a fallback to the current culture so locale-formatted values still resolve.

        Returns $null for null/DBNull/empty input so callers can emit an empty string.
        Throws when a non-empty value cannot be interpreted as a datetime.

    .PARAMETER Value
        The value to coerce.

    .OUTPUTS
        [datetime] or $null.
    #>
    [CmdletBinding()]
    [OutputType([datetime], [System.Object])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [System.Object] $Value = $null
    )

    # --- Null / SQL DBNull -> no value ----------------------------------------
    if ($null -eq $Value -or $Value -is [System.DBNull]) {
        return $null
    }

    # --- Already a datetime ---------------------------------------------------
    if ($Value -is [datetime]) {
        return [datetime]$Value
    }

    # --- DateTimeOffset -> local clock component ------------------------------
    if ($Value -is [System.DateTimeOffset]) {
        return ([System.DateTimeOffset]$Value).DateTime
    }

    # --- String (empty/whitespace -> no value; otherwise parse) ---------------
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::CurrentCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }

    throw "Value '$text' could not be parsed as a date/datetime."
}

function Format-OutputDate {
    <#
    .SYNOPSIS
        Formats a date/datetime value as a compact date-only string 'YYYYMMDD'.

    .DESCRIPTION
        Output/serialisation helper used by the RES / OTB / FIN query modules when
        materialising date-only output columns (e.g. BUSINESS_DATE, SNAPSHOT_DATE,
        CONSIDERED_DATE, TRUNC_BEGIN_DATE, TRUNC_END_DATE).

        Behaviour:
          - Empty / null / DBNull input returns an empty string ("").
          - A [datetime], [DateTimeOffset], or a parseable date/datetime string is
            formatted as 'yyyyMMdd' using the invariant culture (locale-independent).

        NOTE: This helper is for OUTPUT serialisation only. It does NOT apply to
        GraphQL / R&A API request filters, which keep ISO 'YYYY-MM-DD' formatting.

    .PARAMETER Value
        The value to format. Accepts [datetime], $null, [DBNull], an empty string, or a
        string parseable to a datetime.

    .OUTPUTS
        [string] 'YYYYMMDD', or "" for empty/null input.

    .EXAMPLE
        Format-OutputDate ([datetime]'2026-05-07')
        # 20260507

    .EXAMPLE
        Format-OutputDate $null
        # (empty string)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [System.Object] $Value = $null
    )

    try {
        $dt = ConvertTo-DateHelperDateTime -Value $Value
    }
    catch {
        throw "Format-OutputDate: $($_.Exception.Message)"
    }

    if ($null -eq $dt) {
        return ''
    }

    return $dt.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-OutputDateTime {
    <#
    .SYNOPSIS
        Formats a datetime value as 'YYYYMMDD HH:mm:ss'.

    .DESCRIPTION
        Output/serialisation helper used by the RES / OTB / FIN query modules when
        materialising datetime output columns (e.g. CANCELLATION_DATE, TRX_DATE,
        TRX_DATE_UTC).

        Behaviour:
          - Empty / null / DBNull input returns an empty string ("").
          - A [datetime], [DateTimeOffset], or a parseable date/datetime string is
            formatted as 'yyyyMMdd HH:mm:ss' (24-hour clock) using the invariant culture
            (locale-independent).

        NOTE: This helper is for OUTPUT serialisation only. It does NOT apply to
        GraphQL / R&A API request filters, which keep ISO 'YYYY-MM-DD' formatting.

    .PARAMETER Value
        The value to format. Accepts [datetime], $null, [DBNull], an empty string, or a
        string parseable to a datetime.

    .OUTPUTS
        [string] 'YYYYMMDD HH:mm:ss', or "" for empty/null input.

    .EXAMPLE
        Format-OutputDateTime ([datetime]'2026-05-07 12:33:21')
        # 20260507 12:33:21

    .EXAMPLE
        Format-OutputDateTime ''
        # (empty string)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [System.Object] $Value = $null
    )

    try {
        $dt = ConvertTo-DateHelperDateTime -Value $Value
    }
    catch {
        throw "Format-OutputDateTime: $($_.Exception.Message)"
    }

    if ($null -eq $dt) {
        return ''
    }

    return $dt.ToString('yyyyMMdd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Resolve-DateHelperTimeZone {
    <#
    .SYNOPSIS
        Internal helper: resolves a TimeZoneInfo id string into a [TimeZoneInfo],
        with clear, consistent error handling.

    .DESCRIPTION
        Wraps [TimeZoneInfo]::FindSystemTimeZoneById so that a missing/blank id or an
        unrecognised id produces a single, well-formatted error rather than a bare
        platform exception. Used by Convert-ToUtc and Convert-ToLocal.

    .PARAMETER TimeZoneId
        A TimeZoneInfo id resolvable by [TimeZoneInfo]::FindSystemTimeZoneById
        (e.g. 'Central European Standard Time' on Windows, 'Europe/Berlin' on Linux/macOS).

    .PARAMETER Caller
        The name of the calling function, used only to prefix error messages.

    .OUTPUTS
        [System.TimeZoneInfo]
    #>
    [CmdletBinding()]
    [OutputType([System.TimeZoneInfo])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [string] $TimeZoneId,

        [Parameter()]
        [string] $Caller = 'Resolve-DateHelperTimeZone'
    )

    if ([string]::IsNullOrWhiteSpace($TimeZoneId)) {
        throw "${Caller}: a non-empty 'TimeZoneId' is required to perform a time zone conversion."
    }

    try {
        return [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    }
    catch [System.TimeZoneNotFoundException] {
        throw "${Caller}: time zone id '$TimeZoneId' was not found on this system. $($_.Exception.Message)"
    }
    catch [System.InvalidTimeZoneException] {
        throw "${Caller}: time zone id '$TimeZoneId' is corrupt or invalid. $($_.Exception.Message)"
    }
    catch {
        throw "${Caller}: failed to resolve time zone id '$TimeZoneId'. $($_.Exception.Message)"
    }
}

function Convert-ToUtc {
    <#
    .SYNOPSIS
        Converts a hotel-local datetime to UTC using the hotel's time zone.

    .DESCRIPTION
        Converts a datetime expressed in the local wall-clock time of the given
        TimeZoneId to its UTC equivalent using [TimeZoneInfo]::ConvertTimeToUtc, so
        daylight-saving-time (DST) transitions are handled by the platform rather than
        by manual offset arithmetic (REQ-014).

        DateTimeKind handling:
          - Unspecified : treated as local time in TimeZoneId (the expected input) and
                          converted to UTC.
          - Local       : the system-local clock value is normalised to Unspecified and
                          interpreted in TimeZoneId (the loader treats the supplied
                          TimeZoneId as authoritative for the value, not the host's zone).
          - Utc         : already UTC; returned unchanged (idempotent — a no-op).

        DST edge cases: ConvertTimeToUtc treats invalid "spring-forward" local times as
        if DST were in effect and ambiguous "fall-back" times as standard (non-DST) time.

    .PARAMETER LocalDateTime
        The datetime, expressed in the local time of TimeZoneId, to convert to UTC.

    .PARAMETER TimeZoneId
        A TimeZoneInfo id resolvable by [TimeZoneInfo]::FindSystemTimeZoneById.

    .OUTPUTS
        [datetime] The equivalent UTC value (DateTimeKind = Utc).

    .EXAMPLE
        Convert-ToUtc -LocalDateTime ([datetime]'2026-07-01 14:30:00') -TimeZoneId 'Central European Standard Time'
        # 2026-07-01 12:30:00 (UTC; CEST is UTC+2 in July)
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [datetime] $LocalDateTime,

        [Parameter(Mandatory, Position = 1)]
        [string] $TimeZoneId
    )

    $timeZone = Resolve-DateHelperTimeZone -TimeZoneId $TimeZoneId -Caller 'Convert-ToUtc'

    try {
        # Already UTC -> nothing to do (idempotent).
        if ($LocalDateTime.Kind -eq [System.DateTimeKind]::Utc) {
            Write-Verbose ("Convert-ToUtc: input is already Utc ({0:yyyy-MM-dd HH:mm:ss}Z); returning unchanged." -f $LocalDateTime)
            return $LocalDateTime
        }

        # ConvertTimeToUtc requires the source kind to be Unspecified (or Utc) when a
        # source time zone is supplied; a Local kind would make it ignore $timeZone.
        # Normalise to Unspecified so the supplied TimeZoneId is always authoritative.
        $localUnspecified = [datetime]::SpecifyKind($LocalDateTime, [System.DateTimeKind]::Unspecified)

        $utc = [System.TimeZoneInfo]::ConvertTimeToUtc($localUnspecified, $timeZone)

        Write-Verbose ("Convert-ToUtc: tz='{0}' local={1:yyyy-MM-dd HH:mm:ss} -> utc={2:yyyy-MM-dd HH:mm:ss}Z" -f `
            $timeZone.Id, $localUnspecified, $utc)

        return $utc
    }
    catch {
        throw "Convert-ToUtc: failed to convert '$LocalDateTime' from time zone '$TimeZoneId' to UTC. $($_.Exception.Message)"
    }
}

function Convert-ToLocal {
    <#
    .SYNOPSIS
        Converts a UTC datetime to a hotel's local time using the hotel's time zone.

    .DESCRIPTION
        Converts a UTC datetime to its equivalent local wall-clock time in the given
        TimeZoneId using [TimeZoneInfo]::ConvertTimeFromUtc, so daylight-saving-time
        (DST) transitions are handled by the platform (REQ-014).

        DateTimeKind handling:
          - Utc         : used as-is (the expected input).
          - Unspecified : treated as UTC (the loader operates in UTC).
          - Local       : the system-local value is converted to UTC first, then to
                          TimeZoneId local time.

        The returned value has DateTimeKind = Unspecified because it represents local
        wall-clock time in TimeZoneId, which is not necessarily the host's local zone.

    .PARAMETER UtcDateTime
        The UTC datetime to convert to TimeZoneId local time.

    .PARAMETER TimeZoneId
        A TimeZoneInfo id resolvable by [TimeZoneInfo]::FindSystemTimeZoneById.

    .OUTPUTS
        [datetime] The equivalent local value in TimeZoneId (DateTimeKind = Unspecified).

    .EXAMPLE
        Convert-ToLocal -UtcDateTime ([datetime]::new(2026, 7, 1, 12, 30, 0, [System.DateTimeKind]::Utc)) -TimeZoneId 'Central European Standard Time'
        # 2026-07-01 14:30:00 (local; CEST is UTC+2 in July)
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [datetime] $UtcDateTime,

        [Parameter(Mandatory, Position = 1)]
        [string] $TimeZoneId
    )

    $timeZone = Resolve-DateHelperTimeZone -TimeZoneId $TimeZoneId -Caller 'Convert-ToLocal'

    try {
        # Normalise the source instant to a UTC-kind value. ConvertTimeFromUtc requires
        # the source kind to be Utc or Unspecified (never Local).
        $utc = switch ($UtcDateTime.Kind) {
            ([System.DateTimeKind]::Utc)   { $UtcDateTime }
            ([System.DateTimeKind]::Local) { $UtcDateTime.ToUniversalTime() }
            default                        { [datetime]::SpecifyKind($UtcDateTime, [System.DateTimeKind]::Utc) }
        }

        $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $timeZone)

        Write-Verbose ("Convert-ToLocal: tz='{0}' utc={1:yyyy-MM-dd HH:mm:ss}Z -> local={2:yyyy-MM-dd HH:mm:ss}" -f `
            $timeZone.Id, $utc, $local)

        # ConvertTimeFromUtc returns Unspecified kind; keep it explicit — this is local
        # wall-clock time in TimeZoneId, not necessarily the host's local zone.
        return [datetime]::SpecifyKind($local, [System.DateTimeKind]::Unspecified)
    }
    catch {
        throw "Convert-ToLocal: failed to convert '$UtcDateTime' from UTC to time zone '$TimeZoneId'. $($_.Exception.Message)"
    }
}

function Get-DateRangeChunks {
    <#
    .SYNOPSIS
        Splits an inclusive date range into contiguous, non-overlapping chunks of at
        most N days each.

    .DESCRIPTION
        The R&A Data API does not use cursor/offset pagination; data volume for
        transactional subject areas (reservation statistics, financial transactions) is
        controlled by issuing separate requests over bounded date windows (REQ-011).
        This helper splits an inclusive [StartDate, EndDate] business-date range into a
        sequence of consecutive windows, each spanning at most 'ChunkDays' calendar days,
        so callers can loop over the chunks and issue one API request per window.

        Chunking rules:
          - The range is treated as INCLUSIVE of both endpoints and is evaluated on the
            date component only (any time-of-day on the inputs is ignored). Business
            dates have no time-of-day.
          - Chunks are contiguous and non-overlapping: chunk N+1 starts on the calendar
            day immediately after chunk N ends.
          - Each chunk spans at most 'ChunkDays' days inclusively — i.e. a chunk that
            starts on D covers up to [D, D + (ChunkDays - 1)]. The final chunk is clamped
            to 'EndDate'.
          - StartDate == EndDate yields a single one-day chunk (Start == End).

        Each returned element is a [PSCustomObject] with:
          Start [datetime] the chunk's inclusive start date (date-only, Unspecified kind)
          End   [datetime] the chunk's inclusive end date   (date-only, Unspecified kind)

    .PARAMETER StartDate
        The inclusive start of the range. The date component is used; any time-of-day
        is ignored. Must be <= EndDate.

    .PARAMETER EndDate
        The inclusive end of the range. The date component is used; any time-of-day is
        ignored. Must be >= StartDate.

    .PARAMETER ChunkDays
        Maximum number of days a single chunk may span (inclusive). Optional; defaults
        to 7 (the transactional-data chunk size, REQ-011). Must be >= 1.

    .OUTPUTS
        [array] of [PSCustomObject] each with Start and End date-only [datetime] values.

    .EXAMPLE
        Get-DateRangeChunks -StartDate '2026-01-01' -EndDate '2026-01-20'
        # 3 chunks (default 7-day): 2026-01-01..2026-01-07, 2026-01-08..2026-01-14, 2026-01-15..2026-01-20

    .EXAMPLE
        Get-DateRangeChunks -StartDate '2026-01-10' -EndDate '2026-01-10'
        # 1 chunk: 2026-01-10..2026-01-10 (single-day range)
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [datetime] $StartDate,

        [Parameter(Mandatory, Position = 1)]
        [datetime] $EndDate,

        [Parameter(Position = 2)]
        [int] $ChunkDays = 7
    )

    # --- Validate inputs -------------------------------------------------------
    if ($ChunkDays -lt 1) {
        throw "Get-DateRangeChunks: 'ChunkDays' must be >= 1 (received $ChunkDays)."
    }

    # Work on the date component only; business dates carry no time-of-day. Pin the kind
    # to Unspecified so callers don't accidentally treat these as UTC/local instants.
    $rangeStart = [datetime]::SpecifyKind($StartDate.Date, [System.DateTimeKind]::Unspecified)
    $rangeEnd = [datetime]::SpecifyKind($EndDate.Date, [System.DateTimeKind]::Unspecified)

    if ($rangeStart -gt $rangeEnd) {
        throw ("Get-DateRangeChunks: 'StartDate' ({0:yyyy-MM-dd}) must be on or before 'EndDate' ({1:yyyy-MM-dd})." -f $rangeStart, $rangeEnd)
    }

    # --- Build contiguous, non-overlapping chunks ------------------------------
    $chunks = [System.Collections.Generic.List[object]]::new()
    $cursor = $rangeStart

    while ($cursor -le $rangeEnd) {
        # A chunk starting on $cursor covers at most ChunkDays days inclusively:
        # [cursor, cursor + (ChunkDays - 1)]. Clamp the tail to the overall range end.
        $chunkEnd = $cursor.AddDays($ChunkDays - 1)
        if ($chunkEnd -gt $rangeEnd) {
            $chunkEnd = $rangeEnd
        }

        $chunks.Add([PSCustomObject]@{
                Start = $cursor
                End   = $chunkEnd
            })

        # Next chunk begins the day after this one ends (contiguous, no overlap).
        $cursor = $chunkEnd.AddDays(1)
    }

    Write-Verbose ("Get-DateRangeChunks: range {0:yyyy-MM-dd}..{1:yyyy-MM-dd} (ChunkDays={2}) -> {3} chunk(s)." -f `
            $rangeStart, $rangeEnd, $ChunkDays, $chunks.Count)

    # Return as a plain array. Wrap in the array subexpression operator so a single-chunk
    # result is still returned as an array rather than being unwrapped by the pipeline.
    return @($chunks.ToArray())
}

function Get-SnapshotHorizon {
    <#
    .SYNOPSIS
        Computes the forward-looking snapshot horizon (snapshot date + considered-date
        start/end) for OTB and Block Reservations extraction.

    .DESCRIPTION
        OTB (On-The-Books, REQ-006) and Block Reservations (REQ-007) are daily SNAPSHOTS
        of future occupancy/blocks as they stand on a given business date. Each row is
        tagged with two dates:
          - SNAPSHOT_DATE  — the business date of the run (when the data was pulled).
          - CONSIDERED_DATE — a future stay/grid date the row describes.

        This helper resolves the horizon window that the query modules pass to the R&A
        API's mandatory stayDate range filter:
          - SnapshotDate         : the business date of the run.
          - ConsideredDateStart  : the inclusive start of the future window (= SnapshotDate).
          - ConsideredDateEnd    : the inclusive end of the future window
                                   (= SnapshotDate + FutureDays).

        Snapshot date resolution:
          - If -SnapshotDate is supplied, its date component is used (time-of-day ignored;
            a business date has no time-of-day).
          - If -SnapshotDate is NOT supplied, it is derived via Get-BusinessDate for the
            hotel (honouring the hotel time zone + night audit cutover — REQ-014).

        Future-day resolution (in priority order):
          1. The -FutureDays parameter, when supplied (>= 0). The caller passes the horizon
             relevant to the subject area it is extracting (OTB vs Block).
          2. Otherwise the hotel's own configured horizon: 'otbFutureDays' (OTB) or
             'blockFutureDays' (Block), selected via -HorizonType.
          3. Otherwise a sensible default of 365 days.

        A FutureDays of 0 yields a single-day horizon (Start == End == SnapshotDate).

    .PARAMETER Hotel
        Hotel configuration hashtable. Recognised keys:
          otbFutureDays   [int]    OTB future horizon in days (used when HorizonType='Otb'
                                   and -FutureDays is not supplied).
          blockFutureDays [int]    Block future horizon in days (used when
                                   HorizonType='Block' and -FutureDays is not supplied).
          timeZoneId      [string] Required only when -SnapshotDate is not supplied (needed
                                   by Get-BusinessDate).
          nightAuditHour  [int]    Used by Get-BusinessDate when deriving the snapshot date.
          hotelCode       [string] Optional, used only for verbose logging context.

    .PARAMETER SnapshotDate
        The business date of the run. Optional; when omitted it is derived via
        Get-BusinessDate for the hotel. The date component is used; any time-of-day is
        ignored.

    .PARAMETER FutureDays
        The number of days to look forward from the snapshot date (>= 0). Optional; when
        not supplied it falls back to the hotel's otbFutureDays / blockFutureDays (per
        -HorizonType), then to 365.

    .PARAMETER HorizonType
        Selects which hotel-configured horizon to fall back to when -FutureDays is not
        supplied: 'Otb' (default) uses 'otbFutureDays'; 'Block' uses 'blockFutureDays'.

    .OUTPUTS
        [hashtable] with keys:
          SnapshotDate        [datetime] date-only (Unspecified kind)
          ConsideredDateStart [datetime] date-only (Unspecified kind) — inclusive
          ConsideredDateEnd   [datetime] date-only (Unspecified kind) — inclusive

    .EXAMPLE
        $hotel = @{ hotelCode = 'HOTEL1'; otbFutureDays = 365; blockFutureDays = 180 }
        Get-SnapshotHorizon -Hotel $hotel -SnapshotDate '2026-07-30' -HorizonType Otb
        # SnapshotDate=2026-07-30 ConsideredDateStart=2026-07-30 ConsideredDateEnd=2027-07-30

    .EXAMPLE
        Get-SnapshotHorizon -Hotel @{ blockFutureDays = 180 } -SnapshotDate '2026-07-30' -HorizonType Block
        # ConsideredDateEnd = 2026-07-30 + 180 days

    .EXAMPLE
        Get-SnapshotHorizon -Hotel $hotel -SnapshotDate '2026-07-30' -FutureDays 0
        # single-day horizon: Start == End == 2026-07-30
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Hotel,

        [Parameter()]
        [AllowNull()]
        [Nullable[datetime]] $SnapshotDate = $null,

        [Parameter()]
        [AllowNull()]
        [Nullable[int]] $FutureDays = $null,

        [Parameter()]
        [ValidateSet('Otb', 'Block')]
        [string] $HorizonType = 'Otb'
    )

    $hotelCode = if ($Hotel.ContainsKey('hotelCode') -and $Hotel['hotelCode']) { [string]$Hotel['hotelCode'] } else { '<unknown>' }

    try {
        # --- Resolve the snapshot (business) date ------------------------------
        # Use the supplied value's date component, otherwise derive the last fully-closed
        # business date for the hotel (TZ + night-audit aware — REQ-014).
        if ($null -ne $SnapshotDate) {
            $resolvedSnapshot = [datetime]::SpecifyKind(([datetime]$SnapshotDate).Date, [System.DateTimeKind]::Unspecified)
        }
        else {
            Write-Verbose "Get-SnapshotHorizon: hotel '$hotelCode' has no explicit SnapshotDate; deriving via Get-BusinessDate."
            $businessDate = Get-BusinessDate -Hotel $Hotel
            $resolvedSnapshot = [datetime]::SpecifyKind($businessDate.Date, [System.DateTimeKind]::Unspecified)
        }

        # --- Resolve the number of future days ---------------------------------
        # Priority: explicit parameter -> hotel-configured horizon -> default (365).
        $resolvedFutureDays = $null
        $futureDaysSource = $null

        if ($null -ne $FutureDays) {
            $resolvedFutureDays = [int]$FutureDays
            $futureDaysSource = 'parameter'
        }
        else {
            $configKey = if ($HorizonType -eq 'Block') { 'blockFutureDays' } else { 'otbFutureDays' }
            if ($Hotel.ContainsKey($configKey) -and $null -ne $Hotel[$configKey]) {
                $parsedDays = 0
                if (-not [int]::TryParse([string]$Hotel[$configKey], [ref]$parsedDays)) {
                    throw "Get-SnapshotHorizon: hotel '$hotelCode' has a non-integer '$configKey' value '$($Hotel[$configKey])'."
                }
                $resolvedFutureDays = $parsedDays
                $futureDaysSource = "hotel.$configKey"
            }
            else {
                $resolvedFutureDays = 365
                $futureDaysSource = 'default(365)'
                Write-Verbose "Get-SnapshotHorizon: hotel '$hotelCode' has no '$configKey'; falling back to default horizon of 365 days."
            }
        }

        if ($resolvedFutureDays -lt 0) {
            throw "Get-SnapshotHorizon: hotel '$hotelCode' resolved a negative FutureDays ($resolvedFutureDays) from $futureDaysSource. FutureDays must be >= 0."
        }

        # --- Build the inclusive considered-date window ------------------------
        $consideredDateStart = $resolvedSnapshot
        $consideredDateEnd = $resolvedSnapshot.AddDays($resolvedFutureDays)

        Write-Verbose ("Get-SnapshotHorizon: hotel '{0}' horizonType={1} snapshot={2:yyyy-MM-dd} futureDays={3} ({4}) -> considered {5:yyyy-MM-dd}..{6:yyyy-MM-dd}" -f `
            $hotelCode, $HorizonType, $resolvedSnapshot, $resolvedFutureDays, $futureDaysSource, $consideredDateStart, $consideredDateEnd)

        return @{
            SnapshotDate        = $resolvedSnapshot
            ConsideredDateStart = $consideredDateStart
            ConsideredDateEnd   = $consideredDateEnd
        }
    }
    catch {
        throw "Get-SnapshotHorizon: failed to compute snapshot horizon for hotel '$hotelCode'. $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Get-BusinessDate, Convert-ToUtc, Convert-ToLocal, Format-OutputDate, Format-OutputDateTime, Get-DateRangeChunks, Get-SnapshotHorizon
