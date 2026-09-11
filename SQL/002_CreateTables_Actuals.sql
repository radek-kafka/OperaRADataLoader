/* =====================================================================
   OPERA R&A Data Loader — 002_CreateTables_Actuals.sql
   Purpose : Create actuals + operational-log tables:
               dbo.LoadLog          (run/batch audit log)
               ra.RES               (reservation statistics — actuals)
               ra.FIN               (financial transactions — actuals)
   Target  : Microsoft SQL Server (T-SQL)
   Depends : 001_CreateSchema.sql (schema 'ra')
   Notes   : Idempotent — safe to re-run. Each object guarded with
             IF OBJECT_ID(...) IS NULL. Column names follow the OPERA R&A
             native model defined in design.md (RESORT, BUSINESS_DATE,
             RESV_NAME_ID, ...). These are the authoritative MERGE targets
             for SqlWriter.psm1 (Write-RES / Write-FIN) and the Query modules.

   NAME RECONCILIATION (business alias -> authoritative column, per design.md):
       HotelCode        -> RESORT
       ChainCode        -> CHAIN_CODE
       BusinessDate     -> BUSINESS_DATE
       ReservationId    -> RESV_NAME_ID
       MarketSegment    -> MARKET_CODE
       RoomTypeLabel    -> ROOM_CATEGORY_LABEL
       ReservationSource-> SOURCE_CODE
       Channel          -> CHANNEL
       TrxCode          -> TRX_CODE
       TrxType          -> FT_SUBTYPE (charge/payment/package subtype)
       PostingDate      -> TRX_DATE  (local); PostingDateLocal = TRX_DATE,
                           PostingDateUtc = TRX_DATE_UTC
       Amount           -> TRX_AMOUNT / NET_AMOUNT / GROSS_AMOUNT (see columns)
       IsLatePosting    -> IS_LATE_POSTING
       BatchId          -> BATCH_ID
   The friendly table aliases ra.ReservationStats / ra.FinancialTx map to the
   authoritative tables ra.RES / ra.FIN respectively.

   -- GenAI-generated code — reviewed and approved by: <name> <date>
   ===================================================================== */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   dbo.LoadLog — one row per (batch, hotel, query type) extraction run.
   Status values: Running | Success | NoData | Error | Partial
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.LoadLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.LoadLog
    (
        LoadId            BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_LoadLog PRIMARY KEY CLUSTERED,
        BatchId           UNIQUEIDENTIFIER NOT NULL,
        HotelCode         NVARCHAR(20)     NOT NULL,   -- RESORT / hotel code
        ChainCode         NVARCHAR(20)     NULL,
        [Mode]            NVARCHAR(30)     NULL,       -- Full|Delta|OTB|MasterData|All
        QueryType         NVARCHAR(50)     NOT NULL,   -- ReservationStats|FinancialTx|OTB|BLK|RMN|OOO|DIM|...
        BusinessDateFrom  DATE             NULL,
        BusinessDateTo    DATE             NULL,
        StartTime         DATETIME2(3)     NOT NULL
            CONSTRAINT DF_LoadLog_StartTime DEFAULT (SYSUTCDATETIME()),
        EndTime           DATETIME2(3)     NULL,
        DurationSeconds   AS (DATEDIFF(SECOND, StartTime, EndTime)) PERSISTED,
        [Status]          NVARCHAR(20)     NOT NULL
            CONSTRAINT DF_LoadLog_Status DEFAULT (N'Running'),
        [RowCount]        INT              NULL,       -- rows fetched from API
        RowsInserted      INT              NULL,
        RowsUpdated       INT              NULL,
        ErrorMessage      NVARCHAR(MAX)    NULL,
        LoadedBy          NVARCHAR(100)    NULL
            CONSTRAINT DF_LoadLog_LoadedBy DEFAULT (SUSER_SNAME())
    );
    PRINT 'Table [dbo].[LoadLog] created.';
END
ELSE
    PRINT 'Table [dbo].[LoadLog] already exists — skipped.';
GO

/* ---------------------------------------------------------------------
   ra.RES — reservation statistics (actuals).
   Alias: ra.ReservationStats.
   Natural key (MERGE): RESORT + BUSINESS_DATE + RESV_NAME_ID
                        + MARKET_CODE + ROOM_CATEGORY_LABEL
   One row per reservation per business date per stat grain.
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.RES', N'U') IS NULL
BEGIN
    CREATE TABLE ra.RES
    (
        StatId              BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_RES PRIMARY KEY CLUSTERED,
        -- Identity / Join Keys
        RESORT              NVARCHAR(20)  NOT NULL,   -- HotelCode
        CHAIN_CODE          NVARCHAR(20)  NULL,
        BUSINESS_DATE       DATE          NOT NULL,   -- join key -> ra.FIN, ra.OTB
        RESV_NAME_ID        NVARCHAR(50)  NOT NULL,   -- ReservationId, join key -> ra.FIN
        -- Rate / Market Dimensions
        RATE_CODE           NVARCHAR(50)  NULL,
        RATE_CATEGORY       NVARCHAR(50)  NULL,
        MARKET_CODE         NVARCHAR(50)  NULL,       -- MarketSegment
        SOURCE_CODE         NVARCHAR(50)  NULL,       -- ReservationSource
        CHANNEL             NVARCHAR(50)  NULL,       -- Channel
        -- Reservation Details
        ROOM                NVARCHAR(20)  NULL,
        PSEUDO_ROOM_YN      CHAR(1)       NULL,
        ROOM_CATEGORY_LABEL NVARCHAR(20)  NULL,       -- RoomTypeLabel (e.g. DB1, DS1)
        RESV_STATUS         NVARCHAR(30)  NULL,
        QUANTITY            INT           NULL,
        TRUNC_BEGIN_DATE    DATE          NULL,       -- arrival date (truncated)
        TRUNC_END_DATE      DATE          NULL,       -- departure date (truncated)
        COUNTRY             NVARCHAR(10)  NULL,
        NIGHTS              INT           NULL,
        -- Occupancy Counts
        ADULTS              INT           NULL,
        CHILDREN            INT           NULL,
        STAY_ROOMS          INT           NULL,
        STAY_PERSONS        INT           NULL,
        STAY_ADULTS         INT           NULL,
        STAY_CHILDREN       INT           NULL,
        ARR_ROOMS           INT           NULL,
        ARR_PERSONS         INT           NULL,
        DEP_ROOMS           INT           NULL,
        DEP_PERSONS         INT           NULL,
        DAY_USE_ROOMS       INT           NULL,
        DAY_USE_PERSONS     INT           NULL,
        NO_SHOW_ROOMS       INT           NULL,
        NO_SHOW_PERSONS     INT           NULL,
        -- Derived measures (ADR = Revenue / RoomNights; RevPAR = Revenue / PhysicalRooms)
        ROOM_NIGHTS         INT           NULL,       -- RoomNights
        REVENUE             DECIMAL(18,4) NULL,       -- Revenue
        ADR                 DECIMAL(18,4) NULL,       -- Average Daily Rate
        REVPAR              DECIMAL(18,4) NULL,       -- Revenue per available room
        -- Flags
        HOUSE_USE_YN        CHAR(1)       NULL,
        COMPLIMENTARY_YN    CHAR(1)       NULL,
        WALKIN_YN           CHAR(1)       NULL,
        CANCELLATION_DATE   DATETIME2(3)  NULL,
        -- Audit
        BATCH_ID            UNIQUEIDENTIFIER NULL,    -- BatchId
        LOADED_AT           DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_RES_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY           NVARCHAR(100) NULL
            CONSTRAINT DF_ra_RES_LoadedBy DEFAULT (SUSER_SNAME())
    );
    PRINT 'Table [ra].[RES] created.';
END
ELSE
    PRINT 'Table [ra].[RES] already exists — skipped.';
GO

-- Natural-key uniqueness for deterministic MERGE (guarded)
IF OBJECT_ID(N'ra.RES', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'UX_ra_RES_NaturalKey'
                     AND object_id = OBJECT_ID(N'ra.RES'))
BEGIN
    CREATE UNIQUE INDEX UX_ra_RES_NaturalKey
        ON ra.RES (RESORT, BUSINESS_DATE, RESV_NAME_ID, MARKET_CODE, ROOM_CATEGORY_LABEL);
    PRINT 'Index [UX_ra_RES_NaturalKey] created.';
END
GO

/* ---------------------------------------------------------------------
   ra.FIN — financial transactions (actuals).
   Alias: ra.FinancialTx.
   Natural key (MERGE): RESORT + BUSINESS_DATE + RESV_NAME_ID
                        + TRX_NO + TRAN_ACTION_ID
   RESV_NAME_ID is the join key back to ra.RES.
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.FIN', N'U') IS NULL
BEGIN
    CREATE TABLE ra.FIN
    (
        TxId             BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_FIN PRIMARY KEY CLUSTERED,
        -- Identity / Join Keys
        RESORT           NVARCHAR(20)  NOT NULL,      -- HotelCode
        CHAIN_CODE       NVARCHAR(20)  NULL,
        BUSINESS_DATE    DATE          NOT NULL,      -- join key -> ra.RES
        RESV_NAME_ID     NVARCHAR(50)  NULL,          -- ReservationId, join key -> ra.RES
        ORIGINAL_RESV    NVARCHAR(50)  NULL,          -- original resv if transferred
        -- Transaction Identifiers
        TRX_NO           NVARCHAR(50)  NOT NULL,      -- OPERA transaction number
        TRAN_ACTION_ID   NVARCHAR(50)  NOT NULL,      -- OPERA transaction action ID
        TRX_NO_ADDED_BY  NVARCHAR(50)  NULL,          -- parent TRX_NO (links tax to charge)
        -- Transaction Classification
        TRX_CODE         NVARCHAR(20)  NOT NULL,      -- TrxCode, FK -> ra.DIM_TrxCodes (TRX_CODE)
        TC_GROUP         NVARCHAR(50)  NULL,          -- ROOM, FB, PAY, TAX, PKG
        TC_SUBGROUP      NVARCHAR(50)  NULL,
        FT_SUBTYPE       NVARCHAR(10)  NULL,          -- TrxType: C=Charge, FC=Payment, PK=Package
        -- Rate / Market Dimensions
        RATE_CODE        NVARCHAR(50)  NULL,
        MARKET_CODE      NVARCHAR(50)  NULL,
        SOURCE_CODE      NVARCHAR(50)  NULL,
        -- Amounts
        NET_AMOUNT       DECIMAL(18,4) NULL,          -- net of tax (excl. VAT)
        GROSS_AMOUNT     DECIMAL(18,4) NULL,          -- incl. VAT (null for payments)
        TRX_AMOUNT       DECIMAL(18,4) NULL,          -- Amount (transaction amount)
        POSTED_AMOUNT    DECIMAL(18,4) NULL,
        REVENUE_AMT      DECIMAL(18,4) NULL,
        QUANTITY         DECIMAL(18,4) NULL,
        PRICE_PER_UNIT   DECIMAL(18,4) NULL,
        EXCHANGE_RATE    DECIMAL(18,6) NULL
            CONSTRAINT DF_ra_FIN_ExchangeRate DEFAULT (1),
        CURRENCY         NVARCHAR(10)  NULL,          -- ISO currency code
        IND_REVENUE_GP   CHAR(1)       NULL,          -- Y/N revenue group indicator
        -- Date / Time
        POSTING_DATE     DATE          NULL,          -- PostingDate (date-only)
        TRX_DATE         DATETIME2(3)  NOT NULL,      -- PostingDateLocal (posting date, local)
        TRX_DATE_UTC     DATETIME2(3)  NULL,          -- PostingDateUtc
        IS_LATE_POSTING  BIT           NOT NULL
            CONSTRAINT DF_ra_FIN_IsLatePosting DEFAULT (0),  -- TRX_DATE > BUSINESS_DATE
        -- GL Export Codes (from ExportMappings SA if available)
        COSTCENTER       NVARCHAR(50)  NULL,          -- BOF_CODE2 / GL cost centre
        [ACCOUNT]        NVARCHAR(50)  NULL,          -- BOF_CODE5 / GL account
        -- Passer-by (non-reservation transactions)
        PASSER_BY_NAME   NVARCHAR(200) NULL,
        -- Audit
        BATCH_ID         UNIQUEIDENTIFIER NULL,       -- BatchId
        LOADED_AT        DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_FIN_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY        NVARCHAR(100) NULL
            CONSTRAINT DF_ra_FIN_LoadedBy DEFAULT (SUSER_SNAME())
    );
    PRINT 'Table [ra].[FIN] created.';
END
ELSE
    PRINT 'Table [ra].[FIN] already exists — skipped.';
GO

-- Natural-key uniqueness for deterministic MERGE (guarded)
IF OBJECT_ID(N'ra.FIN', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'UX_ra_FIN_NaturalKey'
                     AND object_id = OBJECT_ID(N'ra.FIN'))
BEGIN
    CREATE UNIQUE INDEX UX_ra_FIN_NaturalKey
        ON ra.FIN (RESORT, BUSINESS_DATE, TRX_NO, TRAN_ACTION_ID);
    PRINT 'Index [UX_ra_FIN_NaturalKey] created.';
END
GO
