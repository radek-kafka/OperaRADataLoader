# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    GraphQL-over-HTTP client for the OPERA R&A Data Loader (OHIP R&A Data APIs).

.DESCRIPTION
    Implements the ApiClient.psm1 design (Task 5). The OHIP R&A Data APIs are
    GraphQL APIs (NOT REST): every Subject Area is a named GraphQL operation issued
    as a single HTTP POST to <gatewayUrl>/rna/v1/graphql/. This module wraps that
    transport with:

      * Header injection (REQ-003):
          Authorization: Bearer <token>
          x-app-key:     <Hotel.ApiKey>
          x-request-id:  <new [guid] per request>   (end-to-end tracing)
          Content-Type:  application/json
          Accept:        multipart/mixed; deferSpec=20220824, application/json
          x-hotelid:     <Hotel.HotelCode>          (optional for R&A; sent for
                                                      consistency with other OHIP APIs)

      * HTTP 401 recovery (REQ-003): on 401 -> Clear-TokenCache -> Get-OAuthToken ->
        retry the SAME request exactly once with the fresh token.

      * Transient-error resilience (REQ-011): exponential backoff on
        429 / 500 / 502 / 503 / 504. Delay = min(base * 2^(attempt-1), cap),
        base 2s, cap 30s, max 3 retries (all configurable via settings.json api.*).

      * Per-request throttle (REQ-011): Start-Sleep -Milliseconds
        $config.api.requestDelayMs between successive page/chunk calls.

      * GraphQL errors handling (REQ-011): inspect the response "errors" array.
        WARN and continue when partial errors are present but "data" is non-null;
        THROW when "data" is null (full failure).

    DESIGN RECONCILIATION (important — read before editing):
      The Task 5 subtask text uses generic REST-style vocabulary ("Invoke-RAApi",
      "pagination loop consuming nextPageToken or offset-based paging"). The authoritative
      design.md / requirements.md (REQ-011) clarify the real API is GraphQL and has NO
      cursor/offset pagination — volume is controlled purely by narrow date-range chunks
      chosen by the caller (Query modules via Get-DateRangeChunks).

      Reconciliation applied here:
        - The design's functions Invoke-GraphQL and Invoke-RASubjectArea are the real
          implementation.
        - Invoke-RAApi is exposed as the documented PUBLIC entry point, implemented as a
          thin wrapper/alias over Invoke-GraphQL (single GraphQL POST with the required
          headers). This satisfies the Task 5 "Invoke-RAApi with header injection" subtask
          without inventing a second transport.
        - The "pagination loop" subtask is implemented as the DATE-CHUNK accumulation loop
          in Invoke-RASubjectArea: the caller supplies pre-chunked @{Start;End} ranges (or
          pre-built per-chunk variable sets) and every chunk's rows are flattened into a
          single [array]. A "nextPageToken" is honoured DEFENSIVELY only if a response ever
          returns one, so the code is forward-compatible without depending on paging.

    Dependencies:
      Auth.psm1  — Get-OAuthToken, Clear-TokenCache (imported below; resolved at call time
                   so the module still loads for isolated unit tests).
      Logger.psm1 — Write-Log -Module "ApiClient" (degrades to Write-Verbose if not loaded).

    Test seam:
      Invoke-GraphQL accepts an -Invoker scriptblock that replaces Invoke-WebRequest.
      It receives one hashtable (@{ Uri; Method; Headers; Body; TimeoutSec }) and must
      return an object shaped like @{ StatusCode = <int>; Content = <json string> } OR
      throw an exception carrying a .Response.StatusCode (HttpResponseException-like) to
      simulate HTTP error codes. This lets the 401 / backoff / throttle / errors-array
      logic be exercised with zero network access.

.NOTES
    Module name constant for Logger -Module parameter: "ApiClient"
#>

# ------------------------------------------------------------------------------
# Import Auth (best-effort). Resolved by name at call time as well, so a missing
# import (isolated unit test) does not stop the module from loading.
# ------------------------------------------------------------------------------
$script:AuthModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Auth.psm1'
if (Test-Path -LiteralPath $script:AuthModulePath) {
    Import-Module $script:AuthModulePath -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# Defaults (mirrors settings.json api.* — used when the caller omits a value)
# ------------------------------------------------------------------------------
$script:DefaultRequestDelayMs        = 500
$script:DefaultMaxRetries            = 3
$script:DefaultRetryBaseDelaySeconds = 2
$script:DefaultRetryMaxDelaySeconds  = 30
$script:DefaultRetryableStatusCodes  = @(429, 500, 502, 503, 504)
$script:DefaultHttpTimeoutSeconds    = 120
$script:DefaultGraphQlEndpointPath   = '/rna/v1/graphql/'
$script:DefaultAcceptHeader          = 'multipart/mixed; deferSpec=20220824, application/json'

# ------------------------------------------------------------------------------
# Logging helper — shared Logger when loaded, else Write-Verbose. Never logs the
# bearer token, ApiKey, or ClientSecret (masked upstream by Logger; not passed here).
# ------------------------------------------------------------------------------
function Write-ApiLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $Level,

        [Parameter(Mandatory)]
        [string] $Message,

        [Parameter()]
        [string] $HotelCode = ''
    )

    $writeLog = Get-Command -Name 'Write-Log' -ErrorAction SilentlyContinue
    if ($writeLog) {
        try {
            & $writeLog -Level $Level -Module 'ApiClient' -Message $Message -HotelCode $HotelCode
            return
        }
        catch {
            # Fall through — a logger failure must never break the API layer.
        }
    }

    Write-Verbose ("ApiClient [{0}] {1}: {2}" -f $Level, $HotelCode, $Message)
}

# ------------------------------------------------------------------------------
# Internal config helpers
# ------------------------------------------------------------------------------
function Get-CfgValue {
    <#
    .SYNOPSIS
        Internal: case-insensitive lookup from a hashtable or PSCustomObject.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] [string[]] $Names
    )

    if ($null -eq $Source) { return $null }

    foreach ($name in $Names) {
        if ($Source -is [System.Collections.IDictionary]) {
            foreach ($key in $Source.Keys) {
                if ($key -ieq $name) { return $Source[$key] }
            }
        }
        else {
            $prop = $Source.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
            if ($prop) { return $prop.Value }
        }
    }
    return $null
}

function Resolve-ApiSetting {
    <#
    .SYNOPSIS
        Internal: resolves an api.* setting from a Config object, falling back to a default.

    .DESCRIPTION
        Accepts either the whole settings object (with an .api child) or an api hashtable
        directly. Returns the default when the value is absent or not parseable.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] $Config,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Default
    )

    if ($null -eq $Config) { return $Default }

    # Allow passing either the root settings object or the api sub-object.
    $api = Get-CfgValue -Source $Config -Names @('api')
    if ($null -eq $api) { $api = $Config }

    $val = Get-CfgValue -Source $api -Names @($Name)
    if ($null -eq $val) { return $Default }
    return $val
}

function Get-HttpStatusFromError {
    <#
    .SYNOPSIS
        Internal: extracts an HTTP status code (int) from a thrown web exception.

    .DESCRIPTION
        PowerShell 7 Invoke-WebRequest throws Microsoft.PowerShell.Commands.HttpResponseException
        on non-2xx, exposing .Response.StatusCode (an [System.Net.HttpStatusCode] enum).
        Test seams may throw an exception carrying a .Response.StatusCode int/enum, or set
        an integer .StatusCode directly. This normalises all of those to an [int], or $null
        when no status can be determined (e.g. a socket/DNS failure).
    #>
    [CmdletBinding()]
    [OutputType([Nullable[int]])]
    param(
        [Parameter(Mandatory)] $ErrorObject
    )

    $ex = $null
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        $ex = $ErrorObject.Exception
    }
    elseif ($ErrorObject -is [System.Exception]) {
        $ex = $ErrorObject
    }
    else {
        $ex = $ErrorObject
    }

    if ($null -eq $ex) { return $null }

    # Direct integer .StatusCode (test seam convenience).
    $direct = $ex.PSObject.Properties['StatusCode']
    if ($direct -and $null -ne $direct.Value) {
        $n = 0
        if ([int]::TryParse([string]([int]$direct.Value), [ref]$n)) { return $n }
    }

    # .Response.StatusCode (HttpResponseException and seam-supplied responses).
    $response = $ex.PSObject.Properties['Response']
    if ($response -and $null -ne $response.Value) {
        $sc = $response.Value.PSObject.Properties['StatusCode']
        if ($sc -and $null -ne $sc.Value) {
            try {
                return [int]$sc.Value
            }
            catch {
                $n = 0
                if ([int]::TryParse([string]$sc.Value, [ref]$n)) { return $n }
            }
        }
    }

    return $null
}

function Get-BackoffDelaySeconds {
    <#
    .SYNOPSIS
        Internal: computes the exponential backoff delay for a retry attempt (REQ-011).

    .DESCRIPTION
        Delay = min(BaseSeconds * 2^(Attempt-1), CapSeconds).
          Attempt 1 -> base
          Attempt 2 -> base * 2
          Attempt 3 -> base * 4
        Capped at CapSeconds. Exposed (and deterministic) so backoff timing is unit-testable.

    .PARAMETER Attempt
        1-based retry attempt number.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [ValidateRange(1, [int]::MaxValue)] [int] $Attempt,
        [Parameter(Mandatory)] [ValidateRange(0, [int]::MaxValue)] [int] $BaseSeconds,
        [Parameter(Mandatory)] [ValidateRange(0, [int]::MaxValue)] [int] $CapSeconds
    )

    # 2^(Attempt-1) can grow fast; compute as double then cap before casting.
    $factor = [math]::Pow(2, ($Attempt - 1))
    $raw = [double]$BaseSeconds * $factor
    if ($raw -gt $CapSeconds) { return [int]$CapSeconds }
    return [int]$raw
}

# ------------------------------------------------------------------------------
# Public: Invoke-GraphQL
# ------------------------------------------------------------------------------
function Invoke-GraphQL {
    <#
    .SYNOPSIS
        Issues a single GraphQL POST to the OHIP R&A endpoint with full header injection,
        401 re-auth-and-retry, and 429/5xx exponential backoff.

    .DESCRIPTION
        design.md ApiClient.psm1 — Invoke-GraphQL flow:
          1. Build headers (Authorization/x-app-key/x-request-id/Content-Type/Accept, and
             optional x-hotelid). A NEW x-request-id GUID is generated per attempt.
          2. POST <GatewayUrl><graphqlEndpointPath> with body @{query; variables} | ConvertTo-Json -Depth 12.
          3. HTTP 401 -> Clear-TokenCache + Get-OAuthToken once -> retry the request once.
          4. HTTP 429 / 5xx -> exponential backoff (base 2s, x2, cap 30s, max 3 retries).
          5. Inspect response.errors -> WARN each; if data is null -> throw.
          6. Return the deserialized response object (has .data and optionally .errors).

    .PARAMETER Hotel
        Hotel config (hashtable / PSCustomObject). Recognised keys (case-insensitive):
        HotelCode, GatewayUrl, ApiKey.

    .PARAMETER Query
        The GraphQL query string.

    .PARAMETER Variables
        The GraphQL variables hashtable (becomes the "variables" JSON object).

    .PARAMETER Token
        The current bearer token. When omitted, one is obtained via Get-OAuthToken -Hotel.

    .PARAMETER Config
        Optional settings object (root settings.json or its api sub-object) supplying
        requestDelayMs / maxRetries / retryBaseDelaySeconds / retryMaxDelaySeconds /
        retryableStatusCodes / httpTimeoutSeconds / graphqlEndpointPath.

    .PARAMETER Invoker
        Optional test/DI seam replacing Invoke-WebRequest. Receives one hashtable
        (@{ Uri; Method; Headers; Body; TimeoutSec }) and must return
        @{ StatusCode = <int>; Content = <json string> } or throw a status-bearing exception.

    .PARAMETER TokenProvider
        Optional test/DI seam replacing Get-OAuthToken for the 401 re-auth path. Receives
        the Hotel and returns a token string. Defaults to the real Get-OAuthToken.

    .PARAMETER Sleep
        Optional test/DI seam replacing Start-Sleep for backoff waits. Receives the delay
        in seconds. Defaults to real Start-Sleep so tests do not actually wait.

    .OUTPUTS
        [PSCustomObject] the deserialized GraphQL response (.data / .errors).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] $Hotel,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Query,
        [Parameter()] [hashtable] $Variables = @{},
        [Parameter()] [string] $Token,
        [Parameter()] $Config,
        [Parameter()] [scriptblock] $Invoker,
        [Parameter()] [scriptblock] $TokenProvider,
        [Parameter()] [scriptblock] $Sleep
    )

    # --- Resolve hotel config ------------------------------------------------
    $hotelCode = [string](Get-CfgValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))
    if ([string]::IsNullOrWhiteSpace($hotelCode)) {
        throw 'Invoke-GraphQL: Hotel config is missing a HotelCode.'
    }
    $gatewayUrl = [string](Get-CfgValue -Source $Hotel -Names @('GatewayUrl', 'gatewayUrl'))
    if ([string]::IsNullOrWhiteSpace($gatewayUrl)) {
        throw ("Invoke-GraphQL: Hotel '{0}' config is missing a GatewayUrl." -f $hotelCode)
    }
    $apiKey = [string](Get-CfgValue -Source $Hotel -Names @('ApiKey', 'apiKey'))

    # --- Resolve retry / throttle settings -----------------------------------
    $maxRetries     = [int](Resolve-ApiSetting -Config $Config -Name 'maxRetries'            -Default $script:DefaultMaxRetries)
    $baseDelaySec   = [int](Resolve-ApiSetting -Config $Config -Name 'retryBaseDelaySeconds' -Default $script:DefaultRetryBaseDelaySeconds)
    $maxDelaySec    = [int](Resolve-ApiSetting -Config $Config -Name 'retryMaxDelaySeconds'  -Default $script:DefaultRetryMaxDelaySeconds)
    $httpTimeoutSec = [int](Resolve-ApiSetting -Config $Config -Name 'httpTimeoutSeconds'    -Default $script:DefaultHttpTimeoutSeconds)
    $endpointPath   = [string](Resolve-ApiSetting -Config $Config -Name 'graphqlEndpointPath' -Default $script:DefaultGraphQlEndpointPath)

    $retryableRaw = Resolve-ApiSetting -Config $Config -Name 'retryableStatusCodes' -Default $script:DefaultRetryableStatusCodes
    $retryable = @()
    foreach ($c in @($retryableRaw)) {
        $n = 0
        if ([int]::TryParse([string]$c, [ref]$n)) { $retryable += $n }
    }
    if ($retryable.Count -eq 0) { $retryable = $script:DefaultRetryableStatusCodes }

    # --- Resolve seams -------------------------------------------------------
    $sleepAction = if ($Sleep) { $Sleep } else { { param($sec) Start-Sleep -Seconds $sec } }
    $tokenAction = if ($TokenProvider) { $TokenProvider } else {
        {
            param($h)
            $getToken = Get-Command -Name 'Get-OAuthToken' -ErrorAction SilentlyContinue
            if (-not $getToken) { throw 'Invoke-GraphQL: Get-OAuthToken is not available (Auth.psm1 not imported).' }
            & $getToken -Hotel $h
        }
    }

    # --- Ensure we have a token ---------------------------------------------
    $currentToken = $Token
    if ([string]::IsNullOrWhiteSpace($currentToken)) {
        $currentToken = [string](& $tokenAction $Hotel)
    }

    # --- Build endpoint URI + JSON body -------------------------------------
    $uri = ('{0}{1}' -f $gatewayUrl.TrimEnd('/'), ('/{0}' -f $endpointPath.TrimStart('/')))
    $bodyObject = @{ query = $Query; variables = $Variables }
    $bodyJson = $bodyObject | ConvertTo-Json -Depth 12 -Compress

    # State across the retry loop.
    $reauthAttempted = $false     # 401 -> clear+reauth+retry is allowed exactly once
    $transientRetries = 0         # count of 429/5xx retries consumed (<= maxRetries)
    $attemptNo = 0                # total loop iterations (for logging)

    while ($true) {
        $attemptNo++

        # A NEW x-request-id per attempt for end-to-end tracing (REQ-003).
        $requestId = [guid]::NewGuid().ToString()
        $headers = @{
            'Authorization' = ('Bearer {0}' -f $currentToken)
            'x-app-key'     = $apiKey
            'x-request-id'  = $requestId
            'Content-Type'  = 'application/json'
            'Accept'        = $script:DefaultAcceptHeader
        }
        # x-hotelid is optional for R&A; include for OHIP consistency (REQ-003 SHOULD).
        if (-not [string]::IsNullOrWhiteSpace($hotelCode)) {
            $headers['x-hotelid'] = $hotelCode
        }

        $requestArgs = @{
            Uri        = $uri
            Method     = 'Post'
            Headers    = $headers
            Body       = $bodyJson
            TimeoutSec = $httpTimeoutSec
        }

        Write-ApiLog -Level DEBUG -HotelCode $hotelCode -Message ("GraphQL POST {0} (request-id={1}, attempt={2})" -f $uri, $requestId, $attemptNo)

        $rawResult = $null
        $caught = $null
        try {
            if ($Invoker) {
                $rawResult = & $Invoker $requestArgs
            }
            else {
                $rawResult = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers `
                    -Body $bodyJson -TimeoutSec $httpTimeoutSec -ErrorAction Stop
            }
        }
        catch {
            $caught = $_
        }

        if ($null -ne $caught) {
            $status = Get-HttpStatusFromError -ErrorObject $caught

            # --- 401: clear cache, re-auth once, retry once ------------------
            if ($status -eq 401) {
                if ($reauthAttempted) {
                    Write-ApiLog -Level ERROR -HotelCode $hotelCode -Message 'HTTP 401 again after re-authentication. Aborting request.'
                    throw ("Invoke-GraphQL: HTTP 401 (unauthorized) persisted after re-authentication for hotel '{0}'." -f $hotelCode)
                }
                $reauthAttempted = $true
                Write-ApiLog -Level WARN -HotelCode $hotelCode -Message 'HTTP 401. Clearing token cache and re-authenticating (retry once).'

                $clearCmd = Get-Command -Name 'Clear-TokenCache' -ErrorAction SilentlyContinue
                if ($clearCmd) { & $clearCmd -HotelCode $hotelCode }

                $currentToken = [string](& $tokenAction $Hotel)
                continue   # retry immediately with the fresh token
            }

            # --- 429 / 5xx: exponential backoff ------------------------------
            if ($null -ne $status -and $retryable -contains $status) {
                if ($transientRetries -ge $maxRetries) {
                    Write-ApiLog -Level ERROR -HotelCode $hotelCode -Message ("HTTP {0} after {1} retries. Giving up." -f $status, $maxRetries)
                    throw ("Invoke-GraphQL: HTTP {0} persisted after {1} retries for hotel '{2}'." -f $status, $maxRetries, $hotelCode)
                }
                $transientRetries++
                $delay = Get-BackoffDelaySeconds -Attempt $transientRetries -BaseSeconds $baseDelaySec -CapSeconds $maxDelaySec
                Write-ApiLog -Level WARN -HotelCode $hotelCode -Message ("HTTP {0} (transient). Backoff {1}s then retry {2}/{3}." -f $status, $delay, $transientRetries, $maxRetries)
                & $sleepAction $delay
                continue
            }

            # --- Non-retryable / unknown failure -----------------------------
            $statusText = if ($null -ne $status) { "HTTP $status" } else { 'network/transport error' }
            Write-ApiLog -Level ERROR -HotelCode $hotelCode -Message ("GraphQL request failed ({0}): {1}" -f $statusText, $caught.Exception.Message)
            throw ("Invoke-GraphQL: request failed for hotel '{0}' ({1}): {2}" -f $hotelCode, $statusText, $caught.Exception.Message)
        }

        # --- Success transport: normalise to a response object ---------------
        $response = ConvertFrom-WebResult -RawResult $rawResult

        # --- Inspect the GraphQL errors array (REQ-011) ----------------------
        $errorsArray = $null
        if ($null -ne $response) {
            $errProp = $response.PSObject.Properties['errors']
            if ($errProp) { $errorsArray = $errProp.Value }
        }

        $hasData = $false
        if ($null -ne $response) {
            $dataProp = $response.PSObject.Properties['data']
            if ($dataProp -and $null -ne $dataProp.Value) { $hasData = $true }
        }

        if ($null -ne $errorsArray -and @($errorsArray).Count -gt 0) {
            foreach ($gqlErr in @($errorsArray)) {
                $msg = if ($gqlErr.PSObject.Properties['message']) { [string]$gqlErr.message } else { [string]$gqlErr }
                if ($hasData) {
                    # Partial data present -> WARN and continue (REQ-011).
                    Write-ApiLog -Level WARN -HotelCode $hotelCode -Message ("GraphQL partial error (data present): {0}" -f $msg)
                }
                else {
                    Write-ApiLog -Level ERROR -HotelCode $hotelCode -Message ("GraphQL error (data null): {0}" -f $msg)
                }
            }
            if (-not $hasData) {
                throw ("Invoke-GraphQL: GraphQL response for hotel '{0}' returned errors with null data." -f $hotelCode)
            }
        }

        return $response
    }
}

function ConvertFrom-WebResult {
    <#
    .SYNOPSIS
        Internal: normalises a transport result into a deserialized GraphQL response object.

    .DESCRIPTION
        Accepts:
          * A BasicHtmlWebResponseObject / WebResponseObject from Invoke-WebRequest
            (exposes .Content JSON string).
          * A seam-supplied @{ StatusCode; Content } hashtable/object.
          * An already-deserialized object (returned as-is).
        Returns a PSCustomObject with .data / .errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] $RawResult
    )

    if ($null -eq $RawResult) { return $null }

    # Extract a JSON content string if one is present.
    $content = $null
    $contentProp = $RawResult.PSObject.Properties['Content']
    if ($contentProp -and $null -ne $contentProp.Value) {
        $content = $contentProp.Value
    }

    if ($null -ne $content) {
        if ($content -is [string]) {
            if ([string]::IsNullOrWhiteSpace($content)) { return $null }
            return ($content | ConvertFrom-Json -Depth 64)
        }
        # Content already an object (seam convenience).
        return $content
    }

    # No .Content — assume the caller handed us a deserialized response directly.
    return $RawResult
}

# ------------------------------------------------------------------------------
# Public: Invoke-RASubjectArea
# ------------------------------------------------------------------------------
function Invoke-RASubjectArea {
    <#
    .SYNOPSIS
        Executes a GraphQL Subject Area query across pre-chunked date ranges and returns
        one flattened [array] of normalised [PSCustomObject] rows.

    .DESCRIPTION
        design.md ApiClient.psm1 — Invoke-RASubjectArea flow:
          1. Date chunking is handled by the CALLER (Query modules via Get-DateRangeChunks).
             This function accepts either:
               -Chunks         : an array of pre-built @{ Variables = <hashtable> } (or a
                                 hashtable used directly as the GraphQL variables) — one
                                 GraphQL call per element; OR
               -Variables      : a single variables set (one call), for callers that do not
                                 chunk (e.g. static master data).
          2. For each chunk: call Invoke-GraphQL.
          3. Extract the data array from response.data.<Operation>.<PrimaryView>.
          4. Throttle: Start-Sleep -Milliseconds requestDelayMs BETWEEN calls (not after
             the last one).
          5. Accumulate all chunk rows -> return a single flattened [array].

        PAGINATION RECONCILIATION (REQ-011): the R&A API has no cursor/offset pagination;
        the date-chunk loop IS the "pagination loop". A response nextPageToken is honoured
        DEFENSIVELY: if a chunk response ever exposes data.<Operation>.nextPageToken (or a
        top-level nextPageToken), the same chunk is re-requested with that token merged into
        its variables until the token is absent — so the code is forward-compatible without
        depending on paging that the current API does not implement.

    .PARAMETER Hotel
        Hotel config (hashtable / PSCustomObject).

    .PARAMETER Operation
        The GraphQL operation name (camelCase), e.g. 'statisticsReservationsDaily'.
        Used to locate response.data.<Operation>.

    .PARAMETER PrimaryView
        The primary view name under the operation whose array of rows is collected,
        e.g. 'reservationDailyStatisticsDetails'. When omitted, the first array-valued
        property under data.<Operation> is used.

    .PARAMETER Query
        The GraphQL query string (same for every chunk).

    .PARAMETER Chunks
        Array of per-chunk inputs. Each element is either a hashtable of GraphQL variables,
        or a hashtable/object with a .Variables property. Mutually exclusive with -Variables.

    .PARAMETER Variables
        A single GraphQL variables set (single call). Mutually exclusive with -Chunks.

    .PARAMETER Token
        Optional bearer token passed through to Invoke-GraphQL.

    .PARAMETER Config
        Optional settings object supplying api.requestDelayMs and retry settings.

    .PARAMETER Invoker
        Test/DI seam forwarded to Invoke-GraphQL.

    .PARAMETER TokenProvider
        Test/DI seam forwarded to Invoke-GraphQL.

    .PARAMETER Sleep
        Test/DI seam replacing Start-Sleep for BOTH the throttle and (via Invoke-GraphQL)
        backoff waits. Receives seconds. Note the throttle is specified in milliseconds and
        is passed to this action as seconds (ms/1000) so a single seam covers both.

    .OUTPUTS
        [array] of [PSCustomObject] — all chunk rows flattened into one array.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Chunks')]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] $Hotel,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Operation,
        [Parameter()] [string] $PrimaryView,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Query,

        [Parameter(ParameterSetName = 'Chunks')] [object[]] $Chunks,
        [Parameter(ParameterSetName = 'Single')] [hashtable] $Variables,

        [Parameter()] [string] $Token,
        [Parameter()] $Config,
        [Parameter()] [scriptblock] $Invoker,
        [Parameter()] [scriptblock] $TokenProvider,
        [Parameter()] [scriptblock] $Sleep
    )

    $hotelCode = [string](Get-CfgValue -Source $Hotel -Names @('HotelCode', 'hotelCode'))

    # Normalise the work list into an array of variables hashtables.
    $variableSets = @()
    if ($PSCmdlet.ParameterSetName -eq 'Single') {
        $variableSets = @( ($Variables ?? @{}) )
    }
    else {
        foreach ($chunk in @($Chunks)) {
            if ($null -eq $chunk) { continue }
            if ($chunk -is [hashtable]) {
                # A hashtable with an explicit .Variables key, else the hashtable itself.
                if ($chunk.ContainsKey('Variables')) {
                    $variableSets += ,([hashtable]$chunk['Variables'])
                }
                else {
                    $variableSets += ,([hashtable]$chunk)
                }
            }
            else {
                $vProp = $chunk.PSObject.Properties['Variables']
                if ($vProp -and $null -ne $vProp.Value) {
                    $variableSets += ,([hashtable]$vProp.Value)
                }
                else {
                    throw 'Invoke-RASubjectArea: each -Chunks element must be a variables hashtable or expose a .Variables hashtable.'
                }
            }
        }
    }

    if ($variableSets.Count -eq 0) {
        Write-ApiLog -Level WARN -HotelCode $hotelCode -Message ("No chunks/variables supplied for operation '{0}'. Returning empty result." -f $Operation)
        return @()
    }

    # Throttle (ms) resolved once; passed to the sleep seam as seconds so a single seam
    # covers throttle + backoff.
    $requestDelayMs = [int](Resolve-ApiSetting -Config $Config -Name 'requestDelayMs' -Default $script:DefaultRequestDelayMs)
    $sleepAction = if ($Sleep) { $Sleep } else { { param($sec) Start-Sleep -Seconds $sec } }

    $accumulated = [System.Collections.Generic.List[object]]::new()
    $chunkIndex = 0

    foreach ($vars in $variableSets) {
        $chunkIndex++

        # Per-request throttle BETWEEN calls (not before the first). REQ-011.
        if ($chunkIndex -gt 1 -and $requestDelayMs -gt 0) {
            Write-ApiLog -Level DEBUG -HotelCode $hotelCode -Message ("Throttle {0}ms before chunk {1}/{2}." -f $requestDelayMs, $chunkIndex, $variableSets.Count)
            & $sleepAction ([double]$requestDelayMs / 1000.0)
        }

        # Defensive nextPageToken loop (see reconciliation note). Normally runs once.
        $pageVars = [hashtable]$vars
        $pageGuard = 0
        while ($true) {
            $pageGuard++
            if ($pageGuard -gt 10000) {
                throw ("Invoke-RASubjectArea: pagination guard tripped for operation '{0}' (possible non-terminating nextPageToken)." -f $Operation)
            }

            $gqlArgs = @{
                Hotel     = $Hotel
                Query     = $Query
                Variables = $pageVars
                Config    = $Config
            }
            if ($PSBoundParameters.ContainsKey('Token') -and -not [string]::IsNullOrWhiteSpace($Token)) { $gqlArgs['Token'] = $Token }
            if ($Invoker)       { $gqlArgs['Invoker'] = $Invoker }
            if ($TokenProvider) { $gqlArgs['TokenProvider'] = $TokenProvider }
            if ($Sleep)         { $gqlArgs['Sleep'] = $Sleep }

            $response = Invoke-GraphQL @gqlArgs

            $rows, $nextPageToken = Get-SubjectAreaRows -Response $response -Operation $Operation -PrimaryView $PrimaryView
            foreach ($row in @($rows)) { [void]$accumulated.Add($row) }

            Write-ApiLog -Level DEBUG -HotelCode $hotelCode -Message ("Chunk {0}/{1}: collected {2} row(s)." -f $chunkIndex, $variableSets.Count, @($rows).Count)

            if ([string]::IsNullOrWhiteSpace($nextPageToken)) { break }

            # Forward-compatible paging: merge the token and re-request the same chunk.
            $pageVars = @{} + $pageVars
            $pageVars['nextPageToken'] = $nextPageToken
            Write-ApiLog -Level DEBUG -HotelCode $hotelCode -Message ("nextPageToken present for chunk {0}; requesting next page." -f $chunkIndex)
        }
    }

    Write-ApiLog -Level INFO -HotelCode $hotelCode -Message ("Operation '{0}' collected {1} row(s) across {2} chunk(s)." -f $Operation, $accumulated.Count, $variableSets.Count)

    # Return a normalised flat [array] of PSCustomObject.
    #
    # Use the unary comma operator so a SINGLE-element result is still returned as a
    # real [object[]] and not unwrapped to a scalar by PowerShell's output pipeline.
    # Callers therefore always receive an [array] as the contract promises (Task 5:
    # "Return a normalised [array]"). $result.Count / foreach behave consistently for
    # 0, 1, and N rows.
    $flat = [object[]]$accumulated.ToArray()
    return , $flat
}

function Get-SubjectAreaRows {
    <#
    .SYNOPSIS
        Internal: extracts (rows, nextPageToken) from a GraphQL response for a Subject Area.

    .DESCRIPTION
        Navigates response.data.<Operation>.<PrimaryView>. When -PrimaryView is omitted,
        selects the first array-valued property under data.<Operation>. Returns a two-element
        array: the row array (as [array]) and a nextPageToken string ($null when absent).
        A top-level data.<Operation>.nextPageToken (or data.nextPageToken) is surfaced
        defensively for the forward-compatible paging loop.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] $Response,
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter()] [string] $PrimaryView
    )

    $emptyResult = @( @(), $null )
    if ($null -eq $Response) { return $emptyResult }

    $dataProp = $Response.PSObject.Properties['data']
    if (-not $dataProp -or $null -eq $dataProp.Value) { return $emptyResult }
    $data = $dataProp.Value

    $opProp = $data.PSObject.Properties | Where-Object { $_.Name -ieq $Operation } | Select-Object -First 1
    if (-not $opProp -or $null -eq $opProp.Value) {
        # Defensive: token may sit at the top of data.
        $topToken = $null
        $ttProp = $data.PSObject.Properties['nextPageToken']
        if ($ttProp) { $topToken = [string]$ttProp.Value }
        return @( @(), $topToken )
    }
    $opNode = $opProp.Value

    # nextPageToken (defensive) under the operation node.
    $nextPageToken = $null
    $tokenProp = $opNode.PSObject.Properties['nextPageToken']
    if ($tokenProp -and $null -ne $tokenProp.Value) { $nextPageToken = [string]$tokenProp.Value }

    # Locate the row array: explicit PrimaryView, else first array-valued property.
    $rows = @()
    if (-not [string]::IsNullOrWhiteSpace($PrimaryView)) {
        $pvProp = $opNode.PSObject.Properties | Where-Object { $_.Name -ieq $PrimaryView } | Select-Object -First 1
        if ($pvProp -and $null -ne $pvProp.Value) { $rows = @($pvProp.Value) }
    }
    else {
        foreach ($p in $opNode.PSObject.Properties) {
            if ($p.Name -ieq 'nextPageToken') { continue }
            if ($null -ne $p.Value -and ($p.Value -is [System.Collections.IEnumerable]) -and ($p.Value -isnot [string])) {
                $rows = @($p.Value)
                break
            }
        }
    }

    return @( $rows, $nextPageToken )
}

# ------------------------------------------------------------------------------
# Public: Invoke-RAApi  (documented Task 5 entry point — thin wrapper over Invoke-GraphQL)
# ------------------------------------------------------------------------------
function Invoke-RAApi {
    <#
    .SYNOPSIS
        Public entry point for a single R&A GraphQL request (Task 5 "Invoke-RAApi").

    .DESCRIPTION
        DESIGN RECONCILIATION: the Task 5 subtask names this "Invoke-RAApi" using REST-style
        vocabulary, but the real OHIP R&A API is GraphQL. This function is therefore a thin
        wrapper over Invoke-GraphQL, which performs the actual GraphQL POST with the required
        header injection (Authorization/x-app-key/x-request-id/Content-Type/Accept/x-hotelid),
        401 clear+reauth+retry-once, and 429/5xx exponential backoff. All parameters are
        forwarded verbatim. Prefer Invoke-RASubjectArea for multi-chunk accumulation.

    .OUTPUTS
        [PSCustomObject] the deserialized GraphQL response (.data / .errors).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] $Hotel,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Query,
        [Parameter()] [hashtable] $Variables = @{},
        [Parameter()] [string] $Token,
        [Parameter()] $Config,
        [Parameter()] [scriptblock] $Invoker,
        [Parameter()] [scriptblock] $TokenProvider,
        [Parameter()] [scriptblock] $Sleep
    )

    $forward = @{
        Hotel     = $Hotel
        Query     = $Query
        Variables = $Variables
    }
    if ($PSBoundParameters.ContainsKey('Token'))   { $forward['Token'] = $Token }
    if ($PSBoundParameters.ContainsKey('Config'))  { $forward['Config'] = $Config }
    if ($Invoker)       { $forward['Invoker'] = $Invoker }
    if ($TokenProvider) { $forward['TokenProvider'] = $TokenProvider }
    if ($Sleep)         { $forward['Sleep'] = $Sleep }

    return Invoke-GraphQL @forward
}

# ------------------------------------------------------------------------------
# Exported surface
# ------------------------------------------------------------------------------
Export-ModuleMember -Function @(
    'Invoke-GraphQL',
    'Invoke-RASubjectArea',
    'Invoke-RAApi'
)
