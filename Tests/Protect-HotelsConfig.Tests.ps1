# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
    Pester tests for Tools\Protect-HotelsConfig.ps1 (Task 14 — Credential Protection).

    Covers:
      - Reads plaintext input and writes hotels.json with secret fields encrypted while
        every other field is copied through unchanged.
      - Round-trip verify: encrypt -> decrypt equals the original plaintext.
      - Abort-on-mismatch: a faulty verifier (injected via the seam) throws and no
        output is produced.
      - Plaintext secrets never appear in the verbose stream.

    The script is dot-sourced with $env:PROTECT_HOTELS_NO_MAIN='1' so only its reusable
    functions load (the procedural main body is skipped). The functions accept injectable
    -Encryptor / -Verifier scriptblocks so the encrypt/verify seams are exercised without
    real DPAPI; the real-DPAPI assertions are guarded with -Skip off Windows.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\Tools\Protect-HotelsConfig.ps1'
    $env:PROTECT_HOTELS_NO_MAIN = '1'
    . $script:ScriptPath
    $env:PROTECT_HOTELS_NO_MAIN = $null

    $script:IsWindowsHost = $IsWindows

    # Deterministic fake encryptor/verifier (no DPAPI): "ENC:" prefix + reversible.
    $script:FakeEncryptor = { param($p, $f) 'ENC:' + $p }
    $script:FakeVerifier  = { param($c, $f) $c -replace '^ENC:', '' }

    # A hotel input object mirroring hotels.sample.json shape.
    function New-InputHotel {
        [pscustomobject]@{
            hotelCode      = 'HOTEL1'
            chainCode      = 'CHAIN_A'
            displayName    = 'Grand Hotel Downtown'
            enabled        = $true
            gatewayUrl     = 'https://chaina.hospitality.oracle.com'
            enterpriseId   = 'ent-123'
            clientId       = 'plain-client-id'
            clientSecret   = 'plain-client-secret!@#'
            apiKey         = 'plain-api-key'
            timeZoneId     = 'Central European Standard Time'
            nightAuditHour = 23
            otbFutureDays  = 365
            blockFutureDays = 180
            emailAlerts    = [pscustomobject]@{
                enabled = $true
                error   = [pscustomobject]@{ enabled = $true; to = @('oncall@x.com'); cc = @() }
            }
        }
    }
}

Describe 'Reusable function surface' {
    It 'exposes the encrypt/verify/convert functions after dot-sourcing' {
        Get-Command Protect-ConfigValue -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Protect-HotelObject -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command ConvertTo-EncryptedHotelsConfig -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Protect-SmtpSettings -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Encrypts secrets, copies other fields unchanged (with injected seam)' {

    It 'encrypts clientId/clientSecret/apiKey and preserves all other fields verbatim' {
        $hotel = New-InputHotel
        $result = Protect-HotelObject -Hotel $hotel -Encryptor $FakeEncryptor -Verifier $FakeVerifier

        # Secret fields encrypted (transformed away from plaintext).
        $result['clientId']     | Should -Be 'ENC:plain-client-id'
        $result['clientSecret'] | Should -Be 'ENC:plain-client-secret!@#'
        $result['apiKey']       | Should -Be 'ENC:plain-api-key'

        # Non-secret fields copied unchanged.
        $result['hotelCode']       | Should -Be 'HOTEL1'
        $result['chainCode']       | Should -Be 'CHAIN_A'
        $result['gatewayUrl']      | Should -Be 'https://chaina.hospitality.oracle.com'
        $result['enterpriseId']    | Should -Be 'ent-123'
        $result['timeZoneId']      | Should -Be 'Central European Standard Time'
        $result['nightAuditHour']  | Should -Be 23
        $result['otbFutureDays']   | Should -Be 365
        $result['blockFutureDays'] | Should -Be 180
        $result['enabled']         | Should -BeTrue
        $result['emailAlerts'].enabled | Should -BeTrue
        $result['emailAlerts'].error.to[0] | Should -Be 'oncall@x.com'
    }

    It 'preserves top-level siblings and the hotels array count' {
        $cfg = [pscustomobject]@{
            _comment = 'keep me'
            hotels   = @((New-InputHotel), (New-InputHotel))
        }
        $out = ConvertTo-EncryptedHotelsConfig -InputConfig $cfg -Encryptor $FakeEncryptor -Verifier $FakeVerifier
        $out['_comment'] | Should -Be 'keep me'
        @($out['hotels']).Count | Should -Be 2
        $out['hotels'][0]['clientId'] | Should -Be 'ENC:plain-client-id'
    }
}

Describe 'Round-trip verification' {

    It 'returns ciphertext when decrypt equals the original (fake seam)' {
        $cipher = Protect-ConfigValue -Plain 'secret-value' -FieldName 'test.clientId' `
            -Encryptor $FakeEncryptor -Verifier $FakeVerifier
        $cipher | Should -Be 'ENC:secret-value'
    }

    It 'real DPAPI (CurrentUser default) round-trips through Protect-DpapiValue / Unprotect-DpapiValue' -Skip:(-not $IsWindows) {
        $plain = 'client-secret-!@#$%'
        $cipher = Protect-DpapiValue -Plain $plain -FieldName 'clientSecret'
        $cipher | Should -Not -Be $plain
        (Unprotect-DpapiValue -EncryptedValue $cipher -FieldName 'clientSecret') | Should -Be $plain
    }

    It 'CurrentUser scope produces a DPAPI:CU: tag and round-trips' -Skip:(-not $IsWindows) {
        $plain = 'cu-secret-value-123'
        $cipher = Protect-DpapiValue -Plain $plain -FieldName 'clientSecret' -Scope CurrentUser
        $cipher | Should -Match '^DPAPI:CU:v1:'
        (Unprotect-DpapiValue -EncryptedValue $cipher -FieldName 'clientSecret') | Should -Be $plain
    }

    It 'LocalMachine scope produces a DPAPI:LM: tag and round-trips' -Skip:(-not $IsWindows) {
        $plain = 'lm-secret-value-456'
        $cipher = Protect-DpapiValue -Plain $plain -FieldName 'clientSecret' -Scope LocalMachine
        $cipher | Should -Match '^DPAPI:LM:v1:'
        (Unprotect-DpapiValue -EncryptedValue $cipher -FieldName 'clientSecret') | Should -Be $plain
    }
}

Describe 'Abort on round-trip mismatch (fail safe)' {

    It 'throws when the verifier returns a value that does not match the original' {
        $badVerifier = { param($c, $f) 'WRONG' }
        { Protect-ConfigValue -Plain 'orig' -FieldName 'test.apiKey' `
                -Encryptor $FakeEncryptor -Verifier $badVerifier } |
            Should -Throw -ExpectedMessage '*Round-trip verification FAILED*'
    }

    It 'propagates the abort so ConvertTo-EncryptedHotelsConfig produces no output' {
        $badVerifier = { param($c, $f) 'WRONG' }
        $cfg = [pscustomobject]@{ hotels = @((New-InputHotel)) }
        $captured = $null
        { $captured = ConvertTo-EncryptedHotelsConfig -InputConfig $cfg `
                -Encryptor $FakeEncryptor -Verifier $badVerifier } | Should -Throw
        $captured | Should -BeNullOrEmpty
    }
}

Describe 'Secrets never leak to the verbose stream' {

    It 'does not emit plaintext secret values in verbose output' {
        $hotel = New-InputHotel
        $verbose = $( Protect-HotelObject -Hotel $hotel -Encryptor $FakeEncryptor -Verifier $FakeVerifier -Verbose ) 4>&1 |
            Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
            ForEach-Object { $_.Message }
        $joined = ($verbose -join "`n")
        $joined | Should -Not -Match 'plain-client-id'
        $joined | Should -Not -Match 'plain-client-secret'
        $joined | Should -Not -Match 'plain-api-key'
    }
}

Describe 'SMTP settings encryption' {

    It 'encrypts smtp.username/password and leaves other smtp fields unchanged' {
        $settings = [pscustomobject]@{
            smtp = [pscustomobject]@{
                enabled  = $false
                smtpServer = 'relay.x.com'
                port     = 587
                username = 'svc-smtp'
                password = 'p@ss'
            }
        }
        $changed = Protect-SmtpSettings -Settings $settings -Encryptor $FakeEncryptor -Verifier $FakeVerifier
        $changed | Should -BeTrue
        $settings.smtp.username | Should -Be 'ENC:svc-smtp'
        $settings.smtp.password | Should -Be 'ENC:p@ss'
        $settings.smtp.smtpServer | Should -Be 'relay.x.com'
        $settings.smtp.port | Should -Be 587
    }
}

Describe 'Idempotency' {

    It 'skips values that already look DPAPI-encrypted' {
        $alreadyEnc = ('a' * 120)  # long hex-like string (legacy scheme)
        Test-DpapiEncrypted -Value $alreadyEnc | Should -BeTrue
        Test-DpapiEncrypted -Value 'plain-client-id' | Should -BeFalse
    }

    It 'recognises tagged CU/LM forms and the legacy hex form, rejects plaintext' {
        # New tagged forms (base64 payload does not need to be valid to be recognised).
        Test-DpapiEncrypted -Value 'DPAPI:CU:v1:AAAA' | Should -BeTrue
        Test-DpapiEncrypted -Value 'DPAPI:LM:v1:AAAA' | Should -BeTrue
        # Legacy long-hex form.
        Test-DpapiEncrypted -Value ('0123456789abcdef' * 8) | Should -BeTrue
        # Plaintext / placeholders.
        Test-DpapiEncrypted -Value 'REPLACE_ME-clientSecret' | Should -BeFalse
        Test-DpapiEncrypted -Value 'plain-value' | Should -BeFalse
    }
}
