# Design: OPERA R&A Data Loader

## Overview

This document describes the technical design for the OPERA R&A Data Loader — a PowerShell 7 solution that extracts data from the Oracle Hospitality Integration Platform (OHIP) R&A Data APIs (GraphQL) and lands it in Microsoft SQL Server for multiple hotels across multiple chains. It realises the requirements defined in `requirements.md` (`REQ-001`…`REQ-016`).

The design favours a modular structure: a single orchestrator (`Run-OperaRALoader.ps1`) drives per-hotel processing, delegating to focused modules for authentication, HTTP/GraphQL transport, per-subject-area extraction, date/time handling, SQL persistence, and logging/alerting. Key design principles:

- **Per-hotel isolation** — one hotel's failure does not abort the batch (unless `-FailFast`).
- **Idempotent loads** — all writes use staging + `MERGE` (upsert); master data uses SCD Type 2 history.
- **Snapshot preservation** — daily forward-looking snapshots (OTB, blocks) accumulate keyed by `SNAPSHOT_DATE` and are never overwritten.
- **Secure by default** — credentials encrypted at rest (DPAPI), masked in logs, least-privilege SQL account.
- **Resilience** — token refresh, retry with exponential backoff, date-range chunking for volume control.

See the **Requirements Traceability** section at the end for the design-component → requirement mapping.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│              Run-OperaRALoader.ps1  (Entry Point)                    │
│  -Mode  -HotelCode  -ChainCode  -BusinessDate  -DryRun  -FailFast   │
└──────────────┬──────────────────────────────────────────────────────┘
               │
   ┌───────────▼────────────┐
   │  Config\               │
   │  hotels.json (enc)     │  ← per-hotel credentials + settings
   │  settings.json         │  ← global SQL, SMTP, retry, horizons
   └───────────┬────────────┘
               │  foreach hotel
   ┌───────────▼──────────────────────────────────────────────────────┐
   │  Modules\                                                         │
   │  ├─ Auth.psm1              OAuth2 token manager                  │
   │  ├─ ApiClient.psm1         HTTP wrapper, retry, pagination       │
   │  ├─ SqlWriter.psm1         MERGE / upsert / SCD2 to SQL Server  │
   │  ├─ Logger.psm1            Structured logging + SMTP alert       │
   │  ├─ DateHelper.psm1        Business date / TZ utilities          │
   │  └─ Queries\                                                      │
   │      ├─ ReservationStats.psm1    RES actuals (Get-RES)            │
   │      ├─ FinancialTransactions.psm1  FIN actuals (Get-FIN)         │
   │      ├─ OnTheBooks.psm1           OTB snapshot (Get-OTB)          │
   │      ├─ BlockReservations.psm1    BLK snapshot (Get-BLK)          │
   │      ├─ RoomInventory.psm1        RMN + OOO inventory             │
   │      └─ MasterData.psm1          DIM master lists (Get-DIM)       │
   └───────────┬──────────────────────────────────────────────────────┘
               │
   ┌───────────▼──────────────────────────────────────────────────────┐
   │  SQL Server  (schema: ra)                                         │
   │                                                                   │
   │  ── Operational Logs ──────────────────────────────────────────  │
   │  dbo.LoadLog                                                      │
   │                                                                   │
   │  ── Actuals ───────────────────────────────────────────────────  │
   │  ra.RES            BUSINESS_DATE + RESV_NAME_ID               │
   │  ra.FIN            BUSINESS_DATE + RESV_NAME_ID + TRX_NO      │
   │                                                                   │
   │  ── Daily Snapshots (future view) ─────────────────────────────  │
   │  ra.OTB            SNAPSHOT_DATE + CONSIDERED_DATE             │
   │  ra.BLK            SNAPSHOT_DATE + BLOCK_CODE + CONSIDERED_DATE│
   │                                                                   │
   │  ── Inventory ─────────────────────────────────────────────────  │
   │  ra.RMN            RESORT + ROOM (physical room list)          │
   │  ra.OOO            BUSINESS_DATE + ROOM_CLASS (OOO/OOS counts) │
   │                                                                   │
   │  ── Master Data / Dimensions (SCD Type 2) ──────────────────────  │
   │  ra.DIM_TrxCodes        TC_CODE + TC_GROUP + TC_SUBGROUP       │
   │  ra.DIM_RoomTypes       ROOM_CATEGORY_LABEL                    │
   │  ra.DIM_RateCodes       RATE_CODE + RATE_CATEGORY              │
   │  ra.DIM_MarketCodes     MARKETCODE                             │
   │  ra.DIM_SourceCodes     SOURCE_CODE                            │
   │  ra.DIM_Channels        CHANNEL                                │
   │  ra.Hotels              property configuration                 │
   └───────────────────────────────────────────────────────────────────┘
```

---

## File & Folder Structure

```
OperaRADataLoader\
├─ Run-OperaRALoader.ps1              # Entry point / orchestrator
├─ Config\
│   ├─ hotels.json                    # Encrypted hotel credentials (never commit)
│   ├─ hotels.sample.json             # Plain-text sample (no real creds)
│   └─ settings.json                  # Global config (SQL, SMTP, retry, horizons)
├─ Modules\
│   ├─ Auth.psm1
│   ├─ ApiClient.psm1
│   ├─ SqlWriter.psm1
│   ├─ Logger.psm1
│   ├─ DateHelper.psm1
│   └─ Queries\
│       ├─ ReservationStats.psm1
│       ├─ FinancialTransactions.psm1
│       ├─ OnTheBooks.psm1
│       ├─ BlockReservations.psm1
│       ├─ RoomInventory.psm1
│       └─ MasterData.psm1
├─ SQL\
│   ├─ 001_CreateSchema.sql
│   ├─ 002_CreateTables_Actuals.sql
│   ├─ 003_CreateTables_Snapshots.sql
│   ├─ 004_CreateTables_MasterData.sql
│   └─ 005_CreateIndexes.sql
├─ Tools\
│   └─ Protect-HotelsConfig.ps1       # Utility to encrypt hotels.json
├─ .gitignore
└─ Logs\                              # Auto-created at runtime
```

---

## OHIP R&A Data API — Technical Reference

The R&A Data APIs are part of the Oracle Hospitality Integration Platform (OHIP).
They expose R&A Subject Areas as **GraphQL queries** via a single HTTP POST endpoint.

### Endpoint
```
POST  <gatewayUrl>/rna/v1/graphql/
```
`gatewayUrl` is the OHIP Gateway base URL for the environment (per-hotel config).  
**Note:** `HotelId` (`x-hotelid` header) is optional for R&A Data APIs but included for
consistency with other OHIP APIs.

### Required Headers

| Header          | Value                                                        |
|-----------------|--------------------------------------------------------------|
| `Authorization` | `Bearer <access_token>`                                      |
| `x-app-key`     | Application key from OHIP Developer Portal                   |
| `x-request-id`  | New `[guid]` per request (for tracing)                       |
| `Content-Type`  | `application/json`                                           |
| `Accept`        | `multipart/mixed; deferSpec=20220824, application/json`      |

### Authentication (OAuth 2.0 — OCIM)
```
POST  <gatewayUrl>/oauth/token
Body: grant_type=client_credentials
      &client_id=<ClientId>
      &client_secret=<ClientSecret>
      &scope=urn:opc:hgbu:ws:_myscopes_
```
Returns: `{ "access_token": "...", "expires_in": 3600, "token_type": "Bearer" }`

**Requirements:**
- R&A Platform v24.4+ (OAS version only)
- OHIP Platform v24.3+
- OCIM as Identity Platform (not available for SSD environments)
- Hotel must subscribe to R&A Data APIs plan (GraphQL Plan) in OHIP Developer Portal

### GraphQL Request Structure
```json
{
  "query": "query <SubjectAreaName>($input: <SubjectArea>QueryArgumentsType!) { <subjectAreaCamelCase>(input: $input) { <view1> { field1 field2 } <view2> { field3 } } }",
  "variables": {
    "input": {
      "<primaryViewResort>":    { "_in": ["HOTELCODE"] },
      "<primaryViewStartDate>": { "_eq": "YYYY-MM-DD" },
      "<primaryViewEndDate>":   { "_gte": "YYYY-MM-DD", "_lte": "YYYY-MM-DD" }
    }
  }
}
```

**Key GraphQL rules:**
- Mandatory filter on the primary view's resort/property field (`_in` operator).
- Mandatory date range filters on the primary view — never open-ended.
- Request only the fields needed (avoid over-fetching).
- If columns are needed from multiple child folders, issue separate requests to avoid cartesian joins.
- Responses may contain partial data with an `errors` array — always inspect it.
- No native cursor/offset pagination in the API; date chunking is the primary volume control.

### Output Date Formatting (RES, OTB, FIN)
All date/datetime values emitted to the RES, OTB, and FIN outputs use a compact format:
- **Date-only fields** → `YYYYMMDD` (e.g. `20260507`).
- **Datetime fields** (carry a time component) → `YYYYMMDD HH:mm:ss` (e.g. `20260507 12:33:21`).

Scope and rules:
- Applies to the RES, OTB, and FIN query outputs (e.g. `BUSINESS_DATE`, `TRUNC_BEGIN_DATE`,
  `TRUNC_END_DATE`, `CANCELLATION_DATE`, `SNAPSHOT_DATE`, `CONSIDERED_DATE`, `TRX_DATE`,
  `TRX_DATE_UTC`).
- This is an **output/serialisation** rule only. SQL columns remain `DATE` / `DATETIME2`
  so date semantics, sorting, and joins are preserved; the `YYYYMMDD` form is produced when
  materialising output (CSV / formatted export / display), not stored as text.
- **GraphQL API request filters are NOT affected** — the OHIP R&A API requires ISO
  `YYYY-MM-DD` in `_eq` / `_gte` / `_lte`, so date filters continue to use `YYYY-MM-DD`.
- Empty / null date values render as an empty string (no `YYYYMMDD` placeholder).
- Formatting helper lives in `DateHelper.psm1` (e.g. `Format-OutputDate` /
  `Format-OutputDateTime`) so RES/OTB/FIN modules format consistently.

### Subject Area → Query Mapping

| Export | OHIP Subject Area                    | GraphQL operation name               | Target Table      |
|--------|--------------------------------------|--------------------------------------|-------------------|
| RES    | `StatisticsReservationsDaily`        | `statisticsReservationsDaily`        | `ra.RES`          |
| FIN    | `FinancialTransactionDetails`        | `financialTransactionDetails`        | `ra.FIN`          |
| FIN+   | `FinancialTransactionDetailsExtended`| `financialTransactionDetailsExtended`| `ra.FIN` (alt)    |
| OTB    | `StatisticsForecastSummary`          | `statisticsForecastSummary`          | `ra.OTB`          |
| OTB pace| `StatisticsReservationPace`         | `statisticsReservationPace`          | `ra.OTB` (pace)   |
| BLK    | `BookingsBlock`                      | `bookingsBlock`                      | `ra.BLK`          |
| BLK Δ  | `BookingsBlockProductionChanges`     | `bookingsBlockProductionChanges`     | `ra.BLK` (delta)  |
| RMN    | `InventoryRooms`                     | `inventoryRooms`                     | `ra.RMN`          |
| OOO    | `StatisticsManagersReport`           | `statisticsManagersReport`           | `ra.OOO`          |
| DIM TC | `FinancialTransactionCodes`          | `financialTransactionCodes`          | `ra.DIM_TrxCodes` |
| DIM RT | `InventoryRooms`                     | `inventoryRooms`                     | `ra.DIM_RoomTypes`|
| DIM RC | `RatesCodeDetails`                   | `ratesCodeDetails`                   | `ra.DIM_RateCodes`|
| DIM MC | `ExportMappings`                     | `exportMappings`                     | `ra.DIM_MarketCodes` |
| DIM SC | `ExportMappings`                     | `exportMappings`                     | `ra.DIM_SourceCodes` (source of reservation, SOURCE_CODE) |
| DIM CH | `ExportMappings`                     | `exportMappings`                     | `ra.DIM_Channels` (distribution channel, CHANNEL) |
| Hotels | `ConfigurationResort`                | `configurationResort`                | `ra.Hotels`       |

> GraphQL schemas published at [oracle/hospitality-api-docs](https://github.com/oracle/hospitality-api-docs).
> Verify exact field names via GraphQL introspection (`__type` query) against a live environment.

---

## Components and Interfaces

### Auth.psm1
Manages per-hotel OAuth 2.0 token lifecycle against OCIM.

```
Functions:
  Get-OAuthToken     -Hotel [hashtable]   → bearer token string
  Clear-TokenCache   -HotelCode [string]

Internal state:
  $script:TokenCache = @{}   # key = HotelCode, value = {Token, ExpiresAt}

Flow:
  1. Check cache: ExpiresAt > (Now + SafetyMarginSec) → return cached token
  2. If missing/expired:
       POST <gatewayUrl>/oauth/token
       Content-Type: application/x-www-form-urlencoded
       Body: grant_type=client_credentials
             &client_id=<ClientId>
             &client_secret=<ClientSecret>
             &scope=urn:opc:hgbu:ws:_myscopes_
  3. Parse access_token + expires_in → store in cache with ExpiresAt = Now + expires_in
  4. ClientId and ClientSecret never written to any log
```

### ApiClient.psm1
GraphQL-over-HTTP client with retry, date-chunk pagination, and header injection.

```
Functions:
  Invoke-GraphQL   -Hotel [hashtable] -Query [string] -Variables [hashtable]
                   -Token [string]
                   → [PSCustomObject]  # raw deserialized GraphQL response

  Invoke-RASubjectArea  -Hotel [hashtable] -SubjectArea [string]
                        -Query [string] -Variables [hashtable]
                        -Token [string]
                        → [array] of flat PSCustomObjects (all pages merged)

Flow for Invoke-GraphQL:
  1. Build headers:
       Authorization: Bearer <token>
       x-app-key:     <Hotel.ApiKey>
       x-request-id:  [guid]::NewGuid()
       Content-Type:  application/json
       Accept:        multipart/mixed; deferSpec=20220824, application/json
  2. POST <Hotel.GatewayUrl>/rna/v1/graphql/  body = @{query; variables} | ConvertTo-Json -Depth 10
  3. HTTP 401 → Clear-TokenCache + Get-OAuthToken once → retry
  4. HTTP 429 / 5xx → exponential backoff (base 2s, ×2, cap 30s, max 3 retries)
  5. Inspect response.errors array → log each error as WARN; if data is null → throw
  6. Return deserialized response object

Flow for Invoke-RASubjectArea:
  1. Date chunking is handled by the caller (Query modules) via Get-DateRangeChunks
  2. For each date chunk: call Invoke-GraphQL
  3. Extract the data array from response.data.<operationName>.<primaryView>
  4. Throttle: Start-Sleep -Milliseconds $config.api.requestDelayMs between chunks
  5. Accumulate all chunk results → return flattened [array]

Note: The R&A Data API does not use cursor/offset pagination.
      Volume is controlled by keeping date ranges narrow (default 7-day chunks).
      Multiple child-folder attributes require separate Invoke-GraphQL calls
      to avoid cartesian joins — the Query modules handle this split.
```

### Logger.psm1
Single shared log file for the entire application run. All modules write to the
same file via the shared `$script:LogFilePath` set at startup. Optional SQL
mirror to `dbo.LoadLog`. Per-hotel severity-based email alerts over a shared SMTP transport (recipients from hotels.json emailAlerts).

```
Module-level state (shared across all callers in the process):
  $script:LogFilePath  — absolute path, set once by Initialize-Logger at startup
  $script:LogLevel     — minimum level: DEBUG < INFO < WARN < ERROR
  $script:SqlLogging   — bool, mirror writes to dbo.LoadLog

Functions:
  Initialize-Logger   -LogDirectory [string] -LogLevel [string] -SqlLogging [bool]
                      Sets $script:LogFilePath = "<LogDirectory>\YYYYMMDD_OperaRALoader.log"
                      (YYYYMMDD = date of run, evaluated once at process start)
                      Creates directory if missing. Appends if file already exists (re-run).
                      Called ONCE from Run-OperaRALoader.ps1 before any module is loaded.

  Write-Log           -Level    [INFO|WARN|ERROR|DEBUG]
                      -Module   [string]       ← caller identifier (see table below)
                      -Message  [string]
                      -HotelCode [string]      ← empty string for global/startup messages
                      -BatchId   [guid]        ← [guid]::Empty when not in a batch context

  Start-Batch         -HotelCode [string] -Mode [string] -QueryType [string]
                      → [guid] BatchId
                      Writes initial Running row to dbo.LoadLog (if SqlLogging)

  Complete-Batch      -BatchId [guid] -Status [string] -RowsFetched [int]
                      -RowsInserted [int] -RowsUpdated [int] -ErrorMessage [string]

  Send-AlertEmail     -Hotel [hashtable] -Severity [INFO|WARN|ERROR]
                      -Subject [string] -Body [string] -Attachments [string[]]
                      Uses the shared SMTP transport from settings.json (server, port,
                      from, useSsl, encrypted username/password). Resolves recipients
                      from the hotel's own emailAlerts.<severity>.to[] / .cc[].
                      Sends only when smtp.enabled AND Hotel.emailAlerts.enabled AND
                      Hotel.emailAlerts.<severity>.enabled AND recipients exist.
                      Delivery failure is logged as WARN and never aborts the run.

Log file naming (single file, whole run):
  <LogDirectory>\YYYYMMDD_OperaRALoader.log
  Example:  Logs\20260905_OperaRALoader.log

Log line format (pipe-delimited, fixed-width columns for easy grep/import):
  YYYYMMDD_HH:mm:ss.fff | LEVEL   | MODULE                  | HotelCode | Message

Example lines:
  20260905_06:15:00.001 | INFO    | Run-OperaRALoader       |           | Loader started. Mode=Delta Hotels=3
  20260905_06:15:00.045 | INFO    | Auth                    | HOTEL1    | Token acquired. ExpiresIn=3600s
  20260905_06:15:00.512 | INFO    | ReservationStats        | HOTEL1    | SA=StatisticsReservationsDaily date=2026-09-04..2026-09-04
  20260905_06:15:01.210 | INFO    | ReservationStats        | HOTEL1    | Fetched 24 rows. Duration=698ms
  20260905_06:15:01.215 | INFO    | SqlWriter.Write-RES     | HOTEL1    | BulkCopy staging 24 rows
  20260905_06:15:01.310 | INFO    | SqlWriter.Write-RES     | HOTEL1    | MERGE complete. Inserted=20 Updated=4
  20260905_06:15:01.320 | WARN    | FinancialTransactions   | HOTEL1    | 2 late postings (TRX_DATE > BUSINESS_DATE)
  20260905_06:15:05.001 | ERROR   | ApiClient               | HOTEL2    | HTTP 503 after 3 retries. SA=FinancialTransactionDetails

Module name constants (use exactly these strings for -Module parameter):
  "Run-OperaRALoader"       orchestrator startup and hotel loop
  "Config"                  config loading and credential decryption
  "Auth"                    Auth.psm1 — token acquire/refresh
  "ApiClient"               ApiClient.psm1 — HTTP layer, retries
  "DateHelper"              DateHelper.psm1
  "ReservationStats"        Queries\ReservationStats.psm1
  "FinancialTransactions"   Queries\FinancialTransactions.psm1
  "OnTheBooks"              Queries\OnTheBooks.psm1
  "BlockReservations"       Queries\BlockReservations.psm1
  "RoomInventory"           Queries\RoomInventory.psm1 (RMN + OOO)
  "MasterData"              Queries\MasterData.psm1
  "SqlWriter.Init"          SqlWriter — Initialize-Database
  "SqlWriter.Write-RES"     SqlWriter — Write-ReservationStats
  "SqlWriter.Write-FIN"     SqlWriter — Write-FinancialTx
  "SqlWriter.Write-OTB"     SqlWriter — Write-OnTheBooks
  "SqlWriter.Write-BLK"     SqlWriter — Write-BlockReservations
  "SqlWriter.Write-RMN"     SqlWriter — Write-RoomInventory (RMN)
  "SqlWriter.Write-OOO"     SqlWriter — Write-RoomInventory (OOO)
  "SqlWriter.Write-DIM"     SqlWriter — Write-MasterData

Sensitive mask: bearer tokens, ClientSecret, ApiKey replaced with **** in all output
```

### DateHelper.psm1
Business date and time zone utilities.

```
Functions:
  Get-BusinessDate     -Hotel [hashtable] -ReferenceDate [datetime]
                       → [datetime] adjusted for hotel TZ + night audit cutover
  Convert-ToUtc        -LocalDateTime [datetime] -TimeZoneId [string] → [datetime]
  Convert-ToLocal      -UtcDateTime [datetime]   -TimeZoneId [string] → [datetime]
  Get-DateRangeChunks  -StartDate -EndDate -ChunkDays [int]
                       → [array] of @{Start; End} pairs
  Get-SnapshotHorizon  -Hotel [hashtable] -SnapshotDate [datetime] -FutureDays [int]
                       → @{SnapshotDate; ConsideredDateStart; ConsideredDateEnd}
```

### SqlWriter.psm1
All SQL Server interactions via `Microsoft.Data.SqlClient`.

```
Functions:
  Initialize-Database    -ConnectionString [string]
  Write-RES              -Data [array] -Hotel [hashtable] -BatchId [guid]
  Write-FIN              -Data [array] -Hotel [hashtable] -BatchId [guid]
  Write-OTB              -Data [array] -Hotel [hashtable] -BatchId [guid]
  Write-BLK              -Data [array] -Hotel [hashtable] -BatchId [guid]
  Write-RMN              -Data [array] -Hotel [hashtable] -BatchId [guid]
  Write-OOO              -Data [array] -Hotel [hashtable] -BatchId [guid]
  Write-DIM              -Type [string] -Data [array] -Hotel [hashtable]
                         -BatchId [guid] -RefreshMode [Full|Delta]
  Write-LoadLog          -LogEntry [hashtable]

Patterns:
  Transactional (RES, FIN) → SqlBulkCopy staging → MERGE on natural key
  Snapshots (OTB, BLK)     → SqlBulkCopy staging → MERGE on snapshot composite key
                             (new SNAPSHOT_DATE rows preserved; no overwrite of prior snapshots)
  Inventory (RMN, OOO)     → SqlBulkCopy staging → MERGE on natural key
  Master data (DIM tables) → MERGE with SCD Type 2 (VALID_FROM / VALID_TO / IS_CURRENT)
```

### Queries\ReservationStats.psm1

```
Subject Area:  StatisticsReservationsDaily
Operation:     statisticsReservationsDaily
Primary view:  reservationDailyStatisticsDetails
               Mandatory filters: resort (_in), businessDate range
Target table:  ra.RES

Functions:
  Get-RES  -Hotel [hashtable] -StartDate [date] -EndDate [date]
           → [array] PSCustomObjects

GraphQL field → SQL column:
  resort              → RESORT
  businessDate        → BUSINESS_DATE      [out: YYYYMMDD]
  resvNameId          → RESV_NAME_ID     ← join key → ra.FIN, ra.OTB
  rateCode            → RATE_CODE
  rateCategory        → RATE_CATEGORY
  marketCode          → MARKET_CODE
  sourceCode          → SOURCE_CODE
  channel             → CHANNEL
  truncBeginDate      → TRUNC_BEGIN_DATE   [out: YYYYMMDD]
  truncEndDate        → TRUNC_END_DATE     [out: YYYYMMDD]
  room                → ROOM
  pseudoRoomYn        → PSEUDO_ROOM_YN
  roomCategoryLabel   → ROOM_CATEGORY_LABEL
  resvStatus          → RESV_STATUS
  quantity            → QUANTITY
  adults              → ADULTS
  children            → CHILDREN
  stayRooms           → STAY_ROOMS
  stayPersons         → STAY_PERSONS
  stayAdults          → STAY_ADULTS
  stayChildren        → STAY_CHILDREN
  arrRooms            → ARR_ROOMS
  arrPersons          → ARR_PERSONS
  depRooms            → DEP_ROOMS
  depPersons          → DEP_PERSONS
  dayUseRooms         → DAY_USE_ROOMS
  dayUsePersons       → DAY_USE_PERSONS
  noShowRooms         → NO_SHOW_ROOMS
  noShowPersons       → NO_SHOW_PERSONS
  houseUseYn          → HOUSE_USE_YN
  complimentaryYn     → COMPLIMENTARY_YN
  walkinYn            → WALKIN_YN
  cancellationDate    → CANCELLATION_DATE  [out: YYYYMMDD HH:mm:ss]
  country             → COUNTRY
  nights              → NIGHTS
```

### Queries\FinancialTransactions.psm1

```
Subject Area:  FinancialTransactionDetails
Operation:     financialTransactionDetails
Primary view:  financialTransactionDetails
               Mandatory filters: resort (_in), businessDate range
Target table:  ra.FIN

Functions:
  Get-FIN  -Hotel [hashtable] -StartDate [date] -EndDate [date]
           → [array] PSCustomObjects

GraphQL field → SQL column:
  resort              → RESORT
  businessDate        → BUSINESS_DATE      [out: YYYYMMDD]
  resvNameId          → RESV_NAME_ID       ← join key → ra.RES
  originalResvNameId  → ORIGINAL_RESV
  rateCode            → RATE_CODE
  sourceCode          → SOURCE_CODE
  marketCode          → MARKET_CODE
  ftSubtype           → FT_SUBTYPE         C=Charge FC=Payment PK=Package
  tcGroup             → TC_GROUP
  tcSubgroup          → TC_SUBGROUP
  trxCode             → TRX_CODE           FK → ra.DIM TC_CODE
  trxNo               → TRX_NO             ← transaction identifier
  tranActionId        → TRAN_ACTION_ID     ← transaction action identifier
  trxNoAddedBy        → TRX_NO_ADDED_BY    ← parent TRX_NO (links tax to charge)
  trxDate             → TRX_DATE           populate TRX_DATE_UTC via Convert-ToUtc  [out: YYYYMMDD HH:mm:ss for TRX_DATE + TRX_DATE_UTC]
  netAmount           → NET_AMOUNT         revenue excl. VAT
  grossAmount         → GROSS_AMOUNT       incl. VAT (null for payments)
  trxAmount           → TRX_AMOUNT
  postedAmount        → POSTED_AMOUNT
  revenueAmt          → REVENUE_AMT
  quantity            → QUANTITY
  pricePerUnit        → PRICE_PER_UNIT
  exchangeRate        → EXCHANGE_RATE
  currencyCode        → CURRENCY
  indRevenueGp        → IND_REVENUE_GP     Y=revenue N=non-revenue
  passerByName        → PASSER_BY_NAME
  (trxDate > businessDate) → IS_LATE_POSTING = 1

Note: COSTCENTER / ACCOUNT (GL export codes) not in FinancialTransactionDetails SA.
      Retrieve via ExportMappings SA if needed, join on TRX_CODE.
```

### Queries\OnTheBooks.psm1

```
Subject Area:  StatisticsForecastSummary
Operation:     statisticsForecastSummary
Primary view:  forecastSummaryDetails
               Mandatory filters: resort (_in), stayDate range (= CONSIDERED_DATE)
Target table:  ra.OTB

Functions:
  Get-OTB  -Hotel [hashtable] -SnapshotDate [date] -FutureDays [int]
           → [array] PSCustomObjects

GraphQL field → SQL column:
  resort              → RESORT
  (set by loader)     → SNAPSHOT_DATE     = business date of run   [out: YYYYMMDD]
  stayDate            → CONSIDERED_DATE   ← future stay date   [out: YYYYMMDD]
  eventType           → EVENT_TYPE
  marketCode          → MARKET_CODE
  sourceCode          → SOURCE_CODE
  channel             → CHANNEL
  rateCode            → RATE_CODE
  rateCategory        → RATE_CATEGORY
  roomCategoryLabel   → ROOM_CATEGORY_LABEL
  resvType            → RESV_TYPE
  country             → COUNTRY
  currencyCode        → CURRENCY_CODE
  truncBeginDate      → TRUNC_BEGIN_DATE   [out: YYYYMMDD]
  truncEndDate        → TRUNC_END_DATE     [out: YYYYMMDD]
  arrRooms            → ARR_ROOMS
  depRooms            → DEP_ROOMS
  noRooms             → NO_ROOMS
  dayUseRooms         → DAY_USE_ROOMS
  dayUsePersons       → DAY_USE_PERSONS
  arrPersons          → ARR_PERSONS
  depPersons          → DEP_PERSONS
  adults              → ADULTS
  children            → CHILDREN
  quantity            → QUANTITY
  nights              → NIGHTS
  resvStatus          → RESV_STATUS
  pseudoRoomYn        → PSEUDO_ROOM_YN
  dayUseYn            → DAY_USE_YN
  -- Revenue Gross
  grossRate           → GROSS_RATE
  roomRevenue         → ROOM_REVENUE
  foodRevenue         → FOOD_REVENUE
  otherRevenue        → OTHER_REVENUE
  totalRevenue        → TOTAL_REVENUE
  nonRevenue          → NON_REVENUE
  -- Revenue Net
  netRoomRevenue      → NET_ROOM_REVENUE
  extraRevenue        → EXTRA_REVENUE
  -- Tax
  roomRevenueTax      → ROOM_REVENUE_TAX
  foodRevenueTax      → FOOD_REVENUE_TAX
  otherRevenueTax     → OTHER_REVENUE_TAX
  totalRevenueTax     → TOTAL_REVENUE_TAX
  nonRevenueTax       → NON_REVENUE_TAX

Note: OO_ROOMS / OS_ROOMS not in this SA — sourced from ra.OOO (StatisticsManagersReport).
      REMAINING_BLOCK_ROOMS / PICKEDUP_BLOCK_ROOMS sourced from ra.BLK (BookingsBlock SA)
      and can be joined on RESORT + CONSIDERED_DATE.
```

### Queries\BlockReservations.psm1

```
Subject Area:  BookingsBlock
Operation:     bookingsBlock
Primary view:  blockDetails
               Mandatory filters: resort (_in), stayDate / arrivalDate range
Target table:  ra.BLK

Functions:
  Get-BLK  -Hotel [hashtable] -SnapshotDate [date] -FutureDays [int]
           → [array] PSCustomObjects

GraphQL field → SQL column:
  resort              → RESORT
  (set by loader)     → SNAPSHOT_DATE     = business date of run   [out: YYYYMMDD]
  blockIdDate         → CONSIDERED_DATE   ← block stay/grid date
  blockCode           → BLOCK_CODE
  blockName           → BLOCK_NAME
  roomCategoryLabel   → ROOM_CATEGORY_LABEL
  marketCode          → MARKET_CODE
  sourceCode          → SOURCE_CODE
  rateCode            → RATE_CODE
  rateCategory        → RATE_CATEGORY
  cutoffDate          → CUTOFF_DATE
  (cutoffDate < snapshotDate) → IS_PAST_CUTOFF = 1
  blockedRooms        → ROOMS_CONTRACTED
  pickedUpRooms       → ROOMS_PICKEDUP
  (contracted-pickedup) → ROOMS_REMAINING  ← computed
  -- Revenue Gross
  roomRevenue         → ROOM_REVENUE
  foodRevenue         → FOOD_REVENUE
  otherRevenue        → OTHER_REVENUE
  totalRevenue        → TOTAL_REVENUE
  nonRevenue          → NON_REVENUE
  -- Revenue Net
  netRoomRevenue      → NET_ROOM_REVENUE
  netFoodRevenue      → NET_FOOD_REVENUE
  netOtherRevenue     → NET_OTHER_REVENUE
  netTotalRevenue     → NET_TOTAL_REVENUE
  -- Tax
  roomRevenueTax      → ROOM_REVENUE_TAX
  foodRevenueTax      → FOOD_REVENUE_TAX
  otherRevenueTax     → OTHER_REVENUE_TAX
  totalRevenueTax     → TOTAL_REVENUE_TAX

Note: BookingsBlockProductionChanges SA provides delta (change-since) mode.
```

### Queries\RoomInventory.psm1

```
Subject Areas: InventoryRooms (static room list → ra.RMN)
               StatisticsManagersReport (daily OOO/OOS counts → ra.OOO)
Target tables: ra.RMN, ra.OOO

Functions:
  Get-RMN  -Hotel [hashtable]
           → [array] PSCustomObjects  (static room configuration)

  Get-OOO  -Hotel [hashtable] -StartDate [date] -EndDate [date]
           → [array] PSCustomObjects  (daily OOO/OOS by room class)

GraphQL field → SQL column (InventoryRooms → ra.RMN):
  resort              → RESORT
  room                → ROOM
  roomCategoryLabel   → ROOM_CATEGORY_LABEL
  roomClass           → ROOM_CLASS
  roomStatus          → ROOM_STATUS    (CL/DI/IP/OO/OS — current day only)

GraphQL field → SQL column (StatisticsManagersReport → ra.OOO):
  resort              → RESORT
  businessDate        → BUSINESS_DATE      [out: YYYYMMDD]
  roomClass           → ROOM_CLASS
  oooRooms            → OOO_ROOMS
  osRooms             → OS_ROOMS
  availRoom           → AVAIL_ROOM
  physicalBeds        → PHYSICAL_BEDS
  oooBeds             → OOO_BEDS
  osBeds              → OS_BEDS
```

### Queries\MasterData.psm1

```
Functions:
  Get-MasterData  -Hotel [hashtable] -Type [MasterDataType] -ChangedSince [date]
                  → [array] PSCustomObjects

MasterDataType values and their Subject Areas:

  TrxCodes          → FinancialTransactionCodes   (financialTransactionCodes)
  RateCodes         → RatesCodeDetails            (ratesCodeDetails)
  RateCategories    → RatesCategories             (ratesCategories)
  RoomTypeLabels    → InventoryRooms              (inventoryRooms)
  MarketCodes       → ExportMappings              (exportMappings)   → ra.DIM_MarketCodes
  SourceCodes       → ExportMappings              (exportMappings)   → ra.DIM_SourceCodes  (source of reservation)
  Channels          → ExportMappings              (exportMappings)   → ra.DIM_Channels     (distribution channel)
  Property/Hotels   → ConfigurationResort         (configurationResort)
  ChainConfig       → ConfigurationChain          (configurationChain)

Note: SourceCodes and Channels are TWO SEPARATE, independent code lists and must
      never be merged:
        - SourceCodes = SOURCE OF RESERVATION (booking origin), OPERA field SOURCE_CODE
                        *** PRIORITY / REQUIRED master dimension — always loaded ***
        - Channels    = DISTRIBUTION CHANNEL (e.g. GDS, OTA, Direct, Web, CRO),
                        OPERA field CHANNEL
                        *** OPTIONAL — best-effort load; skipped WITHOUT error if the
                        channel list is unavailable or absent from ExportMappings ***
      MarketCodes (market segment), SourceCodes, and Channels are each pulled as
      distinct code/description pairs from the ExportMappings subject area, one
      logical list per dimension. (If ExportMappings is unavailable, distinct values
      may be harvested from StatisticsReservationsDaily as a fallback, still kept as
      three independent lists.) A missing Channels list is logged at INFO/WARN and
      does not fail the run; a missing SourceCodes list is treated as a real problem.

TrxCodes GraphQL field → SQL column mapping (FinancialTransactionCodes):
  transactionCodeDetails.resort              → HotelCode
  transactionCodeDetails.trxCode            → TrxCode
  transactionCodeDetails.description        → TrxName
  transactionCodeDetails.trxGroup           → TrxGroup
  transactionCodeDetails.trxSubgroup        → TrxType
  transactionCodeDetails.revenueYn          → RevenueYN             (BIT)
  transactionCodeDetails.roomRevenueYn      → IncludedInRoomRevenueYN (BIT)
  transactionCodeDetails.packageYn          → IncludedInPackageYN   (BIT)
  transactionCodeDetails.activeYn           → IsActive

RoomTypeLabels GraphQL field → SQL column mapping (InventoryRooms):
  roomDetails.resort           → HotelCode
  roomDetails.roomCategory     → RoomTypeLabel
  roomDetails.roomCategoryDesc → Description
  roomDetails.roomClass        → RoomClass
  roomDetails.physicalRooms    → PhysicalRoomCount
  roomDetails.activeYn         → IsActive

RateCodes GraphQL field → SQL column mapping (RatesCodeDetails):
  rateCodeDetails.resort          → HotelCode
  rateCodeDetails.rateCode        → Code
  rateCodeDetails.rateDescription → Description
  rateCodeDetails.rateCategory    → RateCategory
  rateCodeDetails.activeYn        → IsActive

MarketCodes GraphQL field → SQL column mapping (ExportMappings, market segment list):
  exportMappingDetails.resort      → HotelCode
  exportMappingDetails.code        → Code            (MARKETCODE)
  exportMappingDetails.description → Description
  exportMappingDetails.groupCode   → SegmentGroup
  exportMappingDetails.activeYn    → IsActive

SourceCodes GraphQL field → SQL column mapping (ExportMappings, SOURCE OF RESERVATION list) [PRIORITY / REQUIRED]:
  -- Independent from Channels. Represents where the booking originated. Always loaded.
  exportMappingDetails.resort      → HotelCode
  exportMappingDetails.code        → Code            (SOURCE_CODE)
  exportMappingDetails.description → Description
  exportMappingDetails.activeYn    → IsActive

Channels GraphQL field → SQL column mapping (ExportMappings, DISTRIBUTION CHANNEL list) [OPTIONAL / best-effort]:
  -- Independent from SourceCodes. Represents the distribution channel (GDS/OTA/Direct/Web/CRO).
  -- Optional dimension: if this list is not returned, skip without failing the run.
  exportMappingDetails.resort      → HotelCode
  exportMappingDetails.code        → Code            (CHANNEL)
  exportMappingDetails.description → Description
  exportMappingDetails.activeYn    → IsActive
```

---

## Configuration Schema

### Config\hotels.json (values encrypted at rest via DPAPI)
```json
{
  "hotels": [
    {
      "hotelCode": "HOTEL1",
      "chainCode": "CHAIN_A",
      "displayName": "Grand Hotel Downtown",
      "enabled": true,
      "gatewayUrl": "https://<environment>.hospitality.oracle.com",
      "enterpriseId": "<enterpriseId>",
      "clientId": "<encrypted>",
      "clientSecret": "<encrypted>",
      "apiKey": "<encrypted>",
      "timeZoneId": "Central European Standard Time",
      "nightAuditHour": 23,
      "nightAuditMinute": 0,
      "otbFutureDays": 365,
      "blockFutureDays": 180,
      "emailAlerts": {
        "enabled": true,
        "error": { "enabled": true,  "to": ["oncall-hotel1@<domain>"], "cc": ["integration-lead@<domain>"] },
        "warn":  { "enabled": true,  "to": ["ops-hotel1@<domain>"],    "cc": ["integration-lead@<domain>"] },
        "info":  { "enabled": false, "to": ["ops-hotel1@<domain>"],    "cc": [] }
      }
    },
    {
      "hotelCode": "HOTEL2",
      "chainCode": "CHAIN_B",
      "displayName": "Beach Resort",
      "enabled": true,
      "gatewayUrl": "https://<environment>.hospitality.oracle.com",
      "enterpriseId": "<enterpriseId>",
      "clientId": "<encrypted>",
      "clientSecret": "<encrypted>",
      "apiKey": "<encrypted>",
      "timeZoneId": "US Eastern Standard Time",
      "nightAuditHour": 0,
      "nightAuditMinute": 0,
      "otbFutureDays": 365,
      "blockFutureDays": 180,
      "emailAlerts": {
        "enabled": true,
        "error": { "enabled": true,  "to": ["oncall-hotel2@<domain>"], "cc": ["integration-lead@<domain>"] },
        "warn":  { "enabled": true,  "to": ["ops-hotel2@<domain>"],    "cc": ["integration-lead@<domain>"] },
        "info":  { "enabled": false, "to": ["ops-hotel2@<domain>"],    "cc": [] }
      }
    }
  ]
}
```

### Config\settings.json
```json
{
  "sqlServer": {
    "connectionString": "Server=.;Database=OperaRA;Integrated Security=True;TrustServerCertificate=True"
  },
  "api": {
    "requestDelayMs": 500,
    "maxRetries": 3,
    "baseRetryDelaySeconds": 2,
    "maxRetryDelaySeconds": 30,
    "tokenSafetyMarginSeconds": 60,
    "graphqlEndpointPath": "/rna/v1/graphql/",
    "oauthScope": "urn:opc:hgbu:ws:_myscopes_"
  },
  "extraction": {
    "defaultOtbFutureDays": 365,
    "defaultBlockFutureDays": 180,
    "transactionalChunkDays": 7,
    "masterDataChunkDays": 0
  },
  "logging": {
    "logDirectory": "Logs",
    "logLevel": "INFO",
    "sqlLogging": true,
    "logName": "OperaRA_Loader"
  },
  "smtp": {
    "enabled": false,
    "smtpServer": "REPLACE_ME-smtp-relay-host",
    "port": 587,
    "useSsl": true,
    "from": "opera-ra-loader@REPLACE_ME.com",
    "fromDisplayName": "OPERA R&A Loader",
    "authRequired": true,
    "username": "REPLACE_ME-smtp-username",
    "password": "<encrypted>",
    "maxInlineEntriesPerEmail": 50
  }
}
```

---

## Data Models

### dbo.LoadLog
```sql
LoadId           BIGINT IDENTITY    PRIMARY KEY
BatchId          UNIQUEIDENTIFIER   NOT NULL
HotelCode        NVARCHAR(20)       NOT NULL
ChainCode        NVARCHAR(20)       NOT NULL
Mode             NVARCHAR(30)       NOT NULL   -- Full|Delta|OTB|MasterData|All
QueryType        NVARCHAR(50)       NOT NULL   -- ReservationStats|FinancialTx|OTB|...
BusinessDateFrom DATE
BusinessDateTo   DATE
StartedAt        DATETIME2          NOT NULL
CompletedAt      DATETIME2
Status           NVARCHAR(20)       NOT NULL   -- Running|Success|NoData|Error
RowsFetched      INT
RowsInserted     INT
RowsUpdated      INT
ErrorMessage     NVARCHAR(MAX)
LoadedBy         NVARCHAR(100)
```

---

### ra.RES  (actuals — reservation statistics)
Natural key for MERGE: `RESORT + BUSINESS_DATE + RESV_NAME_ID`
> One row per reservation per business date. Maps directly to `RESERVATION_STAT_DAILY`.

```sql
StatId            BIGINT IDENTITY    PRIMARY KEY
-- Identity / Join Keys
RESORT            NVARCHAR(20)       NOT NULL              -- OPERA resort code
CHAIN_CODE        NVARCHAR(20)       NOT NULL
BUSINESS_DATE     DATE               NOT NULL              -- join key → ra.FIN, ra.OTB
RESV_NAME_ID      NVARCHAR(50)       NOT NULL              -- join key → ra.FIN
-- Rate / Market Dimensions
RATE_CODE         NVARCHAR(50)
RATE_CATEGORY     NVARCHAR(50)
MARKET_CODE       NVARCHAR(50)
SOURCE_CODE       NVARCHAR(50)
CHANNEL           NVARCHAR(50)
-- Reservation Details
ROOM              NVARCHAR(20)
PSEUDO_ROOM_YN    CHAR(1)
ROOM_CATEGORY_LABEL NVARCHAR(20)                           -- room type label (e.g. DB1, DS1)
RESV_STATUS       NVARCHAR(30)                             -- CHECKED IN, CHECKED OUT, CANCELLED etc.
QUANTITY          INT
TRUNC_BEGIN_DATE  DATE                                     -- arrival date (truncated)
TRUNC_END_DATE    DATE                                     -- departure date (truncated)
COUNTRY           NVARCHAR(10)
NIGHTS            INT
-- Occupancy Counts
ADULTS            INT
CHILDREN          INT
STAY_ROOMS        INT
STAY_PERSONS      INT
STAY_ADULTS       INT
STAY_CHILDREN     INT
ARR_ROOMS         INT
ARR_PERSONS       INT
DEP_ROOMS         INT
DEP_PERSONS       INT
DAY_USE_ROOMS     INT
DAY_USE_PERSONS   INT
NO_SHOW_ROOMS     INT
NO_SHOW_PERSONS   INT
-- Flags
HOUSE_USE_YN      CHAR(1)
COMPLIMENTARY_YN  CHAR(1)
WALKIN_YN         CHAR(1)
CANCELLATION_DATE DATETIME2
-- Audit
BATCH_ID          UNIQUEIDENTIFIER
LOADED_AT         DATETIME2
LOADED_BY         NVARCHAR(100)
```

---

### ra.FIN  (actuals — financial transactions)
Natural key for MERGE: `HotelCode + BusinessDate + Resort + TrxNo + TranActionId`
> Using `TRX_NO` + `TRAN_ACTION_ID` as the surrogate transaction keys from OPERA R&A,
> matching the CSV export. `RESV_NAME_ID` is the join key back to `ra.RES`.

```sql
TxId             BIGINT IDENTITY    PRIMARY KEY
-- Identity / Join Keys
RESORT           NVARCHAR(20)       NOT NULL              -- OPERA resort code
CHAIN_CODE       NVARCHAR(20)       NOT NULL              -- hotel chain
BUSINESS_DATE    DATE               NOT NULL              -- join key → ra.RES
RESV_NAME_ID     NVARCHAR(50)       NOT NULL              -- join key → ra.RES
ORIGINAL_RESV    NVARCHAR(50)                             -- original resv if transferred
-- Transaction Identifiers
TRX_NO           NVARCHAR(50)       NOT NULL              -- OPERA transaction number
TRAN_ACTION_ID   NVARCHAR(50)       NOT NULL              -- OPERA transaction action ID
TRX_NO_ADDED_BY  NVARCHAR(50)                             -- linked parent TRX_NO (tax lines)
-- Transaction Classification
TRX_CODE         NVARCHAR(20)       NOT NULL              -- FK → ra.DIM (TC_CODE)
TC_GROUP         NVARCHAR(50)                             -- e.g. ROOM, FB, PAY, TAX, PKG
TC_SUBGROUP      NVARCHAR(50)                             -- e.g. 100, 200, TAX4
FT_SUBTYPE       NVARCHAR(10)                             -- C=Charge, FC=Payment, PK=Package
-- Rate / Market Dimensions
RATE_CODE        NVARCHAR(50)
MARKET_CODE      NVARCHAR(50)
SOURCE_CODE      NVARCHAR(50)
-- Amounts (all from OPERA R&A)
NET_AMOUNT       DECIMAL(18,4)                            -- net of tax (revenue amount excl. VAT)
GROSS_AMOUNT     DECIMAL(18,4)                            -- gross (incl. VAT) — null for payments
TRX_AMOUNT       DECIMAL(18,4)                            -- transaction amount (= posted for charges)
POSTED_AMOUNT    DECIMAL(18,4)                            -- amount actually posted to the folio
REVENUE_AMT      DECIMAL(18,4)                            -- revenue-recognised amount
QUANTITY         DECIMAL(18,4)                            -- quantity / number of units
PRICE_PER_UNIT   DECIMAL(18,4)                            -- unit price
EXCHANGE_RATE    DECIMAL(18,6)      DEFAULT 1             -- FX rate to base currency
CURRENCY         NVARCHAR(10)                             -- ISO currency code
IND_REVENUE_GP   CHAR(1)                                  -- Y/N revenue group indicator
-- Date / Time
TRX_DATE         DATETIME2          NOT NULL              -- posting date (local)
TRX_DATE_UTC     DATETIME2                                -- posting date UTC
IS_LATE_POSTING  BIT                DEFAULT 0             -- TRX_DATE > BUSINESS_DATE
-- GL Export Codes (from ExportMappings SA — populated if available)
COSTCENTER       NVARCHAR(50)                             -- BOF_CODE2 / GL cost centre
ACCOUNT          NVARCHAR(50)                             -- BOF_CODE5 / GL account
-- Passer-by (non-reservation transactions)
PASSER_BY_NAME   NVARCHAR(200)
-- Audit
BATCH_ID         UNIQUEIDENTIFIER
LOADED_AT        DATETIME2
LOADED_BY        NVARCHAR(100)
```

---

### ra.OTB  (daily snapshot — on the books, future view)
Natural key for MERGE: `RESORT + SNAPSHOT_DATE + CONSIDERED_DATE + MARKET_CODE + ROOM_CATEGORY_LABEL + SOURCE_CODE + CHANNEL + RATE_CODE + RESV_TYPE`
> `SNAPSHOT_DATE` = business date the data was pulled (set by loader).
> `CONSIDERED_DATE` = future stay date being described (= `stayDate` in GraphQL).

```sql
OtbId               BIGINT IDENTITY    PRIMARY KEY
-- Identity
RESORT              NVARCHAR(20)       NOT NULL
CHAIN_CODE          NVARCHAR(20)       NOT NULL
SNAPSHOT_DATE       DATE               NOT NULL              -- business date of run
CONSIDERED_DATE     DATE               NOT NULL              -- future stay date
-- Dimensions
MARKET_CODE         NVARCHAR(50)
SOURCE_CODE         NVARCHAR(50)
CHANNEL             NVARCHAR(50)
RATE_CODE           NVARCHAR(50)
RATE_CATEGORY       NVARCHAR(50)
ROOM_CATEGORY_LABEL NVARCHAR(20)
RESV_TYPE           NVARCHAR(10)                             -- R=Regular, G=Group etc.
EVENT_TYPE          NVARCHAR(10)
COUNTRY             NVARCHAR(10)
CURRENCY_CODE       NVARCHAR(10)
-- Date Range
TRUNC_BEGIN_DATE    DATE
TRUNC_END_DATE      DATE
-- Room / Occupancy Counts
ARR_ROOMS           INT
DEP_ROOMS           INT
NO_ROOMS            INT                                      -- rooms on books
DAY_USE_ROOMS       INT
DAY_USE_PERSONS     INT
ARR_PERSONS         INT
DEP_PERSONS         INT
ADULTS              INT
CHILDREN            INT
QUANTITY            INT
NIGHTS              INT
RESV_STATUS         NVARCHAR(30)
-- Block Rooms (from BookingsBlock SA — joined by RESORT + CONSIDERED_DATE)
REMAINING_BLOCK_ROOMS  INT
PICKEDUP_BLOCK_ROOMS   INT
-- Revenue — Gross (includes VAT)
GROSS_RATE             DECIMAL(18,2)                         -- gross rate per night
ROOM_REVENUE           DECIMAL(18,2)                         -- gross room revenue
FOOD_REVENUE           DECIMAL(18,2)                         -- gross F&B revenue
OTHER_REVENUE          DECIMAL(18,2)                         -- gross other revenue
TOTAL_REVENUE          DECIMAL(18,2)                         -- gross total revenue
NON_REVENUE            DECIMAL(18,2)                         -- non-revenue (deposits etc.)
-- Revenue — Net (excl. VAT)
NET_ROOM_REVENUE       DECIMAL(18,2)                         -- net room revenue
EXTRA_REVENUE          DECIMAL(18,2)                         -- net extras
-- Tax Amounts
ROOM_REVENUE_TAX       DECIMAL(18,2)
FOOD_REVENUE_TAX       DECIMAL(18,2)
OTHER_REVENUE_TAX      DECIMAL(18,2)
TOTAL_REVENUE_TAX      DECIMAL(18,2)
NON_REVENUE_TAX        DECIMAL(18,2)
-- Computed
PSEUDO_ROOM_YN         CHAR(1)
DAY_USE_YN             CHAR(1)
-- Audit
BATCH_ID               UNIQUEIDENTIFIER
LOADED_AT              DATETIME2
LOADED_BY              NVARCHAR(100)
```

---

### ra.BLK  (daily snapshot — block reservations)
Natural key for MERGE: `RESORT + SNAPSHOT_DATE + BLOCK_CODE + CONSIDERED_DATE + ROOM_CATEGORY_LABEL`
> Sourced from `BookingsBlock` SA. `SNAPSHOT_DATE` set by loader = business date of run.

```sql
BlkId               BIGINT IDENTITY    PRIMARY KEY
-- Identity
RESORT              NVARCHAR(20)       NOT NULL
CHAIN_CODE          NVARCHAR(20)       NOT NULL
SNAPSHOT_DATE       DATE               NOT NULL              -- business date of run
CONSIDERED_DATE     DATE               NOT NULL              -- block stay/grid date
-- Block Header
BLOCK_CODE          NVARCHAR(50)       NOT NULL
BLOCK_NAME          NVARCHAR(200)
ROOM_CATEGORY_LABEL NVARCHAR(20)
MARKET_CODE         NVARCHAR(50)
SOURCE_CODE         NVARCHAR(50)
RATE_CODE           NVARCHAR(50)
RATE_CATEGORY       NVARCHAR(50)
CUTOFF_DATE         DATE
IS_PAST_CUTOFF      BIT                DEFAULT 0             -- CUTOFF_DATE < SNAPSHOT_DATE
-- Room Counts
ROOMS_CONTRACTED    INT                                      -- blocked rooms
ROOMS_PICKEDUP      INT                                      -- picked up (actual reservations)
ROOMS_REMAINING     INT                                      -- computed: contracted - pickedup
-- Revenue — Gross
ROOM_REVENUE        DECIMAL(18,2)                            -- gross room revenue on books
FOOD_REVENUE        DECIMAL(18,2)                            -- gross F&B revenue on books
OTHER_REVENUE       DECIMAL(18,2)                            -- gross other revenue on books
TOTAL_REVENUE       DECIMAL(18,2)                            -- gross total revenue on books
NON_REVENUE         DECIMAL(18,2)
-- Revenue — Net (excl. VAT)
NET_ROOM_REVENUE    DECIMAL(18,2)
NET_FOOD_REVENUE    DECIMAL(18,2)
NET_OTHER_REVENUE   DECIMAL(18,2)
NET_TOTAL_REVENUE   DECIMAL(18,2)
-- Tax Amounts
ROOM_REVENUE_TAX    DECIMAL(18,2)
FOOD_REVENUE_TAX    DECIMAL(18,2)
OTHER_REVENUE_TAX   DECIMAL(18,2)
TOTAL_REVENUE_TAX   DECIMAL(18,2)
-- Audit
BATCH_ID            UNIQUEIDENTIFIER
LOADED_AT           DATETIME2
LOADED_BY           NVARCHAR(100)
```

---

### ra.RMN  (room list — physical room configuration)
Natural key for MERGE: `RESORT + ROOM`
```sql
RmnId            BIGINT IDENTITY    PRIMARY KEY
RESORT           NVARCHAR(20)       NOT NULL
CHAIN_CODE       NVARCHAR(20)       NOT NULL
ROOM             NVARCHAR(20)       NOT NULL
ROOM_CATEGORY_LABEL NVARCHAR(20)                           -- room type label
ROOM_CLASS       NVARCHAR(50)
ROOM_STATUS      NVARCHAR(10)                              -- CL, DI, IP, OO, OS
-- Audit
BATCH_ID         UNIQUEIDENTIFIER
LOADED_AT        DATETIME2
LOADED_BY        NVARCHAR(100)
```

---

### ra.OOO  (daily inventory — OOO/OOS by room class)
Natural key for MERGE: `RESORT + BUSINESS_DATE + ROOM_CLASS`
```sql
OooId            BIGINT IDENTITY    PRIMARY KEY
RESORT           NVARCHAR(20)       NOT NULL
CHAIN_CODE       NVARCHAR(20)       NOT NULL
BUSINESS_DATE    DATE               NOT NULL
ROOM_CLASS       NVARCHAR(50)       NOT NULL
OOO_ROOMS        INT
OS_ROOMS         INT
AVAIL_ROOM       INT                                       -- physical - occupied - OOO - OS
OOO_BEDS         INT
OS_BEDS          INT
PHYSICAL_BEDS    INT
-- Audit
BATCH_ID         UNIQUEIDENTIFIER
LOADED_AT        DATETIME2
LOADED_BY        NVARCHAR(100)
```

---

### ra.DIM_TrxCodes  (master — SCD Type 2)
Natural key: `RESORT + TRX_CODE + VALID_FROM`
```sql
TrxCodeKey              BIGINT IDENTITY    PRIMARY KEY
RESORT                  NVARCHAR(20)       NOT NULL
CHAIN_CODE              NVARCHAR(20)       NOT NULL
TRX_CODE                NVARCHAR(20)       NOT NULL
TRX_NAME                NVARCHAR(200)                              -- description
TC_GROUP                NVARCHAR(100)      NOT NULL               -- ROOM, FB, PAY, TAX, PKG, MISC…
TC_SUBGROUP             NVARCHAR(100)                             -- 100, 200, TAX4, PKG…
FT_SUBTYPE              NVARCHAR(10)                              -- C or FC (hardcoded for group)
REVENUE_YN              CHAR(1)            NOT NULL DEFAULT 'N'   -- Y/N
ROOM_REVENUE_YN         CHAR(1)            NOT NULL DEFAULT 'N'
PACKAGE_YN              CHAR(1)            NOT NULL DEFAULT 'N'
IS_ACTIVE               BIT                NOT NULL DEFAULT 1
FLAG                    CHAR(1)            NOT NULL DEFAULT 'N'   -- N=active Y=deleted (DIM file)
VALID_FROM              DATE               NOT NULL
VALID_TO                DATE               NULL
IS_CURRENT              BIT                NOT NULL DEFAULT 1
-- Audit
BATCH_ID                UNIQUEIDENTIFIER
LOADED_AT               DATETIME2
LOADED_BY               NVARCHAR(100)
```

---

### ra.DIM_RoomTypes  (master — SCD Type 2)
Natural key: `RESORT + ROOM_CATEGORY_LABEL + VALID_FROM`
```sql
RoomTypeKey             BIGINT IDENTITY    PRIMARY KEY
RESORT                  NVARCHAR(20)       NOT NULL
CHAIN_CODE              NVARCHAR(20)       NOT NULL
ROOM_CATEGORY_LABEL     NVARCHAR(20)       NOT NULL              -- e.g. DB1, DS1, WB1
DESCRIPTION             NVARCHAR(200)
ROOM_CLASS              NVARCHAR(50)
PHYSICAL_ROOM_COUNT     INT
IS_ACTIVE               BIT                NOT NULL DEFAULT 1
FLAG                    CHAR(1)            NOT NULL DEFAULT 'N'
VALID_FROM              DATE               NOT NULL
VALID_TO                DATE               NULL
IS_CURRENT              BIT                NOT NULL DEFAULT 1
-- Audit
BATCH_ID                UNIQUEIDENTIFIER
LOADED_AT               DATETIME2
LOADED_BY               NVARCHAR(100)
```

---

### ra.DIM_RateCodes / ra.DIM_MarketCodes / ra.DIM_SourceCodes / ra.DIM_Channels
All follow the same SCD Type 2 pattern with `RESORT + CODE + VALID_FROM` natural key:
```sql
<EntityKey>     BIGINT IDENTITY    PRIMARY KEY
RESORT          NVARCHAR(20)       NOT NULL
CHAIN_CODE      NVARCHAR(20)       NOT NULL
CODE            NVARCHAR(50)       NOT NULL     -- RATE_CODE / MARKETCODE / SOURCE_CODE / CHANNEL
DESCRIPTION     NVARCHAR(200)
-- RateCodes only:
RATE_CATEGORY   NVARCHAR(100)
RATE_CLASS      NVARCHAR(100)
-- MarketCodes only:
SEGMENT_GROUP   NVARCHAR(100)
IS_ACTIVE       BIT                NOT NULL DEFAULT 1
FLAG            CHAR(1)            NOT NULL DEFAULT 'N'   -- N=active Y=deleted
VALID_FROM      DATE               NOT NULL
VALID_TO        DATE               NULL
IS_CURRENT      BIT                NOT NULL DEFAULT 1
-- Audit
BATCH_ID        UNIQUEIDENTIFIER
LOADED_AT       DATETIME2
LOADED_BY       NVARCHAR(100)
```

---

### ra.Hotels  (master — property configuration)
```sql
HotelKey         BIGINT IDENTITY    PRIMARY KEY
RESORT           NVARCHAR(20)       NOT NULL UNIQUE
CHAIN_CODE       NVARCHAR(20)       NOT NULL
DISPLAY_NAME     NVARCHAR(200)
CITY             NVARCHAR(100)
COUNTRY          NVARCHAR(50)
CURRENCY_CODE    NVARCHAR(10)
TIME_ZONE_ID     NVARCHAR(100)
NIGHT_AUDIT_HOUR TINYINT
NIGHT_AUDIT_MIN  TINYINT
IS_ACTIVE        BIT                NOT NULL DEFAULT 1
-- Audit
BATCH_ID         UNIQUEIDENTIFIER
LOADED_AT        DATETIME2
LOADED_BY        NVARCHAR(100)
```

---

## Entry Point Parameters

```powershell
Run-OperaRALoader.ps1
  -Mode          [All | Full | Delta | OTB | MasterData]  # default: Delta
  -HotelCode     [string[]]    # optional: restrict to specific hotel(s)
  -ChainCode     [string[]]    # optional: restrict to specific chain(s)
  -BusinessDate  [datetime]    # override business date (default: hotel yesterday)
  -StartDate     [datetime]    # explicit range start for actuals
  -EndDate       [datetime]    # explicit range end for actuals
  -DryRun        [switch]      # fetch data, skip SQL writes
  -FailFast      [switch]      # stop on first hotel error
  -ConfigPath    [string]      # override config directory path
  -Verbose                     # PowerShell standard verbose output
  -Debug                       # PowerShell standard debug output
```

### Mode Behaviour Matrix

| Mode        | RES Stats | FIN Tx | OTB Snapshot | Block Snapshot | Room Inventory | Master Data |
|-------------|-----------|--------|--------------|----------------|----------------|-------------|
| Delta       | ✓         | ✓      | ✓            | ✓              | ✓              | —           |
| OTB         | —         | —      | ✓            | ✓              | ✓              | —           |
| MasterData  | —         | —      | —            | —              | —              | ✓           |
| Full        | ✓         | ✓      | ✓            | ✓              | ✓              | ✓           |
| All         | ✓         | ✓      | ✓            | ✓              | ✓              | ✓           |

---

## Security Considerations
- Credentials encrypted with `ConvertTo-SecureString` / DPAPI (service account bound).
- `Protect-HotelsConfig.ps1` converts plain-text input to encrypted `hotels.json`.
- `hotels.json` listed in `.gitignore` — never committed.
- API keys and secrets never emitted to logs (masked with `****`).
- SQL service account: `db_datawriter` + `EXECUTE` on `ra` schema only. No `db_owner`.

---

## Error Handling
- **HTTP 401**: clear token cache, re-authenticate once using `urn:opc:hgbu:ws:_myscopes_` scope, retry.
- **HTTP 429 / 5xx**: exponential backoff (2 s base, ×2 per attempt, 30 s cap, 3 retries max).
- **GraphQL `errors` array present but `data` not null**: log each error as WARN, continue processing partial data.
- **GraphQL `errors` array present and `data` is null**: treat as full failure, throw exception.
- **Cartesian join risk**: query modules that need attributes from multiple child folders issue separate `Invoke-GraphQL` calls and merge results in PowerShell.
- **Per-hotel isolation**: one hotel failure does not abort others unless `-FailFast`.
- **Late posting detection**: `IsLatePosting = 1` when `PostingDate > BusinessDate`; WARN logged if count > 0.
- **Missing data**: `NoData` status in `dbo.LoadLog`; not treated as error.
- **SCD Type 2 conflict**: on master data change, close existing record (`ValidTo = today - 1`, `IsCurrent = 0`) and insert new version.
- **Exit codes**: 0 = all hotels success; 1 = partial failure; 2 = total failure.

---

## Correctness Properties

Universal invariants the loader must uphold across all valid inputs — every run, every hotel, every date. Each is a property-style statement traceable to the requirement it satisfies; the example-based tests in the Testing Strategy sample these properties.

### Property 1: Re-run idempotency
For any mode and any date range, WHEN the same load runs more than once, THE SYSTEM SHALL leave the target tables in the same state as a single run (no duplicate rows), via staging → `MERGE` on each table's natural key.

**Validates: Requirements 10.1** (REQ-010)

### Property 2: Snapshot preservation
For any daily snapshot (OTB, BLK), WHEN a new snapshot is written, THE SYSTEM SHALL preserve all prior snapshots by using insert-only MERGEs keyed on `SNAPSHOT_DATE`.

**Validates: Requirements 6.1, 7.1** (REQ-006, REQ-007)

### Property 3: Join-key integrity
For any financial-transaction row, THE SYSTEM SHALL carry `RESORT + BUSINESS_DATE + RESV_NAME_ID` so it joins back to `ra.RES`, backfilling a blank `RESORT` from the hotel code rather than leaving it empty.

**Validates: Requirements 4.1, 5.1** (REQ-004, REQ-005)

### Property 4: Audit completeness
For any persisted row in any table, THE SYSTEM SHALL populate the audit columns `BATCH_ID`, `LOADED_AT`, and `LOADED_BY`.

**Validates: Requirements 10.1** (REQ-010)

### Property 5: UTC normalisation
For any datetime that has a UTC counterpart, THE SYSTEM SHALL convert it from the hotel's local time zone such that a local → UTC → local round-trip yields the original instant across DST boundaries, and SHALL preserve the local value verbatim when no time zone is configured.

**Validates: Requirements 14.1** (REQ-014)

### Property 6: Business-date grounding
For any hotel, THE SYSTEM SHALL anchor extraction date logic to the night-audit business date rather than wall-clock midnight, and SHALL treat a missing time zone as a hard error.

**Validates: Requirements 14.2** (REQ-014)

### Property 7: Late-posting classification
For any financial transaction, THE SYSTEM SHALL set `IS_LATE_POSTING = 1` if and only if `TRX_DATE > BUSINESS_DATE`, and `0` otherwise.

**Validates: Requirements 5.2** (REQ-005)

### Property 8: Output vs filter date formats never mix
For any emitted row and any request filter, THE SYSTEM SHALL format output dates as `YYYYMMDD` / `YYYYMMDD HH:mm:ss` and GraphQL request-filter dates as ISO `YYYY-MM-DD`, never mixing the two.

**Validates: Requirements 4.1, 5.1, 6.1, 7.1, 8.1** (REQ-004, REQ-005, REQ-006, REQ-007, REQ-008)

### Property 9: SCD Type 2 monotonicity
For any master-data natural key, THE SYSTEM SHALL keep at most one row with `IS_CURRENT = 1`, closing the current row (`VALID_TO`, `IS_CURRENT = 0`) and inserting a new version on a tracked change, and performing no write when unchanged (treating NULL and empty string as equal).

**Validates: Requirements 9.1** (REQ-009)

### Property 10: SourceCodes and Channels stay independent
For any master-data load, THE SYSTEM SHALL keep SourceCodes and Channels as independent lists in separate target tables, treating an empty SourceCodes list as an error and an empty Channels list as a benign skip.

**Validates: Requirements 9.2** (REQ-009)

### Property 11: Bounded retries
For any transient API failure (429/5xx), THE SYSTEM SHALL retry with capped exponential backoff up to `maxRetries` and then surface an error, never retrying indefinitely.

**Validates: Requirements 11.1** (REQ-011)

### Property 12: Fail-partial, not fail-whole
For any batch of hotels, WHEN one hotel fails, THE SYSTEM SHALL continue processing the others unless `-FailFast` is set, and SHALL return exit code 0 (all success), 1 (partial), or 2 (total failure) accordingly.

**Validates: Requirements 13.1, 15.1** (REQ-013, REQ-015)

### Property 13: Empty is not error
For any expected-but-empty API result, THE SYSTEM SHALL record a `NoData` status in `dbo.LoadLog` and continue, never treating it as a failure.

**Validates: Requirements 15.2** (REQ-015)

### Property 14: DryRun writes nothing
For any run invoked with `-DryRun`, THE SYSTEM SHALL execute queries but call no writer and change no target-table state.

**Validates: Requirements 13.2** (REQ-013)

### Property 15: Secrets never surface
For any log line or emailed content, THE SYSTEM SHALL keep credentials and tokens DPAPI-encrypted at rest and masked (`****`) in output, and SHALL report a decryption failure without echoing the encrypted or plaintext value.

**Validates: Requirements 2.4, 12.1, 16.1** (REQ-002, REQ-012, REQ-016)

---

## Testing Strategy

Tests use **Pester** (PowerShell's test framework) and live in the `Tests\` folder, one spec file per module. External dependencies (OHIP HTTP calls, SQL Server, SMTP, DPAPI) are mocked so the suite runs offline and deterministically in CI.

Every module is exercised through **injected scriptblock seams** (`-TokenRequest`, `-Invoker`, `-TokenProvider`, `-Sleep`, `-SubjectAreaInvoker`, `-SqlExecutor`, `-BulkCopy`, `-CurrentVersionLookup`, `-Encryptor`/`-Verifier`, `-ConfigResolver`, etc.) so no network, SQL Server, SMTP, or real waiting is required. `Run-OperaRALoader.ps1` and `Protect-HotelsConfig.ps1` are dot-sourced with a `*_NO_MAIN=1` environment flag so only their reusable functions load (the procedural main body is skipped). DPAPI-dependent assertions are `-Skip`ped on non-Windows hosts.

### Test Coverage by Module

**`Auth.Tests.ps1` → `Auth.psm1`** (REQ-002, REQ-003)
- Exports `Get-OAuthToken` / `Clear-TokenCache`.
- First call acquires a token; second call reuses the cache (no second request).
- Re-acquires when the cached token falls inside the safety margin (`expires_in` 30 s vs 60 s margin); `-ForceRefresh` bypasses a still-valid token.
- `Clear-TokenCache` forces re-auth on the next call (401 recovery); clearing an unknown hotel is a no-op.
- Decrypts `clientId`/`clientSecret` into a `client_credentials` form body with the fixed `urn:opc:hgbu:ws:_myscopes_` scope, POSTed to `<gatewayUrl>/oauth/token` as `application/x-www-form-urlencoded`.
- Decrypts DPAPI **CU-tagged**, **LM-tagged**, and **legacy untagged** credential forms (back-compat).
- Throws a non-sensitive error when a credential cannot be decrypted, and when the token response has no `access_token`.

**`ApiClient.Tests.ps1` → `ApiClient.psm1`** (REQ-003, REQ-011)
- Exports `Invoke-GraphQL`, `Invoke-RASubjectArea`, `Invoke-RAApi`.
- Injects headers: `Authorization: Bearer`, `x-app-key`, `Content-Type`, `Accept`, `x-hotelid`, and a **new `x-request-id` GUID per request**; POSTs to `<gatewayUrl>/rna/v1/graphql/` with a JSON body carrying `query` + `variables`.
- HTTP 401 → clear cache, re-auth once, retry; throws if 401 persists (exactly 2 attempts).
- Exponential backoff on 429/5xx: delays `2,4,8` then throw (4 attempts); caps at `retryMaxDelaySeconds`; recovers when a transient 500 is followed by success.
- GraphQL `errors` array: WARN + return when `data` is non-null; **throw when `data` is null**.
- `Invoke-RASubjectArea` throttles *between* chunks only (not before the first), flattens all chunks into one real `[object[]]`, and defensively follows a `nextPageToken` if returned.

**`DateHelper.Tests.ps1` → `DateHelper.psm1`** (REQ-014)
- DST-aware `Convert-ToUtc`: +1 h in winter (CET), +2 h in summer (CEST); round-trips winter/summer UTC instants through `Convert-ToLocal | Convert-ToUtc`.
- `Get-BusinessDate` midnight cutover returns local-yesterday; falls back to midnight when `nightAuditHour` is absent; **throws when `timeZoneId` is missing**.
- (Date chunking + `Format-OutputDate` are additionally exercised through the query-module tests.)

**`SqlWriter.Tests.ps1` → `SqlWriter.psm1`** (REQ-009, REQ-010)
- Table specs: RES natural key `RESORT+BUSINESS_DATE+RESV_NAME_ID+MARKET_CODE+ROOM_CATEGORY_LABEL`; FIN `RESORT+BUSINESS_DATE+TRX_NO+TRAN_ACTION_ID`; OTB key includes `SNAPSHOT_DATE`; `DIM_SourceCodes`/`DIM_Channels` resolve to independent targets.
- `Initialize-Database` runs the five DDL scripts in numeric order (001..005), split on standalone `GO`.
- `New-MergeStatement` maps every column, keys on the natural key, stamps `BATCH_ID`/`LOADED_AT`/`LOADED_BY`, emits `OUTPUT $action`.
- `Get-IsLatePosting` / `Get-IsPastCutoff` flag logic, and `Write-FIN`/`Write-BLK` compute the flags during mapping.
- OTB/BLK are **insert-only MERGEs** (`WHEN NOT MATCHED BY TARGET`, no `WHEN MATCHED UPDATE`) so prior snapshots are preserved.
- SCD2 (`Write-DIM`): insert new current version for a new code; expire (`VALID_TO`, `IS_CURRENT=0`) + insert on a tracked change; no-op when unchanged; NULL and empty string treated as equal.
- SourceCodes (required) writes only to `ra.DIM_SourceCodes`; empty Channels payload is a benign no-op. `ra.Hotels` upserts in place (no versioning). `Write-LoadLog` uses the real DDL columns (`StartTime`/`EndTime`/`[RowCount]`, not `StartedAt`/`DurationMs`). MERGE failure rethrows.

**`Logger.Complete-Batch.Tests.ps1` → `Logger.psm1`** (REQ-012, REQ-015)
- `Complete-Batch` with SqlLogging disabled: no throw, writes the INFO summary (`Status=`, `RowsFetched/Inserted/Updated=`, BatchId), renders omitted counts as `<n/a>`, logs a DEBUG "SqlLogging disabled".
- `-Status` is constrained by `ValidateSet` (rejects `Bogus`; accepts `Success`/`NoData`/`Error`/`Partial`).
- SqlLogging enabled with no connection string: WARN "no SQL connection string is configured", never throws.
- *(Scope note: this file covers `Complete-Batch` non-SQL paths only; `Send-AlertEmail` / severity-based email of REQ-016 is designed but not yet covered by an automated test.)*

**`ReservationStats.Tests.ps1` → `Queries\ReservationStats.psm1`** (REQ-004)
- 7-day chunking (20-day range → 3 chunks), `-ChunkDays` override, and `extraction.transactionalChunkDays` from Config; **ISO `YYYY-MM-DD` request filters** (`resort._in`, `businessDate._gte/_lte`); operation `statisticsReservationsDaily` / primary view `reservationDailyStatisticsDetails`.
- Maps key `ra.RES` fields; empty/whitespace source values → `$null`; blank `RESORT` backfilled from hotel code.
- Output formatting: date-only → `YYYYMMDD`, datetime → `YYYYMMDD HH:mm:ss`, empty date → empty string.
- ADR = Revenue/RoomNights, RevPAR = Revenue/PhysicalRooms; does not overwrite API-supplied values; divide-by-zero and missing-denominator → `$null`.
- Multi-chunk accumulation to a flat array (empty → empty array, not `$null`); one INFO row-count+duration log line per chunk.

**`FinancialTransactions.Tests.ps1` → `Queries\FinancialTransactions.psm1`** (REQ-005)
- Same chunking/ISO-filter/operation assertions as RES (operation & view `financialTransactionDetails`).
- Maps key `ra.FIN` fields (`RESV_NAME_ID`, `TRX_NO`, `TRAN_ACTION_ID`, `TRX_NO_ADDED_BY`, `TC_GROUP`, `FT_SUBTYPE`, amounts…); `COSTCENTER`/`ACCOUNT` set `$null` (not in this SA); blank `RESORT` backfilled.
- `TRX_DATE` (local) → `TRX_DATE_UTC` via `timeZoneId` (CEST 10:00 → 08:00 UTC); falls back to local when no timezone; `YYYYMMDD HH:mm:ss` formatting; empty dates → empty string.
- `IS_LATE_POSTING` late/same-day/early; a **single WARN carrying the late-posting count** only when late postings exist.

**`OnTheBooks.Tests.ps1` → `Queries\OnTheBooks.psm1`** (REQ-006)
- Derives `consideredDate` range from the snapshot horizon (`+FutureDays`), ISO filters, operation `statisticsForecastSummary` / view `forecastSummaryDetails`.
- `SNAPSHOT_DATE` from `-SnapshotDate`, `CONSIDERED_DATE` from response `stayDate`; `YYYYMMDD` formatting; blank `RESORT` backfilled.
- `ADR_ON_BOOKS` = ROOM_REVENUE/NO_ROOMS (divide-by-zero → `$null`, API value not overwritten); TENTATIVE/DEFINITE split by reservation status; one INFO "OTB snapshot complete" log with snapshot/considered-range/row count.

**`BlockReservations.Tests.ps1` → `Queries\BlockReservations.psm1`** (REQ-007)
- Snapshot horizon over `blockFutureDays` (falls back to hotel config), ISO filters, operation `bookingsBlock` / view `blockDetails`.
- Maps key `ra.BLK` fields; `SNAPSHOT_DATE` from `-SnapshotDate`, `CONSIDERED_DATE`/`CUTOFF_DATE` from response as `YYYYMMDD`; blank `RESORT` backfilled.
- `ROOMS_REMAINING` = contracted − pickedup (null-guarded, API value not overwritten); `IS_PAST_CUTOFF` past/on/after cutoff; single WARN with past-cutoff count; returns an array for a single row; exposes `Get-BLK` alias.

**`RoomInventory.Tests.ps1` → `Queries\RoomInventory.psm1`** (REQ-008)
- OOO (`statisticsManagersReport`) 7-day chunking + ISO filters; RMN (`inventoryRooms`) is a **single static request with no `businessDate` filter**.
- OOO mapping (`OOO_ROOMS`/`OS_ROOMS`/`ROOM_CLASS`/`PHYSICAL_BEDS`, `BUSINESS_DATE` as `YYYYMMDD`); RMN mapping (`ROOM`/`ROOM_CATEGORY_LABEL`/`ROOM_CLASS`/`ROOM_STATUS`); blank `RESORT` backfilled; missing counts → `$null`.
- `AVAIL_ROOM` = physical − OOO − OS (API value not overwritten; null-guarded); a range crossing today is chunked uniformly (past + future in one call); `Get-RoomInventory` returns a hashtable with `RMN` and `OOO` arrays (arrays even for a single row).

**`MasterData.Tests.ps1` → `Queries\MasterData.psm1`** (REQ-009)
- Routes each `-Type` to its SA operation; ExportMappings dimensions share the SA but use distinct `mappingType` discriminators (`MARKET`/`SOURCE`/`CHANNEL`).
- SourceCodes and Channels map to separate targets and never cross-contaminate; full refresh omits `changedSince`, delta adds an ISO `changedSince._gte` filter.
- Key-field mappings for all 7 types (TrxCodes, RoomTypeLabels, RateCodes, MarketCodes, SourceCodes, Channels, Hotels), incl. `activeYn=N` → `IS_ACTIVE=0`/`FLAG='Y'`.
- **SourceCodes empty → throws** (required); **Channels empty → benign skip** (optional). Change detection logs NEW / DESCRIPTION-changed / DEACTIVATED via `-CurrentRecordsProvider`.

**`Protect-HotelsConfig.Tests.ps1` → `Tools\Protect-HotelsConfig.ps1`** (REQ-002, REQ-016)
- Encrypts `clientId`/`clientSecret`/`apiKey` while copying all other fields (incl. nested `emailAlerts`) verbatim; preserves top-level siblings and hotels-array count.
- Round-trip verify returns ciphertext on match; **aborts (throws, no output) on round-trip mismatch**.
- Real DPAPI (Windows) round-trips `Protect-DpapiValue`/`Unprotect-DpapiValue` and produces `DPAPI:CU:` / `DPAPI:LM:` tags.
- Plaintext secrets never appear in the verbose stream; `Protect-SmtpSettings` encrypts `smtp.username`/`password` only; `Test-DpapiEncrypted` recognises tagged/legacy forms and rejects plaintext (idempotency).

**`RunOperaRALoader.Tests.ps1` → `Run-OperaRALoader.ps1`** (REQ-001, REQ-013, REQ-015)
- Parameter surface: `-Mode` `ValidateSet` (All/Full/Delta/OTB/MasterData); all documented params declared; throws when `StartDate` > `EndDate`.
- `Resolve-Config` fail-fast on missing `connectionString`, missing hotel field (`clientSecret`), or empty hotels array; returns Settings+Hotels for a valid config.
- `Select-Hotels` excludes disabled hotels, filters case-insensitively by `-HotelCode` and by `-ChainCode`, returns empty on no match.
- `Get-RunExitCode`: 0 all-success, 1 partial, 2 total, 0 when none processed. `Get-ModeQuerySet` matches the mode matrix (MasterData→DIM only; OTB→OTB/BLK/RMN; Delta→no DIM; Full/All→DIM+actuals+snapshots).
- `-DryRun` runs queries but calls **zero writers**; without it, writers are called. `Write-SummaryTable` renders Hotel/Status/Rows/Duration; end-to-end `Invoke-Loader` isolates a per-hotel failure (partial, exit 1) and stops after the first failure under `-FailFast` (exit 2). `Test-HotelCredentials` reports failure without leaking the encrypted value.

### Test Levels
- **Unit** — pure functions (date math, flag computation, mapping, key construction, exit-code logic) with no I/O.
- **Module behaviour (seam-injected)** — a module driven through its scriptblock seams with canned GraphQL/DB responses, asserting the field → column contract, request filters, and side effects (logging, WARN counts) with zero network/SQL.
- **End-to-end (manual / gated)** — a single hotel against a non-production OHIP environment, run outside CI, to validate live schema field names via GraphQL introspection (`__type`).

### Running the Suite
```powershell
Invoke-Pester -Path .\Tests -Output Detailed
```
Pester 5.0+ is required (the Logger test notes it is validated on Pester 6.x). The suite runs cross-platform; DPAPI credential tests self-skip on non-Windows hosts.

### Known Coverage Gaps
- **REQ-016 email delivery** — `Send-AlertEmail` (severity gating, per-hotel recipients, log attachment, delivery-failure-never-aborts) has no automated test yet; only `Complete-Batch`'s non-SQL paths are covered in `Logger.Complete-Batch.Tests.ps1`.
- **Live SQL** — `SqlWriter` MERGE/SCD2 behaviour is asserted against a recording fake executor, not a live database; a live-SQL smoke test is skipped when no server is reachable.

### Verification Principles
- Every requirement with observable behaviour (mapping, keys, flags, exit codes, masking) has at least one assertion.
- Field → column mappings are cross-checked against the sample CSVs in `CSVSampleSpec\` where available.
- Live schema field names are confirmed by GraphQL introspection before trusting mappings, since OHIP schema names can vary by release.

---

## Requirements Traceability

Each design element realises one or more requirements from `requirements.md`. When a requirement changes, update the mapped component here and re-verify the associated tests.

| Requirement | Design Section / Component |
|-------------|----------------------------|
| REQ-001 Multi-Hotel Config | Configuration Schema (`hotels.json`), Entry Point Parameters (`-HotelCode`/`-ChainCode`) |
| REQ-002 Secure Credentials | Security Considerations, `Tools\Protect-HotelsConfig.ps1` |
| REQ-003 Authentication | Components and Interfaces → `Auth.psm1`, OHIP API Technical Reference (OAuth) |
| REQ-004 Reservation Stats | `Queries\ReservationStats.psm1`, `ra.RES` schema |
| REQ-005 Financial Tx | `Queries\FinancialTransactions.psm1`, `ra.FIN` schema |
| REQ-006 On-The-Books | `Queries\OnTheBooks.psm1`, `ra.OTB` schema |
| REQ-007 Block Reservations | `Queries\BlockReservations.psm1`, `ra.BLK` schema |
| REQ-008 Room Inventory | `Queries\RoomInventory.psm1`, `ra.RMN` / `ra.OOO` schema |
| REQ-009 Master Data | `Queries\MasterData.psm1`, `ra.DIM_*` schema (SCD2) |
| REQ-010 SQL Storage | Data Models, `SqlWriter.psm1`, `SQL\*.sql` |
| REQ-011 Rate Limiting & Resilience | `ApiClient.psm1`, Error Handling |
| REQ-012 Logging & Monitoring | `Logger.psm1`, `dbo.LoadLog` schema |
| REQ-013 Scheduling & Modes | Entry Point Parameters, Mode Behaviour Matrix |
| REQ-014 Time Zone Handling | `DateHelper.psm1`, output date formatting |
| REQ-015 Fallback & Missing Data | Error Handling (NoData, per-hotel isolation, `-FailFast`) |
| REQ-016 Email Notifications | `Logger.psm1` (`Send-AlertEmail`), Configuration Schema (`emailAlerts`, `smtp`) |
