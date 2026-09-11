# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
    Pester tests for Modules\ApiClient.psm1 (Task 5 — ApiClient Module).

    The OHIP R&A API is GraphQL-over-HTTP. These tests use the -Invoker / -TokenProvider /
    -Sleep scriptblock seams so retry / 401 / backoff / throttle / errors-array / multi-chunk
    accumulation logic is exercised with ZERO network access and ZERO real waiting.

    Helper values (JSON payloads, status-bearing exceptions) are built in each test's local
    scope and captured into the seam closures via .GetNewClosure(), so the closures never
    depend on script-scoped functions being resolvable at invocation time.

    Covers:
      - Header injection: Authorization: Bearer, x-app-key, x-request-id (new GUID per
        request), Content-Type, Accept, x-hotelid.
      - HTTP 401 -> Clear-TokenCache + re-auth + retry once (and abort if 401 persists).
      - Exponential backoff on 429/5xx with correct capped delays and max-3-retries.
      - GraphQL errors-array handling: WARN + return when data present; THROW when data null.
      - Per-request throttle between chunk calls (not before the first).
      - Multi-chunk accumulation flattened into a single [array].
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\Modules\ApiClient.psm1" -Force

    $script:Hotel = @{
        hotelCode  = 'HOTEL1'
        gatewayUrl = 'https://example-gateway.oracle.com/'
        apiKey     = 'test-app-key-123'
    }

    # A settings object with deterministic retry knobs.
    $script:Config = @{
        api = @{
            requestDelayMs        = 500
            maxRetries            = 3
            retryBaseDelaySeconds = 2
            retryMaxDelaySeconds  = 30
            retryableStatusCodes  = @(429, 500, 502, 503, 504)
            httpTimeoutSeconds    = 120
            graphqlEndpointPath   = '/rna/v1/graphql/'
        }
    }

    # --- Plain (non-function) builders usable anywhere, including inside closures
    #     because they are invoked in the TEST body and their RESULT is captured. ---

    # Build a GraphQL reservation-stats JSON payload string.
    $script:MakeResJson = {
        param([object[]] $Rows, [string] $NextPageToken)
        $view = @{ reservationDailyStatisticsDetails = @($Rows) }
        if ($NextPageToken) { $view['nextPageToken'] = $NextPageToken }
        $payload = @{ data = @{ statisticsReservationsDaily = $view } }
        $payload | ConvertTo-Json -Depth 12
    }

    # Build a successful Invoke-WebRequest-shaped transport result (.Content JSON).
    $script:MakeWebResult = {
        param([string] $Json)
        [pscustomobject]@{ StatusCode = 200; Content = $Json }
    }

    # Build a status-bearing exception like PS7 Invoke-WebRequest throws on non-2xx.
    $script:MakeHttpError = {
        param([int] $Status)
        $resp = [pscustomobject]@{ StatusCode = $Status }
        $ex = [System.Exception]::new("HTTP $Status")
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp -Force
        $ex
    }
}

Describe 'ApiClient module load surface' {
    It 'exports Invoke-GraphQL, Invoke-RASubjectArea, and Invoke-RAApi' {
        $names = (Get-Command -Module ApiClient).Name
        $names | Should -Contain 'Invoke-GraphQL'
        $names | Should -Contain 'Invoke-RASubjectArea'
        $names | Should -Contain 'Invoke-RAApi'
    }
}

Describe 'Header injection (REQ-003)' {

    It 'injects Authorization Bearer, x-app-key, x-request-id GUID, Content-Type, Accept, x-hotelid' {
        $okResult = & $script:MakeWebResult (& $script:MakeResJson @(@{ resort = 'HOTEL1' }))
        $cap = @{}
        $invoker = {
            param($RequestArgs)
            $cap.LastRequest = $RequestArgs
            $okResult
        }.GetNewClosure()

        $null = Invoke-GraphQL -Hotel $script:Hotel -Query 'query Q { x }' -Variables @{ a = 1 } `
            -Token 'tok-abc' -Config $script:Config -Invoker $invoker

        $h = $cap.LastRequest.Headers
        $h['Authorization'] | Should -Be 'Bearer tok-abc'
        $h['x-app-key']     | Should -Be 'test-app-key-123'
        $h['Content-Type']  | Should -Be 'application/json'
        $h['Accept']        | Should -Be 'multipart/mixed; deferSpec=20220824, application/json'
        $h['x-hotelid']     | Should -Be 'HOTEL1'

        $parsed = [guid]::Empty
        [guid]::TryParse([string]$h['x-request-id'], [ref]$parsed) | Should -BeTrue
    }

    It 'generates a NEW x-request-id GUID per request' {
        $okResult = & $script:MakeWebResult (& $script:MakeResJson @())
        $ids = [System.Collections.Generic.List[string]]::new()
        $invoker = {
            param($RequestArgs)
            $ids.Add([string]$RequestArgs.Headers['x-request-id'])
            $okResult
        }.GetNewClosure()

        $null = Invoke-GraphQL -Hotel $script:Hotel -Query 'q' -Token 't1' -Config $script:Config -Invoker $invoker
        $null = Invoke-GraphQL -Hotel $script:Hotel -Query 'q' -Token 't2' -Config $script:Config -Invoker $invoker

        $ids.Count | Should -Be 2
        $ids[0] | Should -Not -Be $ids[1]
    }

    It 'posts to <gatewayUrl>/rna/v1/graphql/ with a JSON body carrying query and variables' {
        $okResult = & $script:MakeWebResult (& $script:MakeResJson @())
        $cap = @{}
        $invoker = {
            param($RequestArgs)
            $cap.LastRequest = $RequestArgs
            $okResult
        }.GetNewClosure()

        $null = Invoke-GraphQL -Hotel $script:Hotel -Query 'query Q { field }' -Variables @{ input = @{ x = 1 } } `
            -Token 'tok' -Config $script:Config -Invoker $invoker

        $cap.LastRequest.Uri    | Should -Be 'https://example-gateway.oracle.com/rna/v1/graphql/'
        $cap.LastRequest.Method | Should -Be 'Post'
        $body = $cap.LastRequest.Body | ConvertFrom-Json
        $body.query       | Should -Be 'query Q { field }'
        $body.variables.input.x | Should -Be 1
    }
}

Describe 'HTTP 401 -> clear + reauth + retry once (REQ-003)' {

    It 'clears the token cache, re-authenticates, and retries once on 401' {
        $err401 = & $script:MakeHttpError 401
        $okResult = & $script:MakeWebResult (& $script:MakeResJson @(@{ resort = 'HOTEL1' }))
        $calls = [System.Collections.Generic.List[string]]::new()
        $invoker = {
            param($RequestArgs)
            $calls.Add([string]$RequestArgs.Headers['Authorization'])
            if ($calls.Count -eq 1) { throw $err401 }
            $okResult
        }.GetNewClosure()

        $reauth = @{ Count = 0 }
        $tokenProvider = {
            param($h)
            $reauth.Count++
            "fresh-token-$($reauth.Count)"
        }.GetNewClosure()

        $resp = Invoke-GraphQL -Hotel $script:Hotel -Query 'q' -Token 'stale-token' `
            -Config $script:Config -Invoker $invoker -TokenProvider $tokenProvider

        $calls.Count | Should -Be 2
        $calls[0] | Should -Be 'Bearer stale-token'
        $calls[1] | Should -Be 'Bearer fresh-token-1'
        $reauth.Count | Should -Be 1
        $resp.data.statisticsReservationsDaily.reservationDailyStatisticsDetails.Count | Should -Be 1
    }

    It 'throws when 401 persists after the single re-auth retry' {
        $err401 = & $script:MakeHttpError 401
        $count = @{ N = 0 }
        $invoker = {
            param($RequestArgs)
            $count.N++
            throw $err401
        }.GetNewClosure()
        $tokenProvider = { param($h) 'another-bad-token' }

        { Invoke-GraphQL -Hotel $script:Hotel -Query 'q' -Token 'bad' -Config $script:Config `
                -Invoker $invoker -TokenProvider $tokenProvider } |
            Should -Throw -ExpectedMessage '*401*'

        $count.N | Should -Be 2
    }
}

Describe 'Exponential backoff on 429/5xx (REQ-011)' {

    It 'retries up to 3 times with capped delays 2,4,8 then throws' {
        $err503 = & $script:MakeHttpError 503
        $count = @{ N = 0 }
        $invoker = {
            param($RequestArgs)
            $count.N++
            throw $err503
        }.GetNewClosure()

        $delays = [System.Collections.Generic.List[double]]::new()
        $sleep = { param($sec) $delays.Add([double]$sec) }.GetNewClosure()

        { Invoke-GraphQL -Hotel $script:Hotel -Query 'q' -Token 'tok' -Config $script:Config `
                -Invoker $invoker -Sleep $sleep } |
            Should -Throw -ExpectedMessage '*503*'

        $count.N | Should -Be 4
        $delays.ToArray() | Should -Be @(2, 4, 8)
    }

    It 'caps the backoff delay at retryMaxDelaySeconds' {
        $err429 = & $script:MakeHttpError 429
        $cfg = @{ api = @{ maxRetries = 3; retryBaseDelaySeconds = 10; retryMaxDelaySeconds = 15; retryableStatusCodes = @(429); requestDelayMs = 0 } }
        $invoker = { param($r) throw $err429 }.GetNewClosure()
        $delays = [System.Collections.Generic.List[double]]::new()
        $sleep = { param($sec) $delays.Add([double]$sec) }.GetNewClosure()

        { Invoke-GraphQL -Hotel $script:Hotel -Query 'q' -Token 'tok' -Config $cfg -Invoker $invoker -Sleep $sleep } |
            Should -Throw

        $delays.ToArray() | Should -Be @(10, 15, 15)
    }

    It 'recovers when a transient 500 is followed by success' {
        $err500 = & $script:MakeHttpError 500
        $okResult = & $script:MakeWebResult (& $script:MakeResJson @(@{ resort = 'HOTEL1' }))
        $count = @{ N = 0 }
        $invoker = {
            param($RequestArgs)
            $count.N++
            if ($count.N -eq 1) { throw $err500 }
            $okResult
        }.GetNewClosure()
        $delays = [System.Collections.Generic.List[double]]::new()
        $sleep = { param($sec) $delays.Add([double]$sec) }.GetNewClosure()

        $resp = Invoke-GraphQL -Hotel $script:Hotel -Query 'q' -Token 'tok' -Config $script:Config `
            -Invoker $invoker -Sleep $sleep

        $count.N | Should -Be 2
        $delays.ToArray() | Should -Be @(2)
        $resp.data.statisticsReservationsDaily.reservationDailyStatisticsDetails.Count | Should -Be 1
    }
}

Describe 'GraphQL errors-array handling (REQ-011)' {

    It 'WARNs and returns the response when errors are present but data is non-null' {
        $json = @{
            data   = @{ statisticsReservationsDaily = @{ reservationDailyStatisticsDetails = @(@{ resort = 'HOTEL1' }) } }
            errors = @(@{ message = 'partial: field deprecated' })
        } | ConvertTo-Json -Depth 12
        $okResult = [pscustomobject]@{ StatusCode = 200; Content = $json }
        $invoker = { param($r) $okResult }.GetNewClosure()

        $resp = $null
        { $resp = Invoke-GraphQL -Hotel $script:Hotel -Query 'q' -Token 'tok' -Config $script:Config -Invoker $invoker } |
            Should -Not -Throw
        @($resp.data.statisticsReservationsDaily.reservationDailyStatisticsDetails).Count | Should -Be 1
    }

    It 'THROWs when errors are present and data is null' {
        $json = @{
            data   = $null
            errors = @(@{ message = 'fatal: invalid filter' })
        } | ConvertTo-Json -Depth 12
        $okResult = [pscustomobject]@{ StatusCode = 200; Content = $json }
        $invoker = { param($r) $okResult }.GetNewClosure()

        { Invoke-GraphQL -Hotel $script:Hotel -Query 'q' -Token 'tok' -Config $script:Config -Invoker $invoker } |
            Should -Throw -ExpectedMessage '*null data*'
    }
}

Describe 'Invoke-RASubjectArea throttle + multi-chunk accumulation (REQ-011)' {

    It 'throttles between chunk calls (not before the first) and flattens all chunks into one array' {
        $makeResJson = $script:MakeResJson
        $chunkIdx = @{ N = 0 }
        $invoker = {
            param($RequestArgs)
            $chunkIdx.N++
            $rows = @(
                @{ resort = 'HOTEL1'; seq = 1 },
                @{ resort = 'HOTEL1'; seq = 2 }
            )
            [pscustomobject]@{ StatusCode = 200; Content = (& $makeResJson $rows) }
        }.GetNewClosure()

        $delays = [System.Collections.Generic.List[double]]::new()
        $sleep = { param($sec) $delays.Add([double]$sec) }.GetNewClosure()

        $chunks = @(
            @{ input = @{ businessDate = @{ _eq = '2026-01-01' } } },
            @{ input = @{ businessDate = @{ _eq = '2026-01-02' } } },
            @{ input = @{ businessDate = @{ _eq = '2026-01-03' } } }
        )

        $result = Invoke-RASubjectArea -Hotel $script:Hotel -Operation 'statisticsReservationsDaily' `
            -PrimaryView 'reservationDailyStatisticsDetails' -Query 'query Q { x }' `
            -Chunks $chunks -Token 'tok' -Config $script:Config -Invoker $invoker -Sleep $sleep

        @($result).Count | Should -Be 6
        $delays.Count | Should -Be 2
        $delays.ToArray() | Should -Be @(0.5, 0.5)
    }

    It 'returns a flat [array] of PSCustomObject' {
        $okResult = & $script:MakeWebResult (& $script:MakeResJson @(@{ resort = 'HOTEL1' }))
        $invoker = { param($r) $okResult }.GetNewClosure()
        $result = Invoke-RASubjectArea -Hotel $script:Hotel -Operation 'statisticsReservationsDaily' `
            -PrimaryView 'reservationDailyStatisticsDetails' -Query 'q' `
            -Variables @{ input = @{} } -Token 'tok' -Config $script:Config -Invoker $invoker

        # The module uses a unary-comma return so even a single-element result stays a
        # real [object[]] (Task 5 contract: "Return a normalised [array]").
        $result -is [System.Object[]] | Should -BeTrue
        @($result).Count | Should -Be 1
    }

    It 'defensively follows a nextPageToken when a response returns one' {
        $page1 = & $script:MakeWebResult (& $script:MakeResJson @(@{ seq = 1 }) 'PAGE2')
        $page2 = & $script:MakeWebResult (& $script:MakeResJson @(@{ seq = 2 }))
        $call = @{ N = 0 }
        $invoker = {
            param($RequestArgs)
            $call.N++
            if ($call.N -eq 1) { $page1 } else { $page2 }
        }.GetNewClosure()

        $result = Invoke-RASubjectArea -Hotel $script:Hotel -Operation 'statisticsReservationsDaily' `
            -PrimaryView 'reservationDailyStatisticsDetails' -Query 'q' `
            -Variables @{ input = @{} } -Token 'tok' -Config $script:Config -Invoker $invoker

        $call.N | Should -Be 2
        @($result).Count | Should -Be 2
    }
}

Describe 'Invoke-RAApi wrapper' {

    It 'forwards to Invoke-GraphQL and returns the deserialized response' {
        $okResult = & $script:MakeWebResult (& $script:MakeResJson @(@{ resort = 'HOTEL1' }))
        $invoker = { param($r) $okResult }.GetNewClosure()
        $resp = Invoke-RAApi -Hotel $script:Hotel -Query 'q' -Variables @{ a = 1 } `
            -Token 'tok' -Config $script:Config -Invoker $invoker
        @($resp.data.statisticsReservationsDaily.reservationDailyStatisticsDetails).Count | Should -Be 1
    }
}
