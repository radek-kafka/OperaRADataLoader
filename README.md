# OPERA R&A Data Loader

A production-grade PowerShell 7 solution that extracts Oracle Hospitality **OPERA Cloud
Reporting & Analytics (R&A) Data** from the **Oracle Hospitality Integration Platform
(OHIP)** — via its **GraphQL** R&A Subject Areas — and lands it in **Microsoft SQL Server**.
It supports many hotels across many chains, with per-property encrypted credentials, business-date
aware extraction, SCD Type 2 dimensions, and daily snapshot accumulation for On-The-Books and Blocks.

> The OHIP R&A Data APIs are **GraphQL** (single HTTP `POST` to `<gatewayUrl>/rna/v1/graphql/`), not REST.
> Each Subject Area is a named GraphQL operation. Schemas are published at
> [oracle/hospitality-api-docs](https://github.com/oracle/hospitality-api-docs).

---

## 1. Prerequisites

| Requirement | Detail |
|-------------|--------|
| **PowerShell 7.x** | The orchestrator and all modules declare `#requires -Version 7.0`. Windows PowerShell 5.1 is **not** supported. |
| **Windows host** | Credential protection uses **DPAPI** (`ConvertTo-SecureString` without `-Key`), which is Windows-only. `Tools\Protect-HotelsConfig.ps1` refuses to run on non-Windows. |
| **Microsoft SQL Server** | A reachable SQL Server instance and a database (default `OperaRA`). The account running the loader needs DDL rights on first run (idempotent `CREATE`), then DML (`INSERT`/`UPDATE`/`MERGE`) plus `SqlBulkCopy` into staging. The `Microsoft.Data.SqlClient` provider is used. |
| **Network access to OPERA Cloud R&A (OHIP)** | Outbound HTTPS to each hotel's OHIP Gateway (`gatewayUrl`) for both the OAuth token endpoint (`/oauth/token`) and the GraphQL endpoint (`/rna/v1/graphql/`). |
| **OHIP subscription** | R&A Platform **v24.4+** (OAS), OHIP Platform **v24.3+**, **OCIM** as identity platform, and each hotel subscribed to the R&A Data APIs / GraphQL Plan in the OHIP Developer Portal. Per hotel you need a `clientId`, `clientSecret`, and `apiKey` (`x-app-key`). |
| **(Optional) SMTP relay** | For severity-based alert emails. Shared transport is configured in `Config\settings.json`; recipients are per hotel in `Config\hotels.json`. |
| **(Optional) Pester 5** | To run the unit test suite under `Tests\`. |

---

## 2. Installation

### 2.1 Clone

```powershell
git clone <your-repo-url> OperaRADataLoader
```

Everything runs in place from the repo root; there is no build step. `Logs\` is created
automatically at runtime.

### 2.2 Prepare the plain-text credential input

Copy the sample and fill in real values. `hotels.input.json` and `hotels.json` are **git-ignored**
and must never be committed.

```powershell
Copy-Item .\Config\hotels.sample.json .\Config\hotels.input.json
```

Edit `Config\hotels.input.json` and replace every `REPLACE_ME` placeholder. Per hotel, the required
fields are: `hotelCode`, `chainCode`, `gatewayUrl`, `clientId`, `clientSecret`, `apiKey`, and
`timeZoneId`. Also set `nightAuditHour` / `nightAuditMinute`, the `otbFutureDays` / `blockFutureDays`
horizons, and the per-hotel `emailAlerts` block (per-severity `to[]` / `cc[]` for `error` / `warn` /
`info`). Only `clientId`, `clientSecret`, and `apiKey` are encrypted; all other fields pass through
verbatim.

If you use email alerts, also put the real shared SMTP `username` / `password` into
`Config\settings.json` (`smtp` block) before the next step so they get encrypted in place.

### 2.3 Encrypt credentials — run `Protect-HotelsConfig.ps1` AS the service account

DPAPI ciphertext produced here can **only** be decrypted by the **same Windows account on the same
machine**. Therefore run this on the host the loader will run on, logged on as (or `runas`) the
scheduled service account.

```powershell
# On the loader's host, as the loader's service account:
pwsh -File .\Tools\Protect-HotelsConfig.ps1
```

This reads `Config\hotels.input.json`, encrypts `clientId` / `clientSecret` / `apiKey` per hotel,
**round-trip-verifies each value** (aborts without writing if any value fails to decrypt back to the
original), and writes the encrypted `Config\hotels.json`. Unless you pass `-SkipSmtp`, it also
encrypts `smtp.username` / `smtp.password` in `Config\settings.json` in place. Re-runs are
idempotent (already-encrypted values are detected and left unchanged). Useful switches:

- `-WhatIf` — preview without writing.
- `-SkipSmtp` — only process hotels.
- `-Force` — overwrite an existing `hotels.json` without prompting.
- `-InputPath` / `-OutputPath` / `-SettingsPath` — override the default paths.

After a successful run, delete `Config\hotels.input.json` if you no longer need to re-encrypt.

### 2.4 Configure `settings.json`

Edit `Config\settings.json` for the environment. Key sections:

| Section | Field(s) | Purpose |
|---------|----------|---------|
| `sqlServer` | `connectionString` (required), `server`, `database`, `commandTimeout`, `encrypt`, `trustServerCertificate` | Target SQL Server. The loader reads `connectionString` directly. |
| `api` | `requestDelayMs` (500), `maxRetries` (3), `retryBaseDelaySeconds` (2), `retryMaxDelaySeconds` (30), `retryableStatusCodes` (429/500/502/503/504), `httpTimeoutSeconds`, `tokenSafetyMarginSeconds` (60), `graphqlEndpointPath`, `oauthScope` | Throttle, retry/backoff, token refresh margin, and OHIP endpoint/scope. |
| `extraction` | `otbFutureDays` (365), `blockFutureDays` (365), `transactionalChunkDays` (7), `masterDataChunkDays` | Snapshot horizons and date-chunk sizes (per-hotel `otbFutureDays` / `blockFutureDays` in `hotels.json` override these). |
| `logging` | `logDirectory` (`Logs`), `logLevel` (`INFO`), `sqlLogging` (`true`), `logName` (`OperaRA_Loader`) | One shared daily log file `{yyyyMMdd}_{logName}.log`, optional mirror to `dbo.LoadLog`. |
| `smtp` | `enabled` (`false`), `smtpServer`, `port`, `useSsl`, `from`, `authRequired`, `username`, `password` (DPAPI), `maxInlineEntriesPerEmail` | Shared alert transport. Set `enabled: false` to disable all email regardless of per-hotel settings. |

### 2.5 Create the schema and run the first Full load

`-Mode Full` runs the idempotent DDL (`SQL\001`–`005`) via `Initialize-Database` before extracting.
Start with a dry run to validate connectivity and credentials without writing:

```powershell
# Validate end-to-end without touching SQL:
pwsh -File .\Run-OperaRALoader.ps1 -Mode Full -DryRun -Verbose

# First real Full load (creates schema, loads master data + actuals + snapshots):
pwsh -File .\Run-OperaRALoader.ps1 -Mode Full
```

You can also apply the DDL manually (e.g. via `sqlcmd`) by running `SQL\001_CreateSchema.sql`
through `SQL\005_CreateIndexes.sql` in order; all scripts are guarded with `IF OBJECT_ID(...) IS NULL`
/ `IF NOT EXISTS` and are safe to re-run.

---

## 3. Scheduling

Run the loader as the **same service account** that ran `Protect-HotelsConfig.ps1` on the **same host**
— otherwise the DPAPI-encrypted credentials will not decrypt.

### 3.1 Windows Task Scheduler (XML template)

A daily **Delta** run scheduled after the latest hotel night audit. Import with
`schtasks /Create /TN "OperaRA Delta" /XML .\OperaRA-Delta.xml`. Replace the account, working
directory, and `pwsh.exe` path as needed.

```xml
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>OPERA R&amp;A Data Loader - daily Delta extract</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-01-01T04:30:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <!-- Same service account that ran Protect-HotelsConfig.ps1 on this host -->
      <UserId>DOMAIN\svc-operara</UserId>
      <LogonType>Password</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>C:\Program Files\PowerShell\7\pwsh.exe</Command>
      <Arguments>-NoProfile -NonInteractive -File "C:\AITools\kiro\OperaRADataLoader\Run-OperaRALoader.ps1" -Mode Delta</Arguments>
      <WorkingDirectory>C:\AITools\kiro\OperaRADataLoader</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
```

Schedule the run **after** the night audit of your latest-cutover property so the previous business
date is fully closed. The loader resolves each hotel's business date from its own `nightAuditHour` /
`timeZoneId`, so a single daily trigger works across time zones.

### 3.2 SQL Server Agent job (CmdExec step)

Alternatively, drive it from SQL Agent. The step below uses a **CmdExec** subsystem calling `pwsh`.
The SQL Agent service account (or a proxy) must be the same identity that ran
`Protect-HotelsConfig.ps1` on this host.

```sql
USE msdb;
GO
EXEC dbo.sp_add_job
    @job_name = N'OperaRA - Daily Delta';
GO
EXEC dbo.sp_add_jobstep
    @job_name   = N'OperaRA - Daily Delta',
    @step_name  = N'Run Delta extract',
    @subsystem  = N'CMDEXEC',
    @command    = N'"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -NonInteractive -File "C:\AITools\kiro\OperaRADataLoader\Run-OperaRALoader.ps1" -Mode Delta',
    @on_success_action = 1,   -- quit reporting success
    @on_fail_action    = 2;   -- quit reporting failure (non-zero exit => step fails)
GO
EXEC dbo.sp_add_jobschedule
    @job_name       = N'OperaRA - Daily Delta',
    @name           = N'Daily 04:30',
    @freq_type      = 4,          -- daily
    @freq_interval  = 1,
    @active_start_time = 043000;  -- 04:30:00
GO
EXEC dbo.sp_add_jobserver @job_name = N'OperaRA - Daily Delta';
GO
```

A **CmdExec** step treats any non-zero process exit code as a failed step, which maps directly to
the loader's exit codes (see [§8](#8-exit-codes--monitoring)). Run SQL Agent (or the proxy) under the
service account that owns the DPAPI credentials.

---

## 4. Parameter reference — `Run-OperaRALoader.ps1`

### 4.1 Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Mode` | `string` (set: `All`, `Full`, `Delta`, `OTB`, `MasterData`) | `Delta` | Selects which subject areas run (see the Mode matrix below). `Full` also forces `Initialize-Database`. |
| `-HotelCode` | `string[]` | *(all enabled)* | Restrict the run to one or more hotel codes (case-insensitive). |
| `-ChainCode` | `string[]` | *(all enabled)* | Restrict the run to one or more chain codes (case-insensitive). |
| `-BusinessDate` | `datetime?` | per-hotel previous business date | Override the actuals business date; also used as the OTB/BLK snapshot date. |
| `-StartDate` | `datetime?` | `BusinessDate` | Explicit inclusive start for actuals (RES / FIN / room-inventory range). |
| `-EndDate` | `datetime?` | `BusinessDate` | Explicit inclusive end for actuals. Must be `>= StartDate`. |
| `-DryRun` | `switch` | off | Fetch data but skip every SQL write. Log lines are prefixed `[DRYRUN]`. |
| `-FailFast` | `switch` | off | Stop the whole run on the first hotel error (default: log the error and continue). |
| `-ConfigPath` | `string` | repo `Config\` | Override the config directory (must contain `settings.json` and `hotels.json`). |

Common switches `-Verbose` and `-Debug` are honoured (map to `$VerbosePreference` / `$DebugPreference`).

### 4.2 Mode behaviour matrix

Modes map to an ordered query set by `Get-ModeQuerySet`. Query codes: **DIM** (master data),
**RES** (reservation stats), **FIN** (financial tx), **OTB** (on-the-books), **BLK** (blocks),
**RMN** (room inventory — physical rooms + OOO/OOS).

| `-Mode` | DIM | RES | FIN | OTB | BLK | RMN | Notes |
|---------|:---:|:---:|:---:|:---:|:---:|:---:|-------|
| `Delta` | | ✅ | ✅ | ✅ | ✅ | ✅ | Default daily run — actuals + snapshots, no master data. |
| `OTB` | | | | ✅ | ✅ | ✅ | Forward-looking snapshots + inventory only. |
| `MasterData` | ✅ | | | | | | Dimension refresh only. |
| `Full` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Everything; also runs the idempotent DDL first. |
| `All` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Everything; does **not** force `Initialize-Database`. |

Within a run the per-hotel order is DIM → RES → FIN → OTB → BLK → RMN. In the DIM step, the master
lists load in order `TrxCodes`, `RoomTypeLabels`, `RateCodes`, `MarketCodes`, `SourceCodes`,
`Channels`, `Hotels`. `SourceCodes` is **required** (a failure aborts the hotel); `Channels` is
**optional** (a failure is logged `WARN` and skipped).

### 4.3 Examples

```powershell
# Default daily delta for all enabled hotels
pwsh -File .\Run-OperaRALoader.ps1 -Mode Delta

# One hotel, full load, no writes, verbose
pwsh -File .\Run-OperaRALoader.ps1 -Mode Full -HotelCode HOTEL1 -DryRun -Verbose

# One chain, OTB snapshot for a specific business/snapshot date
pwsh -File .\Run-OperaRALoader.ps1 -Mode OTB -ChainCode CHAIN_A -BusinessDate 2026-07-30

# Re-extract a corrections window for actuals
pwsh -File .\Run-OperaRALoader.ps1 -Mode Delta -HotelCode HOTEL1 -StartDate 2026-07-01 -EndDate 2026-07-07
```

---

## 5. SQL schema overview

All data lands in the `ra` schema (plus `dbo.LoadLog` for run logging). DDL lives in `SQL\001`–`005`.
Every table carries audit columns `BATCH_ID`, `LOADED_AT` (`SYSUTCDATETIME()`), and `LOADED_BY`
(`SUSER_SNAME()`). Column names follow the native OPERA R&A model (e.g. `RESORT` = HotelCode).

### 5.1 Operational log

| Table | Grain | Key columns |
|-------|-------|-------------|
| `dbo.LoadLog` | One row per (batch, hotel, query type) run | `BatchId`, `HotelCode`, `QueryType`, `Status`, `StartTime`/`EndTime`, computed `DurationSeconds`, `RowCount`/`RowsInserted`/`RowsUpdated`, `ErrorMessage` |

`Status` values: `Running` → `Success` | `NoData` | `Error` | `Partial`.

### 5.2 Actuals — `SQL\002`

| Table (alias) | Grain | Natural key (unique index) |
|---------------|-------|----------------------------|
| `ra.RES` (`ReservationStats`) | One row per reservation per business date per stat grain | `RESORT + BUSINESS_DATE + RESV_NAME_ID + MARKET_CODE + ROOM_CATEGORY_LABEL` |
| `ra.FIN` (`FinancialTx`) | One row per folio transaction line | `RESORT + BUSINESS_DATE + TRX_NO + TRAN_ACTION_ID` |

`ra.FIN` carries `IS_LATE_POSTING BIT` and both `TRX_DATE` (local) and `TRX_DATE_UTC`.

### 5.3 Daily snapshots + inventory — `SQL\003`

| Table (alias) | Grain | Natural key (unique index) |
|---------------|-------|----------------------------|
| `ra.OTB` (`OnTheBooks`) | Daily forward-occupancy snapshot | `RESORT + SNAPSHOT_DATE + CONSIDERED_DATE + MARKET_CODE + ROOM_CATEGORY_LABEL + SOURCE_CODE + CHANNEL + RATE_CODE + RESV_TYPE` |
| `ra.BLK` (`BlockReservations`) | Daily group-block snapshot | `RESORT + SNAPSHOT_DATE + BLOCK_CODE + CONSIDERED_DATE + ROOM_CATEGORY_LABEL` |
| `ra.RMN` | Physical room configuration (static) | `RESORT + ROOM` |
| `ra.OOO` | Daily Out-Of-Order / Out-Of-Service counts by room class | `RESORT + BUSINESS_DATE + ROOM_CLASS` |

### 5.4 Master data / dimensions (SCD Type 2) — `SQL\004`

All dimension tables carry SCD2 columns `VALID_FROM DATE NOT NULL`, `VALID_TO DATE NULL`,
`IS_CURRENT BIT NOT NULL DEFAULT 1`, and a natural key of `RESORT + <code column> + VALID_FROM`.

| Table (alias) | Code column | Notes |
|---------------|-------------|-------|
| `ra.DIM_TrxCodes` | `TRX_CODE` | `TC_GROUP`, `TC_SUBGROUP`, `REVENUE_YN`, `ROOM_REVENUE_YN`, `PACKAGE_YN`, `IS_ACTIVE` |
| `ra.DIM_RoomTypes` | `ROOM_CATEGORY_LABEL` | `ROOM_CLASS`, `PHYSICAL_ROOM_COUNT` |
| `ra.DIM_RateCodes` | `CODE` | `RATE_CATEGORY`, `RATE_CLASS` |
| `ra.DIM_MarketCodes` (`MarketSegments`) | `CODE` | `SEGMENT_GROUP` |
| `ra.DIM_SourceCodes` (`ReservationSources`) | `CODE` | **Source of reservation** — required dimension |
| `ra.DIM_Channels` (`Channels`) | `CODE` | **Distribution channel** — optional, independent list |
| `ra.Hotels` | `RESORT` (unique, one current row per hotel) | Not SCD2-versioned; property config |

`SQL\005` adds non-unique performance indexes on `HotelCode`, the various date columns,
`BATCH_ID`, `RESV_NAME_ID`, `TRX_CODE`, and `(RESORT, <code>, IS_CURRENT)` for the dimensions.

### 5.5 Entity relationship notes

- **RES ↔ FIN**: join actuals and folio transactions on `RESORT + BUSINESS_DATE + RESV_NAME_ID`.
  `RESV_NAME_ID` (the OPERA reservation id) is the reservation-level link; `TRX_NO_ADDED_BY` inside
  `ra.FIN` links a tax line back to its parent charge (`TRX_NO`).
- **OTB / BLK snapshot pattern**: `SNAPSHOT_DATE` is the business date the data was pulled and
  **accumulates** — each daily run inserts a fresh set of rows without overwriting prior snapshots
  (because `SNAPSHOT_DATE` is part of the natural key). `CONSIDERED_DATE` is the future stay/grid date
  the row describes. Join `ra.OTB` to `ra.BLK` on `RESORT + CONSIDERED_DATE` to overlay block
  pickup/remaining onto the forecast; `ra.OTB` also carries `REMAINING_BLOCK_ROOMS` /
  `PICKEDUP_BLOCK_ROOMS` for convenience.
- **Room inventory split**: the logical "RoomInventory" view is derived by joining `ra.RMN`
  (physical rooms per `ROOM_CATEGORY_LABEL`) with `ra.OOO` (daily `OOO_ROOMS` / `OS_ROOMS` /
  `AVAIL_ROOM` per `BUSINESS_DATE + ROOM_CLASS`).
- **SCD Type 2 dimensions**: the current version of any code is `IS_CURRENT = 1` with
  `VALID_TO IS NULL`. When a code changes, the prior row is expired (`VALID_TO = today - 1`,
  `IS_CURRENT = 0`) and a new version is inserted (`VALID_FROM = today`, `VALID_TO = NULL`,
  `IS_CURRENT = 1`). Historical fact rows continue to reference the code value valid at the time.
- **SourceCodes vs Channels are independent**: `ra.DIM_SourceCodes` (booking origin) and
  `ra.DIM_Channels` (GDS/OTA/Direct/Web/CRO) are two separate lists and are never merged.

---

## 6. Troubleshooting

### 6.1 OAuth / HTTP 401 token errors

- The loader caches the bearer token per hotel and refreshes it `tokenSafetyMarginSeconds` (default
  60s) before expiry. On a `401` it clears the cache, re-authenticates once, and retries. Repeated
  `401`s usually mean bad `clientId` / `clientSecret`, a hotel not subscribed to the R&A GraphQL plan,
  or a wrong `gatewayUrl`.
- Force a fresh token by clearing the in-memory cache (`Clear-TokenCache -HotelCode <code>` from
  `Auth.psm1`) — in practice a new process run does this automatically.
- If credentials were rotated in OHIP, update `hotels.input.json` and **re-run
  `Protect-HotelsConfig.ps1`** on the loader's host/account to regenerate `hotels.json`.

### 6.2 DPAPI decryption failures

Symptom: startup fails per hotel with *"Credential '<field>' failed to decrypt (was it encrypted by
this service account on this host?)."* DPAPI ciphertext is bound to the **user + machine** that
produced it. Causes and fix:

- The loader is running as a **different account** or on a **different host** than the one that ran
  `Protect-HotelsConfig.ps1`. Re-run the tool as the correct service account on the correct host.
- `hotels.json` was copied from another machine. Regenerate it locally rather than copying.

### 6.3 Late postings

A financial transaction whose `TRX_DATE > BUSINESS_DATE` is flagged `IS_LATE_POSTING = 1` in
`ra.FIN`, and the FIN query logs a `WARN` with the count. This is expected (charges posted after the
business date closed) — not an error. To reconcile a specific window, re-extract it:

```powershell
pwsh -File .\Run-OperaRALoader.ps1 -Mode Delta -HotelCode HOTEL1 -StartDate 2026-07-01 -EndDate 2026-07-07
```

The FIN `MERGE` is keyed on `RESORT + BUSINESS_DATE + TRX_NO + TRAN_ACTION_ID`, so re-runs update in
place without creating duplicates. To review late postings:

```sql
SELECT RESORT, BUSINESS_DATE, TRX_DATE, TRX_NO, TRX_CODE, TRX_AMOUNT
FROM   ra.FIN
WHERE  IS_LATE_POSTING = 1
  AND  RESORT = N'HOTEL1'
ORDER  BY BUSINESS_DATE, TRX_DATE;
```

### 6.4 SCD Type 2 rollback procedure

If a bad master-data version was written (e.g. a description or flag change you need to revert),
correct it by expiring the erroneous version and reactivating the prior one. Always take a backup and
run inside a transaction. Example for a single `ra.DIM_TrxCodes` code:

```sql
BEGIN TRAN;

-- 1. Remove (or expire) the bad current version.
DELETE FROM ra.DIM_TrxCodes
WHERE  RESORT = N'HOTEL1' AND TRX_CODE = N'ROOMREV'
  AND  IS_CURRENT = 1;

-- 2. Reactivate the immediately-prior version as current (open its VALID_TO).
;WITH prior AS (
    SELECT TOP (1) TrxCodeKey
    FROM   ra.DIM_TrxCodes
    WHERE  RESORT = N'HOTEL1' AND TRX_CODE = N'ROOMREV'
    ORDER  BY VALID_FROM DESC
)
UPDATE d
   SET d.VALID_TO = NULL, d.IS_CURRENT = 1
FROM   ra.DIM_TrxCodes d
JOIN   prior p ON p.TrxCodeKey = d.TrxCodeKey;

-- 3. Verify exactly one current row remains for the code, then COMMIT.
SELECT * FROM ra.DIM_TrxCodes
WHERE RESORT = N'HOTEL1' AND TRX_CODE = N'ROOMREV' ORDER BY VALID_FROM;

COMMIT;  -- or ROLLBACK if the verify looks wrong
```

Apply the same pattern to the other dimensions (`ra.DIM_RoomTypes` keyed on `ROOM_CATEGORY_LABEL`;
`ra.DIM_RateCodes` / `DIM_MarketCodes` / `DIM_SourceCodes` / `DIM_Channels` keyed on `CODE`). The
invariant to restore is: **exactly one row with `IS_CURRENT = 1` and `VALID_TO IS NULL` per
`RESORT + code`.** On the next master-data run the loader will re-detect any real change and version
it correctly.

---

## 7. GenAI code headers (Infor policy)

Per Infor company standards, every generated PowerShell source file carries the following header as
its **first line**:

```powershell
# GenAI-generated code — reviewed and approved by: <name> <date>
```

**Audit result (all shipped `.ps1` / `.psm1` files):**

| Area | Files | Header present |
|------|-------|:--------------:|
| Orchestrator | `Run-OperaRALoader.ps1` | ✅ |
| Tool | `Tools\Protect-HotelsConfig.ps1` | ✅ |
| Modules | `Modules\Auth.psm1`, `ApiClient.psm1`, `DateHelper.psm1`, `Logger.psm1`, `SqlWriter.psm1` | ✅ |
| Query modules | `Modules\Queries\ReservationStats.psm1`, `FinancialTransactions.psm1`, `OnTheBooks.psm1`, `BlockReservations.psm1`, `RoomInventory.psm1`, `MasterData.psm1` | ✅ |
| Tests | all `Tests\*.Tests.ps1` (13 files) | ✅ |

All 27 shipped PowerShell files already carry the header; none required changes. Reviewers should
replace `<name>` and `<date>` with the actual approver and approval date at review time.

> **SQL note:** the DDL scripts (`SQL\001`–`005`) use a `-- GenAI-generated code — reviewed and
> approved by: <name> <date>` variant inside their header comment block, which is left as-is.

---

## 8. Exit codes & monitoring

`Run-OperaRALoader.ps1` returns a process exit code computed by `Get-RunExitCode` from the per-hotel
results, so schedulers and monitoring can react without parsing logs.

| Exit code | Meaning | When |
|-----------|---------|------|
| `0` | **All success** | Every processed hotel finished `Success` or `NoData` (also returned when no hotels matched the filter — a no-op). |
| `1` | **Partial failure** | At least one hotel failed **and** at least one succeeded. |
| `2` | **Total failure** | Every processed hotel failed, or a fatal startup error (bad config, DPAPI failure, unhandled exception). |

### Wiring into monitoring

- **Windows Task Scheduler**: the exit code becomes the task's *Last Run Result*. Alert on any value
  other than `0x0`. A `1` (partial) still warrants attention even though some hotels loaded.
- **SQL Server Agent**: a **CmdExec** step fails on any non-zero exit, so the job fails and you can
  attach a notification/operator or Database Mail alert to the job's failure.
- **Email alerts**: with `smtp.enabled = true`, the loader sends per-hotel end-of-run summary emails
  (recipients resolved from each hotel's `emailAlerts`), including inline log entries at the
  triggering severity and the full daily log file attached. Email delivery failure is logged `WARN`
  and never changes the exit code.
- **`dbo.LoadLog` (primary data source for dashboards)**: query recent runs for status, row counts,
  and durations. Example — surface today's failures and no-data runs:

  ```sql
  SELECT HotelCode, QueryType, [Status], [RowCount], RowsInserted, RowsUpdated,
         StartTime, EndTime, DurationSeconds, ErrorMessage
  FROM   dbo.LoadLog
  WHERE  CAST(StartTime AS DATE) = CAST(SYSUTCDATETIME() AS DATE)
    AND  [Status] IN (N'Error', N'Partial', N'NoData')
  ORDER  BY StartTime DESC;
  ```

- **Daily log file**: `Logs\{yyyyMMdd}_OperaRA_Loader.log` (single shared file per run, append-on-rerun).
  The pipe-delimited format (`timestamp | LEVEL | MODULE | HotelCode | Message`) is grep/ingest
  friendly — point a log agent at `ERROR` lines for real-time alerting.
