# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    OAuth 2.0 token lifecycle manager for the OPERA R&A Data Loader (OHIP / OCIM).

.DESCRIPTION
    Manages per-hotel OAuth 2.0 bearer tokens obtained from the OHIP Gateway OAuth
    endpoint using the client_credentials grant (REQ-003). Tokens are cached
    in-memory, keyed by HotelCode, and reused until they approach expiry so the loader
    does not request a fresh token on every API call.

    Module-level state (shared across all callers in the process):
      $script:TokenCache  — hashtable keyed by HotelCode. Each value is a hashtable of
                            the form @{ Token = <string>; ExpiresAt = <datetime UTC> }
                            where ExpiresAt is the absolute UTC instant the token stops
                            being valid (Now + expires_in at acquisition time).

    Flow (design.md — Auth.psm1):
      1. Check cache: ExpiresAt > (UtcNow + SafetyMarginSeconds) -> return cached token.
      2. If missing/expired: POST <gatewayUrl>/oauth/token
             Content-Type: application/x-www-form-urlencoded
             Body: grant_type=client_credentials
                   &client_id=<ClientId>
                   &client_secret=<ClientSecret>
                   &scope=urn:opc:hgbu:ws:_myscopes_
      3. Parse access_token + expires_in -> store in cache with
         ExpiresAt = UtcNow + expires_in.
      4. ClientId and ClientSecret are decrypted from the DPAPI-encrypted hotel config
         immediately before use and are NEVER written to any log or verbose stream.

    Credential handling (REQ-002):
      ClientId/ClientSecret are stored DPAPI-encrypted in the hotel config. They are
      decrypted immediately before building the token request, converted to plaintext
      only in-memory for the POST body, and the plaintext is cleared as soon as the
      request has been built. Neither the credentials nor the resulting bearer token are
      ever emitted to the log or the verbose/debug streams.

      Encrypted values are self-describing. Tools\Protect-HotelsConfig.ps1 produces one
      of two tagged forms and the decryptor reverses whichever it finds; it also accepts
      legacy untagged values for backward compatibility:
        "DPAPI:CU:v1:<base64>"  ProtectedData CurrentUser  scope + app entropy
        "DPAPI:LM:v1:<base64>"  ProtectedData LocalMachine scope + app entropy
        <legacy untagged hex>   old ConvertFrom-SecureString (CurrentUser DPAPI)

.NOTES
    Module name constant for Logger -Module parameter: "Auth"
#>

# ------------------------------------------------------------------------------
# Module-level state
# ------------------------------------------------------------------------------

# In-memory OAuth token cache, keyed by HotelCode.
#
#   Key    : [string]    HotelCode (e.g. 'HOTEL1')
#   Value  : [hashtable] @{
#                Token     = [string]   the bearer access_token
#                ExpiresAt = [datetime] absolute UTC expiry instant
#                                       (acquisition time + expires_in seconds)
#            }
#
# The cache lives for the lifetime of the module (the process/session). Entries are
# added when a token is acquired, read (with an expiry/safety-margin check) on reuse,
# and removed by Clear-TokenCache (e.g. after an HTTP 401 forces re-authentication).
$script:TokenCache = @{}

# Default safety margin (seconds) applied to the cached-token expiry check when the
# caller does not supply one and the hotel/settings config does not specify it.
# REQ-003: default 60 seconds before expiry, configurable.
$script:DefaultSafetyMarginSeconds = 60

# The fixed OAuth scope required on every OHIP token request (REQ-003).
$script:DefaultOAuthScope = 'urn:opc:hgbu:ws:_myscopes_'

# ------------------------------------------------------------------------------
# Self-describing DPAPI scheme constants (credential decryption).
#
# KEEP IN SYNC with Tools\Protect-HotelsConfig.ps1 (Protect-DpapiValue). If you change
# the tag prefixes or the entropy salt here, change them there too, or values encrypted
# by the tool will stop decrypting at runtime.
#
# Tagged format:  "DPAPI:<scope>:v1:<base64>"
#   <scope>  = 'CU' (CurrentUser) | 'LM' (LocalMachine)
#   <base64> = Base64( ProtectedData.Protect( UTF8(plaintext), entropy, scope ) )
# ------------------------------------------------------------------------------
$script:DpapiTagCurrentUser  = 'DPAPI:CU:v1:'
$script:DpapiTagLocalMachine = 'DPAPI:LM:v1:'
# App-specific optionalEntropy: fixed bytes of a constant app salt string.
$script:DpapiEntropy = [System.Text.Encoding]::UTF8.GetBytes('OperaRADataLoader/v1')

# ------------------------------------------------------------------------------
# Logging helper
#
# Auth uses the shared Logger module's Write-Log when it is loaded, but must not
# hard-fail if the logger has not been imported (e.g. isolated unit tests). This
# wrapper resolves Write-Log at call time and degrades to Write-Verbose otherwise.
# The token, ClientId, and ClientSecret are NEVER passed to this helper.
# ------------------------------------------------------------------------------
function Write-AuthLog {
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
            & $writeLog -Level $Level -Module 'Auth' -Message $Message -HotelCode $HotelCode
            return
        }
        catch {
            # Fall through to verbose so a logger failure never breaks auth.
        }
    }

    Write-Verbose ("Auth [{0}] {1}: {2}" -f $Level, $HotelCode, $Message)
}

# ------------------------------------------------------------------------------
# Internal config helpers
# ------------------------------------------------------------------------------

function Get-HotelValue {
    <#
    .SYNOPSIS
        Internal: case-insensitive lookup of a value from the hotel config.

    .DESCRIPTION
        The hotel config originates from JSON (camelCase keys) but callers may pass a
        hashtable or a PSCustomObject with either casing. This resolves a value by
        trying each candidate name against both hashtable keys and object properties.

    .PARAMETER Hotel
        The hotel config (hashtable or PSCustomObject).

    .PARAMETER Names
        Candidate property/key names to try, in order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Hotel,

        [Parameter(Mandatory)]
        [string[]] $Names
    )

    foreach ($name in $Names) {
        if ($Hotel -is [System.Collections.IDictionary]) {
            foreach ($key in $Hotel.Keys) {
                if ($key -ieq $name) {
                    return $Hotel[$key]
                }
            }
        }
        else {
            $prop = $Hotel.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
            if ($prop) {
                return $prop.Value
            }
        }
    }

    return $null
}

function Unprotect-DpapiValue {
    <#
    .SYNOPSIS
        Internal: decrypts a DPAPI-encrypted string into plaintext, in-memory only.

    .DESCRIPTION
        Reverses whichever encryption scheme the value carries, so the loader can read a
        hotels.json produced by Tools\Protect-HotelsConfig.ps1 with either scope, and
        still read values written by the old scheme:

          - "DPAPI:CU:v1:<b64>" -> ProtectedData.Unprotect(CurrentUser, entropy)
          - "DPAPI:LM:v1:<b64>" -> ProtectedData.Unprotect(LocalMachine, entropy)
          - legacy untagged hex  -> ConvertTo-SecureString (CurrentUser DPAPI)

        The plaintext lives only in a local variable and the caller is responsible for
        discarding it promptly.

        REQ-002: the decrypted value is never logged. On any decryption failure a generic,
        scheme-aware error is thrown that does not include the encrypted or decrypted
        material.

    .PARAMETER EncryptedValue
        The DPAPI-encrypted string (tagged or legacy).

    .PARAMETER FieldName
        A non-sensitive field label used only for error messages (e.g. 'ClientId').

    .OUTPUTS
        [string] plaintext value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $EncryptedValue,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FieldName
    )

    $secure = $null
    $bstr = [IntPtr]::Zero
    $cipherBytes = $null
    $plainBytes = $null
    try {
        if ($EncryptedValue.StartsWith($script:DpapiTagCurrentUser) -or
            $EncryptedValue.StartsWith($script:DpapiTagLocalMachine)) {

            $isLocalMachine = $EncryptedValue.StartsWith($script:DpapiTagLocalMachine)
            $tag = if ($isLocalMachine) { $script:DpapiTagLocalMachine } else { $script:DpapiTagCurrentUser }
            $dpScope = if ($isLocalMachine) {
                [System.Security.Cryptography.DataProtectionScope]::LocalMachine
            }
            else {
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            }

            $b64 = $EncryptedValue.Substring($tag.Length)
            $cipherBytes = [System.Convert]::FromBase64String($b64)
            $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $cipherBytes, $script:DpapiEntropy, $dpScope)
            return [System.Text.Encoding]::UTF8.GetString($plainBytes)
        }

        # Legacy untagged value produced by the old ConvertFrom-SecureString scheme.
        $secure = ConvertTo-SecureString -String $EncryptedValue -ErrorAction Stop
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    catch {
        # Never surface the encrypted or decrypted material in the error.
        throw ("Failed to decrypt credential field '{0}'. For LocalMachine-protected values ensure the loader runs on the SAME host that ran Protect-HotelsConfig.ps1; for CurrentUser values ensure the SAME user + host." -f $FieldName)
    }
    finally {
        if ($null -ne $plainBytes) { [System.Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if ($secure) {
            $secure.Dispose()
        }
    }
}

# ------------------------------------------------------------------------------
# Internal cache helpers
#
# These keep the cache shape (@{ Token; ExpiresAt }) in one place so the token
# acquisition, expiry-check, and clear sub-tasks all read/write it consistently.
# Not exported — internal to the module.
# ------------------------------------------------------------------------------

function Set-TokenCacheEntry {
    <#
    .SYNOPSIS
        Internal: stores (or replaces) a token cache entry for a hotel.

    .DESCRIPTION
        Writes an entry of the form @{ Token; ExpiresAt } into $script:TokenCache
        keyed by HotelCode. ExpiresAt is normalised to a UTC-kind [datetime] so all
        expiry comparisons in the module operate in UTC regardless of the caller's
        DateTimeKind.

        The token value itself is never logged.

    .PARAMETER HotelCode
        The hotel code that keys the cache entry.

    .PARAMETER Token
        The bearer access_token string to cache.

    .PARAMETER ExpiresAt
        The absolute instant the token expires. Coerced to UTC kind:
          Utc         -> used as-is
          Local       -> converted to UTC
          Unspecified -> treated as UTC
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $HotelCode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Token,

        [Parameter(Mandatory)]
        [datetime] $ExpiresAt
    )

    $expiresAtUtc = switch ($ExpiresAt.Kind) {
        ([System.DateTimeKind]::Utc)   { $ExpiresAt }
        ([System.DateTimeKind]::Local) { $ExpiresAt.ToUniversalTime() }
        default                        { [datetime]::SpecifyKind($ExpiresAt, [System.DateTimeKind]::Utc) }
    }

    $script:TokenCache[$HotelCode] = @{
        Token     = $Token
        ExpiresAt = $expiresAtUtc
    }

    # NOTE: never log $Token. ExpiresAt only (no secret material).
    Write-Verbose ("Auth: cached token for hotel '{0}' expiring {1:yyyy-MM-dd HH:mm:ss}Z." -f $HotelCode, $expiresAtUtc)
}

function Get-TokenCacheEntry {
    <#
    .SYNOPSIS
        Internal: retrieves the raw cache entry for a hotel, or $null when absent.

    .DESCRIPTION
        Returns the stored @{ Token; ExpiresAt } hashtable for the given HotelCode, or
        $null when no entry exists. Performs no expiry evaluation — the expiry/safety-
        margin check is applied by the token acquisition sub-task.

    .PARAMETER HotelCode
        The hotel code whose cache entry to retrieve.

    .OUTPUTS
        [hashtable] @{ Token; ExpiresAt } or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $HotelCode
    )

    if ($script:TokenCache.ContainsKey($HotelCode)) {
        return $script:TokenCache[$HotelCode]
    }

    return $null
}

function Test-TokenCacheEntryValid {
    <#
    .SYNOPSIS
        Internal: evaluates whether a cache entry is still usable given a safety margin.

    .DESCRIPTION
        Implements the design.md flow step 1 expiry rule:

            ExpiresAt > (UtcNow + SafetyMarginSeconds)

        A cached token is reused only while its absolute UTC expiry is strictly beyond
        the safety horizon (now plus the margin), so the loader refreshes slightly ahead
        of the real expiry and never presents a token that is about to expire mid-request.

    .PARAMETER Entry
        The cache entry hashtable (@{ Token; ExpiresAt }) or $null.

    .PARAMETER SafetyMarginSeconds
        Seconds before real expiry at which the token is considered stale.

    .PARAMETER Now
        Optional reference "now" (UTC). Defaults to [datetime]::UtcNow. Present so the
        expiry logic is deterministically testable.

    .OUTPUTS
        [bool] $true when the entry exists, has a token, and is not within the margin.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [hashtable] $Entry,

        [Parameter(Mandatory)]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $SafetyMarginSeconds,

        [Parameter()]
        [datetime] $Now = [datetime]::UtcNow
    )

    if ($null -eq $Entry) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Entry.Token)) { return $false }
    if ($null -eq $Entry.ExpiresAt) { return $false }

    # Normalise the reference instant and the stored expiry to UTC for comparison.
    $nowUtc = switch ($Now.Kind) {
        ([System.DateTimeKind]::Utc)   { $Now }
        ([System.DateTimeKind]::Local) { $Now.ToUniversalTime() }
        default                        { [datetime]::SpecifyKind($Now, [System.DateTimeKind]::Utc) }
    }

    $expiresAt = [datetime]$Entry.ExpiresAt
    $expiresAtUtc = switch ($expiresAt.Kind) {
        ([System.DateTimeKind]::Utc)   { $expiresAt }
        ([System.DateTimeKind]::Local) { $expiresAt.ToUniversalTime() }
        default                        { [datetime]::SpecifyKind($expiresAt, [System.DateTimeKind]::Utc) }
    }

    $horizon = $nowUtc.AddSeconds($SafetyMarginSeconds)
    return ($expiresAtUtc -gt $horizon)
}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

function Get-OAuthToken {
    <#
    .SYNOPSIS
        Returns a valid OAuth 2.0 bearer token for a hotel, using the in-memory cache.

    .DESCRIPTION
        Implements the design.md Auth.psm1 flow (REQ-003):

          1. Look up the cached entry for the hotel. If it is still valid under the
             safety-margin rule (ExpiresAt > UtcNow + SafetyMarginSeconds), return the
             cached token without contacting the OAuth endpoint.
          2. Otherwise POST the client_credentials grant to
             <gatewayUrl>/oauth/token with
                 Content-Type: application/x-www-form-urlencoded
                 body: grant_type=client_credentials
                       &client_id=<ClientId>&client_secret=<ClientSecret>
                       &scope=urn:opc:hgbu:ws:_myscopes_
          3. Parse access_token + expires_in and cache it with
             ExpiresAt = UtcNow + expires_in via Set-TokenCacheEntry.

        Credential handling (REQ-002): ClientId/ClientSecret are DPAPI-encrypted in the
        hotel config. They are decrypted immediately before building the request body,
        used only in-memory, and cleared right after. Neither the credentials nor the
        token are ever written to a log or verbose/debug stream. The client_id and
        client_secret are URL-encoded when placed in the form body.

    .PARAMETER Hotel
        Hotel configuration (hashtable or PSCustomObject). Recognised keys
        (case-insensitive): HotelCode, GatewayUrl, ClientId (DPAPI), ClientSecret (DPAPI),
        and optionally OAuthScope / TokenSafetyMarginSeconds overrides.

    .PARAMETER SafetyMarginSeconds
        Seconds before real expiry at which a cached token is treated as stale.
        Defaults to the hotel/settings value if present, otherwise 60 (REQ-003).

    .PARAMETER Scope
        The OAuth scope. Defaults to the fixed OHIP scope 'urn:opc:hgbu:ws:_myscopes_'.

    .PARAMETER ForceRefresh
        Bypass the cache and always acquire a fresh token.

    .PARAMETER TokenRequest
        Optional scriptblock used INSTEAD of Invoke-RestMethod to perform the token POST.
        It receives a single hashtable argument (@{ Uri; Body; Headers; TimeoutSec }) and
        must return an object exposing access_token and expires_in. This is the seam used
        by unit tests to inject a mocked token response without network access; production
        callers omit it and the real OAuth endpoint is called.

    .OUTPUTS
        [string] the bearer access_token.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Hotel,

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [Nullable[int]] $SafetyMarginSeconds,

        [Parameter()]
        [string] $Scope,

        [Parameter()]
        [switch] $ForceRefresh,

        [Parameter()]
        [scriptblock] $TokenRequest
    )

    # --- Resolve required config (case-insensitive) --------------------------
    $hotelCode = [string](Get-HotelValue -Hotel $Hotel -Names @('HotelCode', 'hotelCode'))
    if ([string]::IsNullOrWhiteSpace($hotelCode)) {
        throw 'Get-OAuthToken: Hotel config is missing a HotelCode.'
    }

    $gatewayUrl = [string](Get-HotelValue -Hotel $Hotel -Names @('GatewayUrl', 'gatewayUrl'))
    if ([string]::IsNullOrWhiteSpace($gatewayUrl)) {
        throw ("Get-OAuthToken: Hotel '{0}' config is missing a GatewayUrl." -f $hotelCode)
    }

    # Resolve the effective safety margin: explicit param > hotel config > default.
    $margin = $script:DefaultSafetyMarginSeconds
    if ($null -ne $SafetyMarginSeconds) {
        $margin = [int]$SafetyMarginSeconds
    }
    else {
        $cfgMargin = Get-HotelValue -Hotel $Hotel -Names @('TokenSafetyMarginSeconds', 'tokenSafetyMarginSeconds')
        $parsedMargin = 0
        if ($null -ne $cfgMargin -and [int]::TryParse([string]$cfgMargin, [ref]$parsedMargin) -and $parsedMargin -ge 0) {
            $margin = $parsedMargin
        }
    }

    # Resolve the OAuth scope: explicit param > hotel config > fixed default.
    $effectiveScope = $script:DefaultOAuthScope
    if (-not [string]::IsNullOrWhiteSpace($Scope)) {
        $effectiveScope = $Scope
    }
    else {
        $cfgScope = Get-HotelValue -Hotel $Hotel -Names @('OAuthScope', 'oauthScope')
        if (-not [string]::IsNullOrWhiteSpace([string]$cfgScope)) {
            $effectiveScope = [string]$cfgScope
        }
    }

    # --- Step 1: cache check -------------------------------------------------
    if (-not $ForceRefresh) {
        $cached = Get-TokenCacheEntry -HotelCode $hotelCode
        if (Test-TokenCacheEntryValid -Entry $cached -SafetyMarginSeconds $margin) {
            Write-AuthLog -Level DEBUG -HotelCode $hotelCode -Message 'Reusing cached OAuth token (within validity window).'
            return [string]$cached.Token
        }
    }

    # --- Step 2: acquire a fresh token --------------------------------------
    $tokenUri = ('{0}/oauth/token' -f $gatewayUrl.TrimEnd('/'))

    # Decrypt credentials in-memory only, immediately before building the body.
    $clientIdEnc = [string](Get-HotelValue -Hotel $Hotel -Names @('ClientId', 'clientId'))
    $clientSecretEnc = [string](Get-HotelValue -Hotel $Hotel -Names @('ClientSecret', 'clientSecret'))
    if ([string]::IsNullOrWhiteSpace($clientIdEnc)) {
        throw ("Get-OAuthToken: Hotel '{0}' config is missing an encrypted ClientId." -f $hotelCode)
    }
    if ([string]::IsNullOrWhiteSpace($clientSecretEnc)) {
        throw ("Get-OAuthToken: Hotel '{0}' config is missing an encrypted ClientSecret." -f $hotelCode)
    }

    $clientId = $null
    $clientSecret = $null
    $body = $null
    $httpTimeout = 120
    $cfgTimeout = Get-HotelValue -Hotel $Hotel -Names @('HttpTimeoutSeconds', 'httpTimeoutSeconds')
    $parsedTimeout = 0
    if ($null -ne $cfgTimeout -and [int]::TryParse([string]$cfgTimeout, [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
        $httpTimeout = $parsedTimeout
    }

    try {
        $clientId = Unprotect-DpapiValue -EncryptedValue $clientIdEnc -FieldName 'ClientId'
        $clientSecret = Unprotect-DpapiValue -EncryptedValue $clientSecretEnc -FieldName 'ClientSecret'

        # Build the application/x-www-form-urlencoded body. URL-encode each value so
        # secrets with reserved characters are transmitted safely. The body string
        # holds secret material and is discarded in the finally block.
        $body = ('grant_type=client_credentials&client_id={0}&client_secret={1}&scope={2}' -f `
            [System.Uri]::EscapeDataString($clientId),
            [System.Uri]::EscapeDataString($clientSecret),
            [System.Uri]::EscapeDataString($effectiveScope))

        $headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded' }

        Write-AuthLog -Level INFO -HotelCode $hotelCode -Message ('Requesting OAuth token from {0}' -f $tokenUri)

        $requestArgs = @{
            Uri        = $tokenUri
            Body       = $body
            Headers    = $headers
            TimeoutSec = $httpTimeout
        }

        if ($TokenRequest) {
            # Test/DI seam: caller supplies the transport. Never touches the network.
            $response = & $TokenRequest $requestArgs
        }
        else {
            $response = Invoke-RestMethod -Method Post -Uri $tokenUri -Headers $headers `
                -Body $body -ContentType 'application/x-www-form-urlencoded' `
                -TimeoutSec $httpTimeout -ErrorAction Stop
        }
    }
    catch {
        # Do not echo the body/credentials; only the (non-sensitive) failure reason.
        Write-AuthLog -Level ERROR -HotelCode $hotelCode -Message ('OAuth token request failed: {0}' -f $_.Exception.Message)
        throw ("Get-OAuthToken: token request failed for hotel '{0}': {1}" -f $hotelCode, $_.Exception.Message)
    }
    finally {
        # Scrub secret-bearing locals as soon as the request has been issued.
        if ($null -ne $clientId) { $clientId = $null }
        if ($null -ne $clientSecret) { $clientSecret = $null }
        if ($null -ne $body) { $body = $null }
        [System.GC]::Collect()
    }

    # --- Step 3: parse + cache ----------------------------------------------
    $accessToken = if ($null -ne $response) { [string]$response.access_token } else { $null }
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        Write-AuthLog -Level ERROR -HotelCode $hotelCode -Message 'OAuth response did not contain an access_token.'
        throw ("Get-OAuthToken: OAuth response for hotel '{0}' did not contain an access_token." -f $hotelCode)
    }

    # expires_in is seconds. Default to 3600 if the server omits it.
    $expiresIn = 3600
    if ($null -ne $response.expires_in) {
        $parsedExpiry = 0
        if ([int]::TryParse([string]$response.expires_in, [ref]$parsedExpiry) -and $parsedExpiry -gt 0) {
            $expiresIn = $parsedExpiry
        }
    }

    $expiresAt = [datetime]::UtcNow.AddSeconds($expiresIn)
    Set-TokenCacheEntry -HotelCode $hotelCode -Token $accessToken -ExpiresAt $expiresAt

    # REQ-003 / design.md example: log expiry only, never the token value.
    Write-AuthLog -Level INFO -HotelCode $hotelCode -Message ('Token acquired. ExpiresIn={0}s' -f $expiresIn)

    return $accessToken
}

function Clear-TokenCache {
    <#
    .SYNOPSIS
        Removes a hotel's cached token to force re-authentication (e.g. after HTTP 401).

    .DESCRIPTION
        Removes the entry for -HotelCode from $script:TokenCache so the next call to
        Get-OAuthToken re-authenticates against the OAuth endpoint. Used by the ApiClient
        HTTP 401 handler to recover from a rejected/stale token (REQ-003). Clearing a
        hotel that has no cached entry is a no-op and does not throw.

    .PARAMETER HotelCode
        The hotel code whose cached token should be cleared.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $HotelCode
    )

    if ($script:TokenCache.ContainsKey($HotelCode)) {
        [void]$script:TokenCache.Remove($HotelCode)
        Write-AuthLog -Level DEBUG -HotelCode $HotelCode -Message 'Cleared cached OAuth token (forced refresh).'
    }
    else {
        Write-AuthLog -Level DEBUG -HotelCode $HotelCode -Message 'Clear-TokenCache: no cached token to clear.'
    }
}

# ------------------------------------------------------------------------------
# Exported surface
# ------------------------------------------------------------------------------
Export-ModuleMember -Function @(
    'Get-OAuthToken',
    'Clear-TokenCache'
)
