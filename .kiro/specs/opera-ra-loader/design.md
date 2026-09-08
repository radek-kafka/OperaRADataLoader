# Design: OPERA R&A Data Loader

## Architecture Overview

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
| DIM MC/SC/CH | `ExportMappings`               | `exportMappings`                     | `ra.DIM_*`        |
| Hotels | `ConfigurationResort`                | `configurationResort`                | `ra.Hotels`       |

> GraphQL schemas published at [oracle/hospitality-api-docs](https://github.com/oracle/hospitality-api-docs).
> Verify exact field names via GraphQL introspection (`__type` query) against a live environment.

---

## Module Design

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
mirror to `dbo.LoadLog`. SMTP alert on ERROR.

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

  Send-AlertEmail     -Subject [string] -Body [string]
                      Triggered only when SMTP enabled and Level = ERROR

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
  businessDate        → BUSINESS_DATE
  resvNameId          → RESV_NAME_ID     ← join key → ra.FIN, ra.OTB
  rateCode            → RATE_CODE
  rateCategory        → RATE_CATEGORY
  marketCode          → MARKET_CODE
  sourceCode          → SOURCE_CODE
  channel             → CHANNEL
  truncBeginDate      → TRUNC_BEGIN_DATE
  truncEndDate        → TRUNC_END_DATE
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
  cancellationDate    → CANCELLATION_DATE
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
  businessDate        → BUSINESS_DATE
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
  trxDate             → TRX_DATE           populate TRX_DATE_UTC via Convert-ToUtc
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
  (set by loader)     → SNAPSHOT_DATE     = business date of run
  stayDate            → CONSIDERED_DATE   ← future stay date
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
  truncBeginDate      → TRUNC_BEGIN_DATE
  truncEndDate        → TRUNC_END_DATE
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
  (set by loader)     → SNAPSHOT_DATE     = business date of run
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
  businessDate        → BUSINESS_DATE
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
  Property/Hotels   → ConfigurationResort         (configurationResort)
  ChainConfig       → ConfigurationChain          (configurationChain)

Note: MarketSegments, ReservationSources, Channels are dimensions embedded
      within statistical subject areas. They are extracted as distinct
      values from StatisticsReservationsDaily and cached as master data.
      Alternatively ExportMappings SA can provide code-description pairs.

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
      "blockFutureDays": 180
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
      "blockFutureDays": 180
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
    "logNames": {
      "loader": "OperaRA_Loader",
      "res":    "OperaRA_RES",
      "fin":    "OperaRA_FIN",
      "otb":    "OperaRA_OTB",
      "dim":    "OperaRA_DIM",
      "rmn":    "OperaRA_RMN"
    }
  },
  "smtp": {
    "enabled": false,
    "server": "",
    "port": 587,
    "from": "",
    "to": [],
    "useSsl": true
  }
}
```

---

## SQL Server Schema

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

## Error Handling Strategy
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
