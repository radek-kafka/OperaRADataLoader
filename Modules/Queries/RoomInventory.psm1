# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Room Inventory query module for the OPERA R&A Data Loader (Task 12).

.DESCRIPTION
    Extracts the "room inventory" picture for a hotel from the OHIP R&A Data API and
    returns it as two normalised flat [array]s of [PSCustomObject] rows:

      RMN — the physical room configuration list (static; one row per room).
            Subject Area : InventoryRooms
            Operation    : inventoryRooms
            Primary view : inventoryRooms
            Target table : ra.RMN   (natural key RESORT + ROOM)

      OOO — the per-date Out-Of-Order / Out-Of-Service counts by room class.
            Subject Area : StatisticsManagersReport
            Operation    : statisticsManagersReport
            Primary view : statisticsManagersReport
            Target table : ra.OOO   (natural key RESORT + BUSINESS_DATE + ROOM_CLASS)

    ------------------------------------------------------------------------------
    RECONCILIATION — Task 12 text vs SQL\003 + design.md
    ------------------------------------------------------------------------------
    The Task 12 text describes a single "ra.RoomInventory" table with columns
    InventoryDate, RoomTypeLabel, PhysicalRooms, OutOfOrder, OutOfService. The
    authoritative schema (SQL\003_CreateTables_Snapshots.sql + design.md) SPLITS this
    single logical view into two physical tables:

        ra.RoomInventory (logical)  ─┬─►  ra.RMN  (physical room list — static)
                                     └─►  ra.OOO  (daily OOO/OS counts by BUSINESS_DATE
                                                   + ROOM_CLASS)

    Column reconciliation (Task text -> authoritative):
        InventoryDate   -> ra.OOO.BUSINESS_DATE           (per-date grain lives in OOO)
        RoomTypeLabel   -> ra.RMN.ROOM_CATEGORY_LABEL      (physical grain lives in RMN);
                           the OOO grain is ROOM_CLASS (a coarser grouping than the room
                           category label), so per-class OOO/OS aggregates sit on ra.OOO.
        PhysicalRooms   -> derived: COUNT of ra.RMN rows per category (physical room list),
                           and ra.OOO.PHYSICAL_BEDS carries the bed-level physical count
                           the managers-report SA returns per room class.
        OutOfOrder      -> ra.OOO.OOO_ROOMS
        OutOfService    -> ra.OOO.OS_ROOMS
        AvailableRooms  -> ra.OOO.AVAIL_ROOM (= PhysicalRooms - occupied - OOO - OS)

    Because a single ra.RoomInventory row cannot represent both the static physical list
    and the per-date counts, this module returns BOTH shapes so the orchestrator can call:

        $inv = Get-RoomInventory -Hotel $h -StartDate $s -EndDate $e ...
        Write-RoomInventory -RoomData $inv.RMN -OooData $inv.OOO ...
        # (equivalently: Write-RMN -Data $inv.RMN ...; Write-OOO -Data $inv.OOO ...)

    Return shape: a [hashtable] @{ RMN = [array]; OOO = [array] }. Get-RMN and Get-OOO are
    also exported so callers that want a single shape can take just one array.

    ------------------------------------------------------------------------------
    Pipeline (design.md — Queries\RoomInventory.psm1)
    ------------------------------------------------------------------------------
      1. Get-RoomInventory -Hotel -StartDate -EndDate is the public entry point. It calls
         Get-RMN once (static, no date filter) and Get-OOO over the [StartDate, EndDate]
         range, then returns @{ RMN; OOO }.
      2. RMN is a STATIC room list — fetched ONCE via the InventoryRooms SA with no
         per-date chunking (a room's physical configuration does not vary by day). Its
         ROOM_STATUS reflects the current day only (design note).
      3. OOO is per-date. The [StartDate, EndDate] range is split into chunks of
         transactionalChunkDays (default 7) via DateHelper\Get-DateRangeChunks — the same
         primary volume control the transactional modules use (REQ-011). Per chunk a
         GraphQL variables set is built with ISO 'YYYY-MM-DD' filters (resort _in,
         businessDate _gte/_lte). NOTE: request filters keep ISO 'YYYY-MM-DD' — they are
         NOT the compact YYYYMMDD output format.
      4. All chunks are passed to ApiClient\Invoke-RASubjectArea, which issues one GraphQL
         POST per chunk (honouring throttle + backoff) and accumulates every chunk's rows
         into ONE flat [array].
      5. Each raw row is mapped to its OPERA-native column contract (ra.RMN / ra.OOO).
         The BUSINESS_DATE output field is formatted with DateHelper\Format-OutputDate
         (YYYYMMDD) on the OUTPUT rows only.

    Historical + future in one call (Task 12.5): the [StartDate, EndDate] range may span
    past AND future dates (actuals + forecast). The module does NOT special-case "today" —
    Get-DateRangeChunks chunks the whole range uniformly and every chunk is queried the
    same way, so a range crossing the current date is handled transparently.

    AvailableRooms (Task 12.4): AVAIL_ROOM is emitted straight from the API when supplied.
    Only when the API OMITS it is it computed as PhysicalRooms - OutOfOrder - OutOfService
    (null-guarded — if any operand is missing the value stays $null; an API-supplied value
    is never overwritten). PhysicalRooms here uses the row's PHYSICAL_BEDS (the physical
    count the managers-report SA returns for the room class).

    Business-date / missing-data behaviour (steering):
      - Business dates are date-only; the OOO date filter and BUSINESS_DATE output carry
        no time-of-day.
      - Missing / empty source values are emitted as $null consistently and never crash
        the mapper (fallback logic). A blank RESORT in a row is backfilled from the hotel
        code (the resort filter is mandatory).
      - Rate-limit / retry / throttle are handled by the shared ApiClient layer.

    Test seam (unit-testable without network):
      -SubjectAreaInvoker : a scriptblock invoked INSTEAD of the real
                            ApiClient\Invoke-RASubjectArea. It receives a single hashtable
                            of the arguments this module would have passed
                            (@{ Operation; PrimaryView; Query; Chunks; Hotel; Token; Config })
                            and must return an [array] of raw row objects. When omitted the
                            real Invoke-RASubjectArea is used.
      -Invoker / -Sleep   : forwarded to the real Invoke-RASubjectArea (HTTP + throttle
                            seams) when -SubjectAreaInvoker is not supplied.

.NOTES
    Logger -Module constant: "RoomInventory".
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
$script:RmnOperation   = 'inventoryRooms'                 # InventoryRooms SA -> ra.RMN
$script:RmnPrimaryView = 'inventoryRooms'
$script:OooOperation   = 'statisticsManagersReport'       # StatisticsManagersReport SA -> ra.OOO
$script:OooPrimaryView = 'statisticsManagersReport'
$script:OooDefaultChunkDays = 7   # extraction.transactionalChunkDays fallback

# ------------------------------------------------------------------------------
# Logging helper — shared Logger when loaded, else Write-Verbose. Never throws.
# ------------------------------------------------------------------------------
function Write-InvLog {
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
            & $writeLog -Level $Level -Module 'RoomInventory' -Message $Message -HotelCode $HotelCode -BatchId $BatchId
            return
        }
        catch {
            # A logger failure must never break extraction — fall through to verbose.
        }
    }

    Write-Verbose ("RoomInventory [{0}] {1}: {2}" -f $Level, $HotelCode, $Message)
}

# ------------------------------------------------------------------------------
# Internal: case-insensitive lookup from a hashtable / PSCustomObject.
# ------------------------------------------------------------------------------
function Get-InvValue {
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
function ConvertTo-InvString {
    [CmdletBinding()]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text.Trim()
}

# ------------------------------------------------------------------------------
# Internal: normalise a raw API value to a nullable [int] (room / bed counts).
# Returns $null for null/empty/non-numeric so downstream persistence stays clean.
# ------------------------------------------------------------------------------
function ConvertTo-InvInt {
    [CmdletBinding()]
    [OutputType([Nullable[int]])]
    param([Parameter(Position = 0)] [AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    if ($Value -is [int]) { return [int]$Value }
    if ($Value -is [long] -or $Value -is [short] -or $Value -is [byte]) { return [int]$Value }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return [int][math]::Round([double]$Value, [System.MidpointRounding]::AwayFromZero)
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsedInt = 0
    if ([int]::TryParse($text, [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedInt)) {
        return $parsedInt
    }
    # Tolerate decimal-formatted counts ("5.0") from the API.
    $parsedDec = [decimal]0
    if ([decimal]::TryParse($text, [System.Globalization.NumberStyles]::Any,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedDec)) {
        return [int][math]::Round([double]$parsedDec, [System.MidpointRounding]::AwayFromZero)
    }
    return $null
}

# ------------------------------------------------------------------------------
# Internal: build the RMN (InventoryRooms) GraphQL query string.
# ------------------------------------------------------------------------------
function Get-RmnGraphQlQuery {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $fields = @('resort', 'room', 'roomCategoryLabel', 'roomClass', 'roomStatus') -join ' '
    $view = $script:RmnPrimaryView
    $op = $script:RmnOperation

    return ("query InventoryRooms(`$input: InventoryRoomsQueryArgumentsType!) " +
        "{ $op(input: `$input) { $view { $fields } } }")
}

# ------------------------------------------------------------------------------
# Internal: build the OOO (StatisticsManagersReport) GraphQL query string.
# ------------------------------------------------------------------------------
function Get-OooGraphQlQuery {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $fields = @(
        'resort', 'businessDate', 'roomClass',
        'oooRooms', 'osRooms', 'availRoom',
        'physicalBeds', 'oooBeds', 'osBeds'
    ) -join ' '
    $view = $script:OooPrimaryView
    $op = $script:OooOperation

    return ("query StatisticsManagersReport(`$input: StatisticsManagersReportQueryArgumentsType!) " +
        "{ $op(input: `$input) { $view { $fields } } }")
}

# ------------------------------------------------------------------------------
# Internal: build the RMN variables set (static — resort filter only, no dates).
# ------------------------------------------------------------------------------
function New-RmnVariables {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $ResortCode
    )

    return @{
        input = @{
            resort = @{ _in = @($ResortCode) }
        }
    }
}

# ------------------------------------------------------------------------------
# Internal: build one OOO variables set for a single date chunk.
# Request filters use ISO 'YYYY-MM-DD' (NOT the YYYYMMDD output format).
# ------------------------------------------------------------------------------
function New-OooChunkVariables {
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
# Internal: map ONE raw InventoryRooms row to a flat ra.RMN-shaped [PSCustomObject].
# ------------------------------------------------------------------------------
function ConvertTo-RmnRow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)] $Hotel,
        [Parameter()] [AllowNull()] [guid] $BatchId = [guid]::Empty
    )

    $resort = ConvertTo-InvString (Get-InvValue -Source $Raw -Names @('resort'))
    if ($null -eq $resort) {
        # Fallback: resort filter is mandatory, so backfill a blank resort from the hotel.
        $resort = ConvertTo-InvString (Get-InvValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    }
    $chainCode = ConvertTo-InvString (Get-InvValue -Source $Hotel -Names @('ChainCode', 'chainCode'))

    return [PSCustomObject][ordered]@{
        RESORT              = $resort
        CHAIN_CODE          = $chainCode
        ROOM                = (ConvertTo-InvString (Get-InvValue -Source $Raw -Names @('room')))
        ROOM_CATEGORY_LABEL = (ConvertTo-InvString (Get-InvValue -Source $Raw -Names @('roomCategoryLabel', 'roomCategory')))
        ROOM_CLASS          = (ConvertTo-InvString (Get-InvValue -Source $Raw -Names @('roomClass')))
        ROOM_STATUS         = (ConvertTo-InvString (Get-InvValue -Source $Raw -Names @('roomStatus')))
        BATCH_ID            = $BatchId
    }
}

# ------------------------------------------------------------------------------
# Internal: map ONE raw StatisticsManagersReport row to a flat ra.OOO-shaped object.
# AVAIL_ROOM is computed (PHYSICAL_BEDS - OOO_ROOMS - OS_ROOMS) ONLY when the API omits
# it; an API-supplied value is never overwritten, and a missing operand keeps it $null.
# ------------------------------------------------------------------------------
function ConvertTo-OooRow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)] $Hotel,
        [Parameter()] [AllowNull()] [guid] $BatchId = [guid]::Empty
    )

    $resort = ConvertTo-InvString (Get-InvValue -Source $Raw -Names @('resort'))
    if ($null -eq $resort) {
        $resort = ConvertTo-InvString (Get-InvValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    }
    $chainCode = ConvertTo-InvString (Get-InvValue -Source $Hotel -Names @('ChainCode', 'chainCode'))

    # --- Raw date value (parsed / formatted for OUTPUT only) ------------------
    $businessDateRaw = Get-InvValue -Source $Raw -Names @('businessDate')

    # --- Counts ---------------------------------------------------------------
    $oooRooms = ConvertTo-InvInt (Get-InvValue -Source $Raw -Names @('oooRooms'))
    $osRooms = ConvertTo-InvInt (Get-InvValue -Source $Raw -Names @('osRooms'))
    $physicalBeds = ConvertTo-InvInt (Get-InvValue -Source $Raw -Names @('physicalBeds'))

    # --- AVAIL_ROOM: prefer the API value; compute only when the API omits it -
    # AvailableRooms = PhysicalRooms - OutOfOrder - OutOfService. Null-guard the
    # operands (a missing operand leaves AVAIL_ROOM $null) and NEVER overwrite an
    # API-supplied value (Task 12.4).
    $availRoom = ConvertTo-InvInt (Get-InvValue -Source $Raw -Names @('availRoom'))
    if ($null -eq $availRoom) {
        if ($null -ne $physicalBeds -and $null -ne $oooRooms -and $null -ne $osRooms) {
            $availRoom = $physicalBeds - $oooRooms - $osRooms
        }
    }

    # --- Output date formatting via DateHelper (YYYYMMDD) ---------------------
    $fmtDate = Get-Command -Name 'Format-OutputDate' -ErrorAction SilentlyContinue
    $businessDateOut = if ($fmtDate) {
        [string](& $fmtDate $businessDateRaw)
    }
    else {
        $dt = $businessDateRaw -as [datetime]
        if ($null -eq $dt) { '' } else { $dt.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture) }
    }

    return [PSCustomObject][ordered]@{
        RESORT        = $resort
        CHAIN_CODE    = $chainCode
        BUSINESS_DATE = $businessDateOut          # InventoryDate (out: YYYYMMDD)
        ROOM_CLASS    = (ConvertTo-InvString (Get-InvValue -Source $Raw -Names @('roomClass')))
        OOO_ROOMS     = $oooRooms                 # OutOfOrder
        OS_ROOMS      = $osRooms                  # OutOfService
        AVAIL_ROOM    = $availRoom                # AvailableRooms
        OOO_BEDS      = (ConvertTo-InvInt (Get-InvValue -Source $Raw -Names @('oooBeds')))
        OS_BEDS       = (ConvertTo-InvInt (Get-InvValue -Source $Raw -Names @('osBeds')))
        PHYSICAL_BEDS = $physicalBeds             # PhysicalRooms (bed-level physical count)
        BATCH_ID      = $BatchId
    }
}

# ------------------------------------------------------------------------------
# Internal: resolve the effective chunk size (parameter > config > default 7).
# ------------------------------------------------------------------------------
function Resolve-InvChunkDays {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()] [AllowNull()] [Nullable[int]] $ChunkDays,
        [Parameter()] $Config
    )

    if ($null -ne $ChunkDays) { return [int]$ChunkDays }

    if ($null -ne $Config) {
        $extraction = Get-InvValue -Source $Config -Names @('extraction')
        $cfgChunk = if ($null -ne $extraction) {
            Get-InvValue -Source $extraction -Names @('transactionalChunkDays')
        }
        else {
            Get-InvValue -Source $Config -Names @('transactionalChunkDays')
        }
        $parsed = 0
        if ($null -ne $cfgChunk -and [int]::TryParse([string]$cfgChunk, [ref]$parsed) -and $parsed -ge 1) {
            return $parsed
        }
    }
    return $script:OooDefaultChunkDays
}

# ------------------------------------------------------------------------------
# Internal: invoke a Subject Area for one variables set and return raw rows.
# Centralises the seam handling shared by Get-RMN (single call) and Get-OOO (per chunk).
# ------------------------------------------------------------------------------
function Invoke-InvSubjectArea {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [string] $PrimaryView,
        [Parameter(Mandatory)] [string] $Query,
        [Parameter(Mandatory)] [hashtable] $Variables,
        [Parameter(Mandatory)] $Hotel,
        [Parameter()] [string] $Token,
        [Parameter()] $Config,
        [Parameter()] [scriptblock] $SubjectAreaInvoker,
        [Parameter()] [scriptblock] $Invoker,
        [Parameter()] [scriptblock] $Sleep
    )

    $saArgs = @{
        Operation   = $Operation
        PrimaryView = $PrimaryView
        Query       = $Query
        Chunks      = @(@{ Variables = $Variables })
        Hotel       = $Hotel
        Config      = $Config
    }
    if (-not [string]::IsNullOrWhiteSpace($Token)) { $saArgs['Token'] = $Token }

    if ($SubjectAreaInvoker) {
        return @(& $SubjectAreaInvoker $saArgs)
    }

    $invokeReal = Get-Command -Name 'Invoke-RASubjectArea' -ErrorAction SilentlyContinue
    if (-not $invokeReal) {
        throw ("RoomInventory: Invoke-RASubjectArea (ApiClient.psm1) is not available and no -SubjectAreaInvoker seam was supplied (operation '{0}')." -f $Operation)
    }

    $realArgs = @{
        Hotel       = $Hotel
        Operation   = $Operation
        PrimaryView = $PrimaryView
        Query       = $Query
        Chunks      = @(@{ Variables = $Variables })
        Config      = $Config
    }
    if ($saArgs.ContainsKey('Token')) { $realArgs['Token'] = $Token }
    if ($Invoker) { $realArgs['Invoker'] = $Invoker }
    if ($Sleep) { $realArgs['Sleep'] = $Sleep }

    return @(& $invokeReal @realArgs)
}

# ------------------------------------------------------------------------------
# Public: Get-RMN — static physical room list (ra.RMN).
# ------------------------------------------------------------------------------
function Get-RMN {
    <#
    .SYNOPSIS
        Extracts the static physical room configuration list for a hotel and returns a
        normalised flat [array] of ra.RMN-shaped [PSCustomObject] rows.

    .DESCRIPTION
        Issues a SINGLE InventoryRooms request (no date filter — the physical room list is
        static and does not vary by day) via Invoke-RASubjectArea, then maps each row to the
        ra.RMN column contract (RESORT, CHAIN_CODE, ROOM, ROOM_CATEGORY_LABEL, ROOM_CLASS,
        ROOM_STATUS). ROOM_STATUS reflects the current day only (design note).

    .PARAMETER Hotel
        Hotel configuration (hashtable / PSCustomObject). Recognised keys (case-insensitive):
        HotelCode (RESORT), ChainCode.

    .PARAMETER Token
        Optional bearer token forwarded to the API layer.

    .PARAMETER Config
        Optional settings object supplying api.* throttle/retry settings.

    .PARAMETER BatchId
        Optional batch GUID stamped on every output row (BATCH_ID) and used in log context.

    .PARAMETER SubjectAreaInvoker
        Optional test/DI seam invoked INSTEAD of Invoke-RASubjectArea.

    .PARAMETER Invoker
        Optional HTTP seam forwarded to the real Invoke-RASubjectArea.

    .PARAMETER Sleep
        Optional throttle/backoff seam forwarded to the real Invoke-RASubjectArea.

    .OUTPUTS
        [array] of [PSCustomObject] matching the ra.RMN schema.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] $Hotel,
        [Parameter()] [string] $Token,
        [Parameter()] $Config,
        [Parameter()] [guid] $BatchId = [guid]::Empty,
        [Parameter()] [scriptblock] $SubjectAreaInvoker,
        [Parameter()] [scriptblock] $Invoker,
        [Parameter()] [scriptblock] $Sleep
    )

    $hotelCode = [string](Get-InvValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    if ([string]::IsNullOrWhiteSpace($hotelCode)) {
        throw 'Get-RMN: Hotel config is missing a HotelCode.'
    }

    Write-InvLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message 'SA=InventoryRooms (static room list; single request).'

    $query = Get-RmnGraphQlQuery
    $variables = New-RmnVariables -ResortCode $hotelCode

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rawRows = @()
    try {
        $rawRows = @(Invoke-InvSubjectArea -Operation $script:RmnOperation -PrimaryView $script:RmnPrimaryView `
                -Query $query -Variables $variables -Hotel $Hotel -Token $Token -Config $Config `
                -SubjectAreaInvoker $SubjectAreaInvoker -Invoker $Invoker -Sleep $Sleep)
    }
    catch {
        $sw.Stop()
        Write-InvLog -Level ERROR -HotelCode $hotelCode -BatchId $BatchId -Message (
            "RMN fetch FAILED after {0}ms: {1}" -f $sw.ElapsedMilliseconds, $_.Exception.Message)
        throw
    }
    $sw.Stop()

    $mapped = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in $rawRows) {
        if ($null -eq $raw) { continue }
        [void]$mapped.Add((ConvertTo-RmnRow -Raw $raw -Hotel $Hotel -BatchId $BatchId))
    }

    Write-InvLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "RMN extraction complete: {0} room(s) in {1}ms." -f $mapped.Count, $sw.ElapsedMilliseconds)

    # Return a real [array] even for 0/1 rows (unary comma prevents pipeline unwrap).
    $flat = [object[]]$mapped.ToArray()
    return , $flat
}

# ------------------------------------------------------------------------------
# Public: Get-OOO — per-date Out-Of-Order / Out-Of-Service counts (ra.OOO).
# ------------------------------------------------------------------------------
function Get-OOO {
    <#
    .SYNOPSIS
        Extracts daily Out-Of-Order / Out-Of-Service room counts by room class over a
        business-date range and returns a normalised flat [array] of ra.OOO-shaped
        [PSCustomObject] rows.

    .DESCRIPTION
        Splits [StartDate, EndDate] into transactionalChunkDays chunks (default 7) via
        Get-DateRangeChunks, builds one ISO-'YYYY-MM-DD'-filtered StatisticsManagersReport
        variables set per chunk, calls Invoke-RASubjectArea per chunk (accumulating rows
        into one array), maps each row to the ra.OOO column contract, formats BUSINESS_DATE
        (YYYYMMDD), and computes AVAIL_ROOM (PHYSICAL_BEDS - OOO_ROOMS - OS_ROOMS) only when
        the API omits it. Row count + elapsed ms are logged per chunk per hotel.

        The [StartDate, EndDate] range may span historical AND future dates (actuals +
        forecast) in a single call — the chunking + per-chunk query is uniform and does not
        special-case the current date (Task 12.5).

    .PARAMETER Hotel
        Hotel configuration (hashtable / PSCustomObject). Recognised keys (case-insensitive):
        HotelCode (RESORT), ChainCode.

    .PARAMETER StartDate
        Inclusive start business date. Date component only.

    .PARAMETER EndDate
        Inclusive end business date. Date component only. Must be >= StartDate.

    .PARAMETER ChunkDays
        Max days per chunk. Optional; defaults to Config.extraction.transactionalChunkDays,
        else 7.

    .PARAMETER Token
        Optional bearer token forwarded to the API layer.

    .PARAMETER Config
        Optional settings object supplying extraction.transactionalChunkDays and api.*.

    .PARAMETER BatchId
        Optional batch GUID stamped on every output row (BATCH_ID) and used in log context.

    .PARAMETER SubjectAreaInvoker
        Optional test/DI seam invoked INSTEAD of Invoke-RASubjectArea.

    .PARAMETER Invoker
        Optional HTTP seam forwarded to the real Invoke-RASubjectArea.

    .PARAMETER Sleep
        Optional throttle/backoff seam forwarded to the real Invoke-RASubjectArea.

    .OUTPUTS
        [array] of [PSCustomObject] matching the ra.OOO schema.
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

    $hotelCode = [string](Get-InvValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    if ([string]::IsNullOrWhiteSpace($hotelCode)) {
        throw 'Get-OOO: Hotel config is missing a HotelCode.'
    }

    $rangeStart = [datetime]::SpecifyKind($StartDate.Date, [System.DateTimeKind]::Unspecified)
    $rangeEnd = [datetime]::SpecifyKind($EndDate.Date, [System.DateTimeKind]::Unspecified)
    if ($rangeStart -gt $rangeEnd) {
        throw ("Get-OOO: StartDate ({0:yyyy-MM-dd}) must be on or before EndDate ({1:yyyy-MM-dd})." -f $rangeStart, $rangeEnd)
    }

    $effectiveChunkDays = Resolve-InvChunkDays -ChunkDays ($(if ($PSBoundParameters.ContainsKey('ChunkDays')) { $ChunkDays } else { $null })) -Config $Config

    $getChunks = Get-Command -Name 'Get-DateRangeChunks' -ErrorAction SilentlyContinue
    if (-not $getChunks) {
        throw 'Get-OOO: Get-DateRangeChunks (DateHelper.psm1) is not available.'
    }
    $chunks = @(& $getChunks -StartDate $rangeStart -EndDate $rangeEnd -ChunkDays $effectiveChunkDays)

    Write-InvLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "SA=StatisticsManagersReport range={0:yyyy-MM-dd}..{1:yyyy-MM-dd} chunkDays={2} chunks={3}" -f `
            $rangeStart, $rangeEnd, $effectiveChunkDays, $chunks.Count)

    $query = Get-OooGraphQlQuery

    # Build one chunk-variable set per chunk (ISO YYYY-MM-DD filters), retaining the
    # source Start/End so per-chunk row counts/durations can be attributed back.
    $chunkInputs = foreach ($chunk in $chunks) {
        [PSCustomObject]@{
            Start     = $chunk.Start
            End       = $chunk.End
            Variables = (New-OooChunkVariables -ResortCode $hotelCode -ChunkStart $chunk.Start -ChunkEnd $chunk.End)
        }
    }
    $chunkInputs = @($chunkInputs)

    # Iterate chunk-by-chunk so each chunk's row count + elapsed time is logged
    # individually, while ACCUMULATING every chunk's rows into a single flat array.
    $rawRows = [System.Collections.Generic.List[object]]::new()
    $chunkNo = 0
    foreach ($ci in $chunkInputs) {
        $chunkNo++
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        $chunkRows = @()
        try {
            $chunkRows = @(Invoke-InvSubjectArea -Operation $script:OooOperation -PrimaryView $script:OooPrimaryView `
                    -Query $query -Variables $ci.Variables -Hotel $Hotel -Token $Token -Config $Config `
                    -SubjectAreaInvoker $SubjectAreaInvoker -Invoker $Invoker -Sleep $Sleep)
        }
        catch {
            $sw.Stop()
            Write-InvLog -Level ERROR -HotelCode $hotelCode -BatchId $BatchId -Message (
                "chunk {0}/{1} {2:yyyy-MM-dd}..{3:yyyy-MM-dd} FAILED after {4}ms: {5}" -f `
                    $chunkNo, $chunkInputs.Count, $ci.Start, $ci.End, $sw.ElapsedMilliseconds, $_.Exception.Message)
            throw
        }

        $sw.Stop()
        foreach ($r in $chunkRows) { [void]$rawRows.Add($r) }

        Write-InvLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
            "chunk {0}/{1} {2:yyyy-MM-dd}..{3:yyyy-MM-dd} fetched {4} row(s) in {5}ms" -f `
                $chunkNo, $chunkInputs.Count, $ci.Start, $ci.End, @($chunkRows).Count, $sw.ElapsedMilliseconds)
    }

    $mapped = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in $rawRows) {
        if ($null -eq $raw) { continue }
        [void]$mapped.Add((ConvertTo-OooRow -Raw $raw -Hotel $Hotel -BatchId $BatchId))
    }

    Write-InvLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "OOO extraction complete: {0} row(s) across {1} chunk(s)." -f $mapped.Count, $chunkInputs.Count)

    # Return a real [array] even for 0/1 rows (unary comma prevents pipeline unwrap).
    $flat = [object[]]$mapped.ToArray()
    return , $flat
}

# ------------------------------------------------------------------------------
# Public: Get-RoomInventory — the combined RoomInventory picture (RMN + OOO).
# ------------------------------------------------------------------------------
function Get-RoomInventory {
    <#
    .SYNOPSIS
        Extracts the full room-inventory picture for a hotel over a business-date range and
        returns it as @{ RMN = [array]; OOO = [array] } (physical room list + daily OOO/OS
        counts), ready for SqlWriter\Write-RoomInventory -RoomData <RMN> -OooData <OOO>.

    .DESCRIPTION
        The Task 12 single "ra.RoomInventory" view is reconciled to the authoritative
        ra.RMN + ra.OOO split (see the module header). This entry point:
          1. Calls Get-RMN once (static InventoryRooms room list — no date chunking).
          2. Calls Get-OOO over [StartDate, EndDate] (StatisticsManagersReport, chunked by
             transactionalChunkDays; AVAIL_ROOM computed only when the API omits it).
          3. Returns @{ RMN = [array]; OOO = [array] }.

        The date range may span historical AND future dates in a single call (Task 12.5) —
        the OOO chunking is uniform and does not special-case the current date.

    .PARAMETER Hotel
        Hotel configuration (hashtable / PSCustomObject). Recognised keys (case-insensitive):
        HotelCode (RESORT), ChainCode.

    .PARAMETER StartDate
        Inclusive start business date for the OOO range. Date component only.

    .PARAMETER EndDate
        Inclusive end business date for the OOO range. Date component only. Must be >= StartDate.

    .PARAMETER ChunkDays
        Max days per OOO chunk. Optional; defaults to Config.extraction.transactionalChunkDays,
        else 7.

    .PARAMETER Token
        Optional bearer token forwarded to the API layer.

    .PARAMETER Config
        Optional settings object supplying extraction.transactionalChunkDays and api.*.

    .PARAMETER BatchId
        Optional batch GUID stamped on every output row (BATCH_ID) and used in log context.

    .PARAMETER SubjectAreaInvoker
        Optional test/DI seam invoked INSTEAD of Invoke-RASubjectArea for BOTH sub-queries.
        The invoker can branch on the $args.Operation ('inventoryRooms' vs
        'statisticsManagersReport') to return the appropriate raw rows.

    .PARAMETER Invoker
        Optional HTTP seam forwarded to the real Invoke-RASubjectArea.

    .PARAMETER Sleep
        Optional throttle/backoff seam forwarded to the real Invoke-RASubjectArea.

    .OUTPUTS
        [hashtable] @{ RMN = [array]; OOO = [array] }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
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

    $hotelCode = [string](Get-InvValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    if ([string]::IsNullOrWhiteSpace($hotelCode)) {
        throw 'Get-RoomInventory: Hotel config is missing a HotelCode.'
    }

    Write-InvLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "RoomInventory extraction start: range={0:yyyy-MM-dd}..{1:yyyy-MM-dd}" -f $StartDate.Date, $EndDate.Date)

    # --- Common seam args (forwarded to both sub-queries) --------------------
    $common = @{
        Hotel   = $Hotel
        Config  = $Config
        BatchId = $BatchId
    }
    if ($PSBoundParameters.ContainsKey('Token') -and -not [string]::IsNullOrWhiteSpace($Token)) { $common['Token'] = $Token }
    if ($SubjectAreaInvoker) { $common['SubjectAreaInvoker'] = $SubjectAreaInvoker }
    if ($Invoker) { $common['Invoker'] = $Invoker }
    if ($Sleep) { $common['Sleep'] = $Sleep }

    # --- RMN: static physical room list (single request) ---------------------
    # Assign to a variable BEFORE wrapping in @(): Get-RMN returns via the unary-comma
    # idiom (return , $flat), which nests when piped directly into @(...). Assigning
    # first, then @()-wrapping, yields the correct flat array for any row count.
    $rmnResult = Get-RMN @common
    $rmn = @($rmnResult)

    # --- OOO: per-date OOO/OS counts (chunked range) -------------------------
    $oooArgs = $common.Clone()
    $oooArgs['StartDate'] = $StartDate
    $oooArgs['EndDate'] = $EndDate
    if ($PSBoundParameters.ContainsKey('ChunkDays')) { $oooArgs['ChunkDays'] = $ChunkDays }
    $oooResult = Get-OOO @oooArgs
    $ooo = @($oooResult)

    Write-InvLog -Level INFO -HotelCode $hotelCode -BatchId $BatchId -Message (
        "RoomInventory extraction complete: {0} RMN room(s), {1} OOO row(s)." -f $rmn.Count, $ooo.Count)

    # Return the reconciled two-shape result. Hashtable values do not unwrap, so the
    # arrays are stored directly (the caller passes .RMN / .OOO straight to the writers).
    return @{
        RMN = [object[]]$rmn
        OOO = [object[]]$ooo
    }
}

# Design consistency: design.md names the public functions Get-RMN and Get-OOO;
# Task 12 names the combined entry point Get-RoomInventory. Expose all three.
# Get-RoomInventory is the orchestrator entry point; Get-RMN / Get-OOO can be called
# individually (e.g. to write only one target).

# ------------------------------------------------------------------------------
# Exported surface
# ------------------------------------------------------------------------------
Export-ModuleMember -Function @('Get-RoomInventory', 'Get-RMN', 'Get-OOO')
