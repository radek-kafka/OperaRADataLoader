# Tasks: OPERA R&A Data Loader

## Task 1 – Project Scaffold & Configuration
- [x] Create folder structure: `Config\`, `Modules\`, `Modules\Queries\`, `SQL\`, `Tools\`, `Logs\`
- [x] Create `Config\settings.json` with all global settings: SQL Server, API throttle, extraction horizons (`otbFutureDays`, `blockFutureDays`, `transactionalChunkDays`), logging (`logDirectory`, `logLevel`, `sqlLogging`, `logName` — a single shared log file for the whole run), and a shared SMTP transport block (`smtpServer`, `port`, `useSsl`, `from`, `enabled`, and DPAPI-encrypted `username`/`password`) — recipients are NOT global
- [x] Create `Config\hotels.sample.json` with two sample hotels across two different chains (plain text, no real credentials), including `otbFutureDays`, `blockFutureDays`, `nightAuditHour`, `timeZoneId`, and a per-hotel `emailAlerts` block (`enabled` + per-severity `to[]`/`cc[]` for INFO/WARN/ERROR)
- [x] Create `.gitignore` excluding `Config\hotels.json`, `Logs\`, `Config\hotels.input.json`

## Task 2 – Logger Module (`Modules\Logger.psm1`)
- [x] (REBUILD) Implement `Initialize-Logger` — called ONCE at startup by the orchestrator; sets `$script:LogFilePath` to the single shared file `{LogDirectory}\{yyyyMMdd}_{logName}.log` using `logging.logDirectory` + single `logging.logName` from `settings.json` (no per-query-type files); creates `LogDirectory` if absent; opens in append mode so re-runs on the same day accumulate in the same file
- [x] (REBUILD) Implement `Write-Log` with levels INFO / WARN / ERROR / DEBUG; format: `YYYY-MM-DD HH:mm:ss.fff [LEVEL] [HotelCode] [BatchId] Message`; writes to the single shared `$script:LogFilePath` (one common file for the whole run — orchestrator + all query modules)
- [x] Use a single shared log file for the entire run: `Initialize-Logger` is called once at startup by the orchestrator, and every module (orchestrator + all query modules) writes to the same `$script:LogFilePath`. Distinguish sources via the `[HotelCode]` / `[BatchId]` / `[LEVEL]` columns, not separate files
- [x] Log file directory and single log name read from `settings.json` `logging.logDirectory` and `logging.logName`; file name resolves to `{yyyyMMdd}_{logName}.log`
- [x] Implement `Start-Batch` returning a new `[guid]` BatchId; write initial `Running` row to `dbo.LoadLog`
- [x] Implement `Complete-Batch` updating `dbo.LoadLog` with final status, row counts, duration
- [x] Implement `Send-AlertEmail` via `Net.Mail.SmtpClient` using the shared SMTP transport from `settings.json` (server, port, from, useSsl, DPAPI-decrypted username/password); resolve recipients per hotel from `hotels.json` `emailAlerts.<severity>.to[]` / `cc[]`; send end-of-run summary only when `smtp.enabled` AND the hotel's `emailAlerts.enabled` AND that severity is enabled AND recipients exist; attach the daily log file; delivery failure logs WARN and never aborts the run (REQ-016)
- [x] Mask sensitive patterns (bearer tokens, secrets, API keys) with `****` in all log output
- [x] Support `-Verbose` and `-Debug` PowerShell switches via `$VerbosePreference` / `$DebugPreference`

## Task 3 – DateHelper Module (`Modules\DateHelper.psm1`)
- [x] Implement `Get-BusinessDate` — resolves hotel local yesterday accounting for `nightAuditHour` and `timeZoneId`
- [x] Implement `Convert-ToUtc` and `Convert-ToLocal` using `[TimeZoneInfo]::FindSystemTimeZoneById`
- [x] Implement `Format-OutputDate` (date-only → `YYYYMMDD`) and `Format-OutputDateTime` (datetime → `YYYYMMDD HH:mm:ss`); empty/null → empty string. Used by RES/OTB/FIN output. Note: does NOT apply to GraphQL API request filters, which keep ISO `YYYY-MM-DD`
- [x] Implement `Get-DateRangeChunks` — splits a date range into chunks of N days (configurable, default 7 for transactional data)
- [x] Implement `Get-SnapshotHorizon` — returns `SnapshotDate`, `ConsideredDateStart`, `ConsideredDateEnd` based on hotel `otbFutureDays` / `blockFutureDays`
- [x] Cover edge cases: DST transition nights, `nightAuditHour = 0` (midnight), missing config fallback to 00:00

## Task 4 – Auth Module (`Modules\Auth.psm1`)
- [x] Implement in-memory token cache `$script:TokenCache` keyed by `HotelCode`
- [x] Implement `Get-OAuthToken` — POST `/oauth/token` with `client_credentials` grant; parse `access_token` + `expires_in`
- [x] Implement token expiry check: `ExpiresAt > (Now + SafetyMarginSeconds)`
- [x] Implement `Clear-TokenCache -HotelCode` for forced refresh on 401
- [x] Decrypt `ClientId` and `ClientSecret` from DPAPI-encrypted config before use; never log either value

## Task 5 – ApiClient Module (`Modules\ApiClient.psm1`)
- [x] Implement `Invoke-RAApi` with header injection: `Authorization: Bearer`, `x-app-key`, `x-hotelid`, `Content-Type: application/json`
- [x] Implement HTTP 401 handler: `Clear-TokenCache` → `Get-OAuthToken` → retry once
- [x] Implement retry with exponential backoff on 429 / 500 / 502 / 503 / 504 (base 2 s, ×2 per attempt, cap 30 s, max 3 retries)
- [x] Implement pagination loop consuming `nextPageToken` or offset-based paging; collect all pages into single result array
- [x] Implement per-request throttle: `Start-Sleep -Milliseconds $config.api.requestDelayMs` between page calls
- [x] Return normalised `[array]` of `[PSCustomObject]` with consistent field names

## Task 6 – SQL Server DDL Scripts (`SQL\`)
- [x] `SQL\001_CreateSchema.sql` — create schema `ra` with `IF NOT EXISTS` guard
- [x] `SQL\002_CreateTables_Actuals.sql` — `dbo.LoadLog`, `ra.ReservationStats`, `ra.FinancialTx`
  - `ra.ReservationStats` natural key: `HotelCode + BusinessDate + ReservationId + MarketSegment + RoomTypeLabel`
  - `ra.FinancialTx` natural key: `HotelCode + BusinessDate + ReservationId + FolioNo + TrxCode + PostingDate + Amount`; `IsLatePosting BIT DEFAULT 0`; `PostingDateLocal` + `PostingDateUtc`
- [x] `SQL\003_CreateTables_Snapshots.sql` — `ra.OnTheBooks`, `ra.BlockReservations`, `ra.RoomInventory`
  - OTB natural key: `HotelCode + SnapshotDate + ConsideredDate + MarketSegment + RoomTypeLabel + ReservationSource + Channel`
  - Block natural key: `HotelCode + SnapshotDate + BlockCode + ConsideredDate + RoomTypeLabel`; `IsPastCutoff BIT DEFAULT 0`
  - Inventory natural key: `HotelCode + InventoryDate + RoomTypeLabel`
- [x] `SQL\004_CreateTables_MasterData.sql` — `ra.TrxCodes`, `ra.RoomTypeLabels`, `ra.MarketSegments`, `ra.RateCodes`, `ra.ReservationSources`, `ra.Channels`, `ra.Hotels`
  - All master tables include SCD Type 2 columns: `ValidFrom DATE NOT NULL`, `ValidTo DATE NULL`, `IsCurrent BIT NOT NULL DEFAULT 1`
  - `ra.TrxCodes` includes: `TrxGroup`, `TrxType`, `RevenueYN`, `IncludedInRoomRevenueYN`, `IncludedInPackageYN`
  - `ra.RoomTypeLabels` includes: `RoomClass`, `PhysicalRoomCount`
  - `ra.RateCodes` includes: `RateCategory`
  - `ra.MarketSegments` includes: `SegmentGroup`
- [x] `SQL\005_CreateIndexes.sql` — indexes on `HotelCode`, `BusinessDate`/`SnapshotDate`/`ConsideredDate`/`InventoryDate`, `BatchId`, `ReservationId`, `TrxCode`, `IsCurrent`

## Task 7 – SqlWriter Module (`Modules\SqlWriter.psm1`)
- [x] Implement `Initialize-Database` — execute DDL scripts 001–005 idempotently on startup
- [x] Implement `Write-ReservationStats` — `SqlBulkCopy` to staging → `MERGE` into `ra.ReservationStats` on natural key
- [x] Implement `Write-FinancialTx` — `SqlBulkCopy` to staging → `MERGE` into `ra.FinancialTx`; compute `IsLatePosting` during mapping
- [x] Implement `Write-OnTheBooks` — `SqlBulkCopy` to staging → `MERGE` into `ra.OnTheBooks` (insert new `SnapshotDate` rows; do not overwrite prior snapshots)
- [x] Implement `Write-BlockReservations` — `SqlBulkCopy` to staging → `MERGE` into `ra.BlockReservations`; set `IsPastCutoff` where `CutoffDate < SnapshotDate`
- [x] Implement `Write-RoomInventory` — `SqlBulkCopy` to staging → `MERGE` into `ra.RoomInventory` on natural key
- [x] Implement `Write-MasterData` — SCD Type 2 MERGE for all seven master tables:
  - On change detected: `UPDATE` existing record (`ValidTo = today - 1`, `IsCurrent = 0`), `INSERT` new version row
  - On no change: no-op (skip update to avoid unnecessary churn)
  - On new code: `INSERT` with `ValidFrom = today`, `ValidTo = NULL`, `IsCurrent = 1`
- [x] Implement `Write-LoadLog` — insert initial `Running` row and update on completion

## Task 8 – Reservation Statistics Query (`Modules\Queries\ReservationStats.psm1`)
- [x] Implement `Get-ReservationStats -Hotel -StartDate -EndDate`
- [x] Build R&A API request body for the reservation statistics endpoint; apply date chunking via `Get-DateRangeChunks`
- [x] Map API response fields to flat `[PSCustomObject]` matching `ra.ReservationStats` schema including `ReservationId`, `MarketSegment`, `RoomTypeLabel`, `ReservationSource`, `Channel`
- [x] Format output date fields with `Format-OutputDate` / `Format-OutputDateTime`: date-only (`BUSINESS_DATE`, `TRUNC_BEGIN_DATE`, `TRUNC_END_DATE`) → `YYYYMMDD`; datetime (`CANCELLATION_DATE`) → `YYYYMMDD HH:mm:ss`
- [x] Compute `ADR` and `RevPAR` if not returned directly by API (`ADR = Revenue / RoomNights`; `RevPAR = Revenue / PhysicalRooms`)
- [x] Log row count and duration per date chunk per hotel

## Task 9 – Financial Transactions Query (`Modules\Queries\FinancialTransactions.psm1`)
- [x] Implement `Get-FinancialTransactions -Hotel -StartDate -EndDate`
- [x] Build R&A API request body for the financial/folio transactions endpoint; apply date chunking
- [x] Map API response to flat `[PSCustomObject]` matching `ra.FinancialTx` schema including `ReservationId`, `TrxCode`, `TrxType`, `PostingDate`
- [x] Populate `PostingDateLocal` (hotel TZ) and `PostingDateUtc` using `Convert-ToUtc`
- [x] Format output date fields with the DateHelper formatters: date-only (`BUSINESS_DATE`) → `YYYYMMDD`; datetime (`TRX_DATE`, `TRX_DATE_UTC`) → `YYYYMMDD HH:mm:ss`
- [x] Set `IsLatePosting = 1` where `PostingDate > BusinessDate`; log WARN with count if any late postings found

## Task 10 – On-The-Books Query (`Modules\Queries\OnTheBooks.psm1`)
- [x] Implement `Get-OnTheBooks -Hotel -SnapshotDate -FutureDays`
- [x] Use `Get-SnapshotHorizon` to build `ConsideredDateStart` / `ConsideredDateEnd` range
- [x] Build R&A API request body for OTB endpoint
- [x] Map response fields to `ra.OnTheBooks` schema: `SnapshotDate`, `ConsideredDate`, `MarketSegment`, `RoomTypeLabel`, `ReservationSource`, `Channel`, `RoomsOnBooks`, `TentativeRooms`, `DefiniteRooms`, `ADROnBooks`, `RevenueOnBooks`
- [x] Format output date fields with `Format-OutputDate`: date-only (`SNAPSHOT_DATE`, `CONSIDERED_DATE`, `TRUNC_BEGIN_DATE`, `TRUNC_END_DATE`) → `YYYYMMDD`
- [x] Log snapshot date, considered date range, and row count

## Task 11 – Block Reservations Query (`Modules\Queries\BlockReservations.psm1`)
- [x] Implement `Get-BlockReservations -Hotel -SnapshotDate -FutureDays`
- [x] Build R&A API request body for group block endpoint
- [x] Map response to `ra.BlockReservations` schema: `SnapshotDate`, `ConsideredDate`, `BlockCode`, `BlockName`, `RoomTypeLabel`, `MarketSegment`, `RoomsContracted`, `RoomsPickedUp`, `RoomsRemaining`, `CutoffDate`
- [x] Compute `IsPastCutoff = 1` where `CutoffDate < SnapshotDate`; log WARN count if any

## Task 12 – Room Inventory Query (`Modules\Queries\RoomInventory.psm1`)
- [x] Implement `Get-RoomInventory -Hotel -StartDate -EndDate`
- [x] Build R&A API request for room inventory / availability endpoint
- [x] Map response to `ra.RoomInventory` schema: `InventoryDate`, `RoomTypeLabel`, `PhysicalRooms`, `OutOfOrder`, `OutOfService`
- [x] Compute `AvailableRooms = PhysicalRooms - OutOfOrder - OutOfService` if not returned by API
- [x] Support both historical (actuals) and future (forecast) date ranges in a single call

## Task 13 – Master Data Query (`Modules\Queries\MasterData.psm1`)
- [x] Implement `Get-MasterData -Hotel -Type -ChangedSince`; `-Type` accepts: `TrxCodes`, `RoomTypeLabels`, `RateCodes`, `MarketCodes`, `SourceCodes` (source of reservation — PRIORITY/required), `Channels` (distribution channel — OPTIONAL), `Hotels`. `SourceCodes` and `Channels` are two independent code lists and MUST NOT be merged
- [x] Implement full refresh mode (no `-ChangedSince`) and delta mode (pass `ChangedSince` filter to API)
- [x] Map `TrxCodes` response: `TrxCode`, `TrxName`, `TrxGroup`, `TrxType`, `RevenueYN`, `IncludedInRoomRevenueYN`, `IncludedInPackageYN`, `IsActive`
- [x] Map `RoomTypeLabels` response: `RoomTypeLabel`, `Description`, `RoomClass`, `PhysicalRoomCount`, `IsActive`
- [x] Map `MarketCodes` (market segment) from `ExportMappings` to `ra.DIM_MarketCodes`: `Code`, `Description`, `SegmentGroup`, `IsActive`
- [x] Map `RateCodes`: `Code`, `Description`, `RateCategory`, `IsActive`
- [x] Map `SourceCodes` (source of reservation, OPERA `SOURCE_CODE`) from `ExportMappings` to `ra.DIM_SourceCodes`: `Code`, `Description`, `IsActive` — PRIORITY / required dimension, always loaded; a missing source list is treated as an error
- [x] Map `Channels` (distribution channel, OPERA `CHANNEL` — e.g. GDS/OTA/Direct/Web/CRO) from `ExportMappings` to `ra.DIM_Channels`: `Code`, `Description`, `IsActive`; keep as a separate list from `SourceCodes` — OPTIONAL / best-effort: skip WITHOUT failing the run (log INFO/WARN) if the channel list is unavailable or absent
- [x] Detect and log changes between current DB records and API response (new codes, description changes, deactivations)

## Task 14 – Credential Protection Utility (`Tools\Protect-HotelsConfig.ps1`)
- [x] Read plain-text `Config\hotels.input.json` (never committed to source control)
- [x] Encrypt `clientId`, `clientSecret`, `apiKey` per hotel, and the shared `smtp.username`/`smtp.password` in `settings.json`, using `ConvertTo-SecureString` with DPAPI
- [x] Write encrypted values to `Config\hotels.json`; copy all other fields unchanged
- [x] Verify round-trip decryption for each value before writing; abort on mismatch
- [x] Add usage comment header to script with instructions for service account setup

## Task 15 – Entry Point Orchestrator (`Run-OperaRALoader.ps1`)
- [x] Declare all parameters: `-Mode`, `-HotelCode`, `-ChainCode`, `-BusinessDate`, `-StartDate`, `-EndDate`, `-DryRun`, `-FailFast`, `-ConfigPath`
- [x] Load and validate `settings.json` and `hotels.json` at startup; fail fast on missing required fields
- [x] Decrypt hotel credentials (DPAPI); validate decryption before proceeding
- [x] Filter hotel list by `-HotelCode` / `-ChainCode` when specified
- [x] Call `Initialize-Database` when `-Mode Full` or on first run (no schema present)
- [x] Per-hotel execution loop:
  - `Start-Batch` → `Get-OAuthToken`
  - Based on `-Mode`: call relevant query modules in order: MasterData → ReservationStats → FinancialTx → OTB → BlockReservations → RoomInventory
  - Respect `-DryRun`: skip all `Write-*` calls, log `[DRYRUN]` prefix
  - Catch per-hotel errors: log ERROR + `Complete-Batch` with `Error` status; continue unless `-FailFast`
- [x] Output summary table to console on completion: Hotel | Status | Rows | Duration
- [x] Set `exit` code: 0 = all success, 1 = partial failure, 2 = total failure

## Task 16 – Documentation & README (`README.md`)
- [x] Prerequisites: PowerShell 7.x, SQL Server, network access to OPERA Cloud R&A API
- [x] Installation steps: clone, run `Protect-HotelsConfig.ps1`, configure `settings.json`
- [x] Scheduling guidance: Windows Task Scheduler XML template and SQL Agent job example
- [x] Full parameter reference table for `Run-OperaRALoader.ps1`
- [x] SQL schema overview with entity relationship notes (RES ↔ FIN via `BusinessDate + ReservationId`; OTB/Block `SnapshotDate + ConsideredDate` pattern)
- [x] Troubleshooting section: token errors, late postings, SCD2 rollback procedure
- [x] Add `# GenAI-generated code — reviewed and approved by: <name> <date>` header to all `.ps1` / `.psm1` files per Infor policy
- [x] Document exit codes and monitoring integration guidance
