# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Encrypts per-hotel credentials and the shared SMTP credentials for the OPERA R&A
    Data Loader using the Windows Data Protection API (DPAPI). (Task 14 / REQ-002 / REQ-016)

.DESCRIPTION
    Reads a plain-text credential input file (Config\hotels.input.json), DPAPI-encrypts
    every secret field, verifies each value round-trips (encrypt -> decrypt equals the
    original) and only then writes the encrypted Config\hotels.json. If any value fails
    to round-trip, the script ABORTS without writing the output file (fail safe — never
    emit partial or incorrect ciphertext).

    Secrets encrypted:
      Per hotel (hotels.input.json -> hotels.json):  clientId, clientSecret, apiKey
      Shared SMTP (settings.json, encrypted in place): smtp.username, smtp.password

    Encryption uses the .NET [System.Security.Cryptography.ProtectedData] API for BOTH
    scopes so they behave symmetrically. Each encrypted value is a SELF-DESCRIBING
    string carrying a scheme tag prefix so the runtime decryptor knows how to reverse
    it WITHOUT any extra config:

        "DPAPI:CU:v1:<base64>"   CurrentUser  scope (default)
        "DPAPI:LM:v1:<base64>"   LocalMachine scope (-Scope LocalMachine)

    where <base64> is the Base64 of the ProtectedData ciphertext bytes
    (UTF-8 plaintext -> bytes -> ProtectedData.Protect -> Base64). An app-specific
    optionalEntropy (fixed bytes of "OperaRADataLoader/v1") is passed to both Protect
    and Unprotect so not every process on the box can trivially decrypt LocalMachine
    values.

    Modules\Auth.psm1 (Unprotect-DpapiValue) decrypts these tagged values with the SAME
    tag constants and entropy salt, and ALSO falls back to the legacy untagged
    ConvertTo-SecureString path so values already in a deployed hotels.json keep working.

    NOTE (keep in sync): the tag constants and entropy salt below are duplicated in
    Modules\Auth.psm1. If you change them here, change them there too.

    Scope guidance:
      - CurrentUser  : ciphertext is decryptable only by the SAME Windows user on the
                       SAME host. Simplest; matches the historical behaviour.
      - LocalMachine : ciphertext is decryptable by ANY account on the SAME host
                       (recommended for service-account / gMSA setups where the person
                       running this tool differs from the loader's run-as identity).
      A LocalMachine value produced here is still host-bound — moving hosts requires
      re-encrypting.

    All other (non-secret) fields — otbFutureDays, blockFutureDays, nightAuditHour,
    timeZoneId, emailAlerts, gatewayUrl, hotelCode, chainCode, enterpriseId, etc. — are
    copied through VERBATIM.

    SECURITY: plaintext and ciphertext secret values are NEVER written to any log,
    verbose, or debug stream. Secrets are referenced by field name only.

.PARAMETER InputPath
    Plain-text per-hotel credential input. Default: Config\hotels.input.json (git-ignored).

.PARAMETER OutputPath
    Encrypted hotels config to write. Default: Config\hotels.json (git-ignored).

.PARAMETER SettingsPath
    settings.json holding the shared smtp.username / smtp.password. Default: Config\settings.json.
    The SMTP secrets are encrypted in place (the file is rewritten with ciphertext).

.PARAMETER Scope
    The DPAPI protection scope to encrypt with. One of:
      CurrentUser  (default) — decryptable only by the SAME Windows user on the SAME host.
      LocalMachine           — decryptable by ANY account on the SAME host (recommended
                               for service-account / gMSA setups).
    The chosen scope is embedded in each value's scheme tag, so decryption needs no extra
    config. Both scopes are host-bound; moving hosts requires re-encrypting.

.PARAMETER SkipSmtp
    Skip encrypting the shared SMTP credentials in settings.json (only process hotels).

.PARAMETER Force
    Overwrite an existing OutputPath without prompting.

.NOTES
    ── SERVICE ACCOUNT SETUP (READ THIS) ─────────────────────────────────────────────
    DPAPI ciphertext produced here is ALWAYS host-bound. The user binding depends on the
    chosen -Scope:

      -Scope CurrentUser  (default): decryptable only by the SAME Windows user on the
                          SAME host. Run this script logged on as (or `runas`) the exact
                          service account the loader runs as, on the loader's host.
      -Scope LocalMachine : decryptable by ANY account on the SAME host. You no longer
                          must run this tool as the exact service account — only on the
                          same host the loader runs on. Recommended when the loader runs
                          under a service account / gMSA that differs from the person
                          running this tool.

    Steps:
      1. Determine the service account the scheduled loader (Run-OperaRALoader.ps1) will
         run as (e.g. the Task Scheduler / SQL Agent identity), and the host it runs on.
      2. With -Scope CurrentUser: log on to THAT host AS THAT service account (or use
         `runas /user:<account>`) and run this script there. With -Scope LocalMachine:
         run it on THAT host under any account. Either way, running it on a DIFFERENT
         machine produces ciphertext the loader cannot decrypt.
      3. Copy Config\hotels.sample.json to Config\hotels.input.json, replace every
         REPLACE_ME placeholder with the real clientId / clientSecret / apiKey, and put
         the real smtp username / password into Config\settings.json.
      4. Run this script (see EXAMPLE). It writes the encrypted Config\hotels.json and
         rewrites Config\settings.json with encrypted smtp.username / smtp.password.
      5. hotels.input.json is git-ignored and MUST never be committed. Delete it after a
         successful run if you do not need to re-encrypt.

    This is Windows-only (DPAPI). On non-Windows hosts the script stops with an error.

.EXAMPLE
    # CurrentUser (default): run AS the loader's service account, ON the loader's host:
    pwsh -File .\Tools\Protect-HotelsConfig.ps1

.EXAMPLE
    # LocalMachine: run on the loader's host (any account); the loader's service account
    # can then decrypt without being the account that ran this tool:
    pwsh -File .\Tools\Protect-HotelsConfig.ps1 -Scope LocalMachine

.EXAMPLE
    # Custom paths, only the hotels file (skip SMTP), overwrite existing output:
    .\Tools\Protect-HotelsConfig.ps1 -InputPath .\Config\hotels.input.json `
        -OutputPath .\Config\hotels.json -SkipSmtp -Force

.EXAMPLE
    # Preview what would happen without writing any files:
    .\Tools\Protect-HotelsConfig.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [string] $InputPath = (Join-Path $PSScriptRoot '..\Config\hotels.input.json'),

    [Parameter()]
    [string] $OutputPath = (Join-Path $PSScriptRoot '..\Config\hotels.json'),

    [Parameter()]
    [string] $SettingsPath = (Join-Path $PSScriptRoot '..\Config\settings.json'),

    [Parameter()]
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string] $Scope = 'CurrentUser',

    [Parameter()]
    [switch] $SkipSmtp,

    [Parameter()]
    [switch] $Force
)

# ==============================================================================
# Reusable functions (also imported by the Pester tests via the seam below)
# ==============================================================================

# The per-hotel secret fields that must be encrypted. All other fields pass through.
$script:HotelSecretFields = @('clientId', 'clientSecret', 'apiKey')

# ------------------------------------------------------------------------------
# Self-describing DPAPI scheme constants.
#
# KEEP IN SYNC with Modules\Auth.psm1 (Unprotect-DpapiValue). If you change the tag
# prefixes or the entropy salt here, change them in Auth.psm1 too, or already-encrypted
# values will stop decrypting at runtime.
#
# Tagged format:  "DPAPI:<scope>:v1:<base64>"
#   <scope>  = 'CU' (CurrentUser) | 'LM' (LocalMachine)
#   <base64> = Base64( ProtectedData.Protect( UTF8(plaintext), entropy, scope ) )
# ------------------------------------------------------------------------------
$script:DpapiTagCurrentUser  = 'DPAPI:CU:v1:'
$script:DpapiTagLocalMachine = 'DPAPI:LM:v1:'
# App-specific optionalEntropy: fixed bytes of a constant app salt string so not every
# process on the box can trivially decrypt LocalMachine values.
$script:DpapiEntropy = [System.Text.Encoding]::UTF8.GetBytes('OperaRADataLoader/v1')

function Protect-DpapiValue {
    <#
    .SYNOPSIS
        DPAPI-encrypts a plaintext string into a self-describing tagged string.
    .DESCRIPTION
        Uses [System.Security.Cryptography.ProtectedData]::Protect with the requested
        -Scope (CurrentUser or LocalMachine) and the app-specific optionalEntropy, then
        Base64-encodes the ciphertext and prefixes the scheme tag:

            CurrentUser  -> "DPAPI:CU:v1:<base64>"
            LocalMachine -> "DPAPI:LM:v1:<base64>"

        Modules\Auth.psm1 (Unprotect-DpapiValue) reverses this using the SAME tag
        constants and entropy salt. The plaintext is never logged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Plain,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FieldName,

        [Parameter()]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string] $Scope = 'CurrentUser'
    )

    $plainBytes = $null
    try {
        $dpScope = if ($Scope -eq 'LocalMachine') {
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        }
        else {
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        }
        $tag = if ($Scope -eq 'LocalMachine') { $script:DpapiTagLocalMachine } else { $script:DpapiTagCurrentUser }

        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
        $cipherBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes, $script:DpapiEntropy, $dpScope)
        return ($tag + [System.Convert]::ToBase64String($cipherBytes))
    }
    catch {
        throw ("Failed to encrypt credential field '{0}' with scope '{1}'. Ensure this script runs on Windows." -f $FieldName, $Scope)
    }
    finally {
        if ($null -ne $plainBytes) { [System.Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    }
}

function Unprotect-DpapiValue {
    <#
    .SYNOPSIS
        Decrypts a DPAPI value back to plaintext (used only for round-trip verify).
    .DESCRIPTION
        Reverses Protect-DpapiValue's tagged format and also handles legacy untagged
        values so the round-trip check proves the value the loader will read decrypts to
        the original plaintext:

          - "DPAPI:CU:v1:<b64>" -> ProtectedData.Unprotect (CurrentUser + entropy)
          - "DPAPI:LM:v1:<b64>" -> ProtectedData.Unprotect (LocalMachine + entropy)
          - legacy untagged hex  -> ConvertTo-SecureString (CurrentUser DPAPI)

        Mirrors Modules\Auth.psm1's runtime decryption exactly. Never logs material.
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
        throw ("Failed to decrypt credential field '{0}' during round-trip verification." -f $FieldName)
    }
    finally {
        if ($null -ne $plainBytes) { [System.Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if ($secure) { $secure.Dispose() }
    }
}

function Test-DpapiEncrypted {
    <#
    .SYNOPSIS
        Heuristic: does a value already look like DPAPI ciphertext (so we can skip it)?
    .DESCRIPTION
        Recognises BOTH forms so idempotent re-runs skip already-encrypted values:
          - the new tagged form ("DPAPI:CU:" / "DPAPI:LM:" prefix), and
          - the legacy untagged form (a long hex string, >= 100 hex chars, from the old
            ConvertFrom-SecureString scheme).
        Plain-text credentials / REPLACE_ME placeholders match neither.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )
    if ($Value.StartsWith('DPAPI:CU:') -or $Value.StartsWith('DPAPI:LM:')) {
        return $true
    }
    return ($Value -match '^[0-9a-fA-F]{100,}$')
}

function Protect-ConfigValue {
    <#
    .SYNOPSIS
        Encrypts one field and verifies it round-trips; returns the ciphertext.
    .DESCRIPTION
        Combines encrypt + immediate round-trip verify for a single named field. Throws
        (aborting the caller) if the decrypted value does not equal the original plaintext,
        so a bad encryption never reaches the output file. Never logs the values.

        -Encryptor / -Verifier are injectable seams (default to the real DPAPI functions)
        so the behaviour is testable off-Windows and the abort-on-mismatch path can be
        exercised by injecting a faulty verifier.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Plain,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FieldName,

        [Parameter()]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string] $Scope = 'CurrentUser',

        [Parameter()]
        [scriptblock] $Encryptor,

        [Parameter()]
        [scriptblock] $Verifier
    )

    if (-not $Encryptor) {
        $Encryptor = { param($p, $f) Protect-DpapiValue -Plain $p -FieldName $f -Scope $Scope }.GetNewClosure()
    }
    if (-not $Verifier) {
        $Verifier = { param($c, $f) Unprotect-DpapiValue -EncryptedValue $c -FieldName $f }
    }

    $cipher = & $Encryptor $Plain $FieldName
    if ([string]::IsNullOrWhiteSpace($cipher)) {
        throw ("Encryption produced an empty value for field '{0}'; aborting." -f $FieldName)
    }

    $decrypted = & $Verifier $cipher $FieldName
    if ($decrypted -ne $Plain) {
        # Never include the plaintext or ciphertext in the message.
        throw ("Round-trip verification FAILED for field '{0}' (decrypted value did not match the original). Aborting without writing output." -f $FieldName)
    }

    Write-Verbose ("Encrypted and round-trip-verified field '{0}'." -f $FieldName)
    return $cipher
}

function Protect-HotelObject {
    <#
    .SYNOPSIS
        Returns an ordered hashtable copy of a hotel with only secret fields encrypted.
    .DESCRIPTION
        Copies every property verbatim; for each field in $HotelSecretFields present on
        the hotel, encrypts + round-trip-verifies it (unless it already looks encrypted,
        which is skipped for idempotency). All non-secret fields are preserved unchanged.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Hotel,

        [Parameter()]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string] $Scope = 'CurrentUser',

        [Parameter()]
        [scriptblock] $Encryptor,

        [Parameter()]
        [scriptblock] $Verifier
    )

    $result = [ordered]@{}
    $hotelCode = if ($Hotel.PSObject.Properties.Name -contains 'hotelCode') { [string]$Hotel.hotelCode } else { '<unknown>' }

    foreach ($prop in $Hotel.PSObject.Properties) {
        $name = $prop.Name
        $secretMatch = @($script:HotelSecretFields | Where-Object { $_ -ieq $name })
        if ($secretMatch.Count -gt 0) {
            $plain = [string]$prop.Value
            if ([string]::IsNullOrWhiteSpace($plain)) {
                throw ("Hotel '{0}' has an empty '{1}'; provide a real value in the input file before encrypting." -f $hotelCode, $name)
            }
            if (Test-DpapiEncrypted -Value $plain) {
                Write-Verbose ("Hotel '{0}' field '{1}' already looks DPAPI-encrypted; copying unchanged (idempotent)." -f $hotelCode, $name)
                $result[$name] = $plain
            }
            else {
                $result[$name] = Protect-ConfigValue -Plain $plain -FieldName ("{0}.{1}" -f $hotelCode, $name) -Scope $Scope -Encryptor $Encryptor -Verifier $Verifier
            }
        }
        else {
            # Non-secret field: copy verbatim (preserves nested emailAlerts, numbers, bools, arrays).
            $result[$name] = $prop.Value
        }
    }

    return $result
}

function ConvertTo-EncryptedHotelsConfig {
    <#
    .SYNOPSIS
        Encrypts secrets across all hotels in a parsed input config; returns a new object.
    .DESCRIPTION
        Iterates the .hotels array, encrypting each hotel's secret fields. Because every
        value is round-trip-verified inside Protect-ConfigValue, a single failure throws
        and no output object is returned — the caller never writes a partial file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $InputConfig,

        [Parameter()]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string] $Scope = 'CurrentUser',

        [Parameter()]
        [scriptblock] $Encryptor,

        [Parameter()]
        [scriptblock] $Verifier
    )

    if (-not ($InputConfig.PSObject.Properties.Name -contains 'hotels') -or $null -eq $InputConfig.hotels) {
        throw "Input config does not contain a 'hotels' array."
    }

    $encryptedHotels = foreach ($hotel in @($InputConfig.hotels)) {
        Protect-HotelObject -Hotel $hotel -Scope $Scope -Encryptor $Encryptor -Verifier $Verifier
    }

    $out = [ordered]@{}
    # Preserve any top-level sibling properties (e.g. a _comment) verbatim, then hotels.
    foreach ($prop in $InputConfig.PSObject.Properties) {
        if ($prop.Name -ieq 'hotels') { continue }
        $out[$prop.Name] = $prop.Value
    }
    $out['hotels'] = @($encryptedHotels)
    return $out
}

function Protect-SmtpSettings {
    <#
    .SYNOPSIS
        Encrypts smtp.username / smtp.password in a parsed settings object, in place.
    .DESCRIPTION
        Returns the same settings object with the two SMTP secret fields replaced by
        round-trip-verified ciphertext. Fields already encrypted are skipped. All other
        settings are untouched. Returns $true if anything changed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Settings,

        [Parameter()]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string] $Scope = 'CurrentUser',

        [Parameter()]
        [scriptblock] $Encryptor,

        [Parameter()]
        [scriptblock] $Verifier
    )

    if (-not ($Settings.PSObject.Properties.Name -contains 'smtp') -or $null -eq $Settings.smtp) {
        Write-Verbose 'settings.json has no smtp block; nothing to encrypt.'
        return $false
    }

    $smtp = $Settings.smtp
    $changed = $false
    foreach ($field in @('username', 'password')) {
        if (-not ($smtp.PSObject.Properties.Name -contains $field)) { continue }
        $plain = [string]$smtp.$field
        if ([string]::IsNullOrWhiteSpace($plain)) {
            Write-Verbose ("smtp.{0} is empty; skipping." -f $field)
            continue
        }
        if (Test-DpapiEncrypted -Value $plain) {
            Write-Verbose ("smtp.{0} already looks DPAPI-encrypted; leaving unchanged (idempotent)." -f $field)
            continue
        }
        $cipher = Protect-ConfigValue -Plain $plain -FieldName ("smtp.{0}" -f $field) -Scope $Scope -Encryptor $Encryptor -Verifier $Verifier
        $smtp.$field = $cipher
        $changed = $true
    }
    return $changed
}

# ==============================================================================
# Main — skipped when dot-sourced by the test harness (seam).
# The tests dot-source this file to reuse the functions above; they set
# $env:PROTECT_HOTELS_NO_MAIN = '1' so the procedural body below does not run.
# ==============================================================================
if ($env:PROTECT_HOTELS_NO_MAIN -eq '1') {
    return
}

$ErrorActionPreference = 'Stop'

try {
    if (-not $IsWindows) {
        throw 'Protect-HotelsConfig.ps1 requires Windows: DPAPI (ConvertTo-SecureString without -Key) is not available on this platform.'
    }

    $InputPath    = [System.IO.Path]::GetFullPath($InputPath)
    $OutputPath   = [System.IO.Path]::GetFullPath($OutputPath)
    $SettingsPath = [System.IO.Path]::GetFullPath($SettingsPath)

    Write-Verbose ("Input : {0}" -f $InputPath)
    Write-Verbose ("Output: {0}" -f $OutputPath)
    Write-Verbose ("SMTP  : {0}" -f $SettingsPath)
    Write-Verbose ("Scope : {0}" -f $Scope)

    if (-not (Test-Path -LiteralPath $InputPath)) {
        throw ("Input file not found: {0}. Copy Config\hotels.sample.json to hotels.input.json and fill in real credentials first." -f $InputPath)
    }

    # --- Read + parse the plain-text input (never logged). -------------------
    $inputConfig = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $hotelCount = @($inputConfig.hotels).Count
    Write-Verbose ("Read {0} hotel(s) from input." -f $hotelCount)

    # --- Encrypt + round-trip verify every hotel secret. ---------------------
    $encrypted = ConvertTo-EncryptedHotelsConfig -InputConfig $inputConfig -Scope $Scope

    # --- Write hotels.json only after ALL values verified. -------------------
    if (Test-Path -LiteralPath $OutputPath) {
        if (-not $Force -and -not $PSCmdlet.ShouldContinue(
                ("Overwrite existing encrypted config?`n{0}" -f $OutputPath), 'Confirm overwrite')) {
            throw 'Aborted: output file exists and overwrite was declined (use -Force to overwrite).'
        }
    }

    $json = $encrypted | ConvertTo-Json -Depth 20
    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write encrypted hotels config')) {
        Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
        Write-Host ("Wrote encrypted hotels config ({0} scope) for {1} hotel(s): {2}" -f $Scope, $hotelCount, $OutputPath)
    }
    else {
        Write-Host ("[WhatIf] Would write encrypted hotels config for {0} hotel(s): {1}" -f $hotelCount, $OutputPath)
    }

    # --- Encrypt shared SMTP creds in settings.json (in place). --------------
    if (-not $SkipSmtp) {
        if (-not (Test-Path -LiteralPath $SettingsPath)) {
            Write-Warning ("settings.json not found at {0}; skipping SMTP credential encryption." -f $SettingsPath)
        }
        else {
            $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $smtpChanged = Protect-SmtpSettings -Settings $settings -Scope $Scope
            if ($smtpChanged) {
                $settingsJson = $settings | ConvertTo-Json -Depth 20
                if ($PSCmdlet.ShouldProcess($SettingsPath, 'Write encrypted SMTP credentials')) {
                    Set-Content -LiteralPath $SettingsPath -Value $settingsJson -Encoding UTF8
                    Write-Host ("Encrypted smtp.username/smtp.password in: {0}" -f $SettingsPath)
                }
                else {
                    Write-Host ("[WhatIf] Would encrypt smtp.username/smtp.password in: {0}" -f $SettingsPath)
                }
            }
            else {
                Write-Host 'No SMTP credentials required encryption (empty or already encrypted).'
            }
        }
    }

    Write-Host 'Done. Reminder: hotels.input.json is git-ignored and must never be committed.'
    exit 0
}
catch {
    Write-Error ("Protect-HotelsConfig failed: {0}" -f $_.Exception.Message)
    exit 1
}
