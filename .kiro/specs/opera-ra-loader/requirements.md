# Requirements: OPERA R&A Data Loader

## Overview
A production-ready PowerShell 7 solution that connects to the Oracle Hospitality Integration Platform (OHIP) R&A Data APIs, executes **GraphQL queries** against R&A Subject Areas for reservation statistics, financial transactions, on-the-books forecasts, block reservations, room inventory, and master data, then stores results in Microsoft SQL Server tables. The solution supports multiple hotels across multiple hotel chains with secure, configurable credentials per property.

> **API Technology:** The OHIP R&A Data APIs are **GraphQL** APIs (not REST), accessed via a single HTTP POST endpoint at `<gatewayUrl>/rna/v1/graphql/`. Each Subject Area is a separate named GraphQL operation. Schemas are published at [oracle/hospitality-api-docs](https://github.com/oracle/hospitality-api-docs).
>
> **Prerequisites:** R&A Platform v24.4+ (OAS version), OHIP Platform v24.3+, OCIM as Identity Platform, hotel subscribed to the R&A Data APIs / GraphQL Plan in the OHIP Developer Portal.

### Data Domain Map
```
BusinessDate + ReservationId
        │
        ├─── ra.ReservationStats   (actual: arrivals / departures / in-house)
        │         linked via BusinessDate + ReservationId
        └─── ra.FinancialTx        (actual: charges / payments / adjustments)

SnapshotDate + ConsideredDate
        │
        ├─── ra.OnTheBooks         (daily OTB snapshot: future occupancy forecast)
        └─── ra.BlockReservations  (daily block snapshot: group blocks + pickup)

ra.RoomInventory                   (daily snapshot: physical rooms available by RoomTypeLabel)

Master Data (full/delta refresh)
        ├─── ra.MarketSegments
        ├─── ra.RoomTypeLabels
        ├─── ra.RateCodes
        ├─── ra.ReservationSources
        ├─── ra.Channels
        ├─── ra.TrxCodes           (Name, Group, Type, RevenueYN flags)
        └─── ra.Hotels
```

---

## Requirements

### REQ-001 – Multi-Hotel Configuration
- **MUST** support configuration for multiple hotels in a single run or selective execution.
- **MUST** store per-hotel connection parameters: `ClientId`, `ClientSecret`, `ApiKey`, `GatewayUrl`, `EnterpriseId`, `HotelCode`, `ChainCode`.
- **MUST** allow each hotel to belong to a different hotel chain (different `ChainCode` and potentially different `GatewayUrl` / OHIP environment).
- **MUST** support enabling/disabling individual hotels without removing their configuration.
- **MUST** allow filtering execution by hotel code or chain code at runtime via parameters.

### REQ-002 – Secure Credential Storage
- **MUST** never store credentials in plain text within scripts.
- **MUST** support credentials stored in an encrypted JSON config file using `SecureString` / `DPAPI` or SQL Server credential table with column-level encryption.
- **MUST** support reading credentials from environment variables as a fallback for CI/CD pipelines.
- **MUST** mask sensitive values in all log output.

### REQ-003 – Authentication (OAuth 2.0 — OHIP / OCIM)
- **MUST** obtain an OAuth 2.0 bearer token per hotel using the `client_credentials` grant against the OHIP Gateway OAuth endpoint.
- **MUST** use the fixed scope `urn:opc:hgbu:ws:_myscopes_` on every token request.
- **MUST** cache the token in-memory and reuse it until expiry (with a configurable safety margin, default 60 seconds before expiry).
- **MUST** automatically refresh the token on expiry without manual intervention.
- **MUST** pass the following headers on every GraphQL request:
  - `Authorization: Bearer <token>`
  - `x-app-key: <ApiKey>` (application key from OHIP Developer Portal)
  - `x-request-id: <new GUID per request>` (for end-to-end tracing)
  - `Content-Type: application/json`
  - `Accept: multipart/mixed; deferSpec=20220824, application/json`
- **MUST** handle HTTP 401 by clearing the token cache, re-authenticating once, and retrying before failing.
- **SHOULD** pass `x-hotelid` header where appropriate for consistency with other OHIP APIs.

### REQ-004 – Reservation Statistics (Actuals)
- **MUST** query the `StatisticsReservationsDaily` OHIP Subject Area for actual reservation statistics including:
  - Arrivals, Departures, In-House counts by `BusinessDate`.
  - Room nights, ADR (Average Daily Rate), RevPAR.
  - Breakdown by `MarketCode`, `RoomCategory` (RoomTypeLabel), `SourceCode`, `ChannelCode`.
- **MUST** carry `resvNameId` (Reservation ID) on every statistics row to enable join with financial transactions.
- **MUST** apply mandatory GraphQL filters: `resort` (`_in`) + `businessDate` range — never open-ended.
- **MUST** support a configurable date range (start date / end date).
- **MUST** default to the previous business date when no range is provided.
- **MUST** handle business date logic (hotel night audit cutover, not wall-clock midnight).
- **MUST** request only needed fields in the GraphQL query (no over-fetching).

### REQ-005 – Financial Transactions (Actuals)
- **MUST** query the `FinancialTransactionDetails` OHIP Subject Area (or `FinancialTransactionDetailsExtended` for unified reservation context) for financial transactions including:
  - Folio charges, payments, adjustments, package offsets.
  - `trxCode` (transaction code) linkable to `ra.TrxCodes` master data.
  - Net and gross amounts, currency, market code, rate code.
- **MUST** carry `resvNameId` (Reservation ID) and `businessDate` on every transaction row.
- **MUST** support joining to `ra.ReservationStats` via `BusinessDate` + `ReservationId` (`resvNameId`).
- **MUST** apply mandatory GraphQL filters: `resort` (`_in`) + `businessDate` range.
- **MUST** support a configurable date range.
- **MUST** flag and log late postings (`trxDate > businessDate`).
- **MUST** store both local and UTC posting datetimes.
- **MUST** allow re-extraction for a specific date range to handle corrections.

### REQ-006 – On-The-Books (OTB) Snapshot
- **MUST** query the `StatisticsForecastSummary` OHIP Subject Area for the OTB daily snapshot representing future occupancy as of a given snapshot date.
- **MUST** store both `SnapshotDate` (business date of the run = when data was pulled) and `ConsideredDate` (the future `stayDate` the row describes).
- **MUST** include per-`ConsideredDate` metrics: rooms on books, tentative/definite split, ADR on books, revenue on books.
- **MUST** include breakdown by `MarketCode`, `RoomCategory`, `SourceCode`, `ChannelCode`.
- **MUST** support configurable future horizon per hotel (default 365 days).
- **MUST** apply mandatory GraphQL filters: `resort` (`_in`) + `stayDate` range.
- **MUST** use upsert keyed on `HotelCode + SnapshotDate + ConsideredDate + MarketSegment + RoomTypeLabel` to allow daily snapshot accumulation without overwriting prior snapshots.
- **SHOULD** also support `StatisticsReservationPace` Subject Area for historical pace comparison (rooms/revenue on books as of past snapshot dates).

### REQ-007 – Block Reservations Snapshot
- **MUST** query the `BookingsBlock` OHIP Subject Area for group block reservations as of the snapshot date.
- **MUST** store `SnapshotDate` and `ConsideredDate` (the block's stay/grid date — `blockIdDate` field).
- **MUST** include: `BlockCode`, `BlockName`, `RoomCategory` (RoomTypeLabel), `MarketCode`, rooms contracted (`blockedRooms`), rooms picked up (`pickedUpRooms`), rooms remaining (computed), `CutoffDate`.
- **MUST** flag blocks past cutoff date as `IsPastCutoff = 1` (where `cutoffDate < SnapshotDate`).
- **MUST** apply mandatory GraphQL filters: `resort` (`_in`) + stay date range.
- **MUST** use upsert keyed on `HotelCode + SnapshotDate + BlockCode + ConsideredDate + RoomTypeLabel`.
- **SHOULD** also support `BookingsBlockProductionChanges` Subject Area for delta change tracking on blocks.

### REQ-008 – Room Inventory
- **MUST** query the `InventoryRoomsManagement` OHIP Subject Area for daily room maintenance and OOO/OOS assignments by date and room category.
- **MUST** query the `InventoryRooms` Subject Area for static room configuration (physical room count per `RoomCategory`).
- **MUST** store: `HotelCode`, `InventoryDate`, `RoomTypeLabel`, `PhysicalRooms`, `OutOfOrder`, `OutOfService`, `AvailableRooms` (computed).
- **MUST** apply mandatory GraphQL filters: `resort` (`_in`) + date range.
- **MUST** support both actuals (past dates) and forecast availability (future dates).
- **MUST** use upsert keyed on `HotelCode + InventoryDate + RoomTypeLabel`.

### REQ-009 – Master Data Lists
- **MUST** query OHIP R&A Subject Areas for master data, mapping to the following SQL tables:

  | Master Data Type    | OHIP Subject Area             | Key Fields                                                                 |
  |---------------------|-------------------------------|---------------------------------------------------------------------------|
  | `TrxCodes`          | `FinancialTransactionCodes`   | `trxCode`, `description`, `trxGroup`, `trxSubgroup`, `revenueYn`, `roomRevenueYn`, `packageYn`, `activeYn` |
  | `RoomTypeLabels`    | `InventoryRooms`              | `roomCategory`, `roomCategoryDesc`, `roomClass`, `physicalRooms`, `activeYn` |
  | `RateCodes`         | `RatesCodeDetails`            | `rateCode`, `rateDescription`, `rateCategory`, `activeYn`                 |
  | `RateCategories`    | `RatesCategories`             | `rateCategory`, `description`, `beginDate`, `endDate`                     |
  | `Property/Hotels`   | `ConfigurationResort`         | property details, currency, address, time zone                            |
  | `ChainConfig`       | `ConfigurationChain`          | chain-level configuration attributes                                      |

- **MUST** extract `MarketSegments`, `ReservationSources`, and `Channels` as distinct dimension values from `StatisticsReservationsDaily` (no dedicated Subject Area for these dimensions exists); alternatively use `ExportMappings` Subject Area for code-description mapping.
- **MUST** support full refresh and delta (changed-since) modes for all master data types.
- **MUST** detect and log changes between runs (codes added, descriptions changed, deactivated).
- **MUST** maintain SCD Type 2 history for all master data in SQL Server.
- **MUST** enforce referential consistency: transactional tables reference master data codes.

### REQ-010 – SQL Server Storage
- **MUST** store all data in a configurable SQL Server instance and database.
- **MUST** use a consistent schema design with staging tables and target tables.
- **MUST** perform upsert (MERGE) operations to avoid duplicate data on re-runs.
- **MUST** include audit columns on all tables: `LoadedAt`, `LoadedBy`, `SourceHotelCode`, `ChainCode`, `BatchId`.
- **MUST** create tables automatically if they do not exist (idempotent DDL).
- **MUST** log each extraction run to a `dbo.LoadLog` table with status, row counts, and error details.
- **MUST** maintain master data history: when a `TrxCode`, `RatCode`, `MarketSegment`, etc. changes, insert a new version row with `ValidFrom` / `ValidTo` date range (SCD Type 2).

### REQ-011 – API Rate Limiting & Resilience
- **MUST** respect OHIP API rate limits with configurable throttling (`RequestDelayMs`, default 500 ms between GraphQL calls).
- **MUST** implement retry logic with exponential backoff for transient HTTP errors (429, 500, 502, 503, 504).
- **MUST** be configurable: max retries (default 3), base delay (default 2 s), max delay (default 30 s).
- **MUST** control data volume through date-range chunking (default 7-day chunks for transactional data) — the R&A Data API does not use cursor/offset pagination.
- **MUST** always apply mandatory GraphQL filters (`resort` + date range) to comply with OHIP API constraints and avoid server backpressure.
- **MUST** inspect the GraphQL `errors` array in every response: log warnings for partial errors, treat null `data` as a full failure.
- **MUST** issue separate GraphQL requests when attributes from multiple child folders are needed in the same subject area, to avoid cartesian join errors.

### REQ-012 – Logging & Monitoring
- **MUST** write structured logs to a log file (daily rotation) and optionally to SQL Server `dbo.LoadLog`.
- **MUST** include log levels: `INFO`, `WARN`, `ERROR`, `DEBUG`.
- **MUST** log: hotel code, chain code, query type, date range, rows fetched, duration, status.
- **MUST** support `-Verbose` and `-Debug` PowerShell switches.
- **SHOULD** send email alert on critical failure (configurable SMTP settings).

### REQ-013 – Scheduling & Execution Modes
- **MUST** support a `-Mode` parameter: `Full`, `Delta`, `OTB`, `MasterData`, `All`.
- **MUST** be executable from Windows Task Scheduler or SQL Agent job.
- **MUST** support `-HotelCode` and `-ChainCode` parameters to restrict execution to a subset.
- **MUST** support `-BusinessDate` parameter to override the default date logic.
- **MUST** support `-DryRun` switch that fetches data but does not write to SQL Server.
- **MUST** produce a non-zero exit code on failure for scheduler integration.

### REQ-014 – Time Zone Handling
- **MUST** store and process business dates in the hotel's configured local time zone.
- **MUST** convert all datetime values to UTC before storing in SQL Server (with original local time preserved).
- **MUST** support per-hotel time zone configuration.

### REQ-015 – Fallback & Missing Data Handling
- **MUST** log a warning when the API returns no data for an expected date/hotel and continue processing remaining hotels.
- **MUST** record a `NoData` status in `dbo.LoadLog` (not an error) when API returns empty results.
- **MUST** support a `-FailFast` switch to stop all processing on first error (default: continue and log).
