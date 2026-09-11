# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
    Pester tests for Run-OperaRALoader.ps1 (Task 15 — Entry Point Orchestrator).

    Covers:
      - Parameter set / validation (Mode ValidateSet; date parameter consistency).
      - Config load + fail-fast on missing required fields (Resolve-Config seams).
      - Hotel filtering by -HotelCode / -ChainCode (including no-match + disabled).
      - Exit-code computation (all success->0, partial->1, total->2) via Get-RunExitCode.
      - DryRun skips ALL writes (injected fake writers assert zero write calls).
      - Summary table content (Hotel | Status | Rows | Duration).

    The script is dot-sourced with $env:RUN_OPERA_NO_MAIN='1' so only its reusable
    functions load (the procedural main body is skipped). All query/writer/db/token
    functions are injected as fakes, so NO network or SQL is required.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\Run-OperaRALoader.ps1'
    $env:RUN_OPERA_NO_MAIN = '1'
    . $script:ScriptPath
    $env:RUN_OPERA_NO_MAIN = $null

    # ---- Fake config object (mirrors settings.json + hotels.json shapes) ----
    function New-FakeSettings {
        [pscustomobject]@{
            sqlServer = [pscustomobject]@{ connectionString = 'Server=.;Database=OperaRA;Integrated Security=True' }
            logging   = [pscustomobject]@{ logDirectory = 'Logs'; logLevel = 'INFO'; sqlLogging = $false; logName = 'OperaRA_Loader' }
            smtp      = [pscustomobject]@{ enabled = $false }
            extraction = [pscustomobject]@{ transactionalChunkDays = 7 }
        }
    }

    function New-FakeHotel {
        param([string]$Code = 'HOTEL1', [string]$Chain = 'CHAIN_A', [bool]$Enabled = $true)
        [pscustomobject]@{
            hotelCode      = $Code
            chainCode      = $Chain
            displayName    = "Hotel $Code"
            enabled        = $Enabled
            gatewayUrl     = 'https://x.hospitality.oracle.com'
            enterpriseId   = 'ent-1'
            clientId       = 'enc-clientId'
            clientSecret   = 'enc-clientSecret'
            apiKey         = 'enc-apiKey'
            timeZoneId     = 'Central European Standard Time'
            nightAuditHour = 23
            otbFutureDays  = 365
            blockFutureDays = 180
            emailAlerts    = [pscustomobject]@{ enabled = $true }
        }
    }

    function New-FakeConfigResult {
        param([array]$Hotels)
        @{ Settings = (New-FakeSettings); Hotels = @($Hotels); ConfigDir = 'C:\fake\Config' }
    }

    # Always-pass credential tester + token provider + business-date resolver.
    $script:PassCreds = { param($h) @{ Ok = $true; Reason = '' } }
    $script:FakeToken = { param($h) 'fake-token' }
    $script:FakeBizDate = { param($h) [datetime]'2026-07-30' }
}

Describe 'Parameter surface & validation' {
    It 'defines -Mode with a ValidateSet of All/Full/Delta/OTB/MasterData (default Delta)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
        $param | Should -Not -BeNullOrEmpty
        $vs = $param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        $values = $vs.PositionalArguments | ForEach-Object { $_.Value }
        $values | Should -Contain 'All'
        $values | Should -Contain 'Full'
        $values | Should -Contain 'Delta'
        $values | Should -Contain 'OTB'
        $values | Should -Contain 'MasterData'
    }

    It 'declares all required parameters' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $names = $ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        foreach ($p in 'Mode','HotelCode','ChainCode','BusinessDate','StartDate','EndDate','DryRun','FailFast','ConfigPath') {
            $names | Should -Contain $p
        }
    }

    It 'throws when StartDate is after EndDate (date param consistency)' {
        $q = @{ RES = { @() } }
        $w = @{ RES = { } }
        { Invoke-HotelLoad -Hotel (New-FakeHotel) -Mode Delta -Queries $q -Writers $w `
            -StartDate ([datetime]'2026-07-10') -EndDate ([datetime]'2026-07-01') `
            -BusinessDateResolver $script:FakeBizDate } | Should -Throw
    }
}

Describe 'Resolve-Config — fail-fast on missing required fields' {
    It 'throws when sqlServer.connectionString is missing' {
        $settingsReader = { [pscustomobject]@{ sqlServer = [pscustomobject]@{}; logging = [pscustomobject]@{} } }
        $hotelsReader   = { [pscustomobject]@{ hotels = @(New-FakeHotel) } }
        { Resolve-Config -ConfigDir 'C:\fake' -SettingsReader $settingsReader -HotelsReader $hotelsReader } |
            Should -Throw -ExpectedMessage '*connectionString*'
    }

    It 'throws when a hotel is missing a required field (clientSecret)' {
        $bad = New-FakeHotel
        $bad.PSObject.Properties.Remove('clientSecret')
        $settingsReader = { New-FakeSettings }
        $hotelsReader   = { [pscustomobject]@{ hotels = @($bad) } }
        { Resolve-Config -ConfigDir 'C:\fake' -SettingsReader $settingsReader -HotelsReader $hotelsReader } |
            Should -Throw -ExpectedMessage '*clientSecret*'
    }

    It 'throws when the hotels array is empty' {
        $settingsReader = { New-FakeSettings }
        $hotelsReader   = { [pscustomobject]@{ hotels = @() } }
        { Resolve-Config -ConfigDir 'C:\fake' -SettingsReader $settingsReader -HotelsReader $hotelsReader } |
            Should -Throw
    }

    It 'returns Settings + Hotels for a valid config' {
        $settingsReader = { New-FakeSettings }
        $hotelsReader   = { [pscustomobject]@{ hotels = @((New-FakeHotel 'HOTEL1'), (New-FakeHotel 'HOTEL2' 'CHAIN_B')) } }
        $cfg = Resolve-Config -ConfigDir 'C:\fake' -SettingsReader $settingsReader -HotelsReader $hotelsReader
        $cfg.Hotels.Count | Should -Be 2
        $cfg.Settings.sqlServer.connectionString | Should -Not -BeNullOrEmpty
    }
}

Describe 'Select-Hotels — filtering' {
    BeforeAll {
        $script:Pool = @(
            (New-FakeHotel 'HOTEL1' 'CHAIN_A' $true),
            (New-FakeHotel 'HOTEL2' 'CHAIN_B' $true),
            (New-FakeHotel 'HOTEL3' 'CHAIN_A' $false)
        )
    }

    It 'excludes disabled hotels by default' {
        $sel = Select-Hotels -Hotels $script:Pool
        @($sel).Count | Should -Be 2
        (@($sel).hotelCode) | Should -Not -Contain 'HOTEL3'
    }

    It 'filters by -HotelCode (case-insensitive)' {
        $sel = @(Select-Hotels -Hotels $script:Pool -HotelCode 'hotel1')
        $sel.Count | Should -Be 1
        $sel[0].hotelCode | Should -Be 'HOTEL1'
    }

    It 'filters by -ChainCode' {
        $sel = @(Select-Hotels -Hotels $script:Pool -ChainCode 'CHAIN_A')
        # HOTEL3 is CHAIN_A but disabled, so only HOTEL1 remains.
        $sel.Count | Should -Be 1
        $sel[0].hotelCode | Should -Be 'HOTEL1'
    }

    It 'returns empty when no hotel matches the filter' {
        $sel = @(Select-Hotels -Hotels $script:Pool -HotelCode 'NOPE')
        $sel.Count | Should -Be 0
    }
}

Describe 'Get-RunExitCode — exit-code computation' {
    It 'returns 0 when all hotels succeeded' {
        $res = @(
            @{ HotelCode='H1'; Status='Success' },
            @{ HotelCode='H2'; Status='NoData' }
        )
        Get-RunExitCode -Results $res | Should -Be 0
    }

    It 'returns 1 for partial failure' {
        $res = @(
            @{ HotelCode='H1'; Status='Success' },
            @{ HotelCode='H2'; Status='Failed' }
        )
        Get-RunExitCode -Results $res | Should -Be 1
    }

    It 'returns 2 for total failure' {
        $res = @(
            @{ HotelCode='H1'; Status='Failed' },
            @{ HotelCode='H2'; Status='Failed' }
        )
        Get-RunExitCode -Results $res | Should -Be 2
    }

    It 'returns 0 when no hotels were processed' {
        Get-RunExitCode -Results @() | Should -Be 0
    }
}

Describe 'Get-ModeQuerySet — mode behaviour matrix' {
    It 'MasterData -> DIM only' {
        (Get-ModeQuerySet -Mode MasterData) | Should -Be @('DIM')
    }
    It 'OTB -> OTB, BLK, RMN (no RES/FIN/DIM)' {
        $set = Get-ModeQuerySet -Mode OTB
        $set | Should -Not -Contain 'RES'
        $set | Should -Not -Contain 'DIM'
        $set | Should -Contain 'OTB'
    }
    It 'Delta -> RES/FIN/OTB/BLK/RMN, no DIM' {
        (Get-ModeQuerySet -Mode Delta) | Should -Not -Contain 'DIM'
        (Get-ModeQuerySet -Mode Delta) | Should -Contain 'RES'
    }
    It 'Full and All include DIM + actuals + snapshots' {
        (Get-ModeQuerySet -Mode Full) | Should -Contain 'DIM'
        (Get-ModeQuerySet -Mode All)  | Should -Contain 'RES'
    }
}

Describe 'DryRun skips all writes (injected fakes)' {
    It 'invokes queries but never calls any writer under -DryRun' {
        $script:WriteCalls = 0
        $script:QueryCalls = 0
        $q = @{
            RES = { param($a) $script:QueryCalls++; @([pscustomobject]@{ x = 1 }) }
            FIN = { param($a) $script:QueryCalls++; @([pscustomobject]@{ x = 1 }) }
            OTB = { param($a) $script:QueryCalls++; @([pscustomobject]@{ x = 1 }) }
            BLK = { param($a) $script:QueryCalls++; @([pscustomobject]@{ x = 1 }) }
            RMN = { param($a) $script:QueryCalls++; @{ RMN = @([pscustomobject]@{ r = 1 }); OOO = @() } }
            DIM = { param($a) $script:QueryCalls++; @() }
        }
        $w = @{
            RES = { param($a) $script:WriteCalls++ }
            FIN = { param($a) $script:WriteCalls++ }
            OTB = { param($a) $script:WriteCalls++ }
            BLK = { param($a) $script:WriteCalls++ }
            RMN = { param($a) $script:WriteCalls++ }
            DIM = { param($a) $script:WriteCalls++ }
        }
        $res = Invoke-HotelLoad -Hotel (New-FakeHotel) -Mode Delta -Queries $q -Writers $w `
            -DryRun -BusinessDate ([datetime]'2026-07-30') -BusinessDateResolver $script:FakeBizDate
        $script:QueryCalls | Should -BeGreaterThan 0
        $script:WriteCalls | Should -Be 0
        $res.WroteAny | Should -BeFalse
        $res.Rows | Should -BeGreaterThan 0
    }

    It 'DOES call writers when not a dry run' {
        $script:WriteCalls2 = 0
        $q = @{
            RES = { param($a) @([pscustomobject]@{ x = 1 }) }
            FIN = { param($a) @() }
            OTB = { param($a) @() }
            BLK = { param($a) @() }
            RMN = { param($a) @{ RMN = @(); OOO = @() } }
        }
        $w = @{
            RES = { param($a) $script:WriteCalls2++ }
            FIN = { param($a) $script:WriteCalls2++ }
            OTB = { param($a) $script:WriteCalls2++ }
            BLK = { param($a) $script:WriteCalls2++ }
            RMN = { param($a) $script:WriteCalls2++ }
        }
        $null = Invoke-HotelLoad -Hotel (New-FakeHotel) -Mode Delta -Queries $q -Writers $w `
            -BusinessDate ([datetime]'2026-07-30') -BusinessDateResolver $script:FakeBizDate
        $script:WriteCalls2 | Should -BeGreaterThan 0
    }
}

Describe 'Write-SummaryTable — content' {
    It 'contains the column headers and hotel rows' {
        $res = @(
            @{ HotelCode='HOTEL1'; ChainCode='CHAIN_A'; Status='Success'; Rows=42; Duration=[timespan]::FromSeconds(65) },
            @{ HotelCode='HOTEL2'; ChainCode='CHAIN_B'; Status='Failed'; Rows=0; Duration=[timespan]::Zero }
        )
        $table = Write-SummaryTable -Results $res
        $table | Should -Match 'Hotel'
        $table | Should -Match 'Status'
        $table | Should -Match 'Rows'
        $table | Should -Match 'Duration'
        $table | Should -Match 'HOTEL1'
        $table | Should -Match 'HOTEL2'
        $table | Should -Match 'Success'
        $table | Should -Match 'Failed'
        # 65s -> 00:01:05
        $table | Should -Match '00:01:05'
    }

    It 'handles the no-hotels case' {
        Write-SummaryTable -Results @() | Should -Match 'No hotels'
    }
}

Describe 'Invoke-Loader — end-to-end with fakes' {
    It 'processes filtered hotels and returns ExitCode 0 on all success' {
        $hotels = @((New-FakeHotel 'HOTEL1' 'CHAIN_A'), (New-FakeHotel 'HOTEL2' 'CHAIN_B'))
        $q = @{
            RES = { param($a) @([pscustomobject]@{ x = 1 }) }
            FIN = { param($a) @() }
            OTB = { param($a) @() }
            BLK = { param($a) @() }
            RMN = { param($a) @{ RMN = @(); OOO = @() } }
            DIM = { param($a) @() }
        }
        $script:AnyWrite = 0
        $w = @{
            RES = { param($a) $script:AnyWrite++ }
            FIN = { param($a) $script:AnyWrite++ }
            OTB = { param($a) $script:AnyWrite++ }
            BLK = { param($a) $script:AnyWrite++ }
            RMN = { param($a) $script:AnyWrite++ }
            DIM = { param($a) $script:AnyWrite++ }
        }
        $run = Invoke-Loader -Mode Delta -ConfigDir 'C:\fake' `
            -Queries $q -Writers $w `
            -CredentialTester $script:PassCreds -TokenProvider $script:FakeToken `
            -BusinessDateResolver $script:FakeBizDate `
            -ConfigResolver { param($d) New-FakeConfigResult -Hotels $hotels }
        $run.ExitCode | Should -Be 0
        $run.Results.Count | Should -Be 2
        $script:AnyWrite | Should -BeGreaterThan 0
    }

    It 'isolates a per-hotel failure (partial) without -FailFast' {
        $hotels = @((New-FakeHotel 'HOTEL1' 'CHAIN_A'), (New-FakeHotel 'HOTEL2' 'CHAIN_B'))
        # Credential tester fails only HOTEL2.
        $tester = { param($h) if ([string]$h.hotelCode -eq 'HOTEL2') { @{ Ok = $false; Reason = 'bad creds' } } else { @{ Ok = $true; Reason = '' } } }
        $q = @{ RES = { param($a) @([pscustomobject]@{ x = 1 }) }; FIN = { @() }; OTB = { @() }; BLK = { @() }; RMN = { @{ RMN=@(); OOO=@() } }; DIM = { @() } }
        $w = @{ RES = { }; FIN = { }; OTB = { }; BLK = { }; RMN = { }; DIM = { } }
        $run = Invoke-Loader -Mode Delta -ConfigDir 'C:\fake' `
            -Queries $q -Writers $w `
            -CredentialTester $tester -TokenProvider $script:FakeToken `
            -BusinessDateResolver $script:FakeBizDate `
            -ConfigResolver { param($d) New-FakeConfigResult -Hotels $hotels }
        $run.ExitCode | Should -Be 1
        @($run.Results | Where-Object { $_.Status -eq 'Failed' }).Count | Should -Be 1
    }

    It 'returns ExitCode 0 and a no-op summary when the filter matches nothing' {
        $hotels = @((New-FakeHotel 'HOTEL1' 'CHAIN_A'))
        $run = Invoke-Loader -Mode Delta -ConfigDir 'C:\fake' -HotelCode 'NOPE' `
            -CredentialTester $script:PassCreds -TokenProvider $script:FakeToken `
            -BusinessDateResolver $script:FakeBizDate `
            -ConfigResolver { param($d) New-FakeConfigResult -Hotels $hotels }
        $run.ExitCode | Should -Be 0
        $run.Results.Count | Should -Be 0
        $run.Summary | Should -Match 'No hotels'
    }

    It 'stops after first failure when -FailFast is set (total failure -> ExitCode 2)' {
        $hotels = @((New-FakeHotel 'HOTEL1' 'CHAIN_A'), (New-FakeHotel 'HOTEL2' 'CHAIN_B'))
        $tester = { param($h) @{ Ok = $false; Reason = 'bad creds' } }
        $q = @{ RES = { @() }; FIN = { @() }; OTB = { @() }; BLK = { @() }; RMN = { @{ RMN=@(); OOO=@() } }; DIM = { @() } }
        $w = @{ RES = { }; FIN = { }; OTB = { }; BLK = { }; RMN = { }; DIM = { } }
        $run = Invoke-Loader -Mode Delta -ConfigDir 'C:\fake' -FailFast `
            -Queries $q -Writers $w `
            -CredentialTester $tester -TokenProvider $script:FakeToken `
            -BusinessDateResolver $script:FakeBizDate `
            -ConfigResolver { param($d) New-FakeConfigResult -Hotels $hotels }
        # Only the first hotel is attempted before aborting.
        $run.Results.Count | Should -Be 1
        $run.ExitCode | Should -Be 2
    }
}

Describe 'Test-HotelCredentials — decryption seam' {
    It 'reports Ok when the decryptor succeeds for all three fields' {
        $dec = { param($cipher, $field) $true }
        $r = Test-HotelCredentials -Hotel (New-FakeHotel) -Decryptor $dec
        $r.Ok | Should -BeTrue
    }

    It 'reports failure (never leaking the value) when decryption throws' {
        $dec = { param($cipher, $field) throw 'boom' }
        $r = Test-HotelCredentials -Hotel (New-FakeHotel) -Decryptor $dec
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'decrypt'
        $r.Reason | Should -Not -Match 'enc-clientId'
    }
}
