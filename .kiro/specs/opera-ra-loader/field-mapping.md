# OPERA R&A — Field Mapping Reference

> Maps each CSV export field (DERTOUR/DHR Design Document) to:
> the OPERA R&A DB column · the expected GraphQL camelCase field · the SQL Server target column · availability status.
>
> **Availability:**
> ✅ Confirmed in API docs/sample  🔶 Expected (standard R&A column — verify via introspection)
> ⚠️  Available in a different Subject Area  ❌ Not in GraphQL — compute or omit
>
> **Verify exact field names** with a GraphQL `__type` introspection query on a live environment.
> CSV field names = OPERA R&A DB column names. GraphQL names follow camelCase of the same column.

---

## RES — `{RESORT}_OPERA_RES_{yyyymmdd}.csv`
DB Table: `RESERVATION_STAT_DAILY` · SA: `StatisticsReservationsDaily` · Target: `ra.RES`

| CSV / DB Column       | GraphQL Field          | SQL Column              | Status |
|-----------------------|------------------------|-------------------------|--------|
| `BUSINESS_DATE`       | `businessDate`         | `BUSINESS_DATE`         | ✅     |
| `RESORT`              | `resort`               | `RESORT`                | ✅     |
| `RESV_NAME_ID`        | `resvNameId`           | `RESV_NAME_ID`          | ✅     |
| `RATE_CODE`           | `rateCode`             | `RATE_CODE`             | 🔶     |
| `RATE_CATEGORY`       | `rateCategory`         | `RATE_CATEGORY`         | 🔶     |
| `MARKET_CODE`         | `marketCode`           | `MARKET_CODE`           | ✅     |
| `SOURCE_CODE`         | `sourceCode`           | `SOURCE_CODE`           | ✅     |
| `CHANNEL`             | `channel`              | `CHANNEL`               | 🔶     |
| `TRUNC_BEGIN_DATE`    | `truncBeginDate`       | `TRUNC_BEGIN_DATE`      | 🔶     |
| `TRUNC_END_DATE`      | `truncEndDate`         | `TRUNC_END_DATE`        | 🔶     |
| `ROOM`                | `room`                 | `ROOM`                  | 🔶     |
| `PSEUDO_ROOM_YN`      | `pseudoRoomYn`         | `PSEUDO_ROOM_YN`        | 🔶     |
| `ROOM_TYPE` (=LABEL)  | `roomCategoryLabel`    | `ROOM_CATEGORY_LABEL`   | ✅     |
| `RESV_STATUS`         | `resvStatus`           | `RESV_STATUS`           | 🔶     |
| `QUANTITY`            | `quantity`             | `QUANTITY`              | 🔶     |
| `ADULTS`              | `adults`               | `ADULTS`                | 🔶     |
| `CHILDREN`            | `children`             | `CHILDREN`              | 🔶     |
| `STAY_ROOMS`          | `stayRooms`            | `STAY_ROOMS`            | ✅     |
| `STAY_PERSONS`        | `stayPersons`          | `STAY_PERSONS`          | 🔶     |
| `STAY_ADULTS`         | `stayAdults`           | `STAY_ADULTS`           | 🔶     |
| `STAY_CHILDREN`       | `stayChildren`         | `STAY_CHILDREN`         | 🔶     |
| `ARR_ROOMS`           | `arrRooms`             | `ARR_ROOMS`             | ✅     |
| `ARR_PERSONS`         | `arrPersons`           | `ARR_PERSONS`           | 🔶     |
| `DEP_ROOMS`           | `depRooms`             | `DEP_ROOMS`             | ✅     |
| `DEP_PERSONS`         | `depPersons`           | `DEP_PERSONS`           | 🔶     |
| `DAY_USE_ROOMS`       | `dayUseRooms`          | `DAY_USE_ROOMS`         | 🔶     |
| `DAY_USE_PERSONS`     | `dayUsePersons`        | `DAY_USE_PERSONS`       | 🔶     |
| `HOUSE_USE_YN`        | `houseUseYn`           | `HOUSE_USE_YN`          | 🔶     |
| `COMPLIMENTARY_YN`    | `complimentaryYn`      | `COMPLIMENTARY_YN`      | 🔶     |
| `WALKIN_YN`           | `walkinYn`             | `WALKIN_YN`             | 🔶     |
| `NO_SHOW_ROOMS`       | `noShowRooms`          | `NO_SHOW_ROOMS`         | 🔶     |
| `NO_SHOW_PERSONS`     | `noShowPersons`        | `NO_SHOW_PERSONS`       | 🔶     |
| `CANCELLATION_DATE`   | `cancellationDate`     | `CANCELLATION_DATE`     | 🔶     |
| `COUNTRY`             | `country`              | `COUNTRY`               | 🔶     |
| `NIGHTS`              | `nights`               | `NIGHTS`                | 🔶     |

Notes:
- `ROOM_TYPE` in CSV = `ROOM_CATEGORY_LABEL` in DB (label code e.g. `DB1`, `DS1`)
- `RESV_NAME_ID` is the join key → `ra.FIN` (same reservation)

---

## FIN — `{RESORT}_OPERA_FIN_{yyyymmdd}.csv`
DB Table: `FINANCIAL_TRANSACTIONS` · SA: `FinancialTransactionDetails` · Target: `ra.FIN`

| CSV / DB Column       | GraphQL Field          | SQL Column              | Status |
|-----------------------|------------------------|-------------------------|--------|
| `BUSINESS_DATE`       | `businessDate`         | `BUSINESS_DATE`         | ✅     |
| `RESORT`              | `resort`               | `RESORT`                | ✅     |
| `RESV_NAME_ID`        | `resvNameId`           | `RESV_NAME_ID`          | ✅     |
| `ORIGINAL_RESV`       | `originalResvNameId`   | `ORIGINAL_RESV`         | 🔶     |
| `RATE_CODE`           | `rateCode`             | `RATE_CODE`             | ✅     |
| `SOURCE_CODE`         | `sourceCode`           | `SOURCE_CODE`           | ✅     |
| `MARKET_CODE`         | `marketCode`           | `MARKET_CODE`           | ✅     |
| `FT_SUBTYPE`          | `ftSubtype`            | `FT_SUBTYPE`            | ✅     |
| `TC_GROUP`            | `tcGroup`              | `TC_GROUP`              | ✅     |
| `TC_SUBGROUP`         | `tcSubgroup`           | `TC_SUBGROUP`           | ✅     |
| `TRX_CODE`            | `trxCode`              | `TRX_CODE`              | ✅     |
| `TRX_NO`              | `trxNo`                | `TRX_NO`                | ✅     |
| `TRAN_ACTION_ID`      | `tranActionId`         | `TRAN_ACTION_ID`        | ✅     |
| `TRX_NO_ADDED_BY`     | `trxNoAddedBy`         | `TRX_NO_ADDED_BY`       | 🔶     |
| `TRX_DATE`            | `trxDate`              | `TRX_DATE`              | ✅     |
| `NET_AMOUNT`          | `netAmount`            | `NET_AMOUNT`            | ✅     |
| `GROSS_AMOUNT`        | `grossAmount`          | `GROSS_AMOUNT`          | ✅     |
| `TRX_AMOUNT`          | `trxAmount`            | `TRX_AMOUNT`            | 🔶     |
| `POSTED_AMOUNT`       | `postedAmount`         | `POSTED_AMOUNT`         | 🔶     |
| `REVENUE_AMT`         | `revenueAmt`           | `REVENUE_AMT`           | 🔶     |
| `QUANTITY`            | `quantity`             | `QUANTITY`              | ✅     |
| `PRICE_PER_UNIT`      | `pricePerUnit`         | `PRICE_PER_UNIT`        | 🔶     |
| `EXCHANGE_RATE`       | `exchangeRate`         | `EXCHANGE_RATE`         | 🔶     |
| `CURRENCY`            | `currencyCode`         | `CURRENCY`              | ✅     |
| `IND_REVENUE_GP`      | `indRevenueGp`         | `IND_REVENUE_GP`        | 🔶     |
| `PASSER_BY_NAME`      | `passerByName`         | `PASSER_BY_NAME`        | 🔶     |
| `COSTCENTER`          | *(BOF_CODE2)*          | `COSTCENTER`            | ❌ via `ExportMappings` |
| `ACCOUNT`             | *(BOF_CODE5)*          | `ACCOUNT`               | ❌ via `ExportMappings` |
| *(computed)*          | *(trxDate>businessDate)* | `IS_LATE_POSTING`     | ❌ computed             |

Notes:
- `FT_SUBTYPE`: `C`=Charge/Revenue, `FC`=Payment, `PK`=Package offset
- `IND_REVENUE_GP`: `Y`=counted as revenue, `N`=non-revenue (e.g. taxes, payments)
- `TRX_NO_ADDED_BY`: links tax lines back to their parent charge line
- `TRAN_ACTION_ID`: unique action identifier for this posting event
- `NET_AMOUNT` = revenue excl. VAT; `GROSS_AMOUNT` = incl. VAT (null for payments)
- `COSTCENTER` / `ACCOUNT`: GL codes from `ExportMappings` SA — join on `TRX_CODE`

---

## OTB — `{RESORT}_OPERA_OTB_{yyyymmdd}.csv`
DB Table: `RESERVATION_NAME` · SA: `StatisticsForecastSummary` · Target: `ra.OTB`

| CSV / DB Column          | GraphQL Field           | SQL Column               | Status |
|--------------------------|-------------------------|--------------------------|--------|
| `BUSINESS_DATE` (run)    | *(set by loader)*       | `SNAPSHOT_DATE`          | ❌ loader sets |
| `RESORT`                 | `resort`                | `RESORT`                 | ✅     |
| `EVENT_TYPE`             | `eventType`             | `EVENT_TYPE`             | 🔶     |
| `CONSIDERED_DATE`        | `stayDate`              | `CONSIDERED_DATE`        | ✅     |
| `ROOM_TYPE` (=LABEL)     | `roomCategoryLabel`     | `ROOM_CATEGORY_LABEL`    | ✅     |
| `MARKET_CODE`            | `marketCode`            | `MARKET_CODE`            | ✅     |
| `SOURCE_CODE`            | `sourceCode`            | `SOURCE_CODE`            | ✅     |
| `RATE_CODE`              | `rateCode`              | `RATE_CODE`              | 🔶     |
| `RATE_CATEGORY`          | `rateCategory`          | `RATE_CATEGORY`          | 🔶     |
| `RESV_TYPE`              | `resvType`              | `RESV_TYPE`              | 🔶     |
| `PSEUDO_ROOM_YN`         | *(not in OPERA Cloud)*  | `PSEUDO_ROOM_YN`         | ❌     |
| `DAY_USE_YN`             | `dayUseYn`              | `DAY_USE_YN`             | 🔶     |
| `ARR_ROOMS`              | `arrRooms`              | `ARR_ROOMS`              | ✅     |
| `ADULTS`                 | `adults`                | `ADULTS`                 | 🔶     |
| `CHILDREN`               | `children`              | `CHILDREN`               | 🔶     |
| `DEP_ROOMS`              | `depRooms`              | `DEP_ROOMS`              | 🔶     |
| `NO_ROOMS`               | `noRooms`               | `NO_ROOMS`               | 🔶     |
| `OO_ROOMS`               | *(from ra.OOO)*         | `OO_ROOMS`               | ❌ join ra.OOO |
| `OS_ROOMS`               | *(from ra.OOO)*         | `OS_ROOMS`               | ❌ join ra.OOO |
| `REMAINING_BLOCK_ROOMS`  | `remainingBlockRooms`   | `REMAINING_BLOCK_ROOMS`  | ⚠️ `BookingsBlock` |
| `PICKEDUP_BLOCK_ROOMS`   | `pickedupBlockRooms`    | `PICKEDUP_BLOCK_ROOMS`   | ⚠️ `BookingsBlock` |
| `ARR_PERSONS`            | `arrPersons`            | `ARR_PERSONS`            | 🔶     |
| `DEP_PERSONS`            | `depPersons`            | `DEP_PERSONS`            | 🔶     |
| `DAY_USE_ROOMS`          | `dayUseRooms`           | `DAY_USE_ROOMS`          | 🔶     |
| `DAY_USE_PERSONS`        | `dayUsePersons`         | `DAY_USE_PERSONS`        | 🔶     |
| `QUANTITY`               | `quantity`              | `QUANTITY`               | 🔶     |
| `NIGHTS`                 | `nights`                | `NIGHTS`                 | 🔶     |
| `RESV_STATUS`            | `resvStatus`            | `RESV_STATUS`            | 🔶     |
| `CHANNEL`                | `channel`               | `CHANNEL`                | 🔶     |
| `COUNTRY`                | `country`               | `COUNTRY`                | 🔶     |
| `CURRENCY_CODE`          | `currencyCode`          | `CURRENCY_CODE`          | 🔶     |
| `TRUNC_BEGIN_DATE`       | `truncBeginDate`        | `TRUNC_BEGIN_DATE`       | 🔶     |
| `TRUNC_END_DATE`         | `truncEndDate`          | `TRUNC_END_DATE`         | 🔶     |
| `GROSS_RATE`             | `grossRate`             | `GROSS_RATE`             | 🔶     |
| `NET_ROOM_REVENUE`       | `netRoomRevenue`        | `NET_ROOM_REVENUE`       | ✅     |
| `EXTRA_REVENUE`          | `extraRevenue`          | `EXTRA_REVENUE`          | 🔶     |
| `ROOM_REVENUE`           | `roomRevenue`           | `ROOM_REVENUE`           | ✅     |
| `ROOM_REVENUE_TAX`       | `roomRevenueTax`        | `ROOM_REVENUE_TAX`       | 🔶     |
| `FOOD_REVENUE`           | `foodRevenue`           | `FOOD_REVENUE`           | 🔶     |
| `FOOD_REVENUE_TAX`       | `foodRevenueTax`        | `FOOD_REVENUE_TAX`       | 🔶     |
| `OTHER_REVENUE`          | `otherRevenue`          | `OTHER_REVENUE`          | 🔶     |
| `OTHER_REVENUE_TAX`      | `otherRevenueTax`       | `OTHER_REVENUE_TAX`      | 🔶     |
| `TOTAL_REVENUE`          | `totalRevenue`          | `TOTAL_REVENUE`          | 🔶     |
| `TOTAL_REVENUE_TAX`      | `totalRevenueTax`       | `TOTAL_REVENUE_TAX`      | 🔶     |
| `NON_REVENUE`            | `nonRevenue`            | `NON_REVENUE`            | 🔶     |
| `NON_REVENUE_TAX`        | `nonRevenueTax`         | `NON_REVENUE_TAX`        | 🔶     |

---

## BLK — Block Reservations
DB Table: `BLOCK / ALLOTMENT` · SA: `BookingsBlock` · Target: `ra.BLK`

| Field                    | GraphQL Field           | SQL Column               | Status |
|--------------------------|-------------------------|--------------------------|--------|
| *(set by loader)*        | *(loader)*              | `SNAPSHOT_DATE`          | ❌ loader sets |
| `RESORT`                 | `resort`                | `RESORT`                 | ✅     |
| `BLOCK_CODE`             | `blockCode`             | `BLOCK_CODE`             | ✅     |
| `BLOCK_NAME`             | `blockName`             | `BLOCK_NAME`             | ✅     |
| stay/grid date           | `blockIdDate`           | `CONSIDERED_DATE`        | ✅     |
| `ROOM_CATEGORY_LABEL`    | `roomCategoryLabel`     | `ROOM_CATEGORY_LABEL`    | 🔶     |
| `MARKET_CODE`            | `marketCode`            | `MARKET_CODE`            | ✅     |
| `SOURCE_CODE`            | `sourceCode`            | `SOURCE_CODE`            | 🔶     |
| `RATE_CODE`              | `rateCode`              | `RATE_CODE`              | 🔶     |
| `RATE_CATEGORY`          | `rateCategory`          | `RATE_CATEGORY`          | 🔶     |
| cutoff date              | `cutoffDate`            | `CUTOFF_DATE`            | 🔶     |
| *(computed)*             | *(cutoff < snapshot)*   | `IS_PAST_CUTOFF`         | ❌ computed  |
| blocked rooms            | `blockedRooms`          | `ROOMS_CONTRACTED`       | ✅     |
| picked up rooms          | `pickedUpRooms`         | `ROOMS_PICKEDUP`         | ✅     |
| *(computed)*             | *(contracted-pickedup)* | `ROOMS_REMAINING`        | ❌ computed  |
| gross room revenue       | `roomRevenue`           | `ROOM_REVENUE`           | 🔶     |
| gross F&B revenue        | `foodRevenue`           | `FOOD_REVENUE`           | 🔶     |
| gross other revenue      | `otherRevenue`          | `OTHER_REVENUE`          | 🔶     |
| gross total revenue      | `totalRevenue`          | `TOTAL_REVENUE`          | 🔶     |
| non revenue              | `nonRevenue`            | `NON_REVENUE`            | 🔶     |
| net room revenue         | `netRoomRevenue`        | `NET_ROOM_REVENUE`       | 🔶     |
| net F&B revenue          | `netFoodRevenue`        | `NET_FOOD_REVENUE`       | 🔶     |
| net other revenue        | `netOtherRevenue`       | `NET_OTHER_REVENUE`      | 🔶     |
| net total revenue        | `netTotalRevenue`       | `NET_TOTAL_REVENUE`      | 🔶     |
| room revenue tax         | `roomRevenueTax`        | `ROOM_REVENUE_TAX`       | 🔶     |
| food revenue tax         | `foodRevenueTax`        | `FOOD_REVENUE_TAX`       | 🔶     |
| other revenue tax        | `otherRevenueTax`       | `OTHER_REVENUE_TAX`      | 🔶     |
| total revenue tax        | `totalRevenueTax`       | `TOTAL_REVENUE_TAX`      | 🔶     |

---

## DIM — `{RESORT}_OPERA_DIM_{yyyymmdd}.csv`
Format: `RESORT;FIELD_NAME;CODE;DESCRIPTION;FLAG`

| `FIELD_NAME`   | OHIP Subject Area          | GraphQL Operation           | Target Table         |
|----------------|----------------------------|-----------------------------|----------------------|
| `TC_CODE`      | `FinancialTransactionCodes`| `financialTransactionCodes` | `ra.DIM_TrxCodes`    |
| `TC_GROUP`     | `FinancialTransactionCodes`| `financialTransactionCodes` | `ra.DIM_TrxCodes`    |
| `TC_SUBGROUP`  | `FinancialTransactionCodes`| `financialTransactionCodes` | `ra.DIM_TrxCodes`    |
| `ROOM_TYPE`    | `InventoryRooms`           | `inventoryRooms`            | `ra.DIM_RoomTypes`   |
| `RATE_CODE`    | `RatesCodeDetails`         | `ratesCodeDetails`          | `ra.DIM_RateCodes`   |
| `RATE_HEADER`  | `RatesCodeDetails`         | `ratesCodeDetails`          | `ra.DIM_RateCodes`   |
| `MARKETCODE`   | `ExportMappings`           | `exportMappings`            | `ra.DIM_MarketCodes` |
| `SOURCE_CODE`  | `ExportMappings`           | `exportMappings`            | `ra.DIM_SourceCodes` |
| `CHANNEL`      | `ExportMappings`           | `exportMappings`            | `ra.DIM_Channels`    |
| `FT_SUBTYPE`   | Hardcoded                  | N/A                         | *(hardcoded in loader)* |

`FinancialTransactionCodes` key fields:
```
trxCode      → TC_CODE (CODE)
description  → DESCRIPTION
trxGroup     → TC_GROUP
trxSubgroup  → TC_SUBGROUP
revenueYn    → IND_REVENUE_GP equivalent
roomRevenueYn→ room revenue flag
packageYn    → package flag
activeYn     → FLAG (N=active Y=deleted)
```

---

## RMN — `{RESORT}_OPERA_RMN_{yyyymmdd}.csv`
DB Table: `ROOM` · SA: `InventoryRooms` · Target: `ra.RMN`

| CSV / DB Column  | GraphQL Field       | SQL Column           | Status |
|-----------------|---------------------|----------------------|--------|
| `RESORT`        | `resort`            | `RESORT`             | ✅     |
| `ROOM`          | `room`              | `ROOM`               | ✅     |
| `ROOM_STATUS`   | `roomStatus`        | `ROOM_STATUS`        | 🔶     |
| *(from SA)*     | `roomCategoryLabel` | `ROOM_CATEGORY_LABEL`| 🔶     |
| *(from SA)*     | `roomClass`         | `ROOM_CLASS`         | 🔶     |

---

## OOO — `{RESORT}_OPERA_OOO_{yyyymmdd}.csv`
DB Table: `REP_MANAGER` · SA: `StatisticsManagersReport` · Target: `ra.OOO`

| CSV / DB Column  | GraphQL Field    | SQL Column       | Status |
|-----------------|------------------|------------------|--------|
| `RESORT`        | `resort`         | `RESORT`         | ✅     |
| `BUSINESS_DATE` | `businessDate`   | `BUSINESS_DATE`  | ✅     |
| `ROOM_CLASS`    | `roomClass`      | `ROOM_CLASS`     | 🔶     |
| `OS_ROOMS`      | `osRooms`        | `OS_ROOMS`       | 🔶     |
| `OOO_ROOMS`     | `oooRooms`       | `OOO_ROOMS`      | 🔶     |
| `AVAIL_ROOM`    | `availRoom`      | `AVAIL_ROOM`     | 🔶     |
| `PHYSICAL_BEDS` | `physicalBeds`   | `PHYSICAL_BEDS`  | 🔶     |
| `OOO_BEDS`      | `oooBeds`        | `OOO_BEDS`       | 🔶     |
| `OS_BEDS`       | `osBeds`         | `OS_BEDS`        | 🔶     |

---

## GraphQL Introspection — Field Verification

Before implementation, confirm exact field names per Subject Area using:
```graphql
{
  __type(name: "ReservationDailyStatisticsDetailsType") {
    fields { name type { name kind ofType { name } } }
  }
}
```

| Subject Area                  | Expected Primary Type                     |
|-------------------------------|-------------------------------------------|
| `StatisticsReservationsDaily` | `ReservationDailyStatisticsDetailsType`   |
| `FinancialTransactionDetails` | `FinancialTransactionDetailsType`         |
| `StatisticsForecastSummary`   | `ForecastSummaryDetailsType`              |
| `StatisticsManagersReport`    | `ManagersReportDetailsType`               |
| `BookingsBlock`               | `BlockDetailsType`                        |
| `InventoryRooms`              | `RoomDetailsType`                         |
| `FinancialTransactionCodes`   | `TransactionCodeDetailsType`              |
| `RatesCodeDetails`            | `RateCodeDetailsType`                     |
| `ExportMappings`              | `ExportMappingDetailsType`                |
| `ConfigurationResort`         | `PropertyDetailsType`                     |
