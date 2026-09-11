# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Entry-point orchestrator for the OPERA R&A Data Loader (Task 15).

.DESCRIPTION
    Wires together every module built in Tasks 2-14 to extract Oracle Hospitality
    OHIP R&A Data (GraphQL) into SQL Server for one or more hotels across one or more
    chains. Responsibilities:

      * Declare the runtime parameter surface (-Mode, -HotelCode, -ChainCode,
        -BusinessDate, -StartDate, -EndDate, -DryRun, -FailFast, -ConfigPath).
      * Load + validate Config\settings.json and Config\hotels.json; fail fast on
        missing required fields.
      * Validate that each in-scope hotel's DPAPI-encrypted credentials
        (clientId / clientSecret / apiKey) decrypt successfully before any load runs.
        Secret values are NEVER logged.
      * Filter the hotel set by -HotelCode / -ChainCode.
      * Initialize the SQL schema (idempotent DDL) for -Mode Full or when the schema
        is absent.
      * Run the per-hotel execution loop: Initialize-Logger context, Start-Batch,
        resolve the business date (Get-BusinessDate honouring nightAuditHour /
        timeZoneId) and date range, acquire an OAuth token (Get-OAuthToken), then run
        the -Mode-appropriate Get-* query modules and pass their output to the matching
        Write-* writers (skipped under -DryRun). Per-hotel errors are isolated unless
        -FailFast is set.
      * Print a console summary table (Hotel | Status | Rows | Duration).
      * Send per-hotel end-of-run alert emails (Send-AlertEmail) when configured.
      * Exit 0 (all success), 1 (partial failure), or 2 (total failure).

    TESTABILITY
    -----------
    The procedural body at the bottom is guarded: when $env:RUN_OPERA_NO_MAIN -eq '1'
    the script dot-sources its reusable functions (Resolve-Config, Select-Hotels,
    Test-HotelCredentials, Invoke-HotelLoad, Get-RunExitCode, Write-SummaryTable,
    ConvertTo-HotelHashtable, Get-ModeQuerySet) WITHOUT running the loader, so Pester
    can unit-test them with injected fakes (no network / no SQL). This mirrors
    Tools\Protect-HotelsConfig.ps1 ($env:PROTECT_HOTELS_NO_MAIN).

.PARAMETER Mode
    Execution mode. One of: All, Full, Delta, OTB, MasterData. Default: Delta.
      Delta      → RES, FIN, OTB, BLK, RoomInventory
      OTB        → OTB, BLK, RoomInventory
      MasterData → master data (DIM) lists only
      Full / All → everything (Full also forces Initialize-Database)

.PARAMETER HotelCode
    Restrict the run to one or more hotel codes (case-insensitive).

.PARAMETER ChainCode
    Restrict the run to one or more chain codes (case-insensitive).

.PARAMETER BusinessDate
    Override the resolved business date for actuals (default: each hotel's previous
    business date via Get-BusinessDate). Also used as the snapshot date for OTB/BLK.

.PARAMETER StartDate
    Explicit inclusive start date for actuals (RES / FIN / RoomInventory OOO range).

.PARAMETER EndDate
    Explicit inclusive end date for actuals. Must be >= StartDate.

.PARAMETER DryRun
    Fetch data but skip every SQL write. Log lines are prefixed [DRYRUN].

.PARAMETER FailFast
    Stop the whole run on the first hotel error (default: continue and log).

.PARAMETER ConfigPath
    Override the config directory (must contain settings.json and hotels.json).
    Defaults to the repo Config\ folder next to this script.

.EXAMPLE
    .\Run-OperaRALoader.ps1 -Mode Delta

.EXAMPLE
    .\Run-OperaRALoader.ps1 -Mode Full -HotelCode HOTEL1 -DryRun -Verbose

.EXAMPLE
    .\Run-OperaRALoader.ps1 -Mode OTB -ChainCode CHAIN_A -BusinessDate 2026-07-30
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('All', 'Full', 'Delta', 'OTB', 'MasterData')]
    [string] $Mode = 'Delta',

    [Parameter()]
    [string[]] $HotelCode,

    [Parameter()]
    [string[]] $ChainCode,

    [Parameter()]
    [Nullable[datetime]] $BusinessDate,

    [Parameter()]
    [Nullable[datetime]] $StartDate,

    [Parameter()]
    [Nullable[datetime]] $EndDate,

    [Parameter()]
    [switch] $DryRun,

    [Parameter()]
    [switch] $FailFast,

    [Parameter()]
    [string] $ConfigPath
)

# ==============================================================================
# Module import (relative to $PSScriptRoot). Skipped when only the functions are
# needed for unit testing (the guard below returns before the main body runs,
# but importing modules is harmless and keeps parse/import verification honest;
# tests set RUN_OPERA_NO_MAIN and inject fakes so no module call actually fires).
# ==============================================================================
$script:ModulesRoot = Join-Path $PSScriptRoot 'Modules'
$script:QueriesRoot = Join-Path $script:ModulesRoot 'Queries'

function Import-OperaModules {
    <#
    .SYNOPSIS
        Imports all loader modules relative to $PSScriptRoot. Idempotent.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string] $ModulesRoot = $script:ModulesRoot,
        [Parameter()] [string] $QueriesRoot = $script:QueriesRoot
    )

    $modules = @(
        (Join-Path $ModulesRoot 'Logger.psm1'),
        (Join-Path $ModulesRoot 'DateHelper.psm1'),
        (Join-Path $ModulesRoot 'Auth.psm1'),
        (Join-Path $ModulesRoot 'ApiClient.psm1'),
        (Join-Path $ModulesRoot 'SqlWriter.psm1'),
        (Join-Path $QueriesRoot 'ReservationStats.psm1'),
        (Join-Path $QueriesRoot 'FinancialTransactions.psm1'),
        (Join-Path $QueriesRoot 'OnTheBooks.psm1'),
        (Join-Path $QueriesRoot 'BlockReservations.psm1'),
        (Join-Path $QueriesRoot 'RoomInventory.psm1'),
        (Join-Path $QueriesRoot 'MasterData.psm1')
    )
    foreach ($m in $modules) {
        if (-not (Test-Path -LiteralPath $m)) {
            throw "Required module not found: $m"
        }
        Import-Module -Name $m -Force -DisableNameChecking -ErrorAction Stop
    }
}

# ==============================================================================
# Logging shim — use Logger's Write-Log when loaded, else Write-Verbose. Never
# throws so orchestration is not derailed by a logging fault.
# ==============================================================================
function Write-LoaderLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')] [string] $Level,
        [Parameter(Mandatory)] [string] $Message,
        [Parameter()] [string] $HotelCode = '',
        [Parameter()] [guid] $BatchId = [guid]::Empty,
        [Parameter()] [string] $Module = 'Run-OperaRALoader'
    )
    $cmd = Get-Command -Name 'Write-Log' -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            & $cmd -Level $Level -Module $Module -Message $Message -HotelCode $HotelCode -BatchId $BatchId
            return
        }
        catch { }
    }
    Write-Verbose ("{0} [{1}] {2}: {3}" -f $Module, $Level, $HotelCode, $Message)
}

# ==============================================================================
# ConvertTo-HotelHashtable — DateHelper / SqlWriter Write-DIM require a [hashtable]
# Hotel; hotels.json parses to PSCustomObject. This produces a case-tolerant
# hashtable copy exposing the keys those helpers read (hotelCode, timeZoneId,
# nightAuditHour, otbFutureDays, blockFutureDays, chainCode, HotelCode, ChainCode).
# Secret fields are copied through (needed by Get-OAuthToken) but never logged.
# ==============================================================================
function ConvertTo-HotelHashtable {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] $Hotel
    )

    $ht = @{}
    if ($Hotel -is [hashtable]) {
        foreach ($k in $Hotel.Keys) { $ht[$k] = $Hotel[$k] }
    }
    else {
        foreach ($p in $Hotel.PSObject.Properties) { $ht[$p.Name] = $p.Value }
    }

    # Ensure both camelCase (query/date modules) and PascalCase (Write-DIM) keys for
    # the fields those consumers read, without clobbering existing values.
    $code = if ($ht.ContainsKey('hotelCode')) { $ht['hotelCode'] } elseif ($ht.ContainsKey('HotelCode')) { $ht['HotelCode'] } else { $null }
    $chain = if ($ht.ContainsKey('chainCode')) { $ht['chainCode'] } elseif ($ht.ContainsKey('ChainCode')) { $ht['ChainCode'] } else { $null }
    if ($null -ne $code) { $ht['hotelCode'] = $code; $ht['HotelCode'] = $code }
    if ($null -ne $chain) { $ht['chainCode'] = $chain; $ht['ChainCode'] = $chain }
    return $ht
}

# ==============================================================================
# Resolve-Config — load + validate settings.json and hotels.json. Fails fast
# (throws) on a missing file or missing required field. Returns
# @{ Settings = <psobject>; Hotels = <array>; ConfigDir = <path> }.
# ==============================================================================
function Resolve-Config {
    <#
    .SYNOPSIS
        Loads and validates settings.json + hotels.json from the config directory.
    .PARAMETER ConfigDir
        Config directory. Must contain settings.json and hotels.json.
    .PARAMETER SettingsReader / HotelsReader
        Optional test seams returning already-parsed objects instead of reading disk.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $ConfigDir,
        [Parameter()] [scriptblock] $SettingsReader,
        [Parameter()] [scriptblock] $HotelsReader
    )

    # --- settings.json -------------------------------------------------------
    $settingsPath = Join-Path $ConfigDir 'settings.json'
    if ($SettingsReader) {
        $settings = & $SettingsReader $settingsPath
    }
    else {
        if (-not (Test-Path -LiteralPath $settingsPath)) {
            throw "Configuration error: settings.json not found at '$settingsPath'."
        }
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }

    # Required settings fields.
    if ($null -eq $settings) { throw 'Configuration error: settings.json parsed to null.' }
    $sqlServer = $settings.PSObject.Properties['sqlServer']
    if (-not $sqlServer -or $null -eq $settings.sqlServer) {
        throw "Configuration error: settings.json is missing required section 'sqlServer'."
    }
    $connString = $settings.sqlServer.PSObject.Properties['connectionString']
    if (-not $connString -or [string]::IsNullOrWhiteSpace([string]$settings.sqlServer.connectionString)) {
        throw "Configuration error: settings.json is missing required field 'sqlServer.connectionString'."
    }
    if (-not $settings.PSObject.Properties['logging'] -or $null -eq $settings.logging) {
        throw "Configuration error: settings.json is missing required section 'logging'."
    }

    # --- hotels.json ---------------------------------------------------------
    $hotelsPath = Join-Path $ConfigDir 'hotels.json'
    if ($HotelsReader) {
        $hotelsConfig = & $HotelsReader $hotelsPath
    }
    else {
        if (-not (Test-Path -LiteralPath $hotelsPath)) {
            throw "Configuration error: hotels.json not found at '$hotelsPath'. Run Tools\Protect-HotelsConfig.ps1 to create it."
        }
        $hotelsConfig = Get-Content -LiteralPath $hotelsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }

    if ($null -eq $hotelsConfig -or -not $hotelsConfig.PSObject.Properties['hotels'] -or $null -eq $hotelsConfig.hotels) {
        throw "Configuration error: hotels.json is missing the required 'hotels' array."
    }
    $hotels = @($hotelsConfig.hotels)
    if ($hotels.Count -eq 0) {
        throw 'Configuration error: hotels.json contains no hotels.'
    }

    # Validate required per-hotel fields.
    $required = @('hotelCode', 'chainCode', 'gatewayUrl', 'clientId', 'clientSecret', 'apiKey', 'timeZoneId')
    $idx = 0
    foreach ($h in $hotels) {
        $label = if ($h.PSObject.Properties['hotelCode'] -and $h.hotelCode) { [string]$h.hotelCode } else { "index $idx" }
        foreach ($field in $required) {
            $hasProp = $h.PSObject.Properties[$field]
            if (-not $hasProp -or [string]::IsNullOrWhiteSpace([string]$h.$field)) {
                throw "Configuration error: hotel '$label' is missing required field '$field'."
            }
        }
        $idx++
    }

    return @{
        Settings  = $settings
        Hotels    = $hotels
        ConfigDir = $ConfigDir
    }
}

# ==============================================================================
# Select-Hotels — narrow the hotel set by enabled + -HotelCode / -ChainCode.
# Returns the filtered array (may be empty; caller decides how to react).
# ==============================================================================
function Select-Hotels {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array] $Hotels,
        [Parameter()] [string[]] $HotelCode,
        [Parameter()] [string[]] $ChainCode,
        [Parameter()] [switch] $IncludeDisabled
    )

    $result = @($Hotels)

    if (-not $IncludeDisabled) {
        $result = @($result | Where-Object {
                # Treat a missing 'enabled' flag as enabled (opt-out semantics).
                -not $_.PSObject.Properties['enabled'] -or [bool]$_.enabled
            })
    }

    if ($HotelCode -and $HotelCode.Count -gt 0) {
        $wanted = @($HotelCode | ForEach-Object { $_.Trim().ToUpperInvariant() })
        $result = @($result | Where-Object { $wanted -contains ([string]$_.hotelCode).ToUpperInvariant() })
    }

    if ($ChainCode -and $ChainCode.Count -gt 0) {
        $wantedChain = @($ChainCode | ForEach-Object { $_.Trim().ToUpperInvariant() })
        $result = @($result | Where-Object { $wantedChain -contains ([string]$_.chainCode).ToUpperInvariant() })
    }

    return @($result)
}

# ==============================================================================
# Test-HotelCredentials — validate DPAPI decryption of clientId / clientSecret /
# apiKey up front (fail fast per hotel, never logging secret values). Returns
# @{ Ok = <bool>; Reason = <string> }. -Decryptor is an injectable seam.
# ==============================================================================
function Test-HotelCredentials {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] $Hotel,
        [Parameter()] [scriptblock] $Decryptor
    )

    if (-not $Decryptor) {
        # Real DPAPI decrypt: ConvertTo-SecureString without -Key (current user/machine),
        # matching Auth.psm1 / Protect-HotelsConfig.ps1. Value is discarded immediately.
        $Decryptor = {
            param($cipher, $field)
            $secure = $null
            $bstr = [IntPtr]::Zero
            try {
                $secure = ConvertTo-SecureString -String $cipher -ErrorAction Stop
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                return -not [string]::IsNullOrEmpty($plain)
            }
            finally {
                if ($bstr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                if ($secure) { $secure.Dispose() }
            }
        }
    }

    $code = [string]$Hotel.hotelCode
    foreach ($field in @('clientId', 'clientSecret', 'apiKey')) {
        $cipher = [string]$Hotel.$field
        try {
            $ok = & $Decryptor $cipher $field
            if (-not $ok) {
                return @{ Ok = $false; Reason = "Credential '$field' decrypted to an empty value." }
            }
        }
        catch {
            # Never surface cipher/plaintext in the message.
            return @{ Ok = $false; Reason = "Credential '$field' failed to decrypt (was it encrypted by this service account on this host?)." }
        }
    }
    return @{ Ok = $true; Reason = '' }
}

# ==============================================================================
# Get-ModeQuerySet — map -Mode to the ordered set of query types to run, per the
# design.md Mode Behaviour Matrix. Returns an ordered [string[]].
#   RES, FIN, OTB, BLK, RMN, DIM
# ==============================================================================
function Get-ModeQuerySet {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [ValidateSet('All', 'Full', 'Delta', 'OTB', 'MasterData')] [string] $Mode
    )
    switch ($Mode) {
        'MasterData' { return [string[]]@('DIM') }
        'OTB' { return [string[]]@('OTB', 'BLK', 'RMN') }
        'Delta' { return [string[]]@('RES', 'FIN', 'OTB', 'BLK', 'RMN') }
        'Full' { return [string[]]@('DIM', 'RES', 'FIN', 'OTB', 'BLK', 'RMN') }
        'All' { return [string[]]@('DIM', 'RES', 'FIN', 'OTB', 'BLK', 'RMN') }
        default { return [string[]]@() }
    }
}

# ==============================================================================
# Get-RunExitCode — compute the process exit code from per-hotel results.
#   0 = all success (no hotels processed also counts as success/no-op)
#   1 = partial failure (at least one Success/NoData AND at least one Failed)
#   2 = total failure (all processed hotels Failed)
# A hotel result is a hashtable/object exposing a .Status of Success|NoData|Failed.
# ==============================================================================
function Get-RunExitCode {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array] $Results
    )

    if ($null -eq $Results -or $Results.Count -eq 0) { return 0 }

    $failed = @($Results | Where-Object { [string]$_.Status -eq 'Failed' }).Count
    $succeeded = @($Results | Where-Object { @('Success', 'NoData') -contains [string]$_.Status }).Count

    if ($failed -eq 0) { return 0 }
    if ($succeeded -eq 0) { return 2 }
    return 1
}

# ==============================================================================
# Write-SummaryTable — build + return a formatted summary table string
# (Hotel | Status | Rows | Duration). Writing to the host is done by the caller;
# returning the text keeps this pure and unit-testable.
# ==============================================================================
function Write-SummaryTable {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array] $Results
    )

    $rows = foreach ($r in $Results) {
        [pscustomobject]@{
            Hotel    = [string]$r.HotelCode
            Status   = [string]$r.Status
            Rows     = [int]$r.Rows
            Duration = if ($null -ne $r.Duration) { ('{0:hh\:mm\:ss}' -f [timespan]$r.Duration) } else { '00:00:00' }
        }
    }

    if (-not $rows) {
        return 'No hotels were processed.'
    }
    # Force a wide render so no column is dropped when stdout width is narrow.
    return (@($rows) | Format-Table -Property Hotel, Status, Rows, Duration -AutoSize | Out-String -Width 4096).TrimEnd()
}

# ==============================================================================
# Invoke-HotelLoad — run all query→writer steps for ONE hotel for the given Mode.
# Fully seam-injectable so it is unit-testable without network or SQL:
#   -Queries  : hashtable of scriptblocks keyed RES/FIN/OTB/BLK/RMN/DIM. Each is
#               invoked with a single hashtable of args and returns rows (RMN
#               returns @{ RMN; OOO }, DIM callbacks receive a -Type).
#   -Writers  : hashtable of scriptblocks keyed RES/FIN/OTB/BLK/RMN/DIM. Invoked
#               with (@{ Data/RoomData/OooData; BatchId; Hotel; Type }). Skipped
#               entirely under -DryRun.
#   -TokenProvider : scriptblock returning a bearer token (default Get-OAuthToken).
# Returns a per-hotel result hashtable:
#   @{ HotelCode; ChainCode; Status; Rows; Duration; Error; WroteAny }.
# ==============================================================================
function Invoke-HotelLoad {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] $Hotel,
        [Parameter(Mandatory)] [ValidateSet('All', 'Full', 'Delta', 'OTB', 'MasterData')] [string] $Mode,
        [Parameter(Mandatory)] [hashtable] $Queries,
        [Parameter(Mandatory)] [hashtable] $Writers,
        [Parameter()] [switch] $DryRun,
        [Parameter()] [guid] $BatchId = [guid]::NewGuid(),
        [Parameter()] [Nullable[datetime]] $BusinessDate,
        [Parameter()] [Nullable[datetime]] $StartDate,
        [Parameter()] [Nullable[datetime]] $EndDate,
        [Parameter()] $Config,
        [Parameter()] [string] $Token,
        [Parameter()] [scriptblock] $BusinessDateResolver
    )

    $hotelHt = ConvertTo-HotelHashtable -Hotel $Hotel
    $code = [string]$hotelHt['hotelCode']
    $chain = [string]$hotelHt['chainCode']
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $totalRows = 0
    $wroteAny = $false
    $prefix = if ($DryRun) { '[DRYRUN] ' } else { '' }

    # --- Resolve business date + actuals range -------------------------------
    if (-not $BusinessDateResolver) {
        $BusinessDateResolver = { param($h) Get-BusinessDate -Hotel $h }
    }
    $bizDate = if ($BusinessDate) { ([datetime]$BusinessDate).Date } else { ([datetime](& $BusinessDateResolver $hotelHt)).Date }
    $rangeStart = if ($StartDate) { ([datetime]$StartDate).Date } else { $bizDate }
    $rangeEnd = if ($EndDate) { ([datetime]$EndDate).Date } else { $bizDate }
    if ($rangeStart -gt $rangeEnd) {
        throw "Invoke-HotelLoad: StartDate ($($rangeStart.ToString('yyyy-MM-dd'))) must be on or before EndDate ($($rangeEnd.ToString('yyyy-MM-dd')))."
    }

    $querySet = Get-ModeQuerySet -Mode $Mode
    Write-LoaderLog -Level INFO -HotelCode $code -BatchId $BatchId -Message (
        "{0}Hotel load start. Mode={1} BusinessDate={2:yyyy-MM-dd} Range={3:yyyy-MM-dd}..{4:yyyy-MM-dd} Queries={5}" -f `
            $prefix, $Mode, $bizDate, $rangeStart, $rangeEnd, ($querySet -join ','))

    # Common args passed to query seams.
    $common = @{
        Hotel   = $hotelHt
        Token   = $Token
        Config  = $Config
        BatchId = $BatchId
    }

    foreach ($q in $querySet) {
        switch ($q) {
            'DIM' {
                # Master data — independent lists. SourceCodes required, Channels optional.
                $dimTypes = @(
                    @{ Type = 'TrxCodes'; DimTarget = 'DIM_TrxCodes'; Required = $true },
                    @{ Type = 'RoomTypeLabels'; DimTarget = 'DIM_RoomTypes'; Required = $true },
                    @{ Type = 'RateCodes'; DimTarget = 'DIM_RateCodes'; Required = $true },
                    @{ Type = 'MarketCodes'; DimTarget = 'DIM_MarketCodes'; Required = $true },
                    @{ Type = 'SourceCodes'; DimTarget = 'DIM_SourceCodes'; Required = $true },
                    @{ Type = 'Channels'; DimTarget = 'DIM_Channels'; Required = $false },
                    @{ Type = 'Hotels'; DimTarget = 'Hotels'; Required = $true }
                )
                foreach ($d in $dimTypes) {
                    try {
                        $args = $common.Clone()
                        $args['Type'] = $d.Type
                        $rows = @(& $Queries['DIM'] $args)
                        $totalRows += $rows.Count
                        if (-not $DryRun -and $Writers['DIM']) {
                            & $Writers['DIM'] @{ Type = $d.DimTarget; Data = $rows; BatchId = $BatchId; Hotel = $hotelHt; RefreshMode = 'Full' }
                            $wroteAny = $true
                        }
                        elseif ($DryRun) {
                            Write-LoaderLog -Level INFO -HotelCode $code -BatchId $BatchId -Message ("{0}Skipping Write-DIM {1} (dry run). Fetched {2} rows." -f $prefix, $d.DimTarget, $rows.Count)
                        }
                    }
                    catch {
                        if (-not $d.Required) {
                            Write-LoaderLog -Level WARN -HotelCode $code -BatchId $BatchId -Message ("Optional master list '{0}' skipped: {1}" -f $d.Type, $_.Exception.Message)
                        }
                        else {
                            throw
                        }
                    }
                }
            }
            'RES' {
                $args = $common.Clone(); $args['StartDate'] = $rangeStart; $args['EndDate'] = $rangeEnd
                $rows = @(& $Queries['RES'] $args)
                $totalRows += $rows.Count
                if (-not $DryRun -and $Writers['RES']) { & $Writers['RES'] @{ Data = $rows; BatchId = $BatchId; Hotel = $hotelHt }; $wroteAny = $true }
                elseif ($DryRun) { Write-LoaderLog -Level INFO -HotelCode $code -BatchId $BatchId -Message ("{0}Skipping Write-RES (dry run). Fetched {1} rows." -f $prefix, $rows.Count) }
            }
            'FIN' {
                $args = $common.Clone(); $args['StartDate'] = $rangeStart; $args['EndDate'] = $rangeEnd
                $rows = @(& $Queries['FIN'] $args)
                $totalRows += $rows.Count
                if (-not $DryRun -and $Writers['FIN']) { & $Writers['FIN'] @{ Data = $rows; BatchId = $BatchId; Hotel = $hotelHt }; $wroteAny = $true }
                elseif ($DryRun) { Write-LoaderLog -Level INFO -HotelCode $code -BatchId $BatchId -Message ("{0}Skipping Write-FIN (dry run). Fetched {1} rows." -f $prefix, $rows.Count) }
            }
            'OTB' {
                $args = $common.Clone(); $args['SnapshotDate'] = $bizDate
                $rows = @(& $Queries['OTB'] $args)
                $totalRows += $rows.Count
                if (-not $DryRun -and $Writers['OTB']) { & $Writers['OTB'] @{ Data = $rows; BatchId = $BatchId; Hotel = $hotelHt }; $wroteAny = $true }
                elseif ($DryRun) { Write-LoaderLog -Level INFO -HotelCode $code -BatchId $BatchId -Message ("{0}Skipping Write-OTB (dry run). Fetched {1} rows." -f $prefix, $rows.Count) }
            }
            'BLK' {
                $args = $common.Clone(); $args['SnapshotDate'] = $bizDate
                $rows = @(& $Queries['BLK'] $args)
                $totalRows += $rows.Count
                if (-not $DryRun -and $Writers['BLK']) { & $Writers['BLK'] @{ Data = $rows; BatchId = $BatchId; Hotel = $hotelHt }; $wroteAny = $true }
                elseif ($DryRun) { Write-LoaderLog -Level INFO -HotelCode $code -BatchId $BatchId -Message ("{0}Skipping Write-BLK (dry run). Fetched {1} rows." -f $prefix, $rows.Count) }
            }
            'RMN' {
                $args = $common.Clone(); $args['StartDate'] = $rangeStart; $args['EndDate'] = $rangeEnd
                $inv = & $Queries['RMN'] $args
                $rmn = @(); $ooo = @()
                if ($null -ne $inv) {
                    if ($inv -is [hashtable]) { $rmn = @($inv['RMN']); $ooo = @($inv['OOO']) }
                    elseif ($inv.PSObject.Properties['RMN']) { $rmn = @($inv.RMN); $ooo = @($inv.OOO) }
                }
                $totalRows += ($rmn.Count + $ooo.Count)
                if (-not $DryRun -and $Writers['RMN']) { & $Writers['RMN'] @{ RoomData = $rmn; OooData = $ooo; BatchId = $BatchId; Hotel = $hotelHt }; $wroteAny = $true }
                elseif ($DryRun) { Write-LoaderLog -Level INFO -HotelCode $code -BatchId $BatchId -Message ("{0}Skipping Write-RoomInventory (dry run). Fetched RMN={1} OOO={2}." -f $prefix, $rmn.Count, $ooo.Count) }
            }
        }
    }

    $sw.Stop()
    $status = if ($totalRows -eq 0) { 'NoData' } else { 'Success' }
    Write-LoaderLog -Level INFO -HotelCode $code -BatchId $BatchId -Message (
        "{0}Hotel load complete. Status={1} Rows={2} Duration={3:hh\:mm\:ss}" -f $prefix, $status, $totalRows, $sw.Elapsed)

    return @{
        HotelCode = $code
        ChainCode = $chain
        Status    = $status
        Rows      = $totalRows
        Duration  = $sw.Elapsed
        Error     = ''
        WroteAny  = $wroteAny
    }
}

# ==============================================================================
# Invoke-Loader — the orchestration driver used by the main body. Kept as a
# function so the whole flow can be exercised end-to-end with injected fakes.
# ==============================================================================
function Invoke-Loader {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateSet('All', 'Full', 'Delta', 'OTB', 'MasterData')] [string] $Mode,
        [Parameter(Mandatory)] [string] $ConfigDir,
        [Parameter()] [string[]] $HotelCode,
        [Parameter()] [string[]] $ChainCode,
        [Parameter()] [Nullable[datetime]] $BusinessDate,
        [Parameter()] [Nullable[datetime]] $StartDate,
        [Parameter()] [Nullable[datetime]] $EndDate,
        [Parameter()] [switch] $DryRun,
        [Parameter()] [switch] $FailFast,
        # Seams (default to the real module functions).
        [Parameter()] [hashtable] $Queries,
        [Parameter()] [hashtable] $Writers,
        [Parameter()] [scriptblock] $CredentialTester,
        [Parameter()] [scriptblock] $TokenProvider,
        [Parameter()] [scriptblock] $DatabaseInitializer,
        [Parameter()] [scriptblock] $BusinessDateResolver,
        [Parameter()] [scriptblock] $ConfigResolver
    )

    # --- Load + validate config (fail fast). ---------------------------------
    $cfg = if ($ConfigResolver) { & $ConfigResolver $ConfigDir } else { Resolve-Config -ConfigDir $ConfigDir }
    $settings = $cfg.Settings
    $allHotels = @($cfg.Hotels)

    # --- Filter hotels. ------------------------------------------------------
    $selected = Select-Hotels -Hotels $allHotels -HotelCode $HotelCode -ChainCode $ChainCode
    if ($selected.Count -eq 0) {
        Write-LoaderLog -Level WARN -Message 'No hotels matched the -HotelCode / -ChainCode filter (or all are disabled). Nothing to do.'
        return @{ Results = @(); ExitCode = 0; Summary = 'No hotels were processed.' }
    }

    # --- Default query/writer seams to the real module functions. ------------
    if (-not $Queries) {
        $Queries = @{
            RES = { param($a) Get-ReservationStats -Hotel $a.Hotel -StartDate $a.StartDate -EndDate $a.EndDate -Token $a.Token -Config $a.Config -BatchId $a.BatchId }
            FIN = { param($a) Get-FinancialTransactions -Hotel $a.Hotel -StartDate $a.StartDate -EndDate $a.EndDate -Token $a.Token -Config $a.Config -BatchId $a.BatchId }
            OTB = { param($a) Get-OnTheBooks -Hotel $a.Hotel -SnapshotDate $a.SnapshotDate -Token $a.Token -Config $a.Config -BatchId $a.BatchId }
            BLK = { param($a) Get-BlockReservations -Hotel $a.Hotel -SnapshotDate $a.SnapshotDate -Token $a.Token -Config $a.Config -BatchId $a.BatchId }
            RMN = { param($a) Get-RoomInventory -Hotel $a.Hotel -StartDate $a.StartDate -EndDate $a.EndDate -Token $a.Token -Config $a.Config -BatchId $a.BatchId }
            DIM = { param($a) Get-MasterData -Hotel $a.Hotel -Type $a.Type -Token $a.Token -Config $a.Config -BatchId $a.BatchId }
        }
    }
    if (-not $Writers) {
        $Writers = @{
            RES = { param($a) Write-RES -Data $a.Data -BatchId $a.BatchId -Hotel $a.Hotel }
            FIN = { param($a) Write-FIN -Data $a.Data -BatchId $a.BatchId -Hotel $a.Hotel }
            OTB = { param($a) Write-OTB -Data $a.Data -BatchId $a.BatchId -Hotel $a.Hotel }
            BLK = { param($a) Write-BLK -Data $a.Data -BatchId $a.BatchId -Hotel $a.Hotel }
            RMN = { param($a) Write-RoomInventory -RoomData $a.RoomData -OooData $a.OooData -BatchId $a.BatchId -Hotel $a.Hotel }
            DIM = { param($a) Write-DIM -Type $a.Type -Data $a.Data -BatchId $a.BatchId -Hotel $a.Hotel -RefreshMode $a.RefreshMode }
        }
    }

    # --- Initialize the schema for Full mode (idempotent DDL). ---------------
    if ($Mode -in @('Full') -and -not $DryRun) {
        Write-LoaderLog -Level INFO -Message 'Mode=Full: running Initialize-Database (idempotent DDL).'
        if ($DatabaseInitializer) { & $DatabaseInitializer $settings }
        else { Initialize-Database -Settings $settings }
    }
    elseif ($Mode -in @('Full') -and $DryRun) {
        Write-LoaderLog -Level INFO -Message '[DRYRUN] Skipping Initialize-Database.'
    }

    # --- Per-hotel loop. -----------------------------------------------------
    $results = @()
    foreach ($hotel in $selected) {
        $hotelHt = ConvertTo-HotelHashtable -Hotel $hotel
        $code = [string]$hotelHt['hotelCode']
        $chain = [string]$hotelHt['chainCode']

        try {
            # Validate credentials decrypt before doing anything else.
            $credCheck = if ($CredentialTester) { & $CredentialTester $hotel } else { Test-HotelCredentials -Hotel $hotel }
            if (-not $credCheck.Ok) {
                throw "Credential validation failed: $($credCheck.Reason)"
            }

            # Start a batch + acquire a token.
            $batchId = if (Get-Command Start-Batch -ErrorAction SilentlyContinue) {
                Start-Batch -HotelCode $code -Mode $Mode -QueryType 'Loader'
            }
            else { [guid]::NewGuid() }

            $token = if ($TokenProvider) { & $TokenProvider $hotelHt } else { Get-OAuthToken -Hotel $hotelHt }

            $res = Invoke-HotelLoad -Hotel $hotel -Mode $Mode -Queries $Queries -Writers $Writers `
                -DryRun:$DryRun -BatchId $batchId -BusinessDate $BusinessDate -StartDate $StartDate -EndDate $EndDate `
                -Config $settings -Token $token -BusinessDateResolver $BusinessDateResolver

            if (Get-Command Complete-Batch -ErrorAction SilentlyContinue) {
                Complete-Batch -BatchId $batchId -Status $res.Status -RowsFetched $res.Rows -HotelCode $code -ErrorAction SilentlyContinue
            }
            $results += $res
        }
        catch {
            $msg = $_.Exception.Message
            Write-LoaderLog -Level ERROR -HotelCode $code -Message ("Hotel '{0}' failed: {1}" -f $code, $msg)
            if (Get-Command Complete-Batch -ErrorAction SilentlyContinue) {
                try { Complete-Batch -BatchId ([guid]::Empty) -Status 'Error' -ErrorMessage $msg -HotelCode $code -ErrorAction SilentlyContinue } catch { }
            }
            $results += @{ HotelCode = $code; ChainCode = $chain; Status = 'Failed'; Rows = 0; Duration = [timespan]::Zero; Error = $msg; WroteAny = $false }

            if ($FailFast) {
                Write-LoaderLog -Level ERROR -HotelCode $code -Message 'FailFast is set — aborting the run.'
                break
            }
        }
    }

    # --- End-of-run per-hotel alert emails (best-effort). --------------------
    if (Get-Command Send-AlertEmail -ErrorAction SilentlyContinue) {
        $smtp = if ($settings.PSObject.Properties['smtp']) { $settings.smtp } else { $null }
        if ($null -ne $smtp) {
            foreach ($r in $results) {
                $hotelObj = @($selected | Where-Object { ([string]$_.hotelCode).ToUpperInvariant() -eq ([string]$r.HotelCode).ToUpperInvariant() })
                if ($hotelObj.Count -eq 0) { continue }
                $severity = if ([string]$r.Status -eq 'Failed') { 'ERROR' } else { 'INFO' }
                try {
                    Send-AlertEmail -Hotel $hotelObj[0] -Severity $severity `
                        -Subject ("OPERA R&A Loader — {0} {1}" -f $r.HotelCode, $r.Status) `
                        -Body (Write-SummaryTable -Results @($r)) -Smtp $smtp -IsDryRun:$DryRun -ErrorAction SilentlyContinue | Out-Null
                }
                catch {
                    Write-LoaderLog -Level WARN -HotelCode ([string]$r.HotelCode) -Message ("Alert email failed (non-fatal): {0}" -f $_.Exception.Message)
                }
            }
        }
    }

    $exitCode = Get-RunExitCode -Results @($results)
    $summary = Write-SummaryTable -Results @($results)
    return @{ Results = @($results); ExitCode = $exitCode; Summary = $summary }
}

# ==============================================================================
# Main — skipped when dot-sourced by the test harness (seam), mirroring
# Tools\Protect-HotelsConfig.ps1. Tests set $env:RUN_OPERA_NO_MAIN = '1'.
# ==============================================================================
if ($env:RUN_OPERA_NO_MAIN -eq '1') {
    return
}

$ErrorActionPreference = 'Stop'

try {
    # Resolve config directory (parameter override or repo Config\).
    $configDir = if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath } else { Join-Path $PSScriptRoot 'Config' }
    $configDir = [System.IO.Path]::GetFullPath($configDir)

    # Import all modules before initializing the logger.
    Import-OperaModules

    # Load config first so logging can be settings-driven.
    $bootstrapCfg = Resolve-Config -ConfigDir $configDir

    # Initialize the single shared log file from settings.json.
    if (Get-Command Initialize-Logger -ErrorAction SilentlyContinue) {
        Initialize-Logger -Settings $bootstrapCfg.Settings | Out-Null
    }

    Write-LoaderLog -Level INFO -Message (
        "Loader started. Mode={0} DryRun={1} FailFast={2} ConfigDir={3}" -f $Mode, [bool]$DryRun, [bool]$FailFast, $configDir)

    $run = Invoke-Loader -Mode $Mode -ConfigDir $configDir `
        -HotelCode $HotelCode -ChainCode $ChainCode `
        -BusinessDate $BusinessDate -StartDate $StartDate -EndDate $EndDate `
        -DryRun:$DryRun -FailFast:$FailFast `
        -ConfigResolver { param($d) $bootstrapCfg }

    Write-Host ''
    Write-Host 'Run Summary'
    Write-Host '==========='
    Write-Host $run.Summary

    Write-LoaderLog -Level INFO -Message ("Loader finished. ExitCode={0}" -f $run.ExitCode)
    exit $run.ExitCode
}
catch {
    Write-LoaderLog -Level ERROR -Message ("Fatal error: {0}" -f $_.Exception.Message)
    Write-Error ("Run-OperaRALoader failed: {0}" -f $_.Exception.Message)
    exit 2
}
