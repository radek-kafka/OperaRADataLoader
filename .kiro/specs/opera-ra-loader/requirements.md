# Requirements Document

**Project:** OPERA R&A Data Loader

## Introduction
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

## Requirements Summary

| ID | Title | Priority |
|--------|-------------------------------------------|----------|
| REQ-001 | Multi-Hotel Configuration | MUST |
| REQ-002 | Secure Credential Storage | MUST |
| REQ-003 | Authentication (OAuth 2.0 — OHIP / OCIM) | MUST |
| REQ-004 | Reservation Statistics (Actuals) | MUST |
| REQ-005 | Financial Transactions (Actuals) | MUST |
| REQ-006 | On-The-Books (OTB) Snapshot | MUST |
| REQ-007 | Block Reservations Snapshot | MUST |
| REQ-008 | Room Inventory | MUST |
| REQ-009 | Master Data Lists | MUST |
| REQ-010 | SQL Server Storage | MUST |
| REQ-011 | API Rate Limiting & Resilience | MUST |
| REQ-012 | Logging & Monitoring | MUST |
| REQ-013 | Scheduling & Execution Modes | MUST |
| REQ-014 | Time Zone Handling | MUST |
| REQ-015 | Fallback & Missing Data Handling | MUST |
| REQ-016 | Severity-Based Email Notifications | MUST |

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
- **SHOULD** send email alert on critical failure (configurable SMTP settings). See **REQ-016** for full severity-based notification behaviour.

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

### REQ-016 – Severity-Based Email Notifications
- **MUST** provide configurable email notifications driven by log severity, so operators can be alerted when a run produces `INFO`, `WARN`, or `ERROR` events.
- **MUST** define email recipients **per hotel** in `Config\hotels.json` (alongside that hotel's API credentials), not globally: each hotel carries an `emailAlerts` block with an `enabled` toggle and per-severity recipient lists (`to[]` / `cc[]` for `INFO`, `WARN`, `ERROR`). Example for one hotel: `WARN` -> that property's ops + integration lead, `ERROR` -> that property's on-call / escalation list.
- **MUST** allow each severity level to be independently enabled or disabled per hotel (e.g. a hotel notifies on `WARN` and `ERROR` only, suppresses `INFO`), and allow a hotel to disable all its alerts via `emailAlerts.enabled = false`.
- **MUST** treat notifications as **end-of-run summaries**: emails are evaluated and sent after a hotel run (and/or the overall batch) completes, not per individual log event, to avoid inbox flooding across many hotels and query types.
- **MUST** trigger an email for a given severity only when at least one log entry at that level occurred during the run; runs with no qualifying entries send no email for that level.
- **MUST** compose the email body as a **structured run summary** including: `BatchId`, hotel code(s), chain code(s), execution `Mode`, business/date range, per query type (RES, FIN, OTB, DIM, RMN) row counts and status, run duration, and a count of log entries per level (`INFO` / `WARN` / `ERROR`).
- **MUST** include the matching log entries **inline in the email body**, filtered to the triggering severity level (e.g. an `ERROR` notification lists the `ERROR` entries).
- **MUST** attach the **full daily log file** for the run to the notification email so recipients have complete context beyond the filtered inline entries.
- **MUST** use a single shared SMTP transport defined in `Config\settings.json` (`smtpServer`, `port`, `useSsl`, `from`, and credential handling) for delivery, while the recipient distribution lists are resolved per hotel from `Config\hotels.json` `emailAlerts`. When a hotel omits recipients for a severity, no email is sent to that hotel for that level.
- **MUST** never embed SMTP credentials in plain text; the shared SMTP `username` / `password` in `settings.json` **MUST** be DPAPI-encrypted following the same secure handling rules as REQ-002 (encrypted store / environment variable fallback), produced by `Protect-HotelsConfig.ps1`.
- **MUST** mask sensitive values (credentials, tokens, secrets) in any log content that is emailed, consistent with REQ-002 and REQ-012.
- **MUST** ensure email delivery failure does **not** abort or fail the data load: notification errors are logged as `WARN` and the run continues / preserves its own exit code.
- **SHOULD** support a global toggle (`smtp.enabled = false`) that disables all email notifications regardless of per-severity settings, for environments where email is unavailable (e.g. CI/CD).
- **SHOULD** de-duplicate or cap the number of inline entries per email (configurable max, with a "N more — see attached log" note) to keep messages readable when a run generates many entries.
- **SHOULD** respect the `-DryRun` switch: notifications are still evaluated but clearly marked as a dry-run in the subject/body.

---

## Glossary

| Term | Definition |
|------|------------|
| **Business Date** | The hotel's operational date as defined by the night-audit cutover, not wall-clock midnight. All actuals (`ReservationStats`, `FinancialTx`) are keyed to this date. |
| **Snapshot Date** | The business date on which a forward-looking snapshot (OTB, blocks, inventory) was pulled — i.e. "as of" date. |
| **Considered Date** | The future stay date that a snapshot row describes (e.g. the `stayDate` an OTB row forecasts, or a block's grid date). |
| **Late Posting** | A financial transaction whose `trxDate` is later than the `businessDate` it posts to (`trxDate > businessDate`). |
| **OTB** | On-The-Books — future occupancy/revenue committed as of a snapshot date. |
| **ADR** | Average Daily Rate — room revenue divided by rooms sold. |
| **RevPAR** | Revenue Per Available Room — room revenue divided by available rooms. |
| **Pickup** | Rooms actually reserved against a group block (`pickedUpRooms`) versus rooms contracted (`blockedRooms`). |
| **Cutoff Date** | The date after which unsold block rooms are released back to general inventory. |
| **OOO / OOS** | Out Of Order / Out Of Service — rooms removed from sellable inventory. |
| **Subject Area** | A named GraphQL operation exposed by the OHIP R&A Data API (e.g. `StatisticsReservationsDaily`). |
| **SCD Type 2** | Slowly Changing Dimension history: a master-data change inserts a new version row with `ValidFrom` / `ValidTo` rather than overwriting. |
| **OHIP** | Oracle Hospitality Integration Platform. |
| **OCIM** | Oracle Cloud Identity Management — the identity platform issuing OAuth tokens. |
| **R&A** | Reporting & Analytics — the OPERA Cloud data platform the GraphQL APIs expose. |
| **DPAPI** | Windows Data Protection API, used to encrypt credentials at rest. |
| **`resvNameId`** | Reservation ID — the join key between reservation statistics and financial transactions. |
| **Delta / Full Refresh** | Delta = changed-since extraction; Full = complete reload of a data set. |

## Assumptions & Constraints

- **A-01** The target hotels are provisioned on **R&A Platform v24.4+** and **OHIP Platform v24.3+**, and are subscribed to the R&A Data APIs / GraphQL Plan in the OHIP Developer Portal.
- **A-02** The R&A Data API is **GraphQL over a single HTTPS POST endpoint** (`<gatewayUrl>/rna/v1/graphql/`); it does **not** provide REST resources or cursor/offset pagination.
- **A-03** Every query **requires** mandatory filters (`resort` `_in` + a date range); open-ended queries are rejected by the platform.
- **A-04** The solution runs on **PowerShell 7.x** on Windows, with DPAPI available for credential encryption under the executing service account.
- **A-05** A reachable **Microsoft SQL Server** instance and database are available, and the executing account has DDL rights (tables are created idempotently).
- **A-06** OAuth uses the `client_credentials` grant with the fixed scope `urn:opc:hgbu:ws:_myscopes_`.
- **A-07** Each hotel's local time zone is configured; source datetimes may be local and must be normalised to UTC on store.
- **A-08** Runs are scheduled (Task Scheduler / SQL Agent) and default to the previous business date when no range is supplied.
- **A-09** SMTP relay details are shared across hotels via `Config\settings.json`; recipient lists are per-hotel in `Config\hotels.json`.

## Out of Scope

- **OOS-01** Real-time / streaming ingestion — the loader is batch and snapshot oriented.
- **OOS-02** Write-back to OPERA Cloud; the solution is read-only against OHIP.
- **OOS-03** Reporting, dashboards, or BI visualisation on top of the SQL Server tables.
- **OOS-04** Non-R&A OHIP domains (e.g. transactional Reservation/Profile REST APIs) beyond what is needed for the listed Subject Areas.
- **OOS-05** Automated provisioning of OHIP credentials, app keys, or Developer Portal subscriptions.
- **OOS-06** Data-quality remediation beyond flagging and logging (e.g. correcting source records in OPERA).

## Traceability

Requirements map forward to `design.md` (components) and `tasks.md` (implementation tasks). Each requirement ID (`REQ-001`…`REQ-016`) is the stable reference used across all three spec documents; tasks cite the REQ IDs they satisfy. When a requirement changes, update the corresponding design component and re-verify the tasks that reference it.

| Requirement | Primary Module(s) | Notes |
|-------------|-------------------|-------|
| REQ-001, REQ-002 | `Config`, `Tools\Protect-HotelsConfig.ps1` | Per-hotel config + credential encryption |
| REQ-003 | `Modules\Auth.psm1` | OAuth token acquisition, cache, refresh |
| REQ-004 | `Modules\Queries\ReservationStats.psm1` | Actual reservation statistics |
| REQ-005 | `Modules\Queries\FinancialTransactions.psm1` | Actual financial transactions |
| REQ-006 | `Modules\Queries\OnTheBooks.psm1` | OTB snapshot |
| REQ-007 | `Modules\Queries\BlockReservations.psm1` | Block snapshot |
| REQ-008 | `Modules\Queries\RoomInventory.psm1` | Room inventory |
| REQ-009 | `Modules\Queries\MasterData.psm1` | Master data lists + SCD2 |
| REQ-010 | `Modules\SqlWriter.psm1`, `SQL\*.sql` | Storage, MERGE upserts, DDL |
| REQ-011 | `Modules\ApiClient.psm1` | Rate limiting, retry, chunking |
| REQ-012, REQ-016 | `Modules\Logger.psm1` | Logging + severity-based email |
| REQ-013 | `Run-OperaRALoader.ps1` | Modes, parameters, exit codes |
| REQ-014 | `Modules\DateHelper.psm1` | Business date + UTC handling |
| REQ-015 | `Run-OperaRALoader.ps1`, `Modules\Logger.psm1` | NoData status, FailFast |
