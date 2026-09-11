#requires -Version 7.0
# TEMPORARY verification script for the single-shared-file guarantee (Task 2).
# Simulates the orchestrator + two query modules importing Logger.psm1 into SEPARATE
# module script scopes, calls Initialize-Logger exactly ONCE, writes from all sources,
# and asserts exactly ONE log file exists containing lines from every source.
$ErrorActionPreference = 'Stop'

$root      = Split-Path -Parent $PSScriptRoot
$loggerPsm = Join-Path $root 'Modules\Logger.psm1'
$logDir    = Join-Path $env:TEMP ("OperaRA_SharedLogTest_{0}" -f ([guid]::NewGuid().ToString('N')))

$failures = @()

try {
    # --- "Orchestrator" module instance ---------------------------------------
    # -Force guarantees a fresh, separate module script scope (worst case for the
    # single-file guarantee).
    $orch = Import-Module $loggerPsm -Force -PassThru

    # Called ONCE at startup by the orchestrator.
    $path1 = & $orch { Initialize-Logger -LogDirectory $args[0] -LogLevel 'DEBUG' -SqlLogging $false -LogName 'OperaRA_Loader' } $logDir
    Write-Host "Initialize-Logger returned: $path1"

    # --- "Query module A" instance (separate script scope) --------------------
    $modA = Import-Module $loggerPsm -Force -PassThru
    # --- "Query module B" instance (separate script scope) --------------------
    $modB = Import-Module $loggerPsm -Force -PassThru

    # Idempotency: a second Initialize-Logger call in the process must NOT make a new file.
    $path2 = & $modA { Initialize-Logger -LogDirectory ($args[0] + '_DIFFERENT') -LogName 'SHOULD_NOT_BE_USED' } $logDir
    if ($path2 -ne $path1) {
        $failures += "Idempotency guard failed: second Initialize-Logger returned '$path2', expected '$path1'."
    }

    # Write from all three simulated sources without any of them re-initializing.
    & $orch { Write-Log -Level INFO  -Module 'Orchestrator'     -HotelCode ''       -Message 'Loader started' }
    & $modA { Write-Log -Level INFO  -Module 'ReservationStats' -HotelCode 'HOTEL1' -BatchId ([guid]::NewGuid()) -Message 'RES rows fetched' }
    & $modB { Write-Log -Level ERROR -Module 'FinancialTx'      -HotelCode 'HOTEL2' -BatchId ([guid]::NewGuid()) -Message 'HTTP 503 after retries' }
    & $modB { Write-Log -Level DEBUG -Module 'FinancialTx'      -HotelCode 'HOTEL2' -Message 'debug detail' }

    # --- Assertions -----------------------------------------------------------
    $files = @(Get-ChildItem -Path $logDir -Filter '*.log' -File)
    if ($files.Count -ne 1) {
        $failures += "Expected exactly 1 log file, found $($files.Count): $($files.Name -join ', ')"
    }
    else {
        $lines = Get-Content -LiteralPath $files[0].FullName
        Write-Host "`n--- Log file contents ($($files[0].Name)) ---"
        $lines | ForEach-Object { Write-Host $_ }
        Write-Host "--- end ---`n"

        if (-not ($lines | Where-Object { $_ -match '\[INFO\].*Orchestrator: Loader started' }))       { $failures += 'Missing Orchestrator INFO line.' }
        if (-not ($lines | Where-Object { $_ -match '\[INFO\] \[HOTEL1\].*ReservationStats: RES rows' })) { $failures += 'Missing HOTEL1 ReservationStats line with HotelCode column.' }
        if (-not ($lines | Where-Object { $_ -match '\[ERROR\] \[HOTEL2\].*FinancialTx: HTTP 503' }))     { $failures += 'Missing HOTEL2 ERROR line with HotelCode column.' }
        if (-not ($lines | Where-Object { $_ -match '\[DEBUG\] \[HOTEL2\].*FinancialTx: debug detail' }))  { $failures += 'Missing HOTEL2 DEBUG line (level filtering).' }
        # BatchId column present on the RES/FIN lines (a GUID inside brackets).
        if (-not ($lines | Where-Object { $_ -match '\[HOTEL1\] \[[0-9a-fA-F-]{36}\]' }))                  { $failures += 'BatchId column not rendered for HOTEL1 line.' }
    }
}
catch {
    $failures += "Unhandled exception: $($_.Exception.Message)"
}
finally {
    # Clean up the process markers so this test does not leak into other runs.
    [System.Environment]::SetEnvironmentVariable('OPERARA_LOG_FILEPATH', $null, 'Process')
    [System.Environment]::SetEnvironmentVariable('OPERARA_LOG_LEVEL',    $null, 'Process')
    [System.Environment]::SetEnvironmentVariable('OPERARA_LOG_SQLLOGGING', $null, 'Process')
    Get-Module Logger | Remove-Module -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $logDir) { Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures.Count -gt 0) {
    Write-Host "`nVERIFICATION FAILED:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "`nVERIFICATION PASSED: exactly one shared log file, all sources present, idempotency guard held." -ForegroundColor Green
exit 0
