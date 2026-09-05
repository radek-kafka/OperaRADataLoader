# Tasks: OPERA R&A Data Loader

## Task 1 – Project Scaffold & Configuration
- [ ] Create folder structure: `Config\`, `Modules\`, `Modules\Queries\`, `SQL\`, `Tools\`, `Logs\`
- [ ] Create `Config\settings.json` with all global settings: SQL Server, API throttle, extraction horizons (`otbFutureDays`, `blockFutureDays`, `transactionalChunkDays`), logging (`logDirectory`, `logLevel`, `sqlLogging`, `logNames` for each query type: Loader, RES, FIN, OTB, DIM, RMN), SMTP
- [ ] Create `Config\hotels.sample.json` with two sample hotels across two different chains (plain text, no real credentials), including `otbFutureDays`, `blockFutureDays`, `nightAuditHour`, `timeZoneId`
- [ ] Create `.gitignore` excluding `Config\hotels.json`, `Logs\`, `Config\hotels.input.json`

## Task 2 – Logger Module (`Modules\Logger.psm1`)
- [ ] Implement `Initialize-Logger` — sets `$script:LogFilePath` using `{LogDirectory}\{yyyyMMdd}_{LogName}.log` pattern; creates `LogDirectory` if absent; opens in append mode so re-runs on same day accumulate in same file
- [ ] Implement `Write-Log` with levels INFO / WARN / ERROR / DEBUG; format: `YYYY-MM-DD HH:mm:ss.fff [LEVEL] [HotelCode] [BatchId] Message`
- [ ] Implement per-query-type log file routing: orchestrator writes to `{date}_OperaRA_Loader.log`; each query module calls `Initialize-Logger` with its own log name (`OperaRA_RES`, `OperaRA_FIN`, `OperaRA_OTB`, `OperaRA_DIM`, `OperaRA_RMN`) producing separate log files per run day
- [ ] Log file names and directory read from `settings.json` `logging.logDirectory` and `logging.logNames`
- [ ] Implement `Start-Batch` returning a new `[guid]` BatchId; write initial `Running` row to `dbo.LoadLog`
- [ ] Implement `Complete-Batch` updating `dbo.LoadLog` with final status, row counts, duration
- [ ] Implement `Send-AlertEmail` via `Net.Mail.SmtpClient`; trigger on ERROR if SMTP enabled; include log file path in email body
- [ ] Mask sensitive patterns (bearer tokens, secrets, API keys) with `****` in all log output
- [ ] Support `-Verbose` and `-Debug` PowerShell switches via `$VerbosePreference` / `$DebugPreference`

## Task 3 – DateHelper Module (`Modules\DateHelper.psm1`)
- [ ] Implement `Get-BusinessDate` — resolves hotel local yesterday accounting for `nightAuditHour` and `timeZoneId`
- [ ] Implement `Convert-ToUtc` and `Convert-ToLocal` using `[TimeZoneInfo]::FindSystemTimeZoneById`
- [ ] Implement `Get-DateRangeChunks` — splits a date range into chunks of N days (configurable, default 7 for transactional data)
- [ ] Implement `Get-SnapshotHorizon` — returns `SnapshotDate`, `ConsideredDateStart`, `ConsideredDateEnd` based on hotel `otbFutureDays` / `blockFutureDays`
- [ ] Cover edge cases: DST transition nights, `nightAuditHour = 0` (midnight), missing config fallback to 00:00

## Task 4 – Auth Module (`Modules\Auth.psm1`)
- [ ] Implement in-memory token cache `$script:TokenCache` keyed by `HotelCode`
- [ ] Implement `Get-OAuthToken` — POST `/oauth/token` with `client_credentials` grant; parse `access_token` + `expires_in`
- [ ] Implement token expiry check: `ExpiresAt > (Now + SafetyMarginSeconds)`
- [ ] Implement `Clear-TokenCache -HotelCode` for forced refresh on 401
- [ ] Decrypt `ClientId` and `ClientSecret` from DPAPI-encrypted config before use; never log either value

## Task 5 – ApiClient Module (`Modules\ApiClient.psm1`)
- [ ] Implement `Invoke-RAApi` with header injection: `Authorization: Bearer`, `x-app-key`, `x-hotelid`, `Content-Type: application/json`
- [ ] Implement HTTP 401 handler: `Clear-TokenCache` → `Get-OAuthToken` → retry once
- [ ] Implement retry with exponential backoff on 429 / 500 / 502 / 503 / 504 (base 2 s, ×2 per attempt, cap 30 s, max 3 retries)
- [ ] Implement pagination loop consuming `nextPageToken` or offset-based paging; collect all pages into single result array
- [ ] Implement per-request throttle: `Start-Sleep -Milliseconds $config.api.requestDelayMs` between page calls
- [ ] Return normalised `[array]` of `[PSCustomObject]` with consistent field names

## Task 6 – SQL Server DDL Scripts (`SQL\`)
- [ ] `SQL\001_CreateSchema.sql` — create schema `ra` with `IF NOT EXISTS` guard
- [ ] `SQL\002_CreateTables_Actuals.sql` — `dbo.LoadLog`, `ra.ReservationStats`, `ra.FinancialTx`
  - `ra.ReservationStats` natural key: `HotelCode + BusinessDate + ReservationId + MarketSegment + RoomTypeLabel`
  - `ra.FinancialTx` natural key: `HotelCode + BusinessDate + ReservationId + FolioNo + TrxCode + PostingDate + Amount`; `IsLatePosting BIT DEFAULT 0`; `PostingDateLocal` + `PostingDateUtc`
- [ ] `SQL\003_CreateTables_Snapshots.sql` — `ra.OnTheBooks`, `ra.BlockReservations`, `ra.RoomInventory`
  - OTB natural key: `HotelCode + SnapshotDate + ConsideredDate + MarketSegment + RoomTypeLabel + ReservationSource + Channel`
  - Block natural key: `HotelCode + SnapshotDate + BlockCode + ConsideredDate + RoomTypeLabel`; `IsPastCutoff BIT DEFAULT 0`
  - Inventory natural key: `HotelCode + InventoryDate + RoomTypeLabel`
- [ ] `SQL\004_CreateTables_MasterData.sql` — `ra.TrxCodes`, `ra.RoomTypeLabels`, `ra.MarketSegments`, `ra.RateCodes`, `ra.ReservationSources`, `ra.Channels`, `ra.Hotels`
  - All master tables include SCD Type 2 columns: `ValidFrom DATE NOT NULL`, `ValidTo DATE NULL`, `IsCurrent BIT NOT NULL DEFAULT 1`
  - `ra.TrxCodes` includes: `TrxGroup`, `TrxType`, `RevenueYN`, `IncludedInRoomRevenueYN`, `IncludedInPackageYN`
  - `ra.RoomTypeLabels` includes: `RoomClass`, `PhysicalRoomCount`
  - `ra.RateCodes` includes: `RateCategory`
  - `ra.MarketSegments` includes: `SegmentGroup`
- [ ] `SQL\005_CreateIndexes.sql` — indexes on `HotelCode`, `BusinessDate`/`SnapshotDate`/`ConsideredDate`/`InventoryDate`, `BatchId`, `ReservationId`, `TrxCode`, `IsCurrent`

## Task 7 – SqlWriter Module (`Modules\SqlWriter.psm1`)
- [ ] Implement `Initialize-Database` — execute DDL scripts 001–005 idempotently on startup
- [ ] Implement `Write-ReservationStats` — `SqlBulkCopy` to staging → `MERGE` into `ra.ReservationStats` on natural key
- [ ] Implement `Write-FinancialTx` — `SqlBulkCopy` to staging → `MERGE` into `ra.FinancialTx`; compute `IsLatePosting` during mapping
- [ ] Implement `Write-OnTheBooks` — `SqlBulkCopy` to staging → `MERGE` into `ra.OnTheBooks` (insert new `SnapshotDate` rows; do not overwrite prior snapshots)
- [ ] Implement `Write-BlockReservations` — `SqlBulkCopy` to staging → `MERGE` into `ra.BlockReservations`; set `IsPastCutoff` where `CutoffDate < SnapshotDate`
- [ ] Implement `Write-RoomInventory` — `SqlBulkCopy` to staging → `MERGE` into `ra.RoomInventory` on natural key
- [ ] Implement `Write-MasterData` — SCD Type 2 MERGE for all seven master tables:
  - On change detected: `UPDATE` existing record (`ValidTo = today - 1`, `IsCurrent = 0`), `INSERT` new version row
  - On no change: no-op (skip update to avoid unnecessary churn)
  - On new code: `INSERT` with `ValidFrom = today`, `ValidTo = NULL`, `IsCurrent = 1`
- [ ] Implement `Write-LoadLog` — insert initial `Running` row and update on completion

## Task 8 – Reservation Statistics Query (`Modules\Queries\ReservationStats.psm1`)
- [ ] Implement `Get-ReservationStats -Hotel -StartDate -EndDate`
- [ ] Build R&A API request body for the reservation statistics endpoint; apply date chunking via `Get-DateRangeChunks`
- [ ] Map API response fields to flat `[PSCustomObject]` matching `ra.ReservationStats` schema including `ReservationId`, `MarketSegment`, `RoomTypeLabel`, `ReservationSource`, `Channel`
- [ ] Compute `ADR` and `RevPAR` if not returned directly by API (`ADR = Revenue / RoomNights`; `RevPAR = Revenue / PhysicalRooms`)
- [ ] Log row count and duration per date chunk per hotel

## Task 9 – Financial Transactions Query (`Modules\Queries\FinancialTransactions.psm1`)
- [ ] Implement `Get-FinancialTransactions -Hotel -StartDate -EndDate`
- [ ] Build R&A API request body for the financial/folio transactions endpoint; apply date chunking
- [ ] Map API response to flat `[PSCustomObject]` matching `ra.FinancialTx` schema including `ReservationId`, `TrxCode`, `TrxType`, `PostingDate`
- [ ] Populate `PostingDateLocal` (hotel TZ) and `PostingDateUtc` using `Convert-ToUtc`
- [ ] Set `IsLatePosting = 1` where `PostingDate > BusinessDate`; log WARN with count if any late postings found

## Task 10 – On-The-Books Query (`Modules\Queries\OnTheBooks.psm1`)
- [ ] Implement `Get-OnTheBooks -Hotel -SnapshotDate -FutureDays`
- [ ] Use `Get-SnapshotHorizon` to build `ConsideredDateStart` / `ConsideredDateEnd` range
- [ ] Build R&A API request body for OTB endpoint
- [ ] Map response fields to `ra.OnTheBooks` schema: `SnapshotDate`, `ConsideredDate`, `MarketSegment`, `RoomTypeLabel`, `ReservationSource`, `Channel`, `RoomsOnBooks`, `TentativeRooms`, `DefiniteRooms`, `ADROnBooks`, `RevenueOnBooks`
- [ ] Log snapshot date, considered date range, and row count

## Task 11 – Block Reservations Query (`Modules\Queries\BlockReservations.psm1`)
- [ ] Implement `Get-BlockReservations -Hotel -SnapshotDate -FutureDays`
- [ ] Build R&A API request body for group block endpoint
- [ ] Map response to `ra.BlockReservations` schema: `SnapshotDate`, `ConsideredDate`, `BlockCode`, `BlockName`, `RoomTypeLabel`, `MarketSegment`, `RoomsContracted`, `RoomsPickedUp`, `RoomsRemaining`, `CutoffDate`
- [ ] Compute `IsPastCutoff = 1` where `CutoffDate < SnapshotDate`; log WARN count if any

## Task 12 – Room Inventory Query (`Modules\Queries\RoomInventory.psm1`)
- [ ] Implement `Get-RoomInventory -Hotel -StartDate -EndDate`
- [ ] Build R&A API request for room inventory / availability endpoint
- [ ] Map response to `ra.RoomInventory` schema: `InventoryDate`, `RoomTypeLabel`, `PhysicalRooms`, `OutOfOrder`, `OutOfService`
- [ ] Compute `AvailableRooms = PhysicalRooms - OutOfOrder - OutOfService` if not returned by API
- [ ] Support both historical (actuals) and future (forecast) date ranges in a single call

## Task 13 – Master Data Query (`Modules\Queries\MasterData.psm1`)
- [ ] Implement `Get-MasterData -Hotel -Type -ChangedSince`; `-Type` accepts: `MarketSegments`, `RoomTypeLabels`, `RateCodes`, `ReservationSources`, `Channels`, `TrxCodes`, `Hotels`
- [ ] Implement full refresh mode (no `-ChangedSince`) and delta mode (pass `ChangedSince` filter to API)
- [ ] Map `TrxCodes` response: `TrxCode`, `TrxName`, `TrxGroup`, `TrxType`, `RevenueYN`, `IncludedInRoomRevenueYN`, `IncludedInPackageYN`, `IsActive`
- [ ] Map `RoomTypeLabels` response: `RoomTypeLabel`, `Description`, `RoomClass`, `PhysicalRoomCount`, `IsActive`
- [ ] Map `MarketSegments`: `Code`, `Description`, `SegmentGroup`, `IsActive`
- [ ] Map `RateCodes`: `Code`, `Description`, `RateCategory`, `IsActive`
- [ ] Map `ReservationSources`, `Channels`: `Code`, `Description`, `IsActive`
- [ ] Detect and log changes between current DB records and API response (new codes, description changes, deactivations)

## Task 14 – Credential Protection Utility (`Tools\Protect-HotelsConfig.ps1`)
- [ ] Read plain-text `Config\hotels.input.json` (never committed to source control)
- [ ] Encrypt `clientId`, `clientSecret`, `apiKey` per hotel using `ConvertTo-SecureString` with DPAPI
- [ ] Write encrypted values to `Config\hotels.json`; copy all other fields unchanged
- [ ] Verify round-trip decryption for each value before writing; abort on mismatch
- [ ] Add usage comment header to script with instructions for service account setup

## Task 15 – Entry Point Orchestrator (`Run-OperaRALoader.ps1`)
- [ ] Declare all parameters: `-Mode`, `-HotelCode`, `-ChainCode`, `-BusinessDate`, `-StartDate`, `-EndDate`, `-DryRun`, `-FailFast`, `-ConfigPath`
- [ ] Load and validate `settings.json` and `hotels.json` at startup; fail fast on missing required fields
- [ ] Decrypt hotel credentials (DPAPI); validate decryption before proceeding
- [ ] Filter hotel list by `-HotelCode` / `-ChainCode` when specified
- [ ] Call `Initialize-Database` when `-Mode Full` or on first run (no schema present)
- [ ] Per-hotel execution loop:
  - `Start-Batch` → `Get-OAuthToken`
  - Based on `-Mode`: call relevant query modules in order: MasterData → ReservationStats → FinancialTx → OTB → BlockReservations → RoomInventory
  - Respect `-DryRun`: skip all `Write-*` calls, log `[DRYRUN]` prefix
  - Catch per-hotel errors: log ERROR + `Complete-Batch` with `Error` status; continue unless `-FailFast`
- [ ] Output summary table to console on completion: Hotel | Status | Rows | Duration
- [ ] Set `exit` code: 0 = all success, 1 = partial failure, 2 = total failure

## Task 16 – Documentation & README (`README.md`)
- [ ] Prerequisites: PowerShell 7.x, SQL Server, network access to OPERA Cloud R&A API
- [ ] Installation steps: clone, run `Protect-HotelsConfig.ps1`, configure `settings.json`
- [ ] Scheduling guidance: Windows Task Scheduler XML template and SQL Agent job example
- [ ] Full parameter reference table for `Run-OperaRALoader.ps1`
- [ ] SQL schema overview with entity relationship notes (RES ↔ FIN via `BusinessDate + ReservationId`; OTB/Block `SnapshotDate + ConsideredDate` pattern)
- [ ] Troubleshooting section: token errors, late postings, SCD2 rollback procedure
- [ ] Add `# GenAI-generated code — reviewed and approved by: <name> <date>` header to all `.ps1` / `.psm1` files per Infor policy
- [ ] Document exit codes and monitoring integration guidance
