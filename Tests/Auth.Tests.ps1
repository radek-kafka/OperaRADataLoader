# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
    Pester tests for Modules\Auth.psm1 (Task 4 — Auth Module).

    Covers:
      - Cached-token reuse vs. re-acquisition under the safety-margin rule (REQ-003).
      - expires_in -> ExpiresAt caching and expiry evaluation.
      - Clear-TokenCache forcing re-authentication (401 recovery path).
      - DPAPI decryption of ClientId/ClientSecret before the request, and that neither
        the credentials nor the token appear in the request body surfaced to the caller.

    The OAuth endpoint is never contacted: Get-OAuthToken accepts a -TokenRequest
    scriptblock seam that returns a mocked token response.

    NOTE: DPAPI (ConvertTo-SecureString without a key) is Windows-only. The credential
    decryption tests are skipped on non-Windows hosts.
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\Modules\Auth.psm1" -Force

    $script:IsWindowsHost = $IsWindows

    # Encrypt a plaintext value the same way Protect-HotelsConfig.ps1 would (DPAPI).
    function New-DpapiValue {
        param([string] $Plain)
        ConvertTo-SecureString -String $Plain -AsPlainText -Force |
            ConvertFrom-SecureString
    }

    # Build a hotel config with DPAPI-encrypted credentials (Windows only).
    function New-TestHotel {
        param(
            [string] $HotelCode = 'HOTEL1',
            [string] $ClientId = 'test-client-id',
            [string] $ClientSecret = 'test-client-secret!@#'
        )
        @{
            hotelCode    = $HotelCode
            gatewayUrl   = 'https://example-gateway.oracle.com/'
            clientId     = (New-DpapiValue -Plain $ClientId)
            clientSecret = (New-DpapiValue -Plain $ClientSecret)
        }
    }

    # A capturing mock token endpoint: records the request args, returns a token
    # with the given expires_in.
    function New-MockTokenRequest {
        param(
            [string] $AccessToken = 'mock-access-token',
            [int]    $ExpiresIn = 3600,
            [hashtable] $Capture
        )
        {
            param($RequestArgs)
            $Capture.LastRequest = $RequestArgs
            [pscustomobject]@{
                access_token = $AccessToken
                expires_in   = $ExpiresIn
                token_type   = 'Bearer'
            }
        }.GetNewClosure()
    }
}

Describe 'Auth module load surface' {
    It 'exports Get-OAuthToken and Clear-TokenCache' {
        $names = (Get-Command -Module Auth).Name
        $names | Should -Contain 'Get-OAuthToken'
        $names | Should -Contain 'Clear-TokenCache'
    }
}

Describe 'Get-OAuthToken cache reuse and expiry (REQ-003)' -Skip:(-not $IsWindows) {

    BeforeEach {
        # Reset cache between tests via the public clear path.
        Clear-TokenCache -HotelCode 'HOTEL1'
    }

    It 'acquires a token on first call and returns the access_token' {
        $cap = @{}
        $mock = New-MockTokenRequest -AccessToken 'first-token' -ExpiresIn 3600 -Capture $cap
        $hotel = New-TestHotel

        $token = Get-OAuthToken -Hotel $hotel -TokenRequest $mock
        $token | Should -Be 'first-token'
        $cap.LastRequest | Should -Not -BeNullOrEmpty
    }

    It 'reuses the cached token on the second call (no second request)' {
        $count = @{ Calls = 0 }
        $mock = {
            param($RequestArgs)
            $count.Calls++
            [pscustomobject]@{ access_token = "tok-$($count.Calls)"; expires_in = 3600 }
        }.GetNewClosure()
        $hotel = New-TestHotel

        $t1 = Get-OAuthToken -Hotel $hotel -TokenRequest $mock
        $t2 = Get-OAuthToken -Hotel $hotel -TokenRequest $mock

        $count.Calls | Should -Be 1
        $t1 | Should -Be 'tok-1'
        $t2 | Should -Be 'tok-1'
    }

    It 're-acquires when the cached token is within the safety margin' {
        # expires_in = 30s, safety margin = 60s -> ExpiresAt is inside the horizon,
        # so the cached token is stale and must be refreshed on the next call.
        $count = @{ Calls = 0 }
        $mock = {
            param($RequestArgs)
            $count.Calls++
            [pscustomobject]@{ access_token = "tok-$($count.Calls)"; expires_in = 30 }
        }.GetNewClosure()
        $hotel = New-TestHotel

        $t1 = Get-OAuthToken -Hotel $hotel -TokenRequest $mock -SafetyMarginSeconds 60
        $t2 = Get-OAuthToken -Hotel $hotel -TokenRequest $mock -SafetyMarginSeconds 60

        $count.Calls | Should -Be 2
        $t1 | Should -Be 'tok-1'
        $t2 | Should -Be 'tok-2'
    }

    It 'ForceRefresh bypasses a still-valid cached token' {
        $count = @{ Calls = 0 }
        $mock = {
            param($RequestArgs)
            $count.Calls++
            [pscustomobject]@{ access_token = "tok-$($count.Calls)"; expires_in = 3600 }
        }.GetNewClosure()
        $hotel = New-TestHotel

        $null = Get-OAuthToken -Hotel $hotel -TokenRequest $mock
        $t2 = Get-OAuthToken -Hotel $hotel -TokenRequest $mock -ForceRefresh

        $count.Calls | Should -Be 2
        $t2 | Should -Be 'tok-2'
    }
}

Describe 'Clear-TokenCache forces re-authentication (401 recovery)' -Skip:(-not $IsWindows) {

    It 'clearing the cache causes the next call to acquire a fresh token' {
        $count = @{ Calls = 0 }
        $mock = {
            param($RequestArgs)
            $count.Calls++
            [pscustomobject]@{ access_token = "tok-$($count.Calls)"; expires_in = 3600 }
        }.GetNewClosure()
        $hotel = New-TestHotel -HotelCode 'HOTELX'

        $t1 = Get-OAuthToken -Hotel $hotel -TokenRequest $mock          # acquire
        Clear-TokenCache -HotelCode 'HOTELX'                            # simulate 401
        $t2 = Get-OAuthToken -Hotel $hotel -TokenRequest $mock          # re-acquire

        $count.Calls | Should -Be 2
        $t1 | Should -Be 'tok-1'
        $t2 | Should -Be 'tok-2'
    }

    It 'clearing an unknown hotel is a no-op and does not throw' {
        { Clear-TokenCache -HotelCode 'NO-SUCH-HOTEL' } | Should -Not -Throw
    }
}

Describe 'Credential decryption and non-disclosure (REQ-002)' -Skip:(-not $IsWindows) {

    BeforeEach { Clear-TokenCache -HotelCode 'HOTEL1' }

    It 'decrypts ClientId/ClientSecret into the form body before the request' {
        $cap = @{}
        $mock = New-MockTokenRequest -Capture $cap
        $hotel = New-TestHotel -ClientId 'CID-123' -ClientSecret 'SECRET-xyz'

        $null = Get-OAuthToken -Hotel $hotel -TokenRequest $mock

        $body = $cap.LastRequest.Body
        $body | Should -Match 'grant_type=client_credentials'
        $body | Should -Match 'client_id=CID-123'
        $body | Should -Match 'client_secret=SECRET-xyz'
        $body | Should -Match ([regex]::Escape('scope=urn%3Aopc%3Ahgbu%3Aws%3A_myscopes_'))
    }

    It 'posts to <gatewayUrl>/oauth/token with form-urlencoded content type' {
        $cap = @{}
        $mock = New-MockTokenRequest -Capture $cap
        $hotel = New-TestHotel

        $null = Get-OAuthToken -Hotel $hotel -TokenRequest $mock

        $cap.LastRequest.Uri | Should -Be 'https://example-gateway.oracle.com/oauth/token'
        $cap.LastRequest.Headers['Content-Type'] | Should -Be 'application/x-www-form-urlencoded'
    }

    It 'throws a non-sensitive error when a credential cannot be decrypted' {
        $hotel = @{
            hotelCode    = 'BADCRED'
            gatewayUrl   = 'https://example-gateway.oracle.com'
            clientId     = 'not-a-valid-dpapi-blob'
            clientSecret = 'also-invalid'
        }
        { Get-OAuthToken -Hotel $hotel -TokenRequest (New-MockTokenRequest -Capture @{}) } |
            Should -Throw -ExpectedMessage '*decrypt*'
    }
}

Describe 'Token response validation' -Skip:(-not $IsWindows) {

    BeforeEach { Clear-TokenCache -HotelCode 'HOTEL1' }

    It 'throws when the response has no access_token' {
        $mock = { param($r) [pscustomobject]@{ expires_in = 3600 } }
        $hotel = New-TestHotel
        { Get-OAuthToken -Hotel $hotel -TokenRequest $mock } |
            Should -Throw -ExpectedMessage '*access_token*'
    }
}
