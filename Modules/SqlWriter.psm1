# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Database writer module for the OPERA R&A Data Loader.

.DESCRIPTION
    SqlWriter.psm1 owns ALL SQL Server persistence for the loader. It creates the
    schema on startup (Initialize-Database) and upserts each subject area into the
    OPERA-native tables via a common "SqlBulkCopy → #staging → parameterized MERGE"
    pipeline:

        Transactional (RES, FIN) → bulk-copy to #staging → MERGE on natural key
        Snapshots     (OTB, BLK) → bulk-copy to #staging → MERGE on snapshot key
                                    (new SNAPSHOT_DATE rows accumulate; prior
                                     snapshots are NEVER overwritten)
        Inventory     (RMN, OOO) → bulk-copy to #staging → MERGE on natural key
        Master data   (DIM_*, Hotels) → SCD Type 2 (VALID_FROM / VALID_TO / IS_CURRENT)

    Authoritative MERGE targets (OPERA-native names created in SQL\002-004):
        dbo.LoadLog
        ra.RES  (alias ReservationStats)  NK: RESORT+BUSINESS_DATE+RESV_NAME_ID+MARKET_CODE+ROOM_CATEGORY_LABEL
        ra.FIN  (alias FinancialTx)        NK: RESORT+BUSINESS_DATE+TRX_NO+TRAN_ACTION_ID ; IS_LATE_POSTING
        ra.OTB  (alias OnTheBooks)         NK includes SNAPSHOT_DATE → snapshots accumulate
        ra.BLK  (alias BlockReservations)  NK: RESORT+SNAPSHOT_DATE+BLOCK_CODE+CONSIDERED_DATE+ROOM_CATEGORY_LABEL ; IS_PAST_CUTOFF
        ra.RMN  NK: RESORT+ROOM ; ra.OOO NK: RESORT+BUSINESS_DATE+ROOM_CLASS  (RoomInventory split)
        SCD2 masters: ra.DIM_TrxCodes, ra.DIM_RoomTypes, ra.DIM_MarketCodes,
                      ra.DIM_RateCodes, ra.DIM_SourceCodes, ra.DIM_Channels
                      (SourceCodes and Channels are INDEPENDENT lists — never merged)
        ra.Hotels (single current row per RESORT — UNIQUE RESORT)

    TEST SEAM (unit-testable WITHOUT a live SQL Server):
        Every public writer + Initialize-Database accept -SqlExecutor and -BulkCopy
        script blocks. When supplied they replace the real Microsoft.Data.SqlClient
        calls, so MERGE/bulk logic, SCD2 transitions and IS_LATE_POSTING /
        IS_PAST_CUTOFF computations can be verified in isolation. When omitted, the
        module uses Microsoft.Data.SqlClient (falling back to System.Data.SqlClient).

          -SqlExecutor : scriptblock invoked as & $SqlExecutor $Sql $Parameters
                         where $Parameters is [hashtable] name→value. Returns an
                         [int] rows-affected for non-queries, or an object[] of rows
                         (each a hashtable/PSCustomObject) for queries.
          -BulkCopy    : scriptblock invoked as & $BulkCopy $StagingTable $Rows $ColumnMap
                         to load the staging table. Returns [int] rows copied.

    RECONCILIATION WITH Logger.psm1 Start-Batch / Complete-Batch:
        Logger.psm1 already mirrors batch lifecycle rows to dbo.LoadLog and remains
        the primary batch-logging surface. However, Logger's Start-Batch /
        Complete-Batch were written against a *proposed* LoadLog contract
        (StartedAt / CompletedAt / DurationMs / RowsFetched) that does NOT match the
        DDL actually created in SQL\002 (StartTime / EndTime / DurationSeconds
        computed / [RowCount]). SqlWriter's Write-LoadLog is the single source of
        truth aligned to the ACTUAL dbo.LoadLog DDL, so it COMPLEMENTS (does not
        duplicate) Logger: callers that want the DDL-accurate contract use
        Write-LoadLog; Logger's batch helpers should be reconciled to call it (or be
        updated to the DDL columns) in a follow-up. Write-LoadLog is idempotent per
        (BatchId, HotelCode, QueryType): it INSERTs the initial Running row and
        UPDATEs the same row on completion.

    All SQL is parameterized — no run-time value is concatenated into SQL text
    (injection-safe). Every MERGE runs inside a transaction that is rolled back on
    error. Writers stamp BATCH_ID + LOADED_AT/LOADED_BY on every row and log via
    Logger's Write-Log -Module 'SqlWriter.*' (degrading to Write-Verbose when Logger
    is not loaded).
#>

# ------------------------------------------------------------------------------
# Module-level state
# ------------------------------------------------------------------------------

# Preferred ADO.NET provider namespace. Resolved lazily on first real DB use.
$script:SqlClientNamespace = $null

# Default SqlBulkCopy batch size; overridable per-call or from settings
# (sqlServer.bulkCopyBatchSize). Chosen to balance memory vs round-trips for large
# CSV/volume scenarios.
$script:DefaultBulkCopyBatchSize = 5000

# ------------------------------------------------------------------------------
# Logging shim — use Logger's Write-Log when available, else Write-Verbose.
# ------------------------------------------------------------------------------
function Write-SqlWriterLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string] $Level,
        [Parameter(Mandatory)][string] $Message,
        [Parameter()][string] $Module = 'SqlWriter',
        [Parameter()][string] $HotelCode = '',
        [Parameter()][guid] $BatchId = [guid]::Empty
    )

    $writeLog = Get-Command -Name 'Write-Log' -ErrorAction SilentlyContinue
    if ($null -ne $writeLog) {
        try {
            Write-Log -Level $Level -Message $Message -Module $Module -HotelCode $HotelCode -BatchId $BatchId
            return
        }
        catch {
            # Fall through to console degradation if the shared logger fails.
        }
    }

    $line = "[{0}] [{1}] {2}" -f $Level, $Module, $Message
    switch ($Level) {
        'ERROR' { Write-Verbose $line -Verbose:$false; Write-Warning $line }
        'WARN'  { Write-Warning $line }
        default { Write-Verbose $line }
    }
}

# ==============================================================================
# Table metadata — authoritative column lists (OPERA-native) + natural keys.
# These drive staging creation and MERGE column mapping so writers never hard-code
# column lists inline.
# ==============================================================================
function Get-SqlWriterTableSpec {
    <#
    .SYNOPSIS
        Returns the column/natural-key spec for a subject-area table.
    .DESCRIPTION
        Internal (exported for unit tests). Provides, for each writer target, the
        schema-qualified table name, the ordered list of data columns written by the
        loader (excluding IDENTITY / defaulted audit columns that SQL fills), the
        natural-key columns used by the MERGE, and the audit columns stamped by the
        writer. Column names match the DDL in SQL\002-004 exactly.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('RES', 'FIN', 'OTB', 'BLK', 'RMN', 'OOO',
            'DIM_TrxCodes', 'DIM_RoomTypes', 'DIM_MarketCodes', 'DIM_RateCodes',
            'DIM_SourceCodes', 'DIM_Channels', 'Hotels')]
        [string] $Table
    )

    # Audit columns stamped by every writer (SQL supplies defaults, but we set them
    # explicitly so bulk-copy staging carries deterministic values).
    $audit = @('BATCH_ID', 'LOADED_AT', 'LOADED_BY')

    switch ($Table) {
        'RES' {
            return @{
                Target      = 'ra.RES'
                NaturalKey  = @('RESORT', 'BUSINESS_DATE', 'RESV_NAME_ID', 'MARKET_CODE', 'ROOM_CATEGORY_LABEL')
                Columns     = @(
                    'RESORT', 'CHAIN_CODE', 'BUSINESS_DATE', 'RESV_NAME_ID',
                    'RATE_CODE', 'RATE_CATEGORY', 'MARKET_CODE', 'SOURCE_CODE', 'CHANNEL',
                    'ROOM', 'PSEUDO_ROOM_YN', 'ROOM_CATEGORY_LABEL', 'RESV_STATUS', 'QUANTITY',
                    'TRUNC_BEGIN_DATE', 'TRUNC_END_DATE', 'COUNTRY', 'NIGHTS',
                    'ADULTS', 'CHILDREN', 'STAY_ROOMS', 'STAY_PERSONS', 'STAY_ADULTS', 'STAY_CHILDREN',
                    'ARR_ROOMS', 'ARR_PERSONS', 'DEP_ROOMS', 'DEP_PERSONS',
                    'DAY_USE_ROOMS', 'DAY_USE_PERSONS', 'NO_SHOW_ROOMS', 'NO_SHOW_PERSONS',
                    'ROOM_NIGHTS', 'REVENUE', 'ADR', 'REVPAR',
                    'HOUSE_USE_YN', 'COMPLIMENTARY_YN', 'WALKIN_YN', 'CANCELLATION_DATE'
                )
                Audit       = $audit
                LogModule   = 'SqlWriter.Write-RES'
            }
        }
        'FIN' {
            return @{
                Target      = 'ra.FIN'
                NaturalKey  = @('RESORT', 'BUSINESS_DATE', 'TRX_NO', 'TRAN_ACTION_ID')
                Columns     = @(
                    'RESORT', 'CHAIN_CODE', 'BUSINESS_DATE', 'RESV_NAME_ID', 'ORIGINAL_RESV',
                    'TRX_NO', 'TRAN_ACTION_ID', 'TRX_NO_ADDED_BY',
                    'TRX_CODE', 'TC_GROUP', 'TC_SUBGROUP', 'FT_SUBTYPE',
                    'RATE_CODE', 'MARKET_CODE', 'SOURCE_CODE',
                    'NET_AMOUNT', 'GROSS_AMOUNT', 'TRX_AMOUNT', 'POSTED_AMOUNT', 'REVENUE_AMT',
                    'QUANTITY', 'PRICE_PER_UNIT', 'EXCHANGE_RATE', 'CURRENCY', 'IND_REVENUE_GP',
                    'POSTING_DATE', 'TRX_DATE', 'TRX_DATE_UTC', 'IS_LATE_POSTING',
                    'COSTCENTER', 'ACCOUNT', 'PASSER_BY_NAME'
                )
                Audit       = $audit
                LogModule   = 'SqlWriter.Write-FIN'
            }
        }
        'OTB' {
            return @{
                Target      = 'ra.OTB'
                NaturalKey  = @('RESORT', 'SNAPSHOT_DATE', 'CONSIDERED_DATE', 'MARKET_CODE',
                    'ROOM_CATEGORY_LABEL', 'SOURCE_CODE', 'CHANNEL', 'RATE_CODE', 'RESV_TYPE')
                Columns     = @(
                    'RESORT', 'CHAIN_CODE', 'SNAPSHOT_DATE', 'CONSIDERED_DATE',
                    'MARKET_CODE', 'SOURCE_CODE', 'CHANNEL', 'RATE_CODE', 'RATE_CATEGORY',
                    'ROOM_CATEGORY_LABEL', 'RESV_TYPE', 'EVENT_TYPE', 'COUNTRY', 'CURRENCY_CODE',
                    'TRUNC_BEGIN_DATE', 'TRUNC_END_DATE',
                    'ARR_ROOMS', 'DEP_ROOMS', 'NO_ROOMS', 'DAY_USE_ROOMS', 'DAY_USE_PERSONS',
                    'ARR_PERSONS', 'DEP_PERSONS', 'ADULTS', 'CHILDREN', 'QUANTITY', 'NIGHTS', 'RESV_STATUS',
                    'TENTATIVE_ROOMS', 'DEFINITE_ROOMS', 'ADR_ON_BOOKS', 'REVENUE_ON_BOOKS',
                    'REMAINING_BLOCK_ROOMS', 'PICKEDUP_BLOCK_ROOMS',
                    'GROSS_RATE', 'ROOM_REVENUE', 'FOOD_REVENUE', 'OTHER_REVENUE', 'TOTAL_REVENUE', 'NON_REVENUE',
                    'NET_ROOM_REVENUE', 'EXTRA_REVENUE',
                    'ROOM_REVENUE_TAX', 'FOOD_REVENUE_TAX', 'OTHER_REVENUE_TAX', 'TOTAL_REVENUE_TAX', 'NON_REVENUE_TAX',
                    'PSEUDO_ROOM_YN', 'DAY_USE_YN'
                )
                Audit       = $audit
                LogModule   = 'SqlWriter.Write-OTB'
            }
        }
        'BLK' {
            return @{
                Target      = 'ra.BLK'
                NaturalKey  = @('RESORT', 'SNAPSHOT_DATE', 'BLOCK_CODE', 'CONSIDERED_DATE', 'ROOM_CATEGORY_LABEL')
                Columns     = @(
                    'RESORT', 'CHAIN_CODE', 'SNAPSHOT_DATE', 'CONSIDERED_DATE',
                    'BLOCK_CODE', 'BLOCK_NAME', 'ROOM_CATEGORY_LABEL', 'MARKET_CODE', 'SOURCE_CODE',
                    'RATE_CODE', 'RATE_CATEGORY', 'CUTOFF_DATE', 'IS_PAST_CUTOFF',
                    'ROOMS_CONTRACTED', 'ROOMS_PICKEDUP', 'ROOMS_REMAINING',
                    'ROOM_REVENUE', 'FOOD_REVENUE', 'OTHER_REVENUE', 'TOTAL_REVENUE', 'NON_REVENUE',
                    'NET_ROOM_REVENUE', 'NET_FOOD_REVENUE', 'NET_OTHER_REVENUE', 'NET_TOTAL_REVENUE',
                    'ROOM_REVENUE_TAX', 'FOOD_REVENUE_TAX', 'OTHER_REVENUE_TAX', 'TOTAL_REVENUE_TAX'
                )
                Audit       = $audit
                LogModule   = 'SqlWriter.Write-BLK'
            }
        }
        'RMN' {
            return @{
                Target      = 'ra.RMN'
                NaturalKey  = @('RESORT', 'ROOM')
                Columns     = @('RESORT', 'CHAIN_CODE', 'ROOM', 'ROOM_CATEGORY_LABEL', 'ROOM_CLASS', 'ROOM_STATUS')
                Audit       = $audit
                LogModule   = 'SqlWriter.Write-RMN'
            }
        }
        'OOO' {
            return @{
                Target      = 'ra.OOO'
                NaturalKey  = @('RESORT', 'BUSINESS_DATE', 'ROOM_CLASS')
                Columns     = @('RESORT', 'CHAIN_CODE', 'BUSINESS_DATE', 'ROOM_CLASS',
                    'OOO_ROOMS', 'OS_ROOMS', 'AVAIL_ROOM', 'OOO_BEDS', 'OS_BEDS', 'PHYSICAL_BEDS')
                Audit       = $audit
                LogModule   = 'SqlWriter.Write-OOO'
            }
        }
        'DIM_TrxCodes' {
            return @{
                Target      = 'ra.DIM_TrxCodes'
                CodeColumn  = 'TRX_CODE'
                NaturalKey  = @('RESORT', 'TRX_CODE')
                Tracked     = @('CHAIN_CODE', 'TRX_NAME', 'TC_GROUP', 'TC_SUBGROUP', 'FT_SUBTYPE',
                    'REVENUE_YN', 'ROOM_REVENUE_YN', 'PACKAGE_YN', 'IS_ACTIVE', 'FLAG')
                Columns     = @('RESORT', 'CHAIN_CODE', 'TRX_CODE', 'TRX_NAME', 'TC_GROUP', 'TC_SUBGROUP',
                    'FT_SUBTYPE', 'REVENUE_YN', 'ROOM_REVENUE_YN', 'PACKAGE_YN', 'IS_ACTIVE', 'FLAG')
                LogModule   = 'SqlWriter.Write-DIM'
                Scd2        = $true
            }
        }
        'DIM_RoomTypes' {
            return @{
                Target      = 'ra.DIM_RoomTypes'
                CodeColumn  = 'ROOM_CATEGORY_LABEL'
                NaturalKey  = @('RESORT', 'ROOM_CATEGORY_LABEL')
                Tracked     = @('CHAIN_CODE', 'DESCRIPTION', 'ROOM_CLASS', 'PHYSICAL_ROOM_COUNT', 'IS_ACTIVE', 'FLAG')
                Columns     = @('RESORT', 'CHAIN_CODE', 'ROOM_CATEGORY_LABEL', 'DESCRIPTION', 'ROOM_CLASS',
                    'PHYSICAL_ROOM_COUNT', 'IS_ACTIVE', 'FLAG')
                LogModule   = 'SqlWriter.Write-DIM'
                Scd2        = $true
            }
        }
        'DIM_MarketCodes' {
            return @{
                Target      = 'ra.DIM_MarketCodes'
                CodeColumn  = 'CODE'
                NaturalKey  = @('RESORT', 'CODE')
                Tracked     = @('CHAIN_CODE', 'DESCRIPTION', 'SEGMENT_GROUP', 'IS_ACTIVE', 'FLAG')
                Columns     = @('RESORT', 'CHAIN_CODE', 'CODE', 'DESCRIPTION', 'SEGMENT_GROUP', 'IS_ACTIVE', 'FLAG')
                LogModule   = 'SqlWriter.Write-DIM'
                Scd2        = $true
            }
        }
        'DIM_RateCodes' {
            return @{
                Target      = 'ra.DIM_RateCodes'
                CodeColumn  = 'CODE'
                NaturalKey  = @('RESORT', 'CODE')
                Tracked     = @('CHAIN_CODE', 'DESCRIPTION', 'RATE_CATEGORY', 'RATE_CLASS', 'IS_ACTIVE', 'FLAG')
                Columns     = @('RESORT', 'CHAIN_CODE', 'CODE', 'DESCRIPTION', 'RATE_CATEGORY', 'RATE_CLASS', 'IS_ACTIVE', 'FLAG')
                LogModule   = 'SqlWriter.Write-DIM'
                Scd2        = $true
            }
        }
        'DIM_SourceCodes' {
            return @{
                Target      = 'ra.DIM_SourceCodes'
                CodeColumn  = 'CODE'
                NaturalKey  = @('RESORT', 'CODE')
                Tracked     = @('CHAIN_CODE', 'DESCRIPTION', 'IS_ACTIVE', 'FLAG')
                Columns     = @('RESORT', 'CHAIN_CODE', 'CODE', 'DESCRIPTION', 'IS_ACTIVE', 'FLAG')
                LogModule   = 'SqlWriter.Write-DIM'
                Scd2        = $true
            }
        }
        'DIM_Channels' {
            return @{
                Target      = 'ra.DIM_Channels'
                CodeColumn  = 'CODE'
                NaturalKey  = @('RESORT', 'CODE')
                Tracked     = @('CHAIN_CODE', 'DESCRIPTION', 'IS_ACTIVE', 'FLAG')
                Columns     = @('RESORT', 'CHAIN_CODE', 'CODE', 'DESCRIPTION', 'IS_ACTIVE', 'FLAG')
                LogModule   = 'SqlWriter.Write-DIM'
                Scd2        = $true
            }
        }
        'Hotels' {
            return @{
                Target      = 'ra.Hotels'
                CodeColumn  = 'RESORT'
                NaturalKey  = @('RESORT')
                Tracked     = @('CHAIN_CODE', 'DISPLAY_NAME', 'CITY', 'COUNTRY', 'CURRENCY_CODE',
                    'TIME_ZONE_ID', 'NIGHT_AUDIT_HOUR', 'NIGHT_AUDIT_MIN', 'IS_ACTIVE')
                Columns     = @('RESORT', 'CHAIN_CODE', 'DISPLAY_NAME', 'CITY', 'COUNTRY', 'CURRENCY_CODE',
                    'TIME_ZONE_ID', 'NIGHT_AUDIT_HOUR', 'NIGHT_AUDIT_MIN', 'IS_ACTIVE')
                LogModule   = 'SqlWriter.Write-DIM'
                Scd2        = $false   # single current row per RESORT (UNIQUE RESORT)
            }
        }
    }
}

# ==============================================================================
# Connection-string / settings resolution
# ==============================================================================
function Resolve-SqlConnectionString {
    <#
    .SYNOPSIS
        Resolves an effective SQL Server connection string from an explicit value or a
        settings object/path.
    .DESCRIPTION
        Internal (exported for tests). Accepts either a raw connection string, an
        already-parsed settings object (with a sqlServer block), or nothing (returns
        $null). When given a settings object it prefers sqlServer.connectionString and
        otherwise composes a string from server/database/trustedConnection etc.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][string] $ConnectionString,
        [Parameter()][psobject] $Settings
    )

    if (-not [string]::IsNullOrWhiteSpace($ConnectionString)) {
        return $ConnectionString
    }

    if ($null -ne $Settings) {
        $sql = $Settings.sqlServer
        if ($null -ne $sql) {
            if (-not [string]::IsNullOrWhiteSpace([string]$sql.connectionString)) {
                return [string]$sql.connectionString
            }
            # Compose a minimal connection string from discrete fields.
            $parts = [System.Collections.Generic.List[string]]::new()
            if (-not [string]::IsNullOrWhiteSpace([string]$sql.server))   { $parts.Add("Server=$($sql.server)") }
            if (-not [string]::IsNullOrWhiteSpace([string]$sql.database)) { $parts.Add("Database=$($sql.database)") }
            if ($sql.trustedConnection) { $parts.Add('Integrated Security=True') }
            if ($null -ne $sql.encrypt) { $parts.Add("Encrypt=$([bool]$sql.encrypt)") }
            if ($null -ne $sql.trustServerCertificate) { $parts.Add("TrustServerCertificate=$([bool]$sql.trustServerCertificate)") }
            if ($null -ne $sql.connectTimeout) { $parts.Add("Connect Timeout=$([int]$sql.connectTimeout)") }
            if ($parts.Count -gt 0) { return ($parts -join ';') }
        }
    }

    return $null
}

function Resolve-SqlClientNamespace {
    <#
    .SYNOPSIS
        Loads and returns the ADO.NET provider namespace, preferring
        Microsoft.Data.SqlClient and falling back to System.Data.SqlClient.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($null -ne $script:SqlClientNamespace) {
        return $script:SqlClientNamespace
    }

    foreach ($candidate in @('Microsoft.Data.SqlClient', 'System.Data.SqlClient')) {
        try {
            Add-Type -AssemblyName $candidate -ErrorAction Stop
            $script:SqlClientNamespace = $candidate
            Write-SqlWriterLog -Level 'DEBUG' -Message "Using ADO.NET provider '$candidate'."
            return $candidate
        }
        catch {
            continue
        }
    }

    throw "No SQL client provider available. Install 'Microsoft.Data.SqlClient' (preferred) or ensure 'System.Data.SqlClient' is present."
}

# ==============================================================================
# SQL execution primitives (real implementations behind the test seam)
# ==============================================================================
function Invoke-DefaultSqlExecutor {
    <#
    .SYNOPSIS
        The default (real) -SqlExecutor: runs parameterized SQL against SQL Server.
    .DESCRIPTION
        Internal. Opens a connection, binds hashtable parameters as SqlParameters
        (never string-concatenated), runs the command, and returns rows-affected for
        non-queries. Optionally participates in an externally supplied open connection
        + transaction so several statements share one transactional scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Sql,
        [Parameter()][hashtable] $Parameters = @{},
        [Parameter()][string] $ConnectionString,
        [Parameter()][object] $Connection,
        [Parameter()][object] $Transaction,
        [Parameter()][int] $CommandTimeout = 300,
        [Parameter()][switch] $Query
    )

    $ns = Resolve-SqlClientNamespace
    $ownConnection = $false
    $conn = $Connection
    try {
        if ($null -eq $conn) {
            $conn = New-Object "$ns.SqlConnection" $ConnectionString
            $conn.Open()
            $ownConnection = $true
        }

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = $CommandTimeout
        if ($null -ne $Transaction) { $cmd.Transaction = $Transaction }

        foreach ($key in $Parameters.Keys) {
            $pname = if ($key.StartsWith('@')) { $key } else { "@$key" }
            $val = $Parameters[$key]
            if ($null -eq $val) { $val = [System.DBNull]::Value }
            $null = $cmd.Parameters.AddWithValue($pname, $val)
        }

        if ($Query) {
            $reader = $cmd.ExecuteReader()
            $rows = [System.Collections.Generic.List[object]]::new()
            try {
                while ($reader.Read()) {
                    $row = @{}
                    for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                        $name = $reader.GetName($i)
                        $value = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
                        $row[$name] = $value
                    }
                    $rows.Add([pscustomobject]$row)
                }
            }
            finally {
                $reader.Dispose()
            }
            return $rows.ToArray()
        }
        else {
            return [int]$cmd.ExecuteNonQuery()
        }
    }
    finally {
        if ($ownConnection -and $null -ne $conn) {
            try { $conn.Close() } catch { }
            try { $conn.Dispose() } catch { }
        }
    }
}

function Invoke-DefaultBulkCopy {
    <#
    .SYNOPSIS
        The default (real) -BulkCopy: SqlBulkCopy the mapped rows into a staging table.
    .DESCRIPTION
        Internal. Builds a DataTable from the ordered column list, fills it from the
        supplied [PSCustomObject]/hashtable rows, and streams it to the destination
        staging table with SqlBulkCopy. Returns the number of rows copied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $StagingTable,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Rows,
        [Parameter(Mandatory)][string[]] $Columns,
        [Parameter(Mandatory)][object] $Connection,
        [Parameter()][object] $Transaction,
        [Parameter()][int] $BatchSize = 5000
    )

    $ns = Resolve-SqlClientNamespace

    $dt = [System.Data.DataTable]::new()
    foreach ($c in $Columns) { $null = $dt.Columns.Add($c) }

    foreach ($row in $Rows) {
        $dr = $dt.NewRow()
        foreach ($c in $Columns) {
            $v = $row.$c
            $dr[$c] = if ($null -eq $v) { [System.DBNull]::Value } else { $v }
        }
        $dt.Rows.Add($dr)
    }

    $bulkOptions = [enum]::Parse(([type]"$ns.SqlBulkCopyOptions"), 'Default')
    $bulk = if ($null -ne $Transaction) {
        New-Object "$ns.SqlBulkCopy" $Connection, $bulkOptions, $Transaction
    }
    else {
        New-Object "$ns.SqlBulkCopy" $Connection
    }
    try {
        $bulk.DestinationTableName = $StagingTable
        $bulk.BatchSize = $BatchSize
        $bulk.BulkCopyTimeout = 0
        foreach ($c in $Columns) { $null = $bulk.ColumnMappings.Add($c, $c) }
        $bulk.WriteToServer($dt)
    }
    finally {
        $bulk.Close()
    }

    return $dt.Rows.Count
}

# ==============================================================================
# Pure helpers — unit-testable without a database
# ==============================================================================
function ConvertTo-SqlDate {
    <#
    .SYNOPSIS
        Normalizes a value to a [datetime] (date component) or $null.
    .DESCRIPTION
        Internal (exported for tests). Accepts a [datetime], a yyyyMMdd string
        (the loader's output date format), an ISO date string, or $null/empty and
        returns a [datetime] whose Date is the parsed day, or $null when not parseable.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[datetime]])]
    param([Parameter()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return ([datetime]$Value) }

    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $s = $s.Trim()

    # Loader output format yyyyMMdd (optionally with a time suffix "yyyyMMdd HH:mm:ss").
    $datePart = ($s -split '\s+')[0]
    if ($datePart -match '^\d{8}$') {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($datePart, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }
    }

    $out = [datetime]::MinValue
    if ([datetime]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$out)) {
        return $out
    }
    return $null
}

function Get-IsLatePosting {
    <#
    .SYNOPSIS
        Computes the IS_LATE_POSTING flag for a financial transaction.
    .DESCRIPTION
        A posting is "late" when its posting/transaction date is strictly AFTER the
        business date it belongs to (TRX_DATE / PostingDate > BUSINESS_DATE). Uses the
        date component only. Returns 0 when either date is missing (cannot prove late).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()] $PostingDate,
        [Parameter()] $BusinessDate
    )

    $post = ConvertTo-SqlDate -Value $PostingDate
    $biz  = ConvertTo-SqlDate -Value $BusinessDate
    if ($null -eq $post -or $null -eq $biz) { return 0 }
    if ($post.Date -gt $biz.Date) { return 1 }
    return 0
}

function Get-IsPastCutoff {
    <#
    .SYNOPSIS
        Computes the IS_PAST_CUTOFF flag for a block-reservation snapshot row.
    .DESCRIPTION
        A block is past cutoff when its CUTOFF_DATE is strictly BEFORE the SNAPSHOT_DATE
        the row was captured on (CUTOFF_DATE < SNAPSHOT_DATE). Uses the date component
        only. Returns 0 when either date is missing.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()] $CutoffDate,
        [Parameter()] $SnapshotDate
    )

    $cut  = ConvertTo-SqlDate -Value $CutoffDate
    $snap = ConvertTo-SqlDate -Value $SnapshotDate
    if ($null -eq $cut -or $null -eq $snap) { return 0 }
    if ($cut.Date -lt $snap.Date) { return 1 }
    return 0
}

function Get-Scd2Action {
    <#
    .SYNOPSIS
        Decides the SCD Type 2 action for one incoming master-data record versus the
        current stored version.
    .DESCRIPTION
        Pure decision function (exported for tests). Compares the tracked columns of an
        incoming record against the current row (if any) and returns one of:
            'Insert'  — no current row exists → INSERT new current version
            'Update'  — a tracked column changed → expire current (VALID_TO = today-1,
                        IS_CURRENT = 0) then INSERT new current version
            'None'    — nothing tracked changed → no-op (avoid churn)
        Comparison is ordinal/culture-invariant on stringified values so numeric,
        char and text columns compare deterministically. NULL and empty string are
        treated as equal (source systems are inconsistent about which they send).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]] $TrackedColumns,
        [Parameter()] $Incoming,
        [Parameter()] $Current
    )

    if ($null -eq $Current) { return 'Insert' }

    foreach ($col in $TrackedColumns) {
        $inVal  = if ($null -ne $Incoming) { $Incoming.$col } else { $null }
        $curVal = $Current.$col

        $inStr  = if ($null -eq $inVal)  { '' } else { ([string]$inVal).Trim() }
        $curStr = if ($null -eq $curVal) { '' } else { ([string]$curVal).Trim() }

        if (-not [string]::Equals($inStr, $curStr, [System.StringComparison]::Ordinal)) {
            return 'Update'
        }
    }

    return 'None'
}

function Get-QuotedTableName {
    # Splits schema.table and bracket-quotes each part to safely embed as an identifier.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Table)
    $parts = $Table -split '\.'
    return (($parts | ForEach-Object { '[' + ($_ -replace '\]', ']]') + ']' }) -join '.')
}

function New-StagingTableName {
    # Deterministic, collision-resistant temp-table name for a target.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Target)
    $leaf = ($Target -split '\.')[-1]
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return "#stg_${leaf}_$suffix"
}

function New-MergeStatement {
    <#
    .SYNOPSIS
        Builds a deterministic, injection-safe MERGE from a staging table into a target
        on a natural key.
    .DESCRIPTION
        Pure SQL-builder (exported for tests). Emits:
            MERGE <target> AS tgt USING <staging> AS src ON (<nk equality>)
            WHEN MATCHED THEN UPDATE SET <non-key cols>
            WHEN NOT MATCHED BY TARGET THEN INSERT (<cols>) VALUES (<src cols>);
        No run-time data values appear in the text — only column identifiers derived
        from the table spec. When -InsertOnly is set (snapshot accumulation), the
        WHEN MATCHED branch is omitted so existing rows are never overwritten.
        The trailing OUTPUT + $action count is captured by the caller for row stats.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $Staging,
        [Parameter(Mandatory)][string[]] $NaturalKey,
        [Parameter(Mandatory)][string[]] $AllColumns,
        [Parameter()][switch] $InsertOnly
    )

    $tgt = Get-QuotedTableName -Table $Target
    $src = Get-QuotedTableName -Table $Staging
    $q = { param($c) '[' + ($c -replace '\]', ']]') + ']' }

    $onClause = ($NaturalKey | ForEach-Object { "tgt.$(& $q $_) = src.$(& $q $_)" }) -join ' AND '
    $insertCols = ($AllColumns | ForEach-Object { & $q $_ }) -join ', '
    $insertVals = ($AllColumns | ForEach-Object { "src.$(& $q $_)" }) -join ', '

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("MERGE $tgt AS tgt")
    [void]$sb.AppendLine("USING $src AS src")
    [void]$sb.AppendLine("    ON ($onClause)")

    if (-not $InsertOnly) {
        $updateCols = $AllColumns | Where-Object { $NaturalKey -notcontains $_ }
        if ($updateCols.Count -gt 0) {
            $setList = ($updateCols | ForEach-Object { "tgt.$(& $q $_) = src.$(& $q $_)" }) -join ",`n        "
            [void]$sb.AppendLine("WHEN MATCHED THEN UPDATE SET")
            [void]$sb.AppendLine("        $setList")
        }
    }

    [void]$sb.AppendLine("WHEN NOT MATCHED BY TARGET THEN")
    [void]$sb.AppendLine("    INSERT ($insertCols)")
    [void]$sb.AppendLine("    VALUES ($insertVals)")
    [void]$sb.Append("OUTPUT `$action;")

    return $sb.ToString()
}

# ==============================================================================
# Row normalization — stamp audit columns + shape [PSCustomObject] to the spec
# ==============================================================================
function ConvertTo-StagingRow {
    <#
    .SYNOPSIS
        Projects an input record onto the exact ordered column set for a target,
        stamping BATCH_ID / LOADED_AT / LOADED_BY.
    .DESCRIPTION
        Internal. Produces a [PSCustomObject] containing exactly the spec's Columns +
        Audit columns (missing inputs become $null → DBNull at bulk-copy time). Any
        pre-computed flags/derived values already present on the input record are
        preserved.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)][string[]] $Columns,
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter(Mandatory)][string] $LoadedBy,
        [Parameter(Mandatory)][datetime] $LoadedAt
    )

    $out = [ordered]@{}
    foreach ($c in $Columns) {
        $out[$c] = if ($null -ne $Record.PSObject.Properties[$c]) { $Record.$c } else { $null }
    }
    $out['BATCH_ID']  = $BatchId
    $out['LOADED_AT'] = $LoadedAt
    $out['LOADED_BY'] = $LoadedBy
    return [pscustomobject]$out
}

function Get-LoadedByIdentity {
    # Best-effort audit identity (domain\user), never throws.
    [CmdletBinding()][OutputType([string])] param()
    try { return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
            return ("$($env:USERDOMAIN)\$($env:USERNAME)").TrimStart('\')
        }
        return 'OperaRADataLoader'
    }
}

# ==============================================================================
# Core staging → MERGE engine (shared by RES/FIN/OTB/BLK/RMN/OOO)
# ==============================================================================
function Invoke-SqlBulkMerge {
    <#
    .SYNOPSIS
        Bulk-copies rows into a session staging table then MERGEs them into the target,
        all inside one transaction.
    .DESCRIPTION
        The single shared upsert primitive. Steps:
          1. CREATE a staging table shaped like the target (data + audit columns).
          2. BulkCopy the normalized rows into staging (via -BulkCopy seam).
          3. MERGE staging → target on the natural key (via -SqlExecutor seam), with
             -InsertOnly for snapshot accumulation (OTB/BLK) so prior snapshots are
             preserved.
          4. DROP staging.
        Wrapped in a transaction: any failure rolls back and is logged as ERROR. When
        a -SqlExecutor is supplied (test seam) the transaction/connection lifecycle is
        delegated to the seam and only the parameterized statements are recorded, so
        the MERGE column mapping and insert-only behavior are unit-testable without a
        live server. Returns a hashtable @{ RowsStaged; RowsAffected; Merge; Staging }.
    .PARAMETER FlagWarnCount
        Optional count of rows that tripped a business flag (late postings / past
        cutoff); logged as WARN when > 0.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Spec,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Rows,
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter()][string] $HotelCode = '',
        [Parameter()][switch] $InsertOnly,
        [Parameter()][int] $FlagWarnCount = 0,
        [Parameter()][string] $FlagWarnMessage,
        # execution context
        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][scriptblock] $BulkCopy,
        [Parameter()][string] $ConnectionString,
        [Parameter()][int] $BatchSize = 5000,
        [Parameter()][int] $CommandTimeout = 300
    )

    $logModule = [string]$Spec.LogModule
    $target = [string]$Spec.Target
    $allColumns = @($Spec.Columns) + @($Spec.Audit)
    $staging = New-StagingTableName -Target $target
    $mergeSql = New-MergeStatement -Target $target -Staging $staging `
        -NaturalKey $Spec.NaturalKey -AllColumns $allColumns -InsertOnly:$InsertOnly

    Write-SqlWriterLog -Level 'INFO' -Module $logModule -HotelCode $HotelCode -BatchId $BatchId `
        -Message ("BulkCopy staging {0} rows -> {1} (insertOnly={2})" -f $Rows.Count, $target, [bool]$InsertOnly)

    if ($FlagWarnCount -gt 0 -and -not [string]::IsNullOrWhiteSpace($FlagWarnMessage)) {
        Write-SqlWriterLog -Level 'WARN' -Module $logModule -HotelCode $HotelCode -BatchId $BatchId -Message $FlagWarnMessage
    }

    if ($Rows.Count -eq 0) {
        Write-SqlWriterLog -Level 'INFO' -Module $logModule -HotelCode $HotelCode -BatchId $BatchId `
            -Message "No rows to write to $target; skipping MERGE."
        return @{ RowsStaged = 0; RowsAffected = 0; Merge = $mergeSql; Staging = $staging }
    }

    $createStagingSql = "SELECT * INTO $(Get-QuotedTableName -Table $staging) FROM $(Get-QuotedTableName -Table $target) WHERE 1 = 0;"
    $dropStagingSql = "IF OBJECT_ID('tempdb..$staging') IS NOT NULL DROP TABLE $(Get-QuotedTableName -Table $staging);"

    # -------------------- Test-seam path (no live SQL) --------------------
    if ($null -ne $SqlExecutor) {
        try {
            $null = & $SqlExecutor $createStagingSql @{}
            $staged = 0
            if ($null -ne $BulkCopy) {
                $staged = [int](& $BulkCopy $staging $Rows $allColumns)
            }
            else {
                # No bulk seam: fall back to per-row parameterized INSERTs into staging
                # so the seam remains fully functional in tests.
                foreach ($r in $Rows) {
                    $params = @{}
                    $colFrag = ($allColumns | ForEach-Object { "@$_" }) -join ', '
                    foreach ($c in $allColumns) { $params[$c] = $r.$c }
                    $null = & $SqlExecutor ("INSERT INTO $(Get-QuotedTableName -Table $staging) VALUES ($colFrag);") $params
                    $staged++
                }
            }
            $affected = [int](& $SqlExecutor $mergeSql @{})
            $null = & $SqlExecutor $dropStagingSql @{}

            Write-SqlWriterLog -Level 'INFO' -Module $logModule -HotelCode $HotelCode -BatchId $BatchId `
                -Message ("MERGE complete. Staged={0} Affected={1}" -f $staged, $affected)
            return @{ RowsStaged = $staged; RowsAffected = $affected; Merge = $mergeSql; Staging = $staging }
        }
        catch {
            Write-SqlWriterLog -Level 'ERROR' -Module $logModule -HotelCode $HotelCode -BatchId $BatchId `
                -Message ("MERGE into {0} failed (seam): {1}" -f $target, $_.Exception.Message)
            throw
        }
    }

    # -------------------- Real SQL path --------------------
    $ns = Resolve-SqlClientNamespace
    $conn = $null
    $tx = $null
    try {
        $conn = New-Object "$ns.SqlConnection" $ConnectionString
        $conn.Open()
        $tx = $conn.BeginTransaction()

        $null = Invoke-DefaultSqlExecutor -Sql $createStagingSql -Connection $conn -Transaction $tx -CommandTimeout $CommandTimeout
        $staged = Invoke-DefaultBulkCopy -StagingTable $staging -Rows $Rows -Columns $allColumns `
            -Connection $conn -Transaction $tx -BatchSize $BatchSize
        $affected = Invoke-DefaultSqlExecutor -Sql $mergeSql -Connection $conn -Transaction $tx -CommandTimeout $CommandTimeout
        $null = Invoke-DefaultSqlExecutor -Sql $dropStagingSql -Connection $conn -Transaction $tx -CommandTimeout $CommandTimeout

        $tx.Commit()
        Write-SqlWriterLog -Level 'INFO' -Module $logModule -HotelCode $HotelCode -BatchId $BatchId `
            -Message ("MERGE complete. Staged={0} Affected={1}" -f $staged, $affected)
        return @{ RowsStaged = $staged; RowsAffected = $affected; Merge = $mergeSql; Staging = $staging }
    }
    catch {
        if ($null -ne $tx) { try { $tx.Rollback() } catch { } }
        Write-SqlWriterLog -Level 'ERROR' -Module $logModule -HotelCode $HotelCode -BatchId $BatchId `
            -Message ("MERGE into {0} failed; transaction rolled back: {1}" -f $target, $_.Exception.Message)
        throw
    }
    finally {
        if ($null -ne $tx) { try { $tx.Dispose() } catch { } }
        if ($null -ne $conn) { try { $conn.Close() } catch { }; try { $conn.Dispose() } catch { } }
    }
}

# ==============================================================================
# Initialize-Database — run DDL scripts 001–005 idempotently
# ==============================================================================
function Initialize-Database {
    <#
    .SYNOPSIS
        Executes the schema DDL scripts (001–005) in numeric order, idempotently.
    .DESCRIPTION
        Reads SQL\001_CreateSchema.sql .. SQL\005_CreateIndexes.sql in numeric order,
        splits each on GO batch separators, and executes the batches against the target
        database. The scripts are written to be safe to re-run (every object is guarded
        with IF OBJECT_ID/NOT EXISTS), so Initialize-Database can run on every startup.

        Batches are executed through the -SqlExecutor seam when supplied (tests verify
        the five scripts run in order without a live server); otherwise a real
        Microsoft.Data.SqlClient connection is used. Returns a summary hashtable
        @{ Scripts = <ordered file names>; BatchesExecuted = <int> }.
    .PARAMETER ConnectionString
        Target SQL Server connection string. Optional when -Settings supplies one.
    .PARAMETER Settings
        Parsed settings object; sqlServer.connectionString / discrete fields are used
        when -ConnectionString is omitted.
    .PARAMETER SqlDirectory
        Directory containing the numbered .sql scripts. Defaults to the repo SQL folder
        resolved relative to this module.
    .PARAMETER SqlExecutor
        Test seam. Scriptblock invoked as & $SqlExecutor $BatchText @{} per GO batch.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][string] $ConnectionString,
        [Parameter()][psobject] $Settings,
        [Parameter()][string] $SqlDirectory,
        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][int] $CommandTimeout = 300
    )

    if ([string]::IsNullOrWhiteSpace($SqlDirectory)) {
        $SqlDirectory = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'SQL'
    }
    if (-not (Test-Path -LiteralPath $SqlDirectory -PathType Container)) {
        throw "SQL script directory not found: '$SqlDirectory'."
    }

    # Numeric-ordered scripts 001..005 (sorted deterministically by leading number).
    $scripts = Get-ChildItem -LiteralPath $SqlDirectory -Filter '0*.sql' -File |
        Where-Object { $_.Name -match '^\d{3}_' } |
        Sort-Object { [int]($_.Name.Substring(0, 3)) }, Name

    if ($scripts.Count -eq 0) {
        throw "No numbered DDL scripts (NNN_*.sql) found in '$SqlDirectory'."
    }

    $effectiveConnString = $null
    if ($null -eq $SqlExecutor) {
        $effectiveConnString = Resolve-SqlConnectionString -ConnectionString $ConnectionString -Settings $Settings
        if ([string]::IsNullOrWhiteSpace($effectiveConnString)) {
            throw 'Initialize-Database requires a connection string (or -Settings) when no -SqlExecutor seam is supplied.'
        }
    }

    Write-SqlWriterLog -Level 'INFO' -Module 'SqlWriter.Init' `
        -Message ("Initializing database from {0} script(s): {1}" -f $scripts.Count, (($scripts | ForEach-Object Name) -join ', '))

    $ns = $null; $conn = $null
    if ($null -eq $SqlExecutor) {
        $ns = Resolve-SqlClientNamespace
        $conn = New-Object "$ns.SqlConnection" $effectiveConnString
        $conn.Open()
    }

    $batchesExecuted = 0
    try {
        foreach ($script in $scripts) {
            Write-SqlWriterLog -Level 'INFO' -Module 'SqlWriter.Init' -Message ("Executing {0}" -f $script.Name)
            $content = Get-Content -LiteralPath $script.FullName -Raw -ErrorAction Stop
            $batches = Split-SqlBatches -Script $content
            foreach ($batch in $batches) {
                if ([string]::IsNullOrWhiteSpace($batch)) { continue }
                if ($null -ne $SqlExecutor) {
                    $null = & $SqlExecutor $batch @{}
                }
                else {
                    $null = Invoke-DefaultSqlExecutor -Sql $batch -Connection $conn -CommandTimeout $CommandTimeout
                }
                $batchesExecuted++
            }
        }
    }
    catch {
        Write-SqlWriterLog -Level 'ERROR' -Module 'SqlWriter.Init' `
            -Message ("Database initialization failed: {0}" -f $_.Exception.Message)
        throw
    }
    finally {
        if ($null -ne $conn) { try { $conn.Close() } catch { }; try { $conn.Dispose() } catch { } }
    }

    Write-SqlWriterLog -Level 'INFO' -Module 'SqlWriter.Init' `
        -Message ("Database initialization complete. {0} batch(es) executed." -f $batchesExecuted)

    return @{ Scripts = @($scripts | ForEach-Object Name); BatchesExecuted = $batchesExecuted }
}

function Split-SqlBatches {
    <#
    .SYNOPSIS
        Splits a T-SQL script into batches on standalone GO separators.
    .DESCRIPTION
        Pure helper (exported for tests). Splits on lines whose only content is GO
        (case-insensitive, optional trailing batch count ignored), preserving batch
        text otherwise. GO inside strings/comments on non-GO-only lines is not treated
        as a separator (the DDL scripts only use standalone GO lines).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Script)

    $batches = [regex]::Split($Script, '(?im)^\s*GO(?:\s+\d+)?\s*$')
    return @($batches | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# ==============================================================================
# Shared writer front-end used by RES/FIN/OTB/BLK/RMN/OOO
# ==============================================================================
function Invoke-SubjectWriter {
    <#
    .SYNOPSIS
        Normalizes rows for a subject-area table and runs the staging→MERGE.
    .DESCRIPTION
        Internal. Stamps audit columns via ConvertTo-StagingRow then delegates to
        Invoke-SqlBulkMerge. Optional -RowMutator lets a writer compute/derive flags
        (IS_LATE_POSTING, IS_PAST_CUTOFF) on each record before staging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $TableKey,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Data,
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter()][hashtable] $Hotel,
        [Parameter()][switch] $InsertOnly,
        [Parameter()][scriptblock] $RowMutator,
        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][scriptblock] $BulkCopy,
        [Parameter()][string] $ConnectionString,
        [Parameter()][int] $BatchSize = 5000,
        [Parameter()][int] $CommandTimeout = 300
    )

    $spec = Get-SqlWriterTableSpec -Table $TableKey
    $hotelCode = if ($null -ne $Hotel -and $Hotel.ContainsKey('HotelCode')) { [string]$Hotel.HotelCode }
                 elseif ($null -ne $Hotel -and $Hotel.ContainsKey('RESORT')) { [string]$Hotel.RESORT }
                 else { '' }
    $loadedBy = Get-LoadedByIdentity
    $loadedAt = [datetime]::UtcNow

    $flagWarnCount = 0
    $staged = [System.Collections.Generic.List[object]]::new()
    foreach ($rec in $Data) {
        $work = $rec
        if ($null -ne $RowMutator) {
            $result = & $RowMutator $work
            if ($null -ne $result) { $work = $result }
        }
        if ($null -ne $work.PSObject.Properties['__FlagTripped'] -and [bool]$work.__FlagTripped) {
            $flagWarnCount++
        }
        $staged.Add((ConvertTo-StagingRow -Record $work -Columns $spec.Columns -BatchId $BatchId -LoadedBy $loadedBy -LoadedAt $loadedAt))
    }

    $warnMsg = $null
    if ($flagWarnCount -gt 0) {
        $warnMsg = switch ($TableKey) {
            'FIN' { "$flagWarnCount late posting(s) detected (TRX_DATE/PostingDate > BUSINESS_DATE)." }
            'BLK' { "$flagWarnCount block row(s) past cutoff (CUTOFF_DATE < SNAPSHOT_DATE)." }
            default { "$flagWarnCount row(s) tripped a business flag." }
        }
    }

    return Invoke-SqlBulkMerge -Spec $spec -Rows $staged.ToArray() -BatchId $BatchId -HotelCode $hotelCode `
        -InsertOnly:$InsertOnly -FlagWarnCount $flagWarnCount -FlagWarnMessage $warnMsg `
        -SqlExecutor $SqlExecutor -BulkCopy $BulkCopy -ConnectionString $ConnectionString `
        -BatchSize $BatchSize -CommandTimeout $CommandTimeout
}

function Write-RES {
    <#
    .SYNOPSIS
        Upserts reservation-statistics rows into ra.RES (alias ReservationStats).
    .DESCRIPTION
        SqlBulkCopy → #staging → MERGE on RESORT+BUSINESS_DATE+RESV_NAME_ID+MARKET_CODE
        +ROOM_CATEGORY_LABEL. Stamps BATCH_ID + LOADED_AT/LOADED_BY. Returns the
        Invoke-SqlBulkMerge result hashtable.
    #>
    [CmdletBinding()]
    [Alias('Write-ReservationStats')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Data,
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter()][hashtable] $Hotel,
        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][scriptblock] $BulkCopy,
        [Parameter()][string] $ConnectionString,
        [Parameter()][int] $BatchSize = 5000,
        [Parameter()][int] $CommandTimeout = 300
    )
    return Invoke-SubjectWriter -TableKey 'RES' -Data $Data -BatchId $BatchId -Hotel $Hotel `
        -SqlExecutor $SqlExecutor -BulkCopy $BulkCopy -ConnectionString $ConnectionString `
        -BatchSize $BatchSize -CommandTimeout $CommandTimeout
}

function Write-FIN {
    <#
    .SYNOPSIS
        Upserts financial-transaction rows into ra.FIN (alias FinancialTx), computing
        IS_LATE_POSTING during mapping.
    .DESCRIPTION
        Sets IS_LATE_POSTING = 1 where the posting/transaction date is after the
        business date (POSTING_DATE/TRX_DATE > BUSINESS_DATE) unless the caller already
        supplied the flag. SqlBulkCopy → #staging → MERGE on
        RESORT+BUSINESS_DATE+TRX_NO+TRAN_ACTION_ID. Warns with the late-posting count.
    #>
    [CmdletBinding()]
    [Alias('Write-FinancialTx')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Data,
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter()][hashtable] $Hotel,
        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][scriptblock] $BulkCopy,
        [Parameter()][string] $ConnectionString,
        [Parameter()][int] $BatchSize = 5000,
        [Parameter()][int] $CommandTimeout = 300
    )

    $mutator = {
        param($rec)
        $props = $rec.PSObject.Properties
        # Prefer POSTING_DATE, fall back to TRX_DATE for the "posting date" comparison.
        $postingDate = if ($null -ne $props['POSTING_DATE'] -and $null -ne $rec.POSTING_DATE) { $rec.POSTING_DATE }
                       elseif ($null -ne $props['TRX_DATE']) { $rec.TRX_DATE }
                       else { $null }
        $businessDate = if ($null -ne $props['BUSINESS_DATE']) { $rec.BUSINESS_DATE } else { $null }

        $flag = if ($null -ne $props['IS_LATE_POSTING'] -and $null -ne $rec.IS_LATE_POSTING) {
            [int][bool]$rec.IS_LATE_POSTING
        }
        else {
            Get-IsLatePosting -PostingDate $postingDate -BusinessDate $businessDate
        }

        # Return a shallow copy carrying the computed flag + a warn marker.
        $out = [ordered]@{}
        foreach ($p in $props) { $out[$p.Name] = $p.Value }
        $out['IS_LATE_POSTING'] = $flag
        $out['__FlagTripped'] = ($flag -eq 1)
        [pscustomobject]$out
    }

    return Invoke-SubjectWriter -TableKey 'FIN' -Data $Data -BatchId $BatchId -Hotel $Hotel -RowMutator $mutator `
        -SqlExecutor $SqlExecutor -BulkCopy $BulkCopy -ConnectionString $ConnectionString `
        -BatchSize $BatchSize -CommandTimeout $CommandTimeout
}

function Write-OTB {
    <#
    .SYNOPSIS
        Inserts On-The-Books snapshot rows into ra.OTB (alias OnTheBooks) — snapshots
        ACCUMULATE.
    .DESCRIPTION
        Because the natural key includes SNAPSHOT_DATE, each daily snapshot is a new set
        of rows. This writer runs an INSERT-ONLY MERGE (no WHEN MATCHED UPDATE branch)
        so prior snapshots are NEVER overwritten; only genuinely new natural keys are
        inserted. SqlBulkCopy → #staging → MERGE.
    #>
    [CmdletBinding()]
    [Alias('Write-OnTheBooks')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Data,
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter()][hashtable] $Hotel,
        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][scriptblock] $BulkCopy,
        [Parameter()][string] $ConnectionString,
        [Parameter()][int] $BatchSize = 5000,
        [Parameter()][int] $CommandTimeout = 300
    )
    return Invoke-SubjectWriter -TableKey 'OTB' -Data $Data -BatchId $BatchId -Hotel $Hotel -InsertOnly `
        -SqlExecutor $SqlExecutor -BulkCopy $BulkCopy -ConnectionString $ConnectionString `
        -BatchSize $BatchSize -CommandTimeout $CommandTimeout
}

function Write-BLK {
    <#
    .SYNOPSIS
        Inserts block-reservation snapshot rows into ra.BLK (alias BlockReservations),
        computing IS_PAST_CUTOFF; snapshots ACCUMULATE.
    .DESCRIPTION
        Sets IS_PAST_CUTOFF = 1 where CUTOFF_DATE < SNAPSHOT_DATE (unless supplied).
        Uses an INSERT-ONLY MERGE so daily snapshots (keyed on SNAPSHOT_DATE) accumulate
        without overwriting prior snapshots.
    #>
    [CmdletBinding()]
    [Alias('Write-BlockReservations')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Data,
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter()][hashtable] $Hotel,
        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][scriptblock] $BulkCopy,
        [Parameter()][string] $ConnectionString,
        [Parameter()][int] $BatchSize = 5000,
        [Parameter()][int] $CommandTimeout = 300
    )

    $mutator = {
        param($rec)
        $props = $rec.PSObject.Properties
        $cutoff = if ($null -ne $props['CUTOFF_DATE']) { $rec.CUTOFF_DATE } else { $null }
        $snap   = if ($null -ne $props['SNAPSHOT_DATE']) { $rec.SNAPSHOT_DATE } else { $null }

        $flag = if ($null -ne $props['IS_PAST_CUTOFF'] -and $null -ne $rec.IS_PAST_CUTOFF) {
            [int][bool]$rec.IS_PAST_CUTOFF
        }
        else {
            Get-IsPastCutoff -CutoffDate $cutoff -SnapshotDate $snap
        }

        $out = [ordered]@{}
        foreach ($p in $props) { $out[$p.Name] = $p.Value }
        $out['IS_PAST_CUTOFF'] = $flag
        $out['__FlagTripped'] = ($flag -eq 1)
        [pscustomobject]$out
    }

    return Invoke-SubjectWriter -TableKey 'BLK' -Data $Data -BatchId $BatchId -Hotel $Hotel -InsertOnly -RowMutator $mutator `
        -SqlExecutor $SqlExecutor -BulkCopy $BulkCopy -ConnectionString $ConnectionString `
        -BatchSize $BatchSize -CommandTimeout $CommandTimeout
}

function Write-RMN {
    <#
    .SYNOPSIS
        Upserts physical room-configuration rows into ra.RMN (RoomInventory split) on
        RESORT+ROOM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Data,
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter()][hashtable] $Hotel,
        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][scriptblock] $BulkCopy,
        [Parameter()][string] $ConnectionString,
        [Parameter()][int] $BatchSize = 5000,
        [Parameter()][int] $CommandTimeout = 300
    )
    return Invoke-SubjectWriter -TableKey 'RMN' -Data $Data -BatchId $BatchId -Hotel $Hotel `
        -SqlExecutor $SqlExecutor -BulkCopy $BulkCopy -ConnectionString $ConnectionString `
        -BatchSize $BatchSize -CommandTimeout $CommandTimeout
}

function Write-OOO {
    <#
    .SYNOPSIS
        Upserts daily Out-Of-Order/Out-Of-Service counts into ra.OOO (RoomInventory
        split) on RESORT+BUSINESS_DATE+ROOM_CLASS.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Data,
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter()][hashtable] $Hotel,
        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][scriptblock] $BulkCopy,
        [Parameter()][string] $ConnectionString,
        [Parameter()][int] $BatchSize = 5000,
        [Parameter()][int] $CommandTimeout = 300
    )
    return Invoke-SubjectWriter -TableKey 'OOO' -Data $Data -BatchId $BatchId -Hotel $Hotel `
        -SqlExecutor $SqlExecutor -BulkCopy $BulkCopy -ConnectionString $ConnectionString `
        -BatchSize $BatchSize -CommandTimeout $CommandTimeout
}

function Write-RoomInventory {
    <#
    .SYNOPSIS
        Convenience wrapper that writes the RoomInventory split: ra.RMN (physical rooms)
        and ra.OOO (OOO/OS counts) from a combined payload.
    .DESCRIPTION
        Accepts -RoomData (→ ra.RMN) and/or -OooData (→ ra.OOO) and delegates to
        Write-RMN / Write-OOO. Returns @{ RMN = <result>; OOO = <result> }.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]] $RoomData = @(),
        [Parameter()][object[]] $OooData = @(),
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter()][hashtable] $Hotel,
        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][scriptblock] $BulkCopy,
        [Parameter()][string] $ConnectionString,
        [Parameter()][int] $BatchSize = 5000,
        [Parameter()][int] $CommandTimeout = 300
    )

    $result = @{}
    $result['RMN'] = Write-RMN -Data $RoomData -BatchId $BatchId -Hotel $Hotel `
        -SqlExecutor $SqlExecutor -BulkCopy $BulkCopy -ConnectionString $ConnectionString `
        -BatchSize $BatchSize -CommandTimeout $CommandTimeout
    $result['OOO'] = Write-OOO -Data $OooData -BatchId $BatchId -Hotel $Hotel `
        -SqlExecutor $SqlExecutor -BulkCopy $BulkCopy -ConnectionString $ConnectionString `
        -BatchSize $BatchSize -CommandTimeout $CommandTimeout
    return $result
}

# ==============================================================================
# Write-DIM / Write-MasterData — SCD Type 2 for the seven master tables
# ==============================================================================
function Write-DIM {
    <#
    .SYNOPSIS
        Applies SCD Type 2 upserts to a master/dimension table (or a single-current-row
        upsert for ra.Hotels).
    .DESCRIPTION
        For each incoming record the current version is looked up by natural key
        (RESORT + code column, IS_CURRENT = 1). Get-Scd2Action then decides:
            new code   → INSERT a current version (VALID_FROM = today, VALID_TO = NULL,
                         IS_CURRENT = 1)
            change     → expire the current row (VALID_TO = today - 1, IS_CURRENT = 0)
                         then INSERT a new current version
            no change  → no-op (avoids churn)
        ra.Hotels is NOT SCD2-versioned (UNIQUE RESORT): a change updates the single
        current row in place; a new RESORT inserts one row.

        SourceCodes and Channels are INDEPENDENT lists and are never merged together:
            -Type DIM_SourceCodes is a PRIORITY/REQUIRED dimension.
            -Type DIM_Channels is OPTIONAL — an empty/absent payload is a benign no-op.
        Guard: attempting to write source rows into the channels list (or vice-versa)
        is prevented because each -Type resolves to its own dedicated target table.

        All statements are parameterized and run inside one transaction (rolled back on
        error) when using the real path; the -SqlExecutor/-CurrentVersionLookup seams
        make the transition logic testable without a live server. Returns
        @{ Inserted; Updated; Unchanged; Actions }.
    .PARAMETER Type
        Which master table: DIM_TrxCodes, DIM_RoomTypes, DIM_MarketCodes, DIM_RateCodes,
        DIM_SourceCodes, DIM_Channels, or Hotels.
    .PARAMETER CurrentVersionLookup
        Test seam. Scriptblock invoked as & $lookup $Resort $Code returning the current
        stored row (hashtable/PSCustomObject) or $null. When omitted the current row is
        read via -SqlExecutor / real SQL.
    #>
    [CmdletBinding()]
    [Alias('Write-MasterData')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DIM_TrxCodes', 'DIM_RoomTypes', 'DIM_MarketCodes', 'DIM_RateCodes',
            'DIM_SourceCodes', 'DIM_Channels', 'Hotels')]
        [string] $Type,

        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Data,
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter()][hashtable] $Hotel,
        [Parameter()][ValidateSet('Full', 'Delta')][string] $RefreshMode = 'Full',
        [Parameter()][Nullable[datetime]] $AsOfDate,

        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][scriptblock] $CurrentVersionLookup,
        [Parameter()][string] $ConnectionString,
        [Parameter()][int] $CommandTimeout = 300
    )

    $spec = Get-SqlWriterTableSpec -Table $Type
    $hotelCode = if ($null -ne $Hotel -and $Hotel.ContainsKey('HotelCode')) { [string]$Hotel.HotelCode }
                 elseif ($null -ne $Hotel -and $Hotel.ContainsKey('RESORT')) { [string]$Hotel.RESORT }
                 else { '' }
    $loadedBy = Get-LoadedByIdentity
    $loadedAt = [datetime]::UtcNow
    $today = if ($null -ne $AsOfDate) { ([datetime]$AsOfDate).Date } else { [datetime]::UtcNow.Date }
    $codeCol = [string]$spec.CodeColumn

    # DIM_Channels is optional: empty payload is a benign no-op.
    if ($Data.Count -eq 0) {
        $level = if ($Type -eq 'DIM_Channels') { 'INFO' } else { 'INFO' }
        Write-SqlWriterLog -Level $level -Module $spec.LogModule -HotelCode $hotelCode -BatchId $BatchId `
            -Message ("No {0} rows to write; skipping." -f $Type)
        return @{ Inserted = 0; Updated = 0; Unchanged = 0; Actions = @() }
    }

    # ------------------------------------------------------------------
    # Determine execution context: seam vs real SQL (single transaction).
    # ------------------------------------------------------------------
    $useSeam = ($null -ne $SqlExecutor) -or ($null -ne $CurrentVersionLookup)
    $ns = $null; $conn = $null; $tx = $null
    if (-not $useSeam) {
        $effConn = Resolve-SqlConnectionString -ConnectionString $ConnectionString
        if ([string]::IsNullOrWhiteSpace($effConn)) {
            throw "Write-DIM ($Type) requires a connection string when no seam is supplied."
        }
        $ns = Resolve-SqlClientNamespace
        $conn = New-Object "$ns.SqlConnection" $effConn
        $conn.Open()
        $tx = $conn.BeginTransaction()
    }

    # Local executor that routes to seam or the real transactional connection.
    $exec = {
        param([string] $Sql, [hashtable] $Params, [switch] $AsQuery)
        if ($null -ne $SqlExecutor) {
            return & $SqlExecutor $Sql $Params
        }
        return Invoke-DefaultSqlExecutor -Sql $Sql -Parameters $Params -Connection $conn -Transaction $tx -CommandTimeout $CommandTimeout -Query:$AsQuery
    }

    $inserted = 0; $updated = 0; $unchanged = 0
    $actions = [System.Collections.Generic.List[object]]::new()
    $qtarget = Get-QuotedTableName -Table $spec.Target

    try {
        foreach ($rec in $Data) {
            $resort = [string]$rec.RESORT
            $code = [string]$rec.$codeCol

            # --- Look up the current version (seam or SQL) ---
            $current = $null
            if ($null -ne $CurrentVersionLookup) {
                $current = & $CurrentVersionLookup $resort $code
            }
            else {
                $isCurrentPredicate = if ($spec.Scd2) { ' AND IS_CURRENT = 1' } else { '' }
                $lookupSql = "SELECT TOP (1) * FROM $qtarget WHERE RESORT = @RESORT AND [$codeCol] = @CODE$isCurrentPredicate;"
                $rows = & $exec $lookupSql @{ RESORT = $resort; CODE = $code } -AsQuery
                if ($null -ne $rows -and @($rows).Count -gt 0) { $current = @($rows)[0] }
            }

            if (-not $spec.Scd2) {
                # ra.Hotels — single current row per RESORT (update-in-place / insert).
                $action = Get-Scd2Action -TrackedColumns $spec.Tracked -Incoming $rec -Current $current
                switch ($action) {
                    'None' { $unchanged++ }
                    'Insert' {
                        $params = @{}
                        $cols = @($spec.Columns) + @('BATCH_ID', 'LOADED_AT', 'LOADED_BY')
                        foreach ($c in $spec.Columns) { $params[$c] = $rec.$c }
                        $params['BATCH_ID'] = $BatchId; $params['LOADED_AT'] = $loadedAt; $params['LOADED_BY'] = $loadedBy
                        $colList = ($cols | ForEach-Object { "[$_]" }) -join ', '
                        $valList = ($cols | ForEach-Object { "@$_" }) -join ', '
                        $null = & $exec "INSERT INTO $qtarget ($colList) VALUES ($valList);" $params
                        $inserted++
                    }
                    'Update' {
                        $params = @{ RESORT = $resort }
                        $setParts = [System.Collections.Generic.List[string]]::new()
                        foreach ($c in $spec.Tracked) { $params[$c] = $rec.$c; $setParts.Add("[$c] = @$c") }
                        $params['BATCH_ID'] = $BatchId; $setParts.Add('[BATCH_ID] = @BATCH_ID')
                        $params['LOADED_AT'] = $loadedAt; $setParts.Add('[LOADED_AT] = @LOADED_AT')
                        $params['LOADED_BY'] = $loadedBy; $setParts.Add('[LOADED_BY] = @LOADED_BY')
                        $null = & $exec "UPDATE $qtarget SET $($setParts -join ', ') WHERE RESORT = @RESORT;" $params
                        $updated++
                    }
                }
                $actions.Add([pscustomobject]@{ Resort = $resort; Code = $code; Action = $action })
                continue
            }

            # --- SCD Type 2 path ---
            $action = Get-Scd2Action -TrackedColumns $spec.Tracked -Incoming $rec -Current $current
            switch ($action) {
                'None' {
                    $unchanged++
                }
                'Update' {
                    # 1) Expire the current row: VALID_TO = today - 1, IS_CURRENT = 0.
                    $expireParams = @{ RESORT = $resort; CODE = $code; VALID_TO = $today.AddDays(-1) }
                    $expireSql = "UPDATE $qtarget SET VALID_TO = @VALID_TO, IS_CURRENT = 0 " +
                                 "WHERE RESORT = @RESORT AND [$codeCol] = @CODE AND IS_CURRENT = 1;"
                    $null = & $exec $expireSql $expireParams
                    # 2) Insert the new current version.
                    $inserted += (Add-Scd2CurrentVersion -Exec $exec -QTarget $qtarget -Spec $spec `
                        -Record $rec -Today $today -BatchId $BatchId -LoadedAt $loadedAt -LoadedBy $loadedBy)
                    $updated++
                }
                'Insert' {
                    $inserted += (Add-Scd2CurrentVersion -Exec $exec -QTarget $qtarget -Spec $spec `
                        -Record $rec -Today $today -BatchId $BatchId -LoadedAt $loadedAt -LoadedBy $loadedBy)
                }
            }
            $actions.Add([pscustomobject]@{ Resort = $resort; Code = $code; Action = $action })
        }

        if ($null -ne $tx) { $tx.Commit() }
    }
    catch {
        if ($null -ne $tx) { try { $tx.Rollback() } catch { } }
        Write-SqlWriterLog -Level 'ERROR' -Module $spec.LogModule -HotelCode $hotelCode -BatchId $BatchId `
            -Message ("SCD2 MERGE into {0} failed; rolled back: {1}" -f $spec.Target, $_.Exception.Message)
        throw
    }
    finally {
        if ($null -ne $tx) { try { $tx.Dispose() } catch { } }
        if ($null -ne $conn) { try { $conn.Close() } catch { }; try { $conn.Dispose() } catch { } }
    }

    Write-SqlWriterLog -Level 'INFO' -Module $spec.LogModule -HotelCode $hotelCode -BatchId $BatchId `
        -Message ("{0} SCD2 complete. Inserted={1} Updated={2} Unchanged={3}" -f $Type, $inserted, $updated, $unchanged)

    return @{ Inserted = $inserted; Updated = $updated; Unchanged = $unchanged; Actions = $actions.ToArray() }
}

function Add-Scd2CurrentVersion {
    <#
    .SYNOPSIS
        Inserts a new current SCD2 version row (VALID_FROM=today, VALID_TO=NULL,
        IS_CURRENT=1) and returns 1.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][scriptblock] $Exec,
        [Parameter(Mandatory)][string] $QTarget,
        [Parameter(Mandatory)][hashtable] $Spec,
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)][datetime] $Today,
        [Parameter(Mandatory)][guid] $BatchId,
        [Parameter(Mandatory)][datetime] $LoadedAt,
        [Parameter(Mandatory)][string] $LoadedBy
    )

    $cols = @($Spec.Columns) + @('VALID_FROM', 'VALID_TO', 'IS_CURRENT', 'BATCH_ID', 'LOADED_AT', 'LOADED_BY')
    $params = @{}
    foreach ($c in $Spec.Columns) { $params[$c] = $Record.$c }
    $params['VALID_FROM'] = $Today
    $params['VALID_TO'] = $null
    $params['IS_CURRENT'] = 1
    $params['BATCH_ID'] = $BatchId
    $params['LOADED_AT'] = $LoadedAt
    $params['LOADED_BY'] = $LoadedBy

    $colList = ($cols | ForEach-Object { "[$_]" }) -join ', '
    $valList = ($cols | ForEach-Object { "@$_" }) -join ', '
    $null = & $Exec "INSERT INTO $QTarget ($colList) VALUES ($valList);" $params
    return 1
}

# ==============================================================================
# Write-LoadLog — DDL-accurate dbo.LoadLog contract (Running row + completion)
# ==============================================================================
function Write-LoadLog {
    <#
    .SYNOPSIS
        Writes/updates a dbo.LoadLog audit row using the ACTUAL SQL\002 DDL columns.
    .DESCRIPTION
        Two phases keyed by -Action:
          'Start'    → INSERT the initial row with Status = 'Running', StartTime = now.
                       Returns the generated/echoed BatchId (a new GUID when none given).
          'Complete' → UPDATE the row (matched by BatchId + HotelCode + QueryType) with
                       the terminal Status, EndTime = now, [RowCount] / RowsInserted /
                       RowsUpdated, and ErrorMessage. DurationSeconds is a PERSISTED
                       computed column (DATEDIFF over StartTime/EndTime) — not written.

        Column contract (authoritative — matches dbo.LoadLog in SQL\002_CreateTables_Actuals.sql):
            BatchId, HotelCode, ChainCode, [Mode], QueryType, BusinessDateFrom,
            BusinessDateTo, StartTime, EndTime, [Status], [RowCount], RowsInserted,
            RowsUpdated, ErrorMessage, LoadedBy.

        RECONCILIATION: Logger.psm1's Start-Batch/Complete-Batch target a DIFFERENT
        (proposed) column set (StartedAt/CompletedAt/DurationMs/RowsFetched). Those do
        NOT match this DDL. Write-LoadLog is the single DDL-accurate contract; it does
        not duplicate the Logger surface but supersedes its column mapping. Logger's
        helpers should be pointed at Write-LoadLog (or updated to these columns) in a
        follow-up so the whole app uses one LoadLog contract.

        All SQL is parameterized; failures are logged as ERROR and rethrown (unlike
        Logger's best-effort mirror, this is the primary audit write). Uses the
        -SqlExecutor seam when supplied.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Hashtable')]
    [OutputType([guid])]
    param(
        [Parameter(ParameterSetName = 'Hashtable', Position = 0)]
        [hashtable] $LogEntry,

        [Parameter(ParameterSetName = 'Explicit')]
        [ValidateSet('Start', 'Complete')]
        [string] $Action = 'Start',

        [Parameter(ParameterSetName = 'Explicit')][Nullable[guid]] $BatchId,
        [Parameter(ParameterSetName = 'Explicit')][string] $HotelCode,
        [Parameter(ParameterSetName = 'Explicit')][string] $ChainCode,
        [Parameter(ParameterSetName = 'Explicit')][string] $Mode,
        [Parameter(ParameterSetName = 'Explicit')][string] $QueryType,
        [Parameter(ParameterSetName = 'Explicit')][Nullable[datetime]] $BusinessDateFrom,
        [Parameter(ParameterSetName = 'Explicit')][Nullable[datetime]] $BusinessDateTo,
        [Parameter(ParameterSetName = 'Explicit')][string] $Status,
        [Parameter(ParameterSetName = 'Explicit')][Nullable[int]] $RowCount,
        [Parameter(ParameterSetName = 'Explicit')][Nullable[int]] $RowsInserted,
        [Parameter(ParameterSetName = 'Explicit')][Nullable[int]] $RowsUpdated,
        [Parameter(ParameterSetName = 'Explicit')][string] $ErrorMessage,

        [Parameter()][scriptblock] $SqlExecutor,
        [Parameter()][string] $ConnectionString,
        [Parameter()][int] $CommandTimeout = 300
    )

    # Normalize hashtable form into the explicit locals.
    if ($PSCmdlet.ParameterSetName -eq 'Hashtable') {
        $LogEntry = if ($null -eq $LogEntry) { @{} } else { $LogEntry }
        $Action           = if ($LogEntry.ContainsKey('Action')) { [string]$LogEntry.Action } else { 'Start' }
        $BatchId          = if ($LogEntry.ContainsKey('BatchId') -and $null -ne $LogEntry.BatchId) { [guid]$LogEntry.BatchId } else { $null }
        $HotelCode        = [string]$LogEntry.HotelCode
        $ChainCode        = [string]$LogEntry.ChainCode
        $Mode             = [string]$LogEntry.Mode
        $QueryType        = [string]$LogEntry.QueryType
        $BusinessDateFrom = if ($LogEntry.ContainsKey('BusinessDateFrom') -and $null -ne $LogEntry.BusinessDateFrom) { [datetime]$LogEntry.BusinessDateFrom } else { $null }
        $BusinessDateTo   = if ($LogEntry.ContainsKey('BusinessDateTo') -and $null -ne $LogEntry.BusinessDateTo) { [datetime]$LogEntry.BusinessDateTo } else { $null }
        $Status           = [string]$LogEntry.Status
        $RowCount         = if ($LogEntry.ContainsKey('RowCount') -and $null -ne $LogEntry.RowCount) { [int]$LogEntry.RowCount } else { $null }
        $RowsInserted     = if ($LogEntry.ContainsKey('RowsInserted') -and $null -ne $LogEntry.RowsInserted) { [int]$LogEntry.RowsInserted } else { $null }
        $RowsUpdated      = if ($LogEntry.ContainsKey('RowsUpdated') -and $null -ne $LogEntry.RowsUpdated) { [int]$LogEntry.RowsUpdated } else { $null }
        $ErrorMessage     = [string]$LogEntry.ErrorMessage
    }

    $loadedBy = Get-LoadedByIdentity
    $now = [datetime]::UtcNow

    $exec = {
        param([string] $Sql, [hashtable] $Params)
        if ($null -ne $SqlExecutor) { return & $SqlExecutor $Sql $Params }
        $effConn = Resolve-SqlConnectionString -ConnectionString $ConnectionString
        if ([string]::IsNullOrWhiteSpace($effConn)) {
            throw 'Write-LoadLog requires a connection string when no -SqlExecutor seam is supplied.'
        }
        return Invoke-DefaultSqlExecutor -Sql $Sql -Parameters $Params -ConnectionString $effConn -CommandTimeout $CommandTimeout
    }

    try {
        if ($Action -eq 'Start') {
            $batch = if ($null -ne $BatchId) { $BatchId } else { [guid]::NewGuid() }
            $insertSql = @'
INSERT INTO dbo.LoadLog
    (BatchId, HotelCode, ChainCode, [Mode], QueryType,
     BusinessDateFrom, BusinessDateTo, StartTime, [Status], LoadedBy)
VALUES
    (@BatchId, @HotelCode, @ChainCode, @Mode, @QueryType,
     @BusinessDateFrom, @BusinessDateTo, @StartTime, @Status, @LoadedBy);
'@
            $params = @{
                BatchId          = $batch
                HotelCode        = $HotelCode
                ChainCode        = if ([string]::IsNullOrWhiteSpace($ChainCode)) { $null } else { $ChainCode }
                Mode             = if ([string]::IsNullOrWhiteSpace($Mode)) { $null } else { $Mode }
                QueryType        = $QueryType
                BusinessDateFrom = if ($null -ne $BusinessDateFrom) { ([datetime]$BusinessDateFrom).Date } else { $null }
                BusinessDateTo   = if ($null -ne $BusinessDateTo) { ([datetime]$BusinessDateTo).Date } else { $null }
                StartTime        = $now
                Status           = if ([string]::IsNullOrWhiteSpace($Status)) { 'Running' } else { $Status }
                LoadedBy         = $loadedBy
            }
            $null = & $exec $insertSql $params
            Write-SqlWriterLog -Level 'INFO' -Module 'SqlWriter.LoadLog' -HotelCode $HotelCode -BatchId $batch `
                -Message ("LoadLog Running row inserted. QueryType={0} Mode={1}" -f $QueryType, $Mode)
            return $batch
        }
        else {
            if ($null -eq $BatchId) { throw "Write-LoadLog -Action Complete requires -BatchId." }
            $updateSql = @'
UPDATE dbo.LoadLog
SET
    [Status]      = @Status,
    EndTime       = @EndTime,
    [RowCount]    = COALESCE(@RowCount,      [RowCount]),
    RowsInserted  = COALESCE(@RowsInserted,  RowsInserted),
    RowsUpdated   = COALESCE(@RowsUpdated,   RowsUpdated),
    ErrorMessage  = COALESCE(@ErrorMessage,  ErrorMessage)
WHERE BatchId = @BatchId
  AND (@HotelCode IS NULL OR HotelCode = @HotelCode)
  AND (@QueryType IS NULL OR QueryType = @QueryType)
  AND EndTime IS NULL;
'@
            $params = @{
                BatchId      = [guid]$BatchId
                Status       = if ([string]::IsNullOrWhiteSpace($Status)) { 'Success' } else { $Status }
                EndTime      = $now
                RowCount     = if ($null -ne $RowCount) { [int]$RowCount } else { $null }
                RowsInserted = if ($null -ne $RowsInserted) { [int]$RowsInserted } else { $null }
                RowsUpdated  = if ($null -ne $RowsUpdated) { [int]$RowsUpdated } else { $null }
                ErrorMessage = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage }
                HotelCode    = if ([string]::IsNullOrWhiteSpace($HotelCode)) { $null } else { $HotelCode }
                QueryType    = if ([string]::IsNullOrWhiteSpace($QueryType)) { $null } else { $QueryType }
            }
            $affected = [int](& $exec $updateSql $params)
            if ($affected -lt 1) {
                Write-SqlWriterLog -Level 'WARN' -Module 'SqlWriter.LoadLog' -HotelCode $HotelCode -BatchId ([guid]$BatchId) `
                    -Message 'LoadLog completion update matched no open Running row.'
            }
            else {
                Write-SqlWriterLog -Level 'INFO' -Module 'SqlWriter.LoadLog' -HotelCode $HotelCode -BatchId ([guid]$BatchId) `
                    -Message ("LoadLog completed. Status={0} RowCount={1} Inserted={2} Updated={3}" -f `
                        $params.Status, $RowCount, $RowsInserted, $RowsUpdated)
            }
            return ([guid]$BatchId)
        }
    }
    catch {
        Write-SqlWriterLog -Level 'ERROR' -Module 'SqlWriter.LoadLog' -HotelCode $HotelCode `
            -Message ("Write-LoadLog ({0}) failed: {1}" -f $Action, $_.Exception.Message)
        throw
    }
}

# ==============================================================================
# Exports
# ==============================================================================
Export-ModuleMember -Function @(
    'Initialize-Database',
    'Write-RES', 'Write-FIN', 'Write-OTB', 'Write-BLK', 'Write-RMN', 'Write-OOO', 'Write-RoomInventory',
    'Write-DIM', 'Write-LoadLog',
    # Internal helpers exported for unit testing / reuse
    'Get-SqlWriterTableSpec', 'Resolve-SqlConnectionString', 'Split-SqlBatches',
    'New-MergeStatement', 'Get-IsLatePosting', 'Get-IsPastCutoff', 'Get-Scd2Action',
    'ConvertTo-SqlDate', 'ConvertTo-StagingRow', 'Invoke-SqlBulkMerge'
) -Alias @(
    'Write-ReservationStats', 'Write-FinancialTx', 'Write-OnTheBooks', 'Write-BlockReservations', 'Write-MasterData'
)
