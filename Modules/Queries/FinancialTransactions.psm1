# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Financial Transactions (FIN) query module for the OPERA R&A Data Loader (Task 9).

.DESCRIPTION
    Extracts posted financial / folio transactions from the OHIP R&A Data API and returns
    a normalised flat [array] of [PSCustomObject] rows ready to hand to
    SqlWriter\Write-FinancialTx (Write-FIN) which MERGEs into ra.FIN.

    Subject Area : FinancialTransactionDetails
    Operation    : financialTransactionDetails
    Primary view : financialTransactionDetails
                   Mandatory filters: resort (_in), businessDate range (_gte/_lte)
    Target table : ra.FIN  (alias ra.FinancialTx)

    Pipeline (design.md — Queries\FinancialTransactions.psm1):
      1. Get-FinancialTransactions -Hotel -StartDate -EndDate is the public entry point.
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
      5. Each raw API row is mapped to the OPERA-native ra.FIN column contract
         (RESORT, BUSINESS_DATE, RESV_NAME_ID, TRX_NO, TRAN_ACTION_ID, TRX_CODE,
         FT_SUBTYPE, amounts, ...). Output date fields are formatted with
         DateHelper\Format-OutputDate (YYYYMMDD) / Format-OutputDateTime
         (YYYYMMDD HH:mm:ss).

    Business-date / time-zone / late-posting / missing-data behaviour (steering):
      - Business dates are date-only; the date filters and BUSINESS_DATE / POSTING_DATE
        outputs carry no time-of-day.
      - TRX_DATE is the posting datetime in HOTEL-LOCAL wall-clock. When the hotel has a
        timeZoneId, TRX_DATE_UTC is derived via DateHelper\Convert-ToUtc so cross-time-zone
        runs are consistent. When no timeZoneId is configured, TRX_DATE_UTC falls back to
        the local value unchanged (fallback logic — never crash).
      - IS_LATE_POSTING = 1 when the posting date (POSTING_DATE, else TRX_DATE) is strictly
        AFTER the BUSINESS_DATE (date component only). The flag is computed HERE, at
        extraction time, from the raw datetime values BEFORE they are formatted to strings,
        and emitted as an [int] so SqlWriter\Write-FIN uses it directly (both sides agree —
        SqlWriter re-computes defensively only when the caller omits the flag). A single
        WARN carrying the late-posting count is logged when any late postings are found.
      - Missing / empty source values are emitted as $null consistently and never crash the
        mapper (fallback logic).

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
    Logger -Module constant: "FinancialTransactions".
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
$script:FinOperation   = 'financialTransactionDetails'
$script:FinPrimaryView = 'financialTransactionDetails'
$script:FinDefaultChunkDays = 7   # extraction.transactionalChunkDays fallback

# ------------------------------------------------------------------------------
# Logging helper — shared Logger when loaded, else Write-Verbose. Never throws.
# ------------------------------------------------------------------------------
function Write-FinLog {
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
            & $writeLog -Level $Level -Module 'FinancialTransactions' -Message $Message -HotelCode $HotelCode -BatchId $BatchId
            return
        }
        catch {
            # A logger failure must never break extraction — fall through to verbose.
        }
    }

    Write-Verbose ("FinancialTransactions [{0}] {1}: {2}" -f $Level, $HotelCode, $Message)
}

# ------------------------------------------------------------------------------
# Internal: case-insensitive lookup from a hashtable / PSCustomObject.
# ------------------------------------------------------------------------------
function Get-FinValue {
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
function ConvertTo-FinString {
    [CmdletBinding()]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text.Trim()
}

# ------------------------------------------------------------------------------
# Internal: normalise a raw API value to a nullable [decimal] (monetary amounts).
# Returns $null for null/empty/non-numeric so downstream persistence stays clean.
# ------------------------------------------------------------------------------
function ConvertTo-FinDecimal {
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
# Internal: coerce a raw API value to a [datetime], or $null for "no value".
# Mirrors DateHelper\ConvertTo-DateHelperDateTime behaviour without depending on it
# (that helper is internal to DateHelper). Used for TRX_DATE / BUSINESS_DATE parsing
# BEFORE formatting so the late-posting flag and the UTC conversion see real datetimes.
# ------------------------------------------------------------------------------
function ConvertTo-FinDateTime {
    [CmdletBinding()]
    [OutputType([Nullable[datetime]])]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    if ($Value -is [datetime]) { return [datetime]$Value }
    if ($Value -is [System.DateTimeOffset]) { return ([System.DateTimeOffset]$Value).DateTime }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::CurrentCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

# ------------------------------------------------------------------------------
# Internal: compute IS_LATE_POSTING (int 0/1) from raw posting + business dates.
# A posting is late when its date component is strictly AFTER the business date
# (date-only comparison). Returns 0 when either date is missing (cannot prove late).
# This matches SqlWriter\Get-IsLatePosting exactly so both sides agree.
# ------------------------------------------------------------------------------
function Get-FinIsLatePosting {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()] [AllowNull()] $PostingDate,
        [Parameter()] [AllowNull()] $BusinessDate
    )

    $post = ConvertTo-FinDateTime -Value $PostingDate
    $biz = ConvertTo-FinDateTime -Value $BusinessDate
    if ($null -eq $post -or $null -eq $biz) { return 0 }
    if ($post.Date -gt $biz.Date) { return 1 }
    return 0
}

# ------------------------------------------------------------------------------
# Internal: build the FIN GraphQL query string (fields per design.md field map).
# ------------------------------------------------------------------------------
function Get-FinGraphQlQuery {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Request only the fields we map (avoid over-fetching — design GraphQL rules).
    $fields = @(
        'resort', 'businessDate', 'resvNameId', 'originalResvNameId',
        'rateCode', 'sourceCode', 'marketCode',
        'ftSubtype', 'tcGroup', 'tcSubgroup', 'trxCode',
        'trxNo', 'tranActionId', 'trxNoAddedBy', 'trxDate',
        'netAmount', 'grossAmount', 'trxAmount', 'postedAmount', 'revenueAmt',
        'quantity', 'pricePerUnit', 'exchangeRate', 'currencyCode',
        'indRevenueGp', 'passerByName'
    ) -join ' '

    $view = $script:FinPrimaryView
    $op = $script:FinOperation

    return ("query FinancialTransactionDetails(`$input: FinancialTransactionDetailsQueryArgumentsType!) " +
        "{ $op(input: `$input) { $view { $fields } } }")
}

# ------------------------------------------------------------------------------
# Internal: build one GraphQL variables set for a single date chunk.
# Request filters use ISO 'YYYY-MM-DD' (NOT the YYYYMMDD output format).
# ------------------------------------------------------------------------------
function New-FinChunkVariables {
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
# Internal: map ONE raw API row to a flat ra.FIN-shaped [PSCustomObject].
# ------------------------------------------------------------------------------
function ConvertTo-FinRow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)] $Hotel,
        [Parameter()] [AllowNull()] [guid] $BatchId = [guid]::Empty
    )

    $resort = ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('resort'))
    if ($null -eq $resort) {
        # Fallback: resort filter is mandatory, so a blank resort in the row is
        # backfilled from the hotel code rather than dropped.
        $resort = ConvertTo-FinString (Get-FinValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    }
    $chainCode = ConvertTo-FinString (Get-FinValue -Source $Hotel -Names @('ChainCode', 'chainCode'))
    $timeZoneId = ConvertTo-FinString (Get-FinValue -Source $Hotel -Names @('TimeZoneId', 'timeZoneId'))

    # --- Raw date values (parsed BEFORE formatting) --------------------------
    $businessDateRaw = Get-FinValue -Source $Raw -Names @('businessDate')
    # TRX_DATE is the posting datetime; treat it as the hotel-local wall-clock value.
    $trxDateRaw = Get-FinValue -Source $Raw -Names @('trxDate')

    $trxDateLocal = ConvertTo-FinDateTime -Value $trxDateRaw
    $businessDate = ConvertTo-FinDateTime -Value $businessDateRaw

    # --- POSTING_DATE (date-only) — derived from the posting datetime ---------
    # design/field-map: POSTING_DATE is the date-only projection of the posting date.
    $postingDate = if ($null -ne $trxDateLocal) { $trxDateLocal.Date } else { $null }

    # --- TRX_DATE_UTC via Convert-ToUtc (hotel timeZoneId) --------------------
    # TRX_DATE is hotel-local; derive the UTC instant so cross-TZ runs are consistent.
    # Fallback: when no timeZoneId is configured, or the conversion fails, keep the
    # local value unchanged rather than dropping it (never crash the mapper).
    $trxDateUtc = $trxDateLocal
    if ($null -ne $trxDateLocal -and -not [string]::IsNullOrWhiteSpace($timeZoneId)) {
        $convertUtc = Get-Command -Name 'Convert-ToUtc' -ErrorAction SilentlyContinue
        if ($convertUtc) {
            try {
                $trxDateUtc = & $convertUtc -LocalDateTime $trxDateLocal -TimeZoneId $timeZoneId
            }
            catch {
                # Leave the local value; formatting still succeeds. Never crash.
                $trxDateUtc = $trxDateLocal
            }
        }
    }

    # --- Late-posting flag: computed HERE from raw dates (before formatting) --
    # POSTING_DATE (else TRX_DATE) date > BUSINESS_DATE date. Emitted as an [int]
    # so SqlWriter\Write-FIN uses it directly (both sides agree).
    $postForFlag = if ($null -ne $postingDate) { $postingDate } else { $trxDateLocal }
    $isLatePosting = Get-FinIsLatePosting -PostingDate $postForFlag -BusinessDate $businessDate

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

    return [PSCustomObject][ordered]@{
        # Identity / join keys
        RESORT          = $resort
        CHAIN_CODE      = $chainCode
        BUSINESS_DATE   = (& $formatDate $businessDate)
        RESV_NAME_ID    = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('resvNameId')))
        ORIGINAL_RESV   = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('originalResvNameId', 'originalResv')))
        # Transaction identifiers
        TRX_NO          = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('trxNo')))
        TRAN_ACTION_ID  = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('tranActionId')))
        TRX_NO_ADDED_BY = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('trxNoAddedBy')))
        # Transaction classification
        TRX_CODE        = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('trxCode')))
        TC_GROUP        = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('tcGroup')))
        TC_SUBGROUP     = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('tcSubgroup')))
        FT_SUBTYPE      = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('ftSubtype')))
        # Rate / market dimensions
        RATE_CODE       = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('rateCode')))
        MARKET_CODE     = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('marketCode')))
        SOURCE_CODE     = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('sourceCode')))
        # Amounts
        NET_AMOUNT      = (ConvertTo-FinDecimal (Get-FinValue -Source $Raw -Names @('netAmount')))
        GROSS_AMOUNT    = (ConvertTo-FinDecimal (Get-FinValue -Source $Raw -Names @('grossAmount')))
        TRX_AMOUNT      = (ConvertTo-FinDecimal (Get-FinValue -Source $Raw -Names @('trxAmount')))
        POSTED_AMOUNT   = (ConvertTo-FinDecimal (Get-FinValue -Source $Raw -Names @('postedAmount')))
        REVENUE_AMT     = (ConvertTo-FinDecimal (Get-FinValue -Source $Raw -Names @('revenueAmt')))
        QUANTITY        = (ConvertTo-FinDecimal (Get-FinValue -Source $Raw -Names @('quantity')))
        PRICE_PER_UNIT  = (ConvertTo-FinDecimal (Get-FinValue -Source $Raw -Names @('pricePerUnit')))
        EXCHANGE_RATE   = (ConvertTo-FinDecimal (Get-FinValue -Source $Raw -Names @('exchangeRate')))
        CURRENCY        = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('currencyCode', 'currency')))
        IND_REVENUE_GP  = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('indRevenueGp')))
        # Date / time
        POSTING_DATE    = (& $formatDate $postingDate)
        TRX_DATE        = (& $formatDateTime $trxDateLocal)
        TRX_DATE_UTC    = (& $formatDateTime $trxDateUtc)
        IS_LATE_POSTING = $isLatePosting
        # GL export codes — not in FinancialTransactionDetails SA (design note);
        # retrieved via ExportMappings SA if needed. Emitted as $null here.
        COSTCENTER      = $null
        ACCOUNT         = $null
        # Passer-by (non-reservation transactions)
        PASSER_BY_NAME  = (ConvertTo-FinString (Get-FinValue -Source $Raw -Names @('passerByName')))
        # Audit
        BATCH_ID        = $BatchId
    }
}

# ------------------------------------------------------------------------------
# Public: Get-FinancialTransactions
# ------------------------------------------------------------------------------
function Get-FinancialTransactions {
    <#
    .SYNOPSIS
        Extracts posted financial transactions (FIN actuals) for a hotel over a business-date
        range and returns a normalised flat [array] of ra.FIN-shaped [PSCustomObject] rows.

    .DESCRIPTION
        Splits [StartDate, EndDate] into transactionalChunkDays chunks (default 7) via
        Get-DateRangeChunks, builds one ISO-'YYYY-MM-DD'-filtered GraphQL variables set
        per chunk, calls Invoke-RASubjectArea (which accumulates all chunks into one
        array), maps each row to the ra.FIN column contract, populates TRX_DATE_UTC via
        Convert-ToUtc (hotel timeZoneId), formats output dates (YYYYMMDD /
        YYYYMMDD HH:mm:ss), and computes IS_LATE_POSTING (POSTING_DATE/TRX_DATE >
        BUSINESS_DATE). Row count + elapsed ms are logged per chunk per hotel, and a single
        WARN carrying the late-posting count is logged when any late postings are found.

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
        [array] of [PSCustomObject] matching the ra.FIN schema.
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

    $hotelCode = [string](Get-FinValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    if ([string]::IsNullOrWhiteSpace($hotelCode)) {
        throw 'Get-FinancialTransactions: Hotel config is missing a HotelCode.'
    }

    $rangeStart = [datetime]::SpecifyKind($StartDate.Date, [System.DateTimeKind]::Unspecified)
    $rangeEnd = [datetime]::SpecifyKind($EndDate.Date, [System.DateTimeKind]::Unspecified)
    if ($rangeStart -gt $rangeEnd) {
        throw ("Get-FinancialTransactions: StartDate ({0:yyyy-MM-dd}) must be on or before EndDate ({1:yyyy-MM-dd})." -f $rangeStart, $rangeEnd)
    }

    # --- Resolve chunk size (parameter > config > default 7) -----------------
    $effectiveChunkDays = $script:FinDefaultChunkDays
    if ($PSBoundParameters.ContainsKey('ChunkDays')) {
        $effectiveChunkDays = $ChunkDays
    }
    elseif ($null -ne $Config) {
        $extraction = Get-FinValue -Source $Config -Names @('extraction')
        $cfgChunk = if ($null -ne $extraction) {
            Get-FinValue -Source $extraction -Names @('transactionalChunkDays')
        }
        else {
            Get-FinValue -Source $Config -Names @('transactionalChunkDays')
        }
        $parsed = 0
        if ($null -ne $cfgChunk -and [int]::TryParse([string]$cfgChunk, [ref]$parsed) -and $parsed -ge 1) {
            $effectiveChunkDays = $parsed
        }
    }

    # --- Build the date chunks (primary volume control — REQ-011) ------------
    $getChunks = Get-Command -Name 'Get-DateRangeChunks' -ErrorAction SilentlyContinue
    if (-not $getChunks) {
        throw 'Get-FinancialTransactions: Get-DateRangeChunks (DateHelper.psm1) is not available.'
    }
    $chunks = @(& $getChunks -StartDate $rangeStart -EndDate $rangeEnd -ChunkDays $effectiveChunkDays)

    Write-FinLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "SA=FinancialTransactionDetails range={0:yyyy-MM-dd}..{1:yyyy-MM-dd} chunkDays={2} chunks={3}" -f `
            $rangeStart, $rangeEnd, $effectiveChunkDays, $chunks.Count)

    $query = Get-FinGraphQlQuery

    # --- Build one chunk-variable set per chunk (ISO YYYY-MM-DD filters) ------
    # Each element is @{ Variables = <hashtable>; Start; End } so we can:
    #   a) hand the Variables to Invoke-RASubjectArea (which accepts .Variables), and
    #   b) log/attribute per-chunk row counts and durations back to the source range.
    $chunkInputs = foreach ($chunk in $chunks) {
        [PSCustomObject]@{
            Start     = $chunk.Start
            End       = $chunk.End
            Variables = (New-FinChunkVariables -ResortCode $hotelCode -ChunkStart $chunk.Start -ChunkEnd $chunk.End)
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
        throw 'Get-FinancialTransactions: Invoke-RASubjectArea (ApiClient.psm1) is not available and no -SubjectAreaInvoker seam was supplied.'
    }

    $chunkNo = 0
    foreach ($ci in $chunkInputs) {
        $chunkNo++
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        $saArgs = @{
            Operation   = $script:FinOperation
            PrimaryView = $script:FinPrimaryView
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
                    Operation   = $script:FinOperation
                    PrimaryView = $script:FinPrimaryView
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
            Write-FinLog -Level ERROR -HotelCode $hotelCode -BatchId $BatchId -Message (
                "chunk {0}/{1} {2:yyyy-MM-dd}..{3:yyyy-MM-dd} FAILED after {4}ms: {5}" -f `
                    $chunkNo, $chunkInputs.Count, $ci.Start, $ci.End, $sw.ElapsedMilliseconds, $_.Exception.Message)
            throw
        }

        $sw.Stop()
        foreach ($r in $chunkRows) { [void]$rawRows.Add($r) }

        # Log row count + duration per date chunk per hotel.
        Write-FinLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
            "chunk {0}/{1} {2:yyyy-MM-dd}..{3:yyyy-MM-dd} fetched {4} row(s) in {5}ms" -f `
                $chunkNo, $chunkInputs.Count, $ci.Start, $ci.End, @($chunkRows).Count, $sw.ElapsedMilliseconds)
    }

    # --- Map raw rows -> flat ra.FIN PSCustomObjects -------------------------
    $mapped = [System.Collections.Generic.List[object]]::new()
    $lateCount = 0
    foreach ($raw in $rawRows) {
        if ($null -eq $raw) { continue }
        $row = ConvertTo-FinRow -Raw $raw -Hotel $Hotel -BatchId $BatchId
        if ($row.IS_LATE_POSTING -eq 1) { $lateCount++ }
        [void]$mapped.Add($row)
    }

    # --- Single WARN with the late-posting count when any are found ----------
    if ($lateCount -gt 0) {
        Write-FinLog -Level WARN -HotelCode $hotelCode -BatchId $BatchId -Message (
            "{0} late posting(s) (TRX_DATE > BUSINESS_DATE)." -f $lateCount)
    }

    Write-FinLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "FIN extraction complete: {0} row(s) across {1} chunk(s); {2} late posting(s)." -f `
            $mapped.Count, $chunkInputs.Count, $lateCount)

    # Return a real [array] even for 0/1 rows (unary comma prevents pipeline unwrap).
    $flat = [object[]]$mapped.ToArray()
    return , $flat
}

# Design consistency: design.md names the function Get-FIN. Expose it as an alias so
# both the design name and the Task 9 name (Get-FinancialTransactions) resolve.
Set-Alias -Name 'Get-FIN' -Value 'Get-FinancialTransactions'

# ------------------------------------------------------------------------------
# Exported surface
# ------------------------------------------------------------------------------
Export-ModuleMember -Function @('Get-FinancialTransactions') -Alias @('Get-FIN')
