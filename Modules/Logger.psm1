# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Structured logging module for the OPERA R&A Data Loader.

.DESCRIPTION
    Provides shared, module-scoped logging state and functions. All callers in the
    process (orchestrator + every query module) write to a SINGLE shared log file for
    the whole run via $script:LogFilePath, which is established once at startup by
    Initialize-Logger. Sources are distinguished by the [HotelCode] / [BatchId] /
    [LEVEL] columns, not by separate files.

    Module-level state (shared across all callers in the process):
      $script:LogFilePath  — absolute path to the active log file
      $script:LogLevel     — minimum level to emit: DEBUG < INFO < WARN < ERROR
      $script:SqlLogging   — bool, mirror batch writes to dbo.LoadLog

    SINGLE-SHARED-FILE guarantee (REQ-012 / REQ-016):
    Each .psm1 loaded instance has its own script scope, so relying on $script:LogFilePath
    alone is fragile if a module is re-imported with -Force, via a differently-normalized
    path, or through New-Module. To guarantee ONE file for the whole run, Initialize-Logger
    (called once at startup by the orchestrator) publishes the resolved path/level/flag into
    PROCESS-scoped environment markers, and Write-Log resolves its target via
    Get-SharedLogFilePath (own $script:LogFilePath first, then the process marker). A second
    Initialize-Logger call in the same process is a guarded no-op that returns the already-
    resolved path unless -Force is passed.

    Log file naming pattern (single shared file for the whole run):
      <logDirectory>\<yyyyMMdd>_<logName>.log
      Example:  Logs\20260905_OperaRA_Loader.log
      where logDirectory + logName are read from settings.json (logging.logDirectory,
      logging.logName) and yyyyMMdd is the date of the run, evaluated once at process
      start.

    NOTE: Initialize-Logger and Write-Log (plus sensitive masking) are implemented in
    this file. Start-Batch, Complete-Batch, and Send-AlertEmail are implemented in
    separate sub-tasks.
#>

# ------------------------------------------------------------------------------
# Module-level state
# ------------------------------------------------------------------------------
$script:LogFilePath = $null
$script:LogLevel    = 'INFO'
$script:SqlLogging  = $false

# SQL Server connection string used to mirror batch lifecycle rows to dbo.LoadLog.
# Populated by Initialize-Logger from settings.json (sqlServer.connectionString) when
# SQL logging is enabled. May also be supplied directly to Start-Batch/Complete-Batch
# for standalone callers and unit tests. Null when SQL logging is not configured.
$script:SqlConnectionString = $null

# Date of the run, evaluated ONCE at module load / process start so that all log
# lines for a single run resolve to the same daily file even if the process runs
# across midnight.
$script:RunDateStamp = (Get-Date).ToString('yyyyMMdd')

# Valid log levels (ordered by severity).
$script:ValidLogLevels = @('DEBUG', 'INFO', 'WARN', 'ERROR')

# Process-wide mutex name used to serialize concurrent file appends. Multiple
# modules (orchestrator + query modules) write to the same shared log file within
# a single process; a named mutex plus retry keeps writes from interleaving or
# failing under IO contention. Kept local (no "Global\" prefix) so it is scoped to
# the current session, which is sufficient for a single-process run.
$script:LogMutexName = 'OperaRADataLoader.SharedLog'

# ------------------------------------------------------------------------------
# Process-wide shared-state markers (SINGLE-SHARED-FILE guarantee — REQ-012 / REQ-016)
# ------------------------------------------------------------------------------
# A .psm1 module gets its OWN script scope per loaded module instance. When the
# orchestrator imports Logger.psm1 and every query module ALSO imports Logger.psm1,
# PowerShell normally reuses the single already-loaded instance, so $script:LogFilePath
# is genuinely shared. However, that guarantee is fragile: a module re-imported with
# -Force, via a differently-cased/normalized path, or through New-Module gets a fresh
# script scope with a NULL $script:LogFilePath — which would silently produce a second
# file (or lose lines).
#
# To make the single-file guarantee robust regardless of how each caller imports the
# module, Initialize-Logger publishes the resolved path (and level / SQL-logging flag)
# into PROCESS-scoped environment variables. Every Write-Log resolves its effective log
# path from $script:LogFilePath first and falls back to these markers, so every module
# in the process converges on the exact same file for the whole run. The markers live in
# the PowerShell process only (Scope = 'Process') and are never persisted to the machine
# or user environment.
$script:EnvLogFilePath = 'OPERARA_LOG_FILEPATH'
$script:EnvLogLevel    = 'OPERARA_LOG_LEVEL'
$script:EnvSqlLogging  = 'OPERARA_LOG_SQLLOGGING'

function Set-SharedLogMarker {
    <#
    .SYNOPSIS
        Publishes the resolved shared-log state into process-scoped environment markers.
    .DESCRIPTION
        Internal helper (not exported). Writes the resolved log file path, level, and
        SQL-logging flag to process-scoped environment variables so that Logger.psm1
        instances living in a different module script scope still converge on the same
        single shared log file for the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Level,
        [Parameter(Mandatory)][bool]   $SqlLogging
    )
    [System.Environment]::SetEnvironmentVariable($script:EnvLogFilePath, $Path,  [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($script:EnvLogLevel,    $Level, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($script:EnvSqlLogging,  ([string]$SqlLogging), [System.EnvironmentVariableTarget]::Process)
}

function Get-SharedLogFilePath {
    <#
    .SYNOPSIS
        Resolves the effective shared-log file path for the current caller.
    .DESCRIPTION
        Internal helper (not exported). Returns this module instance's own
        $script:LogFilePath when set; otherwise falls back to the process-scoped
        marker published by whichever module instance ran Initialize-Logger. When the
        fallback is used, the local $script:LogLevel is hydrated from the marker so that
        level filtering stays consistent across module instances. Returns $null when the
        logger has not been initialized anywhere in the process.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrEmpty($script:LogFilePath)) {
        return $script:LogFilePath
    }

    $markerPath = [System.Environment]::GetEnvironmentVariable($script:EnvLogFilePath, [System.EnvironmentVariableTarget]::Process)
    if ([string]::IsNullOrEmpty($markerPath)) {
        return $null
    }

    # This module instance was imported into a separate script scope after another
    # instance initialized logging. Adopt the shared path and mirror its level so this
    # instance behaves identically without re-running Initialize-Logger.
    $script:LogFilePath = $markerPath
    $markerLevel = [System.Environment]::GetEnvironmentVariable($script:EnvLogLevel, [System.EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($markerLevel) -and ($script:ValidLogLevels -contains $markerLevel)) {
        $script:LogLevel = $markerLevel
    }
    $markerSql = [System.Environment]::GetEnvironmentVariable($script:EnvSqlLogging, [System.EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($markerSql)) {
        $parsedSql = $false
        if ([bool]::TryParse($markerSql, [ref]$parsedSql)) {
            $script:SqlLogging = $parsedSql
        }
    }

    return $script:LogFilePath
}

function Initialize-Logger {
    <#
    .SYNOPSIS
        Initializes shared logging state and resolves the active log file path.

    .DESCRIPTION
        Sets $script:LogFilePath using the pattern:
            <LogDirectory>\<yyyyMMdd>_<LogName>.log
        where yyyyMMdd is the date of the run captured once at process start.

        Creates LogDirectory if it does not exist. Opens (touches) the log file in
        append mode so that re-runs on the same day accumulate in the same file and
        an existing file is never truncated.

        Also sets $script:LogLevel and $script:SqlLogging module state.

    .PARAMETER LogDirectory
        Directory where log files are written. Created if missing. Relative paths are
        resolved against the current working directory.

    .PARAMETER LogLevel
        Minimum level to emit: DEBUG, INFO, WARN, or ERROR. Defaults to INFO.

    .PARAMETER SqlLogging
        When $true, batch lifecycle rows are mirrored to dbo.LoadLog. Defaults to $false.

    .PARAMETER LogName
        Base name for the single shared log file used by the entire run. The whole
        application (orchestrator + all query modules) writes to one file per run day;
        sources are distinguished by the [HotelCode] / [BatchId] / [LEVEL] columns,
        not by separate files. Defaults to OperaRA_Loader.

    .OUTPUTS
        [string] The resolved absolute log file path.

    .PARAMETER SettingsPath
        Path to a settings.json file. When supplied (the 'FromSettings' parameter set),
        the log directory, log name, log level, and SQL-logging flag are read from the
        file's `logging` section (`logging.logDirectory`, `logging.logName`,
        `logging.logLevel`, `logging.sqlLogging`) instead of being passed explicitly.
        This is the settings.json-driven entry point the orchestrator uses at startup.

    .PARAMETER Settings
        An already-parsed settings object (e.g. the result of
        `Get-Content settings.json | ConvertFrom-Json`) whose `logging` section supplies
        the same fields as -SettingsPath. Use this to avoid re-reading the file when the
        orchestrator has already loaded settings.

    .EXAMPLE
        Initialize-Logger -LogDirectory 'Logs' -LogLevel 'INFO' -SqlLogging $true -LogName 'OperaRA_Loader'

    .EXAMPLE
        # settings.json-driven: reads logging.logDirectory and logging.logName from the file
        Initialize-Logger -SettingsPath 'Config\settings.json'

    .EXAMPLE
        $settings = Get-Content 'Config\settings.json' -Raw | ConvertFrom-Json
        Initialize-Logger -Settings $settings
    #>
    [CmdletBinding(DefaultParameterSetName = 'Explicit')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Explicit')]
        [ValidateNotNullOrEmpty()]
        [string] $LogDirectory,

        [Parameter(ParameterSetName = 'Explicit')]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $LogLevel = 'INFO',

        [Parameter(ParameterSetName = 'Explicit')]
        [bool] $SqlLogging = $false,

        [Parameter(ParameterSetName = 'Explicit')]
        [ValidateNotNullOrEmpty()]
        [string] $LogName = 'OperaRA_Loader',

        # Optional SQL Server connection string used to mirror batch rows to
        # dbo.LoadLog when SqlLogging is enabled. When omitted and the settings-driven
        # parameter sets are used, it is resolved from sqlServer.connectionString.
        [Parameter(ParameterSetName = 'Explicit')]
        [Parameter(ParameterSetName = 'FromSettingsPath')]
        [Parameter(ParameterSetName = 'FromSettings')]
        [string] $SqlConnectionString,

        [Parameter(Mandatory, ParameterSetName = 'FromSettingsPath')]
        [ValidateNotNullOrEmpty()]
        [string] $SettingsPath,

        [Parameter(Mandatory, ParameterSetName = 'FromSettings')]
        [ValidateNotNull()]
        [psobject] $Settings,

        # Re-initialize even if the logger was already initialized in this process.
        # By default a second Initialize-Logger call in the same process is a no-op that
        # returns the already-resolved shared path, so the whole run keeps exactly ONE
        # log file (REQ-012). Use -Force only for tests or an intentional re-target.
        [Parameter(ParameterSetName = 'Explicit')]
        [Parameter(ParameterSetName = 'FromSettingsPath')]
        [Parameter(ParameterSetName = 'FromSettings')]
        [switch] $Force
    )

    try {
        # --------------------------------------------------------------------------
        # Idempotency guard (SINGLE-SHARED-FILE guarantee — REQ-012 / REQ-016).
        #
        # Initialize-Logger is meant to be called exactly ONCE at startup by the
        # orchestrator. If it is called again in the same process (e.g. a module also
        # calls it defensively), we must NOT create or point at a different file.
        # Detect a prior initialization via either this module instance's
        # $script:LogFilePath or the process-scoped marker, and short-circuit to the
        # already-resolved path unless the caller explicitly passes -Force.
        # --------------------------------------------------------------------------
        if (-not $Force) {
            $existingPath = if (-not [string]::IsNullOrEmpty($script:LogFilePath)) {
                $script:LogFilePath
            }
            else {
                [System.Environment]::GetEnvironmentVariable($script:EnvLogFilePath, [System.EnvironmentVariableTarget]::Process)
            }

            if (-not [string]::IsNullOrEmpty($existingPath)) {
                Write-Verbose "Initialize-Logger: logger already initialized for this process; reusing shared log file '$existingPath'. Use -Force to re-target."
                # Ensure this module instance's local state and the process markers are
                # consistent with the already-resolved path before returning.
                $script:LogFilePath = $existingPath
                $markerLevel = [System.Environment]::GetEnvironmentVariable($script:EnvLogLevel, [System.EnvironmentVariableTarget]::Process)
                if (-not [string]::IsNullOrWhiteSpace($markerLevel) -and ($script:ValidLogLevels -contains $markerLevel)) {
                    $script:LogLevel = $markerLevel
                }
                Set-SharedLogMarker -Path $script:LogFilePath -Level $script:LogLevel -SqlLogging $script:SqlLogging
                return $script:LogFilePath
            }
        }

        # --------------------------------------------------------------------------
        # Settings.json-driven resolution.
        #
        # The task contract states the log directory and single log name are read from
        # settings.json `logging.logDirectory` and `logging.logName`. When invoked via
        # the 'FromSettingsPath' or 'FromSettings' parameter sets we hydrate the local
        # parameters from that `logging` section before resolving the path, so both the
        # orchestrator (which loads settings once) and standalone callers get identical
        # behavior. Explicit parameters remain supported for unit tests and callers that
        # already have the individual values.
        # --------------------------------------------------------------------------
        if ($PSCmdlet.ParameterSetName -in @('FromSettingsPath', 'FromSettings')) {
            if ($PSCmdlet.ParameterSetName -eq 'FromSettingsPath') {
                Write-Verbose "Initialize-Logger: loading logging settings from '$SettingsPath'."
                if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
                    throw "Settings file not found: '$SettingsPath'."
                }
                $Settings = Get-Content -LiteralPath $SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            }

            $logging = $Settings.logging
            if ($null -eq $logging) {
                throw "Settings object does not contain a 'logging' section."
            }

            if ([string]::IsNullOrWhiteSpace([string]$logging.logDirectory)) {
                throw "Settings 'logging.logDirectory' is missing or empty."
            }
            if ([string]::IsNullOrWhiteSpace([string]$logging.logName)) {
                throw "Settings 'logging.logName' is missing or empty."
            }

            $LogDirectory = [string]$logging.logDirectory
            $LogName      = [string]$logging.logName

            # logLevel / sqlLogging are optional in the logging section; fall back to
            # the documented defaults when absent.
            if (-not [string]::IsNullOrWhiteSpace([string]$logging.logLevel)) {
                $candidateLevel = [string]$logging.logLevel
                if ($script:ValidLogLevels -notcontains $candidateLevel) {
                    throw "Settings 'logging.logLevel' value '$candidateLevel' is invalid. Expected one of: $($script:ValidLogLevels -join ', ')."
                }
                $LogLevel = $candidateLevel
            }
            if ($null -ne $logging.sqlLogging) {
                $SqlLogging = [bool]$logging.sqlLogging
            }

            # When SQL logging is enabled we need a connection string to mirror batch
            # rows to dbo.LoadLog. Prefer an explicitly supplied -SqlConnectionString,
            # otherwise read it from the settings `sqlServer.connectionString` block so
            # Start-Batch / Complete-Batch can write without re-reading settings.
            if ($SqlLogging) {
                if ([string]::IsNullOrWhiteSpace($SqlConnectionString)) {
                    $sqlServer = $Settings.sqlServer
                    if ($null -ne $sqlServer -and -not [string]::IsNullOrWhiteSpace([string]$sqlServer.connectionString)) {
                        $SqlConnectionString = [string]$sqlServer.connectionString
                    }
                }
                if ([string]::IsNullOrWhiteSpace($SqlConnectionString)) {
                    Write-Verbose "Initialize-Logger: SqlLogging is enabled but no connection string was found in settings 'sqlServer.connectionString'. Batch rows will not be mirrored to dbo.LoadLog."
                }
            }
        }

        Write-Verbose "Initialize-Logger: starting. LogDirectory='$LogDirectory' LogLevel='$LogLevel' SqlLogging=$SqlLogging LogName='$LogName'"

        # Resolve LogDirectory to an absolute path without requiring it to exist yet.
        $absoluteLogDirectory = if ([System.IO.Path]::IsPathRooted($LogDirectory)) {
            $LogDirectory
        }
        else {
            [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Location).ProviderPath -ChildPath $LogDirectory))
        }

        # Create the log directory if it does not exist.
        if (-not (Test-Path -LiteralPath $absoluteLogDirectory -PathType Container)) {
            Write-Verbose "Initialize-Logger: log directory does not exist. Creating '$absoluteLogDirectory'."
            $null = New-Item -Path $absoluteLogDirectory -ItemType Directory -Force -ErrorAction Stop
        }
        else {
            Write-Verbose "Initialize-Logger: log directory already exists: '$absoluteLogDirectory'."
        }

        # Build the daily shared log file name using the run-start date stamp.
        $fileName = "{0}_{1}.log" -f $script:RunDateStamp, $LogName
        $resolvedPath = Join-Path -Path $absoluteLogDirectory -ChildPath $fileName

        # Open in append mode so re-runs on the same day accumulate. This creates the
        # file if it is missing and never truncates an existing file.
        $fileStream = $null
        try {
            $fileStream = [System.IO.File]::Open(
                $resolvedPath,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
        }
        finally {
            if ($null -ne $fileStream) {
                $fileStream.Dispose()
            }
        }

        # Commit module-level state only after the file is confirmed writable.
        $script:LogFilePath         = $resolvedPath
        $script:LogLevel            = $LogLevel
        $script:SqlLogging          = $SqlLogging
        $script:SqlConnectionString = if ([string]::IsNullOrWhiteSpace($SqlConnectionString)) { $null } else { $SqlConnectionString }

        # Publish the resolved path/level/flag into process-scoped markers so every
        # OTHER module instance that imports Logger.psm1 converges on this exact same
        # single shared file for the whole run (see Get-SharedLogFilePath).
        Set-SharedLogMarker -Path $script:LogFilePath -Level $script:LogLevel -SqlLogging $script:SqlLogging

        Write-Verbose "Initialize-Logger: initialized. LogFilePath='$($script:LogFilePath)'"

        return $script:LogFilePath
    }
    catch {
        $message = "Initialize-Logger failed to initialize logging in directory '$LogDirectory': $($_.Exception.Message)"
        Write-Error -Message $message -Exception $_.Exception
        throw
    }
}

function Test-CallerPreferenceActive {
    <#
    .SYNOPSIS
        Determines whether the CALLER's -Verbose / -Debug common switch is active, as seen
        from inside a module function (REQ-012).

    .DESCRIPTION
        Internal helper (not exported). PowerShell does NOT flow the caller's
        $VerbosePreference / $DebugPreference into a called [CmdletBinding()] module
        function's scope unless the corresponding switch is re-passed. Because Logger.psm1
        functions live in a SEPARATE module session state, walking numeric scopes with
        Get-Variable cannot reach the caller's preference either.

        The reliable, documented mechanism is $PSCmdlet.GetVariableValue(name), which reads
        the variable from the CALLER's scope across the module boundary. So when the
        orchestrator is launched with -Debug/-Verbose and then calls
        `Write-Log -Level DEBUG ...` (WITHOUT re-passing the switch), this helper still
        observes the orchestrator's non-'SilentlyContinue' preference and reports it active.

        Best-effort: any lookup failure (e.g. $PSCmdlet unavailable) yields $false rather
        than throwing, so logging never breaks.

    .PARAMETER VariableName
        The preference variable to read from the caller: 'DebugPreference' or
        'VerbosePreference'.

    .PARAMETER Cmdlet
        Write-Log's own $PSCmdlet, whose GetVariableValue resolves against Write-Log's
        caller scope.

    .OUTPUTS
        [bool] $true when the caller's preference is effectively active.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DebugPreference', 'VerbosePreference')]
        [string] $VariableName,

        [Parameter()]
        $Cmdlet
    )

    if ($null -eq $Cmdlet) {
        return $false
    }

    $silent = [System.Management.Automation.ActionPreference]::SilentlyContinue
    try {
        $callerValue = $Cmdlet.GetVariableValue($VariableName)
        if ($null -eq $callerValue) {
            return $false
        }
        return ([System.Management.Automation.ActionPreference]$callerValue) -ne $silent
    }
    catch {
        # Never let preference resolution break logging.
        return $false
    }
}

# ------------------------------------------------------------------------------
# Function stubs — implemented in later sub-tasks (Task 2). Declared here so the
# module and its Export-ModuleMember surface remain stable across sub-tasks.
# ------------------------------------------------------------------------------
function Write-Log {
    <#
    .SYNOPSIS
        Writes a formatted, severity-filtered, sensitive-masked log line.

    .DESCRIPTION
        Emits a single log line in the format:

            YYYY-MM-DD HH:mm:ss.fff [LEVEL] [HotelCode] [BatchId] Message

        Behavior:
          - Level filtering: only lines at or above $script:LogLevel are written,
            using the ordering DEBUG < INFO < WARN < ERROR.
          - PowerShell -Verbose / -Debug switches (REQ-012): the orchestrator and this
            function use [CmdletBinding()], so the -Verbose / -Debug common parameters
            flow into $VerbosePreference / $DebugPreference and are honored at runtime:
              * -Debug   effectively lowers the emit threshold to DEBUG so DEBUG entries
                         are written to the shared file log AND mirrored to the debug
                         stream, regardless of the configured minimum $script:LogLevel.
                         It never raises an already-lower threshold.
              * -Verbose mirrors INFO detail to the PowerShell verbose stream.
          - Sensitive masking (REQ-002): bearer tokens, client secrets, API keys,
            access tokens, x-app-key, and generic password/secret/apikey values are
            replaced with **** before the line is written or echoed.
          - Console streams honor $VerbosePreference / $DebugPreference:
              DEBUG -> Write-Debug   (only when -Debug is active)
              INFO  -> Write-Verbose (only when -Verbose or -Debug is active)
              WARN  -> Write-Warning
              ERROR -> Write-Error (non-terminating)
            Console emission never throws or halts execution.
          - The line is appended to $script:LogFilePath as UTF-8 with a
            FileShare.ReadWrite lock so concurrent callers can append.
          - If Initialize-Logger has not been called ($script:LogFilePath is null),
            the function degrades gracefully to console/verbose output and does not throw.
          - A file-write failure never aborts the caller; it is surfaced via
            Write-Warning and execution continues.

        NOTE: The task title format is authoritative and takes precedence over the
        pipe-delimited example shown in design.md.

    .PARAMETER Level
        Severity: DEBUG, INFO, WARN, or ERROR.

    .PARAMETER Message
        The message text. Sensitive values are masked before output.

    .PARAMETER HotelCode
        Hotel code for context. Empty for global/startup messages. Rendered as an
        empty bracket placeholder [] when not supplied.

    .PARAMETER BatchId
        Batch context GUID. [guid]::Empty when not in a batch; rendered as an empty
        bracket placeholder [] in that case.

    .PARAMETER Module
        Optional caller/source identifier (e.g. 'Orchestrator', 'ReservationStats').
        Accepted for forward compatibility with the shared-file design so the same
        call sites work regardless of format; the authoritative line format for this
        sub-task does not render a Module column, so when supplied it is prefixed to
        the message text as "<Module>: <message>".

    .EXAMPLE
        Write-Log -Level INFO -Message 'Loader started' 
    .EXAMPLE
        Write-Log -Level ERROR -HotelCode 'HOTEL1' -BatchId $batchId -Message 'HTTP 503 after retries'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $Level,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [string] $Message,

        [Parameter()]
        [string] $HotelCode = '',

        [Parameter()]
        [guid] $BatchId = [guid]::Empty,

        [Parameter()]
        [string] $Module = ''
    )

    # --- Resolve active PowerShell -Verbose / -Debug switches (REQ-012) -------
    # Advanced functions/scripts using [CmdletBinding()] (the orchestrator entry
    # point and this function) automatically accept the -Verbose / -Debug common
    # parameters, which flow into $VerbosePreference / $DebugPreference. We honor
    # them here so operators can raise log detail at runtime without editing
    # settings.json:
    #   -Debug   -> emit DEBUG entries regardless of the configured $script:LogLevel,
    #               and mirror DEBUG detail to the PowerShell debug stream.
    #   -Verbose -> mirror INFO/verbose detail to the PowerShell verbose stream.
    #
    # IMPORTANT: PowerShell does NOT automatically propagate $VerbosePreference /
    # $DebugPreference into a called [CmdletBinding()] function. When the orchestrator
    # is invoked with -Debug/-Verbose and then simply calls `Write-Log -Level DEBUG ...`
    # (WITHOUT re-passing the switch), Write-Log's own $DebugPreference is reset to
    # 'SilentlyContinue' in its local scope. To honor the caller's intent we resolve the
    # EFFECTIVE preference from three sources, in order:
    #   1. This function's own bound switch (-Verbose/-Debug passed directly to Write-Log).
    #   2. The caller's preference variable (walked up the scope chain), which reflects
    #      the orchestrator's -Verbose/-Debug.
    #   3. The local default ('SilentlyContinue').
    $silentPref    = [System.Management.Automation.ActionPreference]::SilentlyContinue
    # Local (Write-Log's own) view: -Debug/-Verbose passed directly to Write-Log, or a
    # script/global preference already set the value in this module scope.
    $debugLocal    = $PSBoundParameters.ContainsKey('Debug')   -or ($DebugPreference   -ne $silentPref)
    $verboseLocal  = $PSBoundParameters.ContainsKey('Verbose') -or ($VerbosePreference -ne $silentPref)
    # Caller's view: $PSCmdlet.GetVariableValue reads the CALLER's scope across the module
    # boundary, so the orchestrator's -Debug/-Verbose (which sets $DebugPreference /
    # $VerbosePreference in ITS scope) is honored even though PowerShell does not propagate
    # those preferences into this module function automatically (REQ-012).
    $debugActive   = $debugLocal   -or (Test-CallerPreferenceActive -VariableName 'DebugPreference'   -Cmdlet $PSCmdlet)
    $verboseActive = $verboseLocal -or (Test-CallerPreferenceActive -VariableName 'VerbosePreference' -Cmdlet $PSCmdlet)

    # --- Level filtering ------------------------------------------------------
    # $script:ValidLogLevels is ordered by severity: DEBUG(0) < INFO(1) < WARN(2) < ERROR(3).
    $currentThreshold = [array]::IndexOf($script:ValidLogLevels, $script:LogLevel)
    if ($currentThreshold -lt 0) {
        # Defensive: if module state is somehow invalid, treat threshold as INFO.
        $currentThreshold = [array]::IndexOf($script:ValidLogLevels, 'INFO')
    }

    # When -Debug is active, effectively lower the threshold to DEBUG at runtime so
    # DEBUG entries are emitted (to both the file log and the console) regardless of
    # the configured minimum $script:LogLevel. This never RAISES the threshold, so an
    # already-permissive configured level is preserved.
    if ($debugActive) {
        $debugThreshold = [array]::IndexOf($script:ValidLogLevels, 'DEBUG')
        if ($debugThreshold -ge 0 -and $debugThreshold -lt $currentThreshold) {
            $currentThreshold = $debugThreshold
        }
    }

    $lineSeverity = [array]::IndexOf($script:ValidLogLevels, $Level)
    if ($lineSeverity -lt $currentThreshold) {
        return
    }

    # --- Compose message (optional Module prefix) -----------------------------
    # The authoritative format for this sub-task has no dedicated Module column, so
    # when a caller supplies -Module we fold it into the message text to preserve
    # source attribution without breaking the bracketed column layout.
    $composedMessage = if ([string]::IsNullOrWhiteSpace($Module)) {
        $Message
    }
    else {
        "$($Module): $Message"
    }

    # --- Sensitive masking (REQ-002) -----------------------------------------
    $maskedMessage = Get-MaskedLogText -Text $composedMessage

    # --- Format the line ------------------------------------------------------
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')

    # Empty HotelCode / empty BatchId render as empty brackets [] so columns stay parseable.
    $hotelToken = if ([string]::IsNullOrWhiteSpace($HotelCode)) { '' } else { $HotelCode }
    $batchToken = if ($BatchId -eq [guid]::Empty) { '' } else { $BatchId.ToString() }

    $logLine = "{0} [{1}] [{2}] [{3}] {4}" -f $timestamp, $Level, $hotelToken, $batchToken, $maskedMessage

    # --- Console stream emission (never throws) -------------------------------
    # WARN / ERROR always surface on their dedicated streams. DEBUG and INFO are
    # mirrored to the PowerShell debug / verbose streams, gated on the effective
    # -Debug / -Verbose state resolved above.
    #
    # Because PowerShell does not propagate the caller's preference into this module
    # function, Write-Log's LOCAL $DebugPreference / $VerbosePreference are still
    # 'SilentlyContinue' even when the orchestrator was launched with -Debug/-Verbose —
    # which would cause Write-Debug / Write-Verbose to silently drop the record. We
    # therefore pass -Debug / -Verbose explicitly on those calls so the record is
    # actually emitted to the corresponding stream when the switch is effectively active.
    try {
        switch ($Level) {
            'DEBUG' {
                if ($debugActive) {
                    Write-Debug   -Message $logLine -Debug
                }
            }
            'INFO'  {
                if ($verboseActive -or $debugActive) {
                    Write-Verbose -Message $logLine -Verbose
                }
            }
            'WARN'  { Write-Warning -Message $logLine }
            'ERROR' { Write-Error   -Message $logLine -ErrorAction Continue }
        }
    }
    catch {
        # Console emission must never abort the caller.
    }

    # --- File write (append, UTF-8, share-tolerant, never aborts caller) ------
    # Resolve the effective shared log path. This returns this module instance's own
    # $script:LogFilePath when set, otherwise the process-scoped marker published by
    # whichever module instance ran Initialize-Logger — guaranteeing every module in
    # the run writes to the SAME single file (REQ-012 / REQ-016).
    $effectiveLogPath = Get-SharedLogFilePath
    if ([string]::IsNullOrEmpty($effectiveLogPath)) {
        # Logger not initialized anywhere in the process — degrade gracefully.
        Write-Verbose "Write-Log: LogFilePath not set (Initialize-Logger not called). Line: $logLine"
        return
    }

    # Concurrency strategy: multiple modules in this process append to the same
    # shared file. A named mutex serializes writes; a bounded retry loop tolerates
    # transient IO contention (e.g. antivirus/indexer locks). Both the mutex and the
    # retries are best-effort — any failure degrades to a warning and never aborts
    # the caller.
    $maxAttempts = 3
    $mutex       = $null
    $haveHandle  = $false

    try {
        try {
            $mutex = [System.Threading.Mutex]::new($false, $script:LogMutexName)
        }
        catch {
            # If the mutex cannot be created, fall through to unsynchronized writes;
            # FileShare.ReadWrite + retries still provide a reasonable safety net.
            $mutex = $null
        }

        if ($null -ne $mutex) {
            try {
                # Wait briefly for the mutex; proceed anyway on timeout/abandon so a
                # stuck holder can never block logging indefinitely.
                $haveHandle = $mutex.WaitOne(2000)
            }
            catch [System.Threading.AbandonedMutexException] {
                # A previous holder exited without releasing; we now own it.
                $haveHandle = $true
            }
            catch {
                $haveHandle = $false
            }
        }

        $written = $false
        for ($attempt = 1; $attempt -le $maxAttempts -and -not $written; $attempt++) {
            $fileStream = $null
            $writer     = $null
            try {
                $fileStream = [System.IO.File]::Open(
                    $effectiveLogPath,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite
                )
                # UTF-8 without BOM (append mode: BOM would only be relevant on new
                # files, and a no-BOM encoder keeps appended content clean).
                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                $writer = [System.IO.StreamWriter]::new($fileStream, $utf8NoBom)
                $writer.WriteLine($logLine)
                $writer.Flush()
                $written = $true
            }
            catch [System.IO.IOException] {
                # Transient contention — back off briefly and retry.
                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Milliseconds (50 * $attempt)
                }
                else {
                    Write-Warning "Write-Log: failed to write to '$effectiveLogPath' after $maxAttempts attempts: $($_.Exception.Message)"
                }
            }
            catch {
                # Non-transient failure — a logging failure must never abort the caller.
                Write-Warning "Write-Log: failed to write to '$effectiveLogPath': $($_.Exception.Message)"
                break
            }
            finally {
                if ($null -ne $writer) { $writer.Dispose() }
                elseif ($null -ne $fileStream) { $fileStream.Dispose() }
            }
        }
    }
    catch {
        # Absolute backstop — logging never throws into the caller.
        Write-Warning "Write-Log: unexpected logging failure: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $mutex) {
            if ($haveHandle) {
                try { $mutex.ReleaseMutex() } catch { }
            }
            $mutex.Dispose()
        }
    }
}

function Get-MaskedLogText {
    <#
    .SYNOPSIS
        Masks sensitive values (tokens, secrets, API keys) with **** for log output.

    .DESCRIPTION
        Internal helper (not exported). Applies a series of case-insensitive regex
        replacements covering the sensitive patterns required by REQ-002 / REQ-012
        (secrets never emitted to logs) and REQ-016 (masking applied to emailed content).
        Only the sensitive VALUE portion is replaced with **** so the surrounding
        structure of the message (keys, punctuation) stays intact and parseable.

        Patterns masked:
          - Authorization: Bearer <token>            -> Authorization: Bearer ****
          - bare  Bearer <token>                     -> Bearer ****
          - OAuth access_token / refresh_token values (JSON or query string)
          - client_secret / clientSecret values      (JSON or form)
          - client_id / clientId values              (secret-adjacent; design.md says
            ClientId/ClientSecret are never written to any log)
          - API key headers: x-app-key, apiKey / ApiKey / api_key
          - password / pwd values (JSON, form, or SQL/SMTP connection strings)
          - username / user id / uid values (SMTP or connection strings)
          - generic secret / token / password / apikey assignments
          - standalone long JWT strings (three base64url segments) that appear
            without a preceding keyword, as a defense-in-depth fallback
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    # Character class that delimits the END of a masked value. A value runs until the
    # next whitespace, quote, comma, semicolon, ampersand, or closing brace/bracket so
    # that JSON, query strings, form bodies, and connection strings all terminate cleanly
    # while the surrounding structure is preserved.
    $valueTail = '[^\s"'',;&}\]]+'
    $result    = $Text

    # 1) Authorization header with Bearer scheme:  Authorization: Bearer <token>
    $result = [regex]::Replace($result, "(Authorization\s*[:=]\s*Bearer\s+)$valueTail", '${1}****', $opts)

    # 2) Bare Bearer token:  Bearer <token>
    $result = [regex]::Replace($result, "(\bBearer\s+)$valueTail", '${1}****', $opts)

    # 3) OAuth token JSON/query values: access_token / refresh_token
    #    "access_token": "<value>"  |  access_token=<value>  |  refresh_token=<value>
    $result = [regex]::Replace(
        $result,
        "([""']?(?:access_token|refresh_token)[""']?\s*[:=]\s*[""']?)$valueTail",
        '${1}****',
        $opts
    )

    # 4) API key headers/fields:  x-app-key, apiKey, api_key, ApiKey
    $result = [regex]::Replace(
        $result,
        "([""']?(?:x-app-key|apikey|api_key)[""']?\s*[:=]\s*[""']?)$valueTail",
        '${1}****',
        $opts
    )

    # 5) OAuth client credentials (secret AND id — design.md: ClientId/ClientSecret
    #    are never written to any log):  client_secret / clientSecret / client_id / clientId
    $result = [regex]::Replace(
        $result,
        "([""']?(?:client_secret|clientSecret|client_id|clientId)[""']?\s*[:=]\s*[""']?)$valueTail",
        '${1}****',
        $opts
    )

    # 6) Generic secret / password / token assignments (JSON, form, query string):
    #    password= pwd= secret= token= apikey=
    $result = [regex]::Replace(
        $result,
        "([""']?(?:password|pwd|secret|token|apikey)[""']?\s*[:=]\s*[""']?)$valueTail",
        '${1}****',
        $opts
    )

    # 7) SMTP / connection-string identity values:  username= | user= | user id= | uid=
    #    Masked because SMTP and SQL connection strings carry credentials (REQ-016).
    $result = [regex]::Replace(
        $result,
        "([""']?(?:username|user\s?id|uid|user)[""']?\s*[:=]\s*[""']?)$valueTail",
        '${1}****',
        $opts
    )

    # 8) Defense-in-depth fallback: a standalone JWT (three base64url segments joined
    #    by dots) that slipped through without a preceding keyword. Replaced whole so a
    #    raw token pasted into a message is never leaked.
    $result = [regex]::Replace(
        $result,
        '\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b',
        '****',
        $opts
    )

    return $result
}

function Start-Batch {
    <#
    .SYNOPSIS
        Starts a load batch, returning a new BatchId and (optionally) recording a
        'Running' row in dbo.LoadLog.

    .DESCRIPTION
        Generates a fresh batch correlation id via [guid]::NewGuid() and returns it to
        the caller. The returned BatchId is used across the run to correlate log lines
        (Write-Log -BatchId) and, later, the matching Complete-Batch update.

        When SQL logging is enabled ($script:SqlLogging) and a connection string is
        available, an initial row is inserted into dbo.LoadLog with Status='Running'
        and StartedAt=now. Row-count columns (RowsFetched / RowsInserted / RowsUpdated)
        are left NULL and are populated later by Complete-Batch.

        The database write is best-effort and never aborts the run: any failure is
        logged as a WARN via Write-Log and the valid BatchId is still returned. This
        matches the REQ-015 fallback behavior — a SQL logging failure must not stop
        data processing.

        The INSERT is fully parameterized (Microsoft.Data.SqlClient) — no run-time
        values are concatenated into the SQL text — to prevent SQL injection.

    .PARAMETER HotelCode
        The hotel/property code this batch is processing (dbo.LoadLog.HotelCode).

    .PARAMETER Mode
        The run mode (Full|Delta|OTB|MasterData|All) — dbo.LoadLog.Mode.

    .PARAMETER QueryType
        The query/subject area being loaded (e.g. ReservationStats, FinancialTx) —
        dbo.LoadLog.QueryType.

    .PARAMETER ChainCode
        Optional chain code for the hotel (dbo.LoadLog.ChainCode). Defaults to empty
        string when the hotel is not part of a chain.

    .PARAMETER BusinessDateFrom
        Optional lower bound of the business-date range being loaded
        (dbo.LoadLog.BusinessDateFrom). Omit for snapshot/master-data runs.

    .PARAMETER BusinessDateTo
        Optional upper bound of the business-date range being loaded
        (dbo.LoadLog.BusinessDateTo).

    .PARAMETER ConnectionString
        Optional SQL Server connection string override. When omitted, the module-level
        $script:SqlConnectionString captured by Initialize-Logger is used.

    .OUTPUTS
        [guid] The new BatchId. Always returned, even if the dbo.LoadLog insert fails.

    .EXAMPLE
        $batchId = Start-Batch -HotelCode 'HOTEL1' -Mode 'Delta' -QueryType 'ReservationStats'

    .EXAMPLE
        $batchId = Start-Batch -HotelCode 'HOTEL1' -ChainCode 'CHAINA' -Mode 'Full' `
                               -QueryType 'FinancialTx' `
                               -BusinessDateFrom '2026-07-01' -BusinessDateTo '2026-07-07'
    #>
    [CmdletBinding()]
    [OutputType([guid])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $HotelCode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Mode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $QueryType,

        [Parameter()]
        [string] $ChainCode = '',

        [Parameter()]
        [Nullable[datetime]] $BusinessDateFrom,

        [Parameter()]
        [Nullable[datetime]] $BusinessDateTo,

        [Parameter()]
        [string] $ConnectionString
    )

    # A BatchId is always generated first so the caller receives a valid correlation
    # id regardless of whether the optional SQL mirror succeeds.
    $batchId = [guid]::NewGuid()
    $startedAt = Get-Date

    Write-Log -Level 'INFO' -Module 'Logger' -HotelCode $HotelCode -BatchId $batchId `
        -Message ("Batch started. Mode={0} QueryType={1} ChainCode={2}" -f $Mode, $QueryType, $(if ([string]::IsNullOrWhiteSpace($ChainCode)) { '<none>' } else { $ChainCode }))

    # SQL mirroring is optional. Skip quietly when disabled.
    if (-not $script:SqlLogging) {
        Write-Log -Level 'DEBUG' -Module 'Logger' -HotelCode $HotelCode -BatchId $batchId `
            -Message 'SqlLogging disabled; skipping dbo.LoadLog Running row.'
        return $batchId
    }

    # Resolve the connection string: explicit override wins, otherwise fall back to
    # the module-level value captured by Initialize-Logger.
    $effectiveConnectionString = if (-not [string]::IsNullOrWhiteSpace($ConnectionString)) {
        $ConnectionString
    }
    else {
        $script:SqlConnectionString
    }

    if ([string]::IsNullOrWhiteSpace($effectiveConnectionString)) {
        # SqlLogging requested but no connection string is available. Per REQ-015 this
        # is a non-fatal logging condition — warn and continue with a valid BatchId.
        Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $HotelCode -BatchId $batchId `
            -Message 'SqlLogging enabled but no SQL connection string is configured; dbo.LoadLog Running row was not written.'
        return $batchId
    }

    # Determine the audit "LoadedBy" value (domain\user or user@host). Best-effort:
    # never let identity resolution break batch creation.
    $loadedBy = try {
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
            "$($env:USERDOMAIN)\$($env:USERNAME)".TrimStart('\')
        }
        else {
            'OperaRADataLoader'
        }
    }

    $connection = $null
    $command    = $null
    try {
        # Microsoft.Data.SqlClient is the driver used across the SqlWriter design.
        # Add-Type is a no-op if the assembly is already loaded in the session.
        Add-Type -AssemblyName 'Microsoft.Data.SqlClient' -ErrorAction Stop

        # Parameterized INSERT — values are bound as SqlParameters, never interpolated,
        # to prevent SQL injection. Row-count columns are intentionally omitted so they
        # remain NULL until Complete-Batch populates them.
        $insertSql = @'
INSERT INTO dbo.LoadLog
    (BatchId, HotelCode, ChainCode, [Mode], QueryType,
     BusinessDateFrom, BusinessDateTo, StartedAt, Status, LoadedBy)
VALUES
    (@BatchId, @HotelCode, @ChainCode, @Mode, @QueryType,
     @BusinessDateFrom, @BusinessDateTo, @StartedAt, @Status, @LoadedBy);
'@

        $connection = [Microsoft.Data.SqlClient.SqlConnection]::new($effectiveConnectionString)
        $connection.Open()

        $command = $connection.CreateCommand()
        $command.CommandText = $insertSql

        # --- Bind parameters with explicit SQL types (defensive, injection-safe) ----
        $null = $command.Parameters.Add('@BatchId',   [System.Data.SqlDbType]::UniqueIdentifier)
        $command.Parameters['@BatchId'].Value = $batchId

        $null = $command.Parameters.Add('@HotelCode', [System.Data.SqlDbType]::NVarChar, 20)
        $command.Parameters['@HotelCode'].Value = $HotelCode

        $null = $command.Parameters.Add('@ChainCode', [System.Data.SqlDbType]::NVarChar, 20)
        $command.Parameters['@ChainCode'].Value = if ([string]::IsNullOrWhiteSpace($ChainCode)) { '' } else { $ChainCode }

        $null = $command.Parameters.Add('@Mode',      [System.Data.SqlDbType]::NVarChar, 30)
        $command.Parameters['@Mode'].Value = $Mode

        $null = $command.Parameters.Add('@QueryType', [System.Data.SqlDbType]::NVarChar, 50)
        $command.Parameters['@QueryType'].Value = $QueryType

        $null = $command.Parameters.Add('@BusinessDateFrom', [System.Data.SqlDbType]::Date)
        $command.Parameters['@BusinessDateFrom'].Value = if ($null -eq $BusinessDateFrom) { [System.DBNull]::Value } else { $BusinessDateFrom.Value.Date }

        $null = $command.Parameters.Add('@BusinessDateTo', [System.Data.SqlDbType]::Date)
        $command.Parameters['@BusinessDateTo'].Value = if ($null -eq $BusinessDateTo) { [System.DBNull]::Value } else { $BusinessDateTo.Value.Date }

        $null = $command.Parameters.Add('@StartedAt', [System.Data.SqlDbType]::DateTime2)
        $command.Parameters['@StartedAt'].Value = $startedAt

        $null = $command.Parameters.Add('@Status',    [System.Data.SqlDbType]::NVarChar, 20)
        $command.Parameters['@Status'].Value = 'Running'

        $null = $command.Parameters.Add('@LoadedBy',  [System.Data.SqlDbType]::NVarChar, 100)
        $command.Parameters['@LoadedBy'].Value = $loadedBy

        $null = $command.ExecuteNonQuery()

        Write-Log -Level 'DEBUG' -Module 'Logger' -HotelCode $HotelCode -BatchId $batchId `
            -Message 'Wrote initial Running row to dbo.LoadLog.'
    }
    catch {
        # A SQL logging failure must never abort the run (REQ-015). Warn and continue;
        # the BatchId returned below is still valid for in-process correlation.
        Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $HotelCode -BatchId $batchId `
            -Message ("Failed to write Running row to dbo.LoadLog: {0}. Continuing without SQL batch logging." -f $_.Exception.Message)
    }
    finally {
        if ($null -ne $command) {
            try { $command.Dispose() } catch { }
        }
        if ($null -ne $connection) {
            try {
                if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
                    $connection.Close()
                }
            }
            catch { }
            try { $connection.Dispose() } catch { }
        }
    }

    return $batchId
}

function Complete-Batch {
    <#
    .SYNOPSIS
        Finalizes a load batch by updating its dbo.LoadLog row with the final status,
        row counts, and run duration.

    .DESCRIPTION
        Complete-Batch is the counterpart to Start-Batch. It locates the dbo.LoadLog
        row created by Start-Batch (matched by BatchId) and updates it with the final
        outcome of the batch:
          - Status              — the terminal status (Success|NoData|Error|Partial).
                                  Per REQ-015, 'NoData' is a valid NON-error status.
          - RowsFetched / RowsInserted / RowsUpdated — optional row counts. When a
                                  count is omitted it is left as the existing value /
                                  NULL (bound as DBNull), never zeroed.
          - CompletedAt         — set to now.
          - DurationMs          — computed IN SQL as DATEDIFF(MILLISECOND, StartedAt,
                                  @CompletedAt) using the StartedAt already persisted by
                                  Start-Batch, so no client clock-skew assumptions are
                                  needed. When an explicit -StartedAt fallback is
                                  supplied it is used only if the row has no StartedAt.
          - ErrorMessage        — optional; written when the status indicates failure.

        SQL mirroring is OPTIONAL and best-effort. When $script:SqlLogging is $false the
        function logs a DEBUG line and returns without touching the database. When SQL
        logging is enabled but no connection string is resolvable it logs a WARN and
        returns. A SQL failure MUST NEVER abort the run (REQ-015): the database work is
        wrapped in try/catch, failures are logged as WARN via Write-Log, and the
        function never throws to the caller.

        The UPDATE is fully parameterized (Microsoft.Data.SqlClient) — no run-time
        values are concatenated into the SQL text — to prevent SQL injection. Explicit
        SqlDbType bindings match the Start-Batch conventions, and [System.DBNull]::Value
        is used for null row counts / null error message.

        NOTE: The completion columns updated here — CompletedAt (DateTime2),
        DurationMs (Int), RowsFetched (Int), RowsInserted (Int), RowsUpdated (Int),
        ErrorMessage (NVarChar) — MUST be present in the dbo.LoadLog DDL created in
        Task 6 (SQL\002). They complement the columns Start-Batch already writes
        (BatchId, HotelCode, ChainCode, [Mode], QueryType, BusinessDateFrom,
        BusinessDateTo, StartedAt, Status, LoadedBy).

    .PARAMETER BatchId
        The batch correlation id returned by Start-Batch. Identifies the dbo.LoadLog
        row to update (WHERE BatchId = @BatchId).

    .PARAMETER Status
        The terminal batch status. One of: Success, NoData, Error, Partial.
        'NoData' is a valid non-error outcome (REQ-015).

    .PARAMETER RowsFetched
        Optional count of rows fetched from the source API. Left as-is / NULL when omitted.

    .PARAMETER RowsInserted
        Optional count of rows inserted into the target table. Left as-is / NULL when omitted.

    .PARAMETER RowsUpdated
        Optional count of rows updated in the target table. Left as-is / NULL when omitted.

    .PARAMETER ErrorMessage
        Optional error/message text. Written to dbo.LoadLog.ErrorMessage; typically
        supplied when Status is 'Error' or 'Partial'.

    .PARAMETER HotelCode
        Optional hotel/property code used only for log-line context (Write-Log -HotelCode).
        Not written to the row (the row already carries HotelCode from Start-Batch).

    .PARAMETER StartedAt
        Optional fallback batch start time. Duration is normally computed in SQL from the
        row's persisted StartedAt; this value is only used to populate StartedAt in the
        UPDATE when the row's StartedAt is NULL (defensive), keeping DurationMs correct.

    .PARAMETER ConnectionString
        Optional SQL Server connection string override. When omitted, the module-level
        $script:SqlConnectionString captured by Initialize-Logger is used.

    .OUTPUTS
        None. The function is best-effort and never throws; it returns after logging.

    .EXAMPLE
        Complete-Batch -BatchId $batchId -Status 'Success' -RowsFetched 1200 -RowsInserted 1100 -RowsUpdated 100

    .EXAMPLE
        Complete-Batch -BatchId $batchId -Status 'Error' -ErrorMessage 'HTTP 503 after retries'

    .EXAMPLE
        # A run that returned no source data — a valid, non-error terminal status (REQ-015).
        Complete-Batch -BatchId $batchId -Status 'NoData'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [guid] $BatchId,

        [Parameter(Mandatory)]
        [ValidateSet('Success', 'NoData', 'Error', 'Partial')]
        [string] $Status,

        [Parameter()]
        [Nullable[int]] $RowsFetched,

        [Parameter()]
        [Nullable[int]] $RowsInserted,

        [Parameter()]
        [Nullable[int]] $RowsUpdated,

        [Parameter()]
        [string] $ErrorMessage,

        [Parameter()]
        [string] $HotelCode = '',

        [Parameter()]
        [Nullable[datetime]] $StartedAt,

        [Parameter()]
        [string] $ConnectionString
    )

    $completedAt = Get-Date

    # Human-readable summary bits for the log lines.
    $rowsFetchedText  = if ($null -eq $RowsFetched)  { '<n/a>' } else { $RowsFetched }
    $rowsInsertedText = if ($null -eq $RowsInserted) { '<n/a>' } else { $RowsInserted }
    $rowsUpdatedText  = if ($null -eq $RowsUpdated)  { '<n/a>' } else { $RowsUpdated }

    Write-Log -Level 'INFO' -Module 'Logger' -HotelCode $HotelCode -BatchId $BatchId `
        -Message ("Batch completed. Status={0} RowsFetched={1} RowsInserted={2} RowsUpdated={3}" -f `
            $Status, $rowsFetchedText, $rowsInsertedText, $rowsUpdatedText)

    # SQL mirroring is optional. Skip quietly when disabled.
    if (-not $script:SqlLogging) {
        Write-Log -Level 'DEBUG' -Module 'Logger' -HotelCode $HotelCode -BatchId $BatchId `
            -Message 'SqlLogging disabled; skipping dbo.LoadLog completion update.'
        return
    }

    # Resolve the connection string: explicit override wins, otherwise fall back to
    # the module-level value captured by Initialize-Logger.
    $effectiveConnectionString = if (-not [string]::IsNullOrWhiteSpace($ConnectionString)) {
        $ConnectionString
    }
    else {
        $script:SqlConnectionString
    }

    if ([string]::IsNullOrWhiteSpace($effectiveConnectionString)) {
        # SqlLogging requested but no connection string is available. Per REQ-015 this
        # is a non-fatal logging condition — warn and continue.
        Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $HotelCode -BatchId $BatchId `
            -Message 'SqlLogging enabled but no SQL connection string is configured; dbo.LoadLog completion update was not written.'
        return
    }

    $connection = $null
    $command    = $null
    try {
        # Microsoft.Data.SqlClient is the driver used across the SqlWriter design.
        # Add-Type is a no-op if the assembly is already loaded in the session.
        Add-Type -AssemblyName 'Microsoft.Data.SqlClient' -ErrorAction Stop

        # Parameterized UPDATE — values are bound as SqlParameters, never interpolated,
        # to prevent SQL injection.
        #
        # DurationMs is computed IN SQL from the row's already-persisted StartedAt so
        # there are no client clock-skew assumptions. As a defensive fallback, if the
        # row's StartedAt is NULL and an explicit -StartedAt was supplied, StartedAt is
        # backfilled with COALESCE so DurationMs still resolves. Row-count and
        # ErrorMessage columns use COALESCE(@Param, ExistingColumn) so an omitted
        # (DBNull) argument leaves the existing value untouched rather than nulling it.
        $updateSql = @'
UPDATE dbo.LoadLog
SET
    StartedAt     = COALESCE(StartedAt, @StartedAt),
    Status        = @Status,
    RowsFetched   = COALESCE(@RowsFetched,  RowsFetched),
    RowsInserted  = COALESCE(@RowsInserted, RowsInserted),
    RowsUpdated   = COALESCE(@RowsUpdated,  RowsUpdated),
    ErrorMessage  = COALESCE(@ErrorMessage, ErrorMessage),
    CompletedAt   = @CompletedAt,
    DurationMs    = DATEDIFF(MILLISECOND, COALESCE(StartedAt, @StartedAt, @CompletedAt), @CompletedAt)
WHERE BatchId = @BatchId;
'@

        $connection = [Microsoft.Data.SqlClient.SqlConnection]::new($effectiveConnectionString)
        $connection.Open()

        $command = $connection.CreateCommand()
        $command.CommandText = $updateSql

        # --- Bind parameters with explicit SQL types (defensive, injection-safe) ----
        $null = $command.Parameters.Add('@BatchId', [System.Data.SqlDbType]::UniqueIdentifier)
        $command.Parameters['@BatchId'].Value = $BatchId

        $null = $command.Parameters.Add('@Status', [System.Data.SqlDbType]::NVarChar, 20)
        $command.Parameters['@Status'].Value = $Status

        $null = $command.Parameters.Add('@RowsFetched', [System.Data.SqlDbType]::Int)
        $command.Parameters['@RowsFetched'].Value = if ($null -eq $RowsFetched) { [System.DBNull]::Value } else { $RowsFetched.Value }

        $null = $command.Parameters.Add('@RowsInserted', [System.Data.SqlDbType]::Int)
        $command.Parameters['@RowsInserted'].Value = if ($null -eq $RowsInserted) { [System.DBNull]::Value } else { $RowsInserted.Value }

        $null = $command.Parameters.Add('@RowsUpdated', [System.Data.SqlDbType]::Int)
        $command.Parameters['@RowsUpdated'].Value = if ($null -eq $RowsUpdated) { [System.DBNull]::Value } else { $RowsUpdated.Value }

        $null = $command.Parameters.Add('@ErrorMessage', [System.Data.SqlDbType]::NVarChar, -1)
        $command.Parameters['@ErrorMessage'].Value = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { [System.DBNull]::Value } else { $ErrorMessage }

        $null = $command.Parameters.Add('@StartedAt', [System.Data.SqlDbType]::DateTime2)
        $command.Parameters['@StartedAt'].Value = if ($null -eq $StartedAt) { [System.DBNull]::Value } else { $StartedAt.Value }

        $null = $command.Parameters.Add('@CompletedAt', [System.Data.SqlDbType]::DateTime2)
        $command.Parameters['@CompletedAt'].Value = $completedAt

        $rowsAffected = $command.ExecuteNonQuery()

        if ($rowsAffected -lt 1) {
            # No matching Running row (e.g. Start-Batch's insert was skipped/failed).
            # Non-fatal: the run still completes; surface as WARN for diagnostics.
            Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $HotelCode -BatchId $BatchId `
                -Message 'No dbo.LoadLog row matched the BatchId; completion update affected 0 rows.'
        }
        else {
            Write-Log -Level 'DEBUG' -Module 'Logger' -HotelCode $HotelCode -BatchId $BatchId `
                -Message ("Updated dbo.LoadLog completion row (Status={0}, {1} row(s) affected)." -f $Status, $rowsAffected)
        }
    }
    catch {
        # A SQL logging failure must never abort the run (REQ-015). Warn and continue.
        Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $HotelCode -BatchId $BatchId `
            -Message ("Failed to update completion row in dbo.LoadLog: {0}. Continuing without SQL batch logging." -f $_.Exception.Message)
    }
    finally {
        if ($null -ne $command) {
            try { $command.Dispose() } catch { }
        }
        if ($null -ne $connection) {
            try {
                if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
                    $connection.Close()
                }
            }
            catch { }
            try { $connection.Dispose() } catch { }
        }
    }
}

function Send-AlertEmail {
    <#
    .SYNOPSIS
        Sends an end-of-run severity-based alert email for a single hotel over the
        shared SMTP transport, attaching the daily log file (REQ-016).

    .DESCRIPTION
        Send-AlertEmail delivers a structured end-of-run summary notification for ONE
        hotel and ONE severity level. It is designed to be called once per qualifying
        severity after a hotel run (or the overall batch) completes — never per
        individual log entry — so operators are not flooded.

        Transport (shared, from settings.json `smtp`):
          smtpServer, port, useSsl, from (+ optional fromDisplayName), and DPAPI-encrypted
          username / password. The SMTP transport is shared by every hotel; only the
          recipient distribution lists differ per hotel.

        Recipients (per hotel, from hotels.json `emailAlerts`):
          Resolved from the hotel's own emailAlerts.<severity>.to[] / .cc[]. Recipient
          lists are NOT global.

        Gating — an email is sent ONLY when ALL of the following are true:
          1. smtp.enabled -eq $true                       (global transport enabled)
          2. Hotel.emailAlerts.enabled -eq $true          (hotel opted in)
          3. Hotel.emailAlerts.<severity>.enabled -eq $true (this severity enabled)
          4. At least one `to` recipient exists for that severity
        When any gate is not met the function logs a DEBUG/INFO reason and returns
        WITHOUT sending — this is a normal, non-error outcome.

        Credentials:
          smtp.username / smtp.password are DPAPI-encrypted (produced by
          Protect-HotelsConfig.ps1). They are decrypted just-in-time via
          ConvertTo-SecureString (current-user DPAPI). If a value is not a valid
          DPAPI blob (e.g. a plain-text dev value or the REPLACE_ME placeholder), it is
          used verbatim as a fallback so non-encrypted dev/CI setups still work. Neither
          the plain-text nor encrypted credential is ever written to a log line.

        Attachment:
          The daily shared log file (the effective $script:LogFilePath) is attached so
          recipients get full context beyond the inline entries. A missing/locked log
          file is skipped with a WARN and does not prevent the email.

        Resilience (REQ-016):
          Email delivery failure MUST NOT abort or fail the data load. Every failure
          path is caught, logged as WARN via Write-Log, and the function returns without
          throwing. The caller's exit code is preserved.

    .PARAMETER Hotel
        The hotel configuration object/hashtable (from hotels.json). Must expose
        `hotelCode` and an `emailAlerts` block with `enabled` and per-severity
        (`error`/`warn`/`info`) `enabled` + `to[]` / `cc[]` lists.

    .PARAMETER Severity
        The triggering severity: INFO, WARN, or ERROR. Selects which emailAlerts.<severity>
        recipient list and enable flag are used.

    .PARAMETER Subject
        The email subject line.

    .PARAMETER Body
        The email body (structured run summary + inline filtered entries). Treated as
        plain text by default; pass -BodyAsHtml to send as HTML.

    .PARAMETER Smtp
        The shared SMTP transport configuration (settings.json `smtp` section). Supplies
        smtpServer, port, useSsl, from, fromDisplayName, enabled, and encrypted
        username/password.

    .PARAMETER Attachments
        Optional explicit attachment paths. When omitted, the current daily log file
        (effective $script:LogFilePath) is attached automatically.

    .PARAMETER BodyAsHtml
        When set, the body is sent as HTML.

    .PARAMETER IsDryRun
        When set, the notification is still evaluated and sent but the subject/body are
        clearly marked as a dry-run (REQ-016 SHOULD).

    .OUTPUTS
        [bool] $true when an email was dispatched; $false when gated out or when a
        (logged, non-fatal) failure prevented delivery. Never throws.

    .EXAMPLE
        Send-AlertEmail -Hotel $hotel -Severity 'ERROR' -Subject 'Run failed' `
                        -Body $summary -Smtp $settings.smtp
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Hotel,

        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Severity,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Subject,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [string] $Body,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Smtp,

        [Parameter()]
        [string[]] $Attachments,

        [Parameter()]
        [switch] $BodyAsHtml,

        [Parameter()]
        [switch] $IsDryRun
    )

    # Resolve hotel code for log context up front (best-effort).
    $hotelCode = ''
    try {
        if ($null -ne $Hotel.hotelCode) { $hotelCode = [string]$Hotel.hotelCode }
        elseif ($null -ne $Hotel.HotelCode) { $hotelCode = [string]$Hotel.HotelCode }
    }
    catch { $hotelCode = '' }

    $severityKey = $Severity.ToLowerInvariant()

    # ---------------------------------------------------------------------------
    # Gate 1 — global SMTP transport enabled.
    # ---------------------------------------------------------------------------
    $smtpEnabled = $false
    try { $smtpEnabled = [bool]$Smtp.enabled } catch { $smtpEnabled = $false }
    if (-not $smtpEnabled) {
        Write-Log -Level 'DEBUG' -Module 'Logger' -HotelCode $hotelCode `
            -Message "Send-AlertEmail: smtp.enabled is false; skipping $Severity notification."
        return $false
    }

    # ---------------------------------------------------------------------------
    # Gate 2 — hotel opted in to alerts.
    # ---------------------------------------------------------------------------
    $alerts = $null
    try { $alerts = $Hotel.emailAlerts } catch { $alerts = $null }
    if ($null -eq $alerts) {
        Write-Log -Level 'DEBUG' -Module 'Logger' -HotelCode $hotelCode `
            -Message "Send-AlertEmail: hotel has no emailAlerts block; skipping $Severity notification."
        return $false
    }

    $hotelAlertsEnabled = $false
    try { $hotelAlertsEnabled = [bool]$alerts.enabled } catch { $hotelAlertsEnabled = $false }
    if (-not $hotelAlertsEnabled) {
        Write-Log -Level 'DEBUG' -Module 'Logger' -HotelCode $hotelCode `
            -Message "Send-AlertEmail: hotel emailAlerts.enabled is false; skipping $Severity notification."
        return $false
    }

    # ---------------------------------------------------------------------------
    # Gate 3 — this severity enabled for the hotel.
    # ---------------------------------------------------------------------------
    $severityBlock = $null
    try { $severityBlock = $alerts.$severityKey } catch { $severityBlock = $null }
    if ($null -eq $severityBlock) {
        Write-Log -Level 'DEBUG' -Module 'Logger' -HotelCode $hotelCode `
            -Message "Send-AlertEmail: hotel emailAlerts.$severityKey is not configured; skipping $Severity notification."
        return $false
    }

    $severityEnabled = $false
    try { $severityEnabled = [bool]$severityBlock.enabled } catch { $severityEnabled = $false }
    if (-not $severityEnabled) {
        Write-Log -Level 'DEBUG' -Module 'Logger' -HotelCode $hotelCode `
            -Message "Send-AlertEmail: hotel emailAlerts.$severityKey.enabled is false; skipping $Severity notification."
        return $false
    }

    # ---------------------------------------------------------------------------
    # Gate 4 — at least one 'to' recipient exists for this severity.
    # ---------------------------------------------------------------------------
    $toRecipients = @()
    $ccRecipients = @()
    try {
        if ($null -ne $severityBlock.to) {
            $toRecipients = @($severityBlock.to | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
        }
    }
    catch { $toRecipients = @() }
    try {
        if ($null -ne $severityBlock.cc) {
            $ccRecipients = @($severityBlock.cc | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
        }
    }
    catch { $ccRecipients = @() }

    if ($toRecipients.Count -lt 1) {
        Write-Log -Level 'INFO' -Module 'Logger' -HotelCode $hotelCode `
            -Message "Send-AlertEmail: no 'to' recipients configured for emailAlerts.$severityKey; skipping $Severity notification."
        return $false
    }

    # ---------------------------------------------------------------------------
    # Resolve transport fields.
    # ---------------------------------------------------------------------------
    $smtpServer = ''
    try { $smtpServer = [string]$Smtp.smtpServer } catch { $smtpServer = '' }
    if ([string]::IsNullOrWhiteSpace($smtpServer)) {
        Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $hotelCode `
            -Message "Send-AlertEmail: smtp.smtpServer is missing; cannot send $Severity notification. Continuing run."
        return $false
    }

    $smtpPort = 25
    try { if ($null -ne $Smtp.port) { $smtpPort = [int]$Smtp.port } } catch { $smtpPort = 25 }

    $useSsl = $false
    try { if ($null -ne $Smtp.useSsl) { $useSsl = [bool]$Smtp.useSsl } } catch { $useSsl = $false }

    $fromAddress = ''
    try { $fromAddress = [string]$Smtp.from } catch { $fromAddress = '' }
    if ([string]::IsNullOrWhiteSpace($fromAddress)) {
        Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $hotelCode `
            -Message "Send-AlertEmail: smtp.from is missing; cannot send $Severity notification. Continuing run."
        return $false
    }

    $fromDisplayName = ''
    try { if ($null -ne $Smtp.fromDisplayName) { $fromDisplayName = [string]$Smtp.fromDisplayName } } catch { $fromDisplayName = '' }

    $authRequired = $true
    try { if ($null -ne $Smtp.authRequired) { $authRequired = [bool]$Smtp.authRequired } } catch { $authRequired = $true }

    # ---------------------------------------------------------------------------
    # Compose subject / body (mark dry-run when requested — REQ-016 SHOULD).
    # ---------------------------------------------------------------------------
    $effectiveSubject = if ($IsDryRun) { "[DRYRUN] $Subject" } else { $Subject }
    $effectiveBody = if ($IsDryRun) {
        "*** DRY RUN — no data was written to SQL Server ***`n`n$Body"
    }
    else {
        $Body
    }

    # ---------------------------------------------------------------------------
    # Resolve attachments: explicit paths, otherwise the current daily log file.
    # A missing/unreadable attachment is skipped with a WARN (never fatal).
    # ---------------------------------------------------------------------------
    $attachmentPaths = New-Object System.Collections.Generic.List[string]
    $candidatePaths = if ($PSBoundParameters.ContainsKey('Attachments') -and $null -ne $Attachments) {
        @($Attachments)
    }
    else {
        $logPath = Get-SharedLogFilePath
        if ([string]::IsNullOrWhiteSpace($logPath)) { @() } else { @($logPath) }
    }

    foreach ($candidate in $candidatePaths) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $attachmentPaths.Add($candidate)
        }
        else {
            Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $hotelCode `
                -Message "Send-AlertEmail: attachment '$candidate' not found; sending $Severity notification without it."
        }
    }

    # ---------------------------------------------------------------------------
    # Decrypt SMTP credentials (DPAPI). Fall back to plain text for dev/CI values
    # that are not valid DPAPI blobs. Credentials are never logged.
    # ---------------------------------------------------------------------------
    $networkCredential = $null
    if ($authRequired) {
        $username = ''
        try { $username = [string]$Smtp.username } catch { $username = '' }
        $encryptedPassword = ''
        try { $encryptedPassword = [string]$Smtp.password } catch { $encryptedPassword = '' }

        if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($encryptedPassword)) {
            Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $hotelCode `
                -Message "Send-AlertEmail: smtp.authRequired is true but username/password are missing; attempting anonymous send for $Severity notification."
        }
        else {
            $securePassword = $null
            try {
                # Preferred path: value is a DPAPI-encrypted SecureString blob.
                $securePassword = ConvertTo-SecureString -String $encryptedPassword -ErrorAction Stop
            }
            catch {
                # Fallback: treat the value as plain text (dev/CI or placeholder). This
                # keeps non-encrypted setups working without leaking the value to logs.
                try {
                    $securePassword = ConvertTo-SecureString -String $encryptedPassword -AsPlainText -Force -ErrorAction Stop
                }
                catch {
                    $securePassword = $null
                }
            }

            if ($null -ne $securePassword) {
                try {
                    $networkCredential = [System.Net.NetworkCredential]::new($username, $securePassword)
                }
                catch {
                    Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $hotelCode `
                        -Message "Send-AlertEmail: failed to build SMTP network credential; attempting anonymous send for $Severity notification."
                    $networkCredential = $null
                }
            }
            else {
                Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $hotelCode `
                    -Message "Send-AlertEmail: failed to decrypt smtp.password; attempting anonymous send for $Severity notification."
            }
        }
    }

    # ---------------------------------------------------------------------------
    # Send via Net.Mail.SmtpClient. Every failure is caught, logged WARN, non-fatal.
    # ---------------------------------------------------------------------------
    $mailMessage = $null
    $smtpClient  = $null
    try {
        $mailMessage = [System.Net.Mail.MailMessage]::new()

        if ([string]::IsNullOrWhiteSpace($fromDisplayName)) {
            $mailMessage.From = [System.Net.Mail.MailAddress]::new($fromAddress)
        }
        else {
            $mailMessage.From = [System.Net.Mail.MailAddress]::new($fromAddress, $fromDisplayName)
        }

        foreach ($to in $toRecipients) {
            try { $mailMessage.To.Add($to) }
            catch {
                Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $hotelCode `
                    -Message "Send-AlertEmail: invalid 'to' address skipped for $Severity notification."
            }
        }
        foreach ($cc in $ccRecipients) {
            try { $mailMessage.CC.Add($cc) }
            catch {
                Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $hotelCode `
                    -Message "Send-AlertEmail: invalid 'cc' address skipped for $Severity notification."
            }
        }

        if ($mailMessage.To.Count -lt 1) {
            Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $hotelCode `
                -Message "Send-AlertEmail: all 'to' addresses were invalid; skipping $Severity notification. Continuing run."
            return $false
        }

        $mailMessage.Subject    = $effectiveSubject
        $mailMessage.Body       = $effectiveBody
        $mailMessage.IsBodyHtml = [bool]$BodyAsHtml

        foreach ($attach in $attachmentPaths) {
            try {
                $mailMessage.Attachments.Add([System.Net.Mail.Attachment]::new($attach))
            }
            catch {
                Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $hotelCode `
                    -Message "Send-AlertEmail: failed to attach '$attach'; sending $Severity notification without it."
            }
        }

        $smtpClient = [System.Net.Mail.SmtpClient]::new($smtpServer, $smtpPort)
        $smtpClient.EnableSsl = $useSsl
        if ($null -ne $networkCredential) {
            $smtpClient.UseDefaultCredentials = $false
            $smtpClient.Credentials = $networkCredential
        }

        $smtpClient.Send($mailMessage)

        Write-Log -Level 'INFO' -Module 'Logger' -HotelCode $hotelCode `
            -Message ("Send-AlertEmail: {0} notification sent to {1} recipient(s) (cc {2}). DryRun={3}." -f `
                $Severity, $mailMessage.To.Count, $mailMessage.CC.Count, [bool]$IsDryRun)

        return $true
    }
    catch {
        # REQ-016: delivery failure must never abort the run. Log WARN and continue.
        Write-Log -Level 'WARN' -Module 'Logger' -HotelCode $hotelCode `
            -Message ("Send-AlertEmail: failed to send {0} notification: {1}. Run continues; exit code preserved." -f `
                $Severity, $_.Exception.Message)
        return $false
    }
    finally {
        if ($null -ne $mailMessage) {
            try { $mailMessage.Dispose() } catch { }
        }
        if ($null -ne $smtpClient) {
            try { $smtpClient.Dispose() } catch { }
        }
    }
}

Export-ModuleMember -Function @(
    'Initialize-Logger',
    'Write-Log',
    'Start-Batch',
    'Complete-Batch',
    'Send-AlertEmail'
)
