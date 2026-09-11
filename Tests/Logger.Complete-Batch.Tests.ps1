# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

<#
.SYNOPSIS
    Pester tests for Logger.psm1 Complete-Batch — non-SQL behavior paths only.

.DESCRIPTION
    Validates the branches of Complete-Batch that can run without a live SQL Server:
      1. SqlLogging disabled  -> returns without throwing, writes the INFO completion line.
      2. Invalid -Status      -> rejected by ValidateSet (never reaches SQL).
      3. SqlLogging enabled but no connection string configured -> logs WARN, never throws.

    No live database is required or contacted. The logger is pointed at a per-test
    temporary directory so the shared log file can be inspected and cleaned up. The
    module-scoped $script:SqlLogging / $script:SqlConnectionString flags are set via
    InModuleScope so no real settings.json or SQL Server is involved.

    Requires Pester 5.0+ (tested on Pester 6.x).
#>

BeforeAll {
    $script:ModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\Logger.psm1'
    Import-Module $script:ModulePath -Force

    # Each test run gets its own isolated temp log directory so we never touch the
    # real Logs\ folder and can assert on / clean up the produced file.
    $script:TestLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ("OperaRALoggerTests_" + [guid]::NewGuid().ToString('N'))

    # Reset any process-scoped shared-log markers left over from other runs so the
    # idempotency guard in Initialize-Logger does not short-circuit our -Force init.
    foreach ($v in 'OPERARA_LOG_FILEPATH', 'OPERARA_LOG_LEVEL', 'OPERARA_LOG_SQLLOGGING') {
        [System.Environment]::SetEnvironmentVariable($v, $null, [System.EnvironmentVariableTarget]::Process)
    }

    # Initialize the logger to the temp directory. DEBUG level so completion DEBUG/INFO
    # lines are all captured in the file for assertions. -Force to bypass the once-per-
    # process idempotency guard.
    $script:LogFilePath = Initialize-Logger -LogDirectory $script:TestLogDir -LogLevel 'DEBUG' -LogName 'LoggerTest' -Force

    # Helper: read the current contents of the shared log file (empty string if absent).
    function Get-LogContent {
        if (Test-Path -LiteralPath $script:LogFilePath) {
            return (Get-Content -LiteralPath $script:LogFilePath -Raw)
        }
        return ''
    }
}

AfterAll {
    # Remove the module-scoped state and the temp log directory.
    if ($script:TestLogDir -and (Test-Path -LiteralPath $script:TestLogDir)) {
        Remove-Item -LiteralPath $script:TestLogDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($v in 'OPERARA_LOG_FILEPATH', 'OPERARA_LOG_LEVEL', 'OPERARA_LOG_SQLLOGGING') {
        [System.Environment]::SetEnvironmentVariable($v, $null, [System.EnvironmentVariableTarget]::Process)
    }
    Remove-Module Logger -Force -ErrorAction SilentlyContinue
}

Describe 'Complete-Batch — SqlLogging disabled' {

    BeforeEach {
        # Ensure SQL mirroring is OFF for this context.
        InModuleScope Logger {
            $script:SqlLogging = $false
            $script:SqlConnectionString = $null
        }
    }

    It 'returns without throwing and writes the INFO batch-completed summary line' {
        $batchId = [guid]::NewGuid()

        # Capture file length before the call so we only inspect newly-written lines.
        $before = Get-LogContent

        { Complete-Batch -BatchId $batchId -Status 'Success' `
                -RowsFetched 1200 -RowsInserted 1100 -RowsUpdated 100 `
                -HotelCode 'HOTEL1' } | Should -Not -Throw

        $after = Get-LogContent
        $newText = $after.Substring($before.Length)

        # INFO completion summary line present, containing the status and row counts.
        $newText | Should -Match '\[INFO\]'
        $newText | Should -Match 'Batch completed\.'
        $newText | Should -Match 'Status=Success'
        $newText | Should -Match 'RowsFetched=1200'
        $newText | Should -Match 'RowsInserted=1100'
        $newText | Should -Match 'RowsUpdated=100'
        # The BatchId should be present for correlation.
        $newText | Should -Match ([regex]::Escape($batchId.ToString()))
    }

    It 'renders omitted row counts as not-available (n slash a) in the summary and does not throw' {
        $batchId = [guid]::NewGuid()
        $before = Get-LogContent

        { Complete-Batch -BatchId $batchId -Status 'NoData' -HotelCode 'HOTEL2' } | Should -Not -Throw

        $newText = (Get-LogContent).Substring($before.Length)
        $newText | Should -Match 'Status=NoData'
        $newText | Should -Match 'RowsFetched=<n/a>'
    }

    It 'writes a DEBUG line noting the SQL update was skipped' {
        $batchId = [guid]::NewGuid()
        $before = Get-LogContent

        Complete-Batch -BatchId $batchId -Status 'Success' -HotelCode 'HOTEL1'

        $newText = (Get-LogContent).Substring($before.Length)
        $newText | Should -Match 'SqlLogging disabled'
    }
}

Describe 'Complete-Batch — Status validation' {

    It 'rejects an invalid Status value via ValidateSet' {
        $batchId = [guid]::NewGuid()
        { Complete-Batch -BatchId $batchId -Status 'Bogus' } | Should -Throw
    }

    It 'accepts each documented terminal status' -ForEach @(
        @{ Status = 'Success' }
        @{ Status = 'NoData' }
        @{ Status = 'Error' }
        @{ Status = 'Partial' }
    ) {
        InModuleScope Logger { $script:SqlLogging = $false; $script:SqlConnectionString = $null }
        $batchId = [guid]::NewGuid()
        { Complete-Batch -BatchId $batchId -Status $Status } | Should -Not -Throw
    }
}

Describe 'Complete-Batch — SqlLogging enabled without connection string' {

    BeforeEach {
        # SQL mirroring requested, but no connection string resolvable anywhere.
        InModuleScope Logger {
            $script:SqlLogging = $true
            $script:SqlConnectionString = $null
        }
    }

    AfterEach {
        InModuleScope Logger {
            $script:SqlLogging = $false
            $script:SqlConnectionString = $null
        }
    }

    It 'never throws and logs a WARN that no connection string is configured' {
        $batchId = [guid]::NewGuid()
        $before = Get-LogContent

        { Complete-Batch -BatchId $batchId -Status 'Error' `
                -ErrorMessage 'HTTP 503 after retries' -HotelCode 'HOTEL1' } | Should -Not -Throw

        $newText = (Get-LogContent).Substring($before.Length)
        $newText | Should -Match '\[WARN\]'
        $newText | Should -Match 'no SQL connection string is configured'
        # It must NOT have attempted the completion DEBUG success path.
        $newText | Should -Not -Match 'row\(s\) affected'
    }
}
