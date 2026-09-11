/* =====================================================================
   OPERA R&A Data Loader — 003_CreateTables_Snapshots.sql
   Purpose : Create daily-snapshot + inventory tables:
               ra.OTB   (On-The-Books daily forecast snapshot)
               ra.BLK   (Block reservations daily snapshot)
               ra.RMN   (physical room configuration list)
               ra.OOO   (daily Out-Of-Order / Out-Of-Service counts)
   Target  : Microsoft SQL Server (T-SQL)
   Depends : 001_CreateSchema.sql (schema 'ra')
   Notes   : Idempotent — safe to re-run. Each object guarded with
             IF OBJECT_ID(...) IS NULL. Column names follow the OPERA R&A
             native model in design.md and are the MERGE targets for
             SqlWriter.psm1 (Write-OTB / Write-BLK / Write-RMN / Write-OOO).

   NAME RECONCILIATION (business alias -> authoritative, per design.md):
       ra.OnTheBooks       -> ra.OTB
       ra.BlockReservations-> ra.BLK
       ra.RoomInventory    -> split into ra.RMN (physical rooms) + ra.OOO
                              (OOO/OOS counts). The single-table "RoomInventory"
                              view (PhysicalRooms / OutOfOrder / OutOfService /
                              AvailableRooms by InventoryDate + RoomTypeLabel) is
                              derived by joining ra.RMN (PhysicalRooms per
                              ROOM_CATEGORY_LABEL) with ra.OOO (OOO_ROOMS / OS_ROOMS
                              / AVAIL_ROOM per BUSINESS_DATE + ROOM_CLASS).
       SnapshotDate        -> SNAPSHOT_DATE
       ConsideredDate      -> CONSIDERED_DATE
       MarketSegment       -> MARKET_CODE
       RoomTypeLabel       -> ROOM_CATEGORY_LABEL
       ReservationSource   -> SOURCE_CODE
       Channel             -> CHANNEL
       RoomsOnBooks        -> NO_ROOMS
       TentativeRooms/DefiniteRooms -> derived from RESV_TYPE / RESV_STATUS grain
       ADROnBooks          -> derived (ROOM_REVENUE / NO_ROOMS)
       RevenueOnBooks      -> TOTAL_REVENUE / ROOM_REVENUE
       RoomsContracted     -> ROOMS_CONTRACTED
       RoomsPickedUp       -> ROOMS_PICKEDUP
       RoomsRemaining      -> ROOMS_REMAINING
       CutoffDate          -> CUTOFF_DATE
       IsPastCutoff        -> IS_PAST_CUTOFF
       InventoryDate       -> BUSINESS_DATE (ra.OOO)
       PhysicalRooms       -> (count from ra.RMN) / PHYSICAL_BEDS (ra.OOO)
       OutOfOrder          -> OOO_ROOMS
       OutOfService        -> OS_ROOMS
       AvailableRooms      -> AVAIL_ROOM
   OTB inserts new SNAPSHOT_DATE rows without overwriting prior snapshots
   (the natural key includes SNAPSHOT_DATE, so daily snapshots accumulate).

   -- GenAI-generated code — reviewed and approved by: <name> <date>
   ===================================================================== */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   ra.OTB — On-The-Books daily snapshot (future occupancy forecast).
   Alias: ra.OnTheBooks.
   Natural key (MERGE): RESORT + SNAPSHOT_DATE + CONSIDERED_DATE
                        + MARKET_CODE + ROOM_CATEGORY_LABEL
                        + SOURCE_CODE + CHANNEL + RATE_CODE + RESV_TYPE
   SNAPSHOT_DATE = business date the data was pulled (set by loader).
   CONSIDERED_DATE = future stay date (= stayDate in GraphQL).
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.OTB', N'U') IS NULL
BEGIN
    CREATE TABLE ra.OTB
    (
        OtbId               BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_OTB PRIMARY KEY CLUSTERED,
        -- Identity
        RESORT              NVARCHAR(20)  NOT NULL,   -- HotelCode
        CHAIN_CODE          NVARCHAR(20)  NULL,
        SNAPSHOT_DATE       DATE          NOT NULL,   -- SnapshotDate (business date of run)
        CONSIDERED_DATE     DATE          NOT NULL,   -- ConsideredDate (future stay date)
        -- Dimensions
        MARKET_CODE         NVARCHAR(50)  NULL,       -- MarketSegment
        SOURCE_CODE         NVARCHAR(50)  NULL,       -- ReservationSource
        CHANNEL             NVARCHAR(50)  NULL,       -- Channel
        RATE_CODE           NVARCHAR(50)  NULL,
        RATE_CATEGORY       NVARCHAR(50)  NULL,
        ROOM_CATEGORY_LABEL NVARCHAR(20)  NULL,       -- RoomTypeLabel
        RESV_TYPE           NVARCHAR(10)  NULL,       -- R=Regular, G=Group (tentative/definite grain)
        EVENT_TYPE          NVARCHAR(10)  NULL,
        COUNTRY             NVARCHAR(10)  NULL,
        CURRENCY_CODE       NVARCHAR(10)  NULL,
        -- Date Range
        TRUNC_BEGIN_DATE    DATE          NULL,
        TRUNC_END_DATE      DATE          NULL,
        -- Room / Occupancy Counts
        ARR_ROOMS           INT           NULL,
        DEP_ROOMS           INT           NULL,
        NO_ROOMS            INT           NULL,       -- RoomsOnBooks
        DAY_USE_ROOMS       INT           NULL,
        DAY_USE_PERSONS     INT           NULL,
        ARR_PERSONS         INT           NULL,
        DEP_PERSONS         INT           NULL,
        ADULTS              INT           NULL,
        CHILDREN            INT           NULL,
        QUANTITY            INT           NULL,
        NIGHTS              INT           NULL,
        RESV_STATUS         NVARCHAR(30)  NULL,       -- tentative/definite split source
        -- Derived on-books measures
        TENTATIVE_ROOMS     INT           NULL,       -- TentativeRooms (derived)
        DEFINITE_ROOMS      INT           NULL,       -- DefiniteRooms  (derived)
        ADR_ON_BOOKS        DECIMAL(18,4) NULL,       -- ADROnBooks (derived)
        REVENUE_ON_BOOKS    DECIMAL(18,4) NULL,       -- RevenueOnBooks (derived)
        -- Block Rooms (from ra.BLK — joined by RESORT + CONSIDERED_DATE)
        REMAINING_BLOCK_ROOMS INT         NULL,
        PICKEDUP_BLOCK_ROOMS  INT         NULL,
        -- Revenue — Gross (incl. VAT)
        GROSS_RATE          DECIMAL(18,2) NULL,
        ROOM_REVENUE        DECIMAL(18,2) NULL,
        FOOD_REVENUE        DECIMAL(18,2) NULL,
        OTHER_REVENUE       DECIMAL(18,2) NULL,
        TOTAL_REVENUE       DECIMAL(18,2) NULL,
        NON_REVENUE         DECIMAL(18,2) NULL,
        -- Revenue — Net (excl. VAT)
        NET_ROOM_REVENUE    DECIMAL(18,2) NULL,
        EXTRA_REVENUE       DECIMAL(18,2) NULL,
        -- Tax Amounts
        ROOM_REVENUE_TAX    DECIMAL(18,2) NULL,
        FOOD_REVENUE_TAX    DECIMAL(18,2) NULL,
        OTHER_REVENUE_TAX   DECIMAL(18,2) NULL,
        TOTAL_REVENUE_TAX   DECIMAL(18,2) NULL,
        NON_REVENUE_TAX     DECIMAL(18,2) NULL,
        -- Flags
        PSEUDO_ROOM_YN      CHAR(1)       NULL,
        DAY_USE_YN          CHAR(1)       NULL,
        -- Audit
        BATCH_ID            UNIQUEIDENTIFIER NULL,    -- BatchId
        LOADED_AT           DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_OTB_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY           NVARCHAR(100) NULL
            CONSTRAINT DF_ra_OTB_LoadedBy DEFAULT (SUSER_SNAME())
    );
    PRINT 'Table [ra].[OTB] created.';
END
ELSE
    PRINT 'Table [ra].[OTB] already exists — skipped.';
GO

-- OTB natural-key uniqueness: guarantees new SNAPSHOT_DATE rows accumulate
-- (never overwrite prior snapshots) while preventing dupes within a snapshot.
IF OBJECT_ID(N'ra.OTB', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'UX_ra_OTB_NaturalKey'
                     AND object_id = OBJECT_ID(N'ra.OTB'))
BEGIN
    CREATE UNIQUE INDEX UX_ra_OTB_NaturalKey
        ON ra.OTB (RESORT, SNAPSHOT_DATE, CONSIDERED_DATE, MARKET_CODE,
                   ROOM_CATEGORY_LABEL, SOURCE_CODE, CHANNEL, RATE_CODE, RESV_TYPE);
    PRINT 'Index [UX_ra_OTB_NaturalKey] created.';
END
GO

/* ---------------------------------------------------------------------
   ra.BLK — block reservations daily snapshot.
   Alias: ra.BlockReservations.
   Natural key (MERGE): RESORT + SNAPSHOT_DATE + BLOCK_CODE
                        + CONSIDERED_DATE + ROOM_CATEGORY_LABEL
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.BLK', N'U') IS NULL
BEGIN
    CREATE TABLE ra.BLK
    (
        BlkId               BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_BLK PRIMARY KEY CLUSTERED,
        -- Identity
        RESORT              NVARCHAR(20)  NOT NULL,   -- HotelCode
        CHAIN_CODE          NVARCHAR(20)  NULL,
        SNAPSHOT_DATE       DATE          NOT NULL,   -- SnapshotDate (business date of run)
        CONSIDERED_DATE     DATE          NOT NULL,   -- ConsideredDate (block stay/grid date)
        -- Block Header
        BLOCK_CODE          NVARCHAR(50)  NOT NULL,   -- BlockCode
        BLOCK_NAME          NVARCHAR(200) NULL,       -- BlockName
        ROOM_CATEGORY_LABEL NVARCHAR(20)  NULL,       -- RoomTypeLabel
        MARKET_CODE         NVARCHAR(50)  NULL,       -- MarketSegment
        SOURCE_CODE         NVARCHAR(50)  NULL,
        RATE_CODE           NVARCHAR(50)  NULL,
        RATE_CATEGORY       NVARCHAR(50)  NULL,
        CUTOFF_DATE         DATE          NULL,       -- CutoffDate
        IS_PAST_CUTOFF      BIT           NOT NULL
            CONSTRAINT DF_ra_BLK_IsPastCutoff DEFAULT (0),  -- CUTOFF_DATE < SNAPSHOT_DATE
        -- Room Counts
        ROOMS_CONTRACTED    INT           NULL,       -- RoomsContracted (blocked rooms)
        ROOMS_PICKEDUP      INT           NULL,       -- RoomsPickedUp
        ROOMS_REMAINING     INT           NULL,       -- RoomsRemaining (contracted - pickedup)
        -- Revenue — Gross
        ROOM_REVENUE        DECIMAL(18,2) NULL,
        FOOD_REVENUE        DECIMAL(18,2) NULL,
        OTHER_REVENUE       DECIMAL(18,2) NULL,
        TOTAL_REVENUE       DECIMAL(18,2) NULL,
        NON_REVENUE         DECIMAL(18,2) NULL,
        -- Revenue — Net (excl. VAT)
        NET_ROOM_REVENUE    DECIMAL(18,2) NULL,
        NET_FOOD_REVENUE    DECIMAL(18,2) NULL,
        NET_OTHER_REVENUE   DECIMAL(18,2) NULL,
        NET_TOTAL_REVENUE   DECIMAL(18,2) NULL,
        -- Tax Amounts
        ROOM_REVENUE_TAX    DECIMAL(18,2) NULL,
        FOOD_REVENUE_TAX    DECIMAL(18,2) NULL,
        OTHER_REVENUE_TAX   DECIMAL(18,2) NULL,
        TOTAL_REVENUE_TAX   DECIMAL(18,2) NULL,
        -- Audit
        BATCH_ID            UNIQUEIDENTIFIER NULL,    -- BatchId
        LOADED_AT           DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_BLK_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY           NVARCHAR(100) NULL
            CONSTRAINT DF_ra_BLK_LoadedBy DEFAULT (SUSER_SNAME())
    );
    PRINT 'Table [ra].[BLK] created.';
END
ELSE
    PRINT 'Table [ra].[BLK] already exists — skipped.';
GO

IF OBJECT_ID(N'ra.BLK', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'UX_ra_BLK_NaturalKey'
                     AND object_id = OBJECT_ID(N'ra.BLK'))
BEGIN
    CREATE UNIQUE INDEX UX_ra_BLK_NaturalKey
        ON ra.BLK (RESORT, SNAPSHOT_DATE, BLOCK_CODE, CONSIDERED_DATE, ROOM_CATEGORY_LABEL);
    PRINT 'Index [UX_ra_BLK_NaturalKey] created.';
END
GO

/* ---------------------------------------------------------------------
   ra.RMN — physical room configuration (static room list).
   Part of the RoomInventory alias (physical rooms per room category).
   Natural key (MERGE): RESORT + ROOM
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.RMN', N'U') IS NULL
BEGIN
    CREATE TABLE ra.RMN
    (
        RmnId               BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_RMN PRIMARY KEY CLUSTERED,
        RESORT              NVARCHAR(20)  NOT NULL,   -- HotelCode
        CHAIN_CODE          NVARCHAR(20)  NULL,
        ROOM                NVARCHAR(20)  NOT NULL,
        ROOM_CATEGORY_LABEL NVARCHAR(20)  NULL,       -- RoomTypeLabel
        ROOM_CLASS          NVARCHAR(50)  NULL,
        ROOM_STATUS         NVARCHAR(10)  NULL,       -- CL, DI, IP, OO, OS
        -- Audit
        BATCH_ID            UNIQUEIDENTIFIER NULL,    -- BatchId
        LOADED_AT           DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_RMN_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY           NVARCHAR(100) NULL
            CONSTRAINT DF_ra_RMN_LoadedBy DEFAULT (SUSER_SNAME())
    );
    PRINT 'Table [ra].[RMN] created.';
END
ELSE
    PRINT 'Table [ra].[RMN] already exists — skipped.';
GO

IF OBJECT_ID(N'ra.RMN', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'UX_ra_RMN_NaturalKey'
                     AND object_id = OBJECT_ID(N'ra.RMN'))
BEGIN
    CREATE UNIQUE INDEX UX_ra_RMN_NaturalKey
        ON ra.RMN (RESORT, ROOM);
    PRINT 'Index [UX_ra_RMN_NaturalKey] created.';
END
GO

/* ---------------------------------------------------------------------
   ra.OOO — daily Out-Of-Order / Out-Of-Service counts by room class.
   Part of the RoomInventory alias (InventoryDate = BUSINESS_DATE).
   Natural key (MERGE): RESORT + BUSINESS_DATE + ROOM_CLASS
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.OOO', N'U') IS NULL
BEGIN
    CREATE TABLE ra.OOO
    (
        OooId            BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_OOO PRIMARY KEY CLUSTERED,
        RESORT           NVARCHAR(20)  NOT NULL,      -- HotelCode
        CHAIN_CODE       NVARCHAR(20)  NULL,
        BUSINESS_DATE    DATE          NOT NULL,      -- InventoryDate
        ROOM_CLASS       NVARCHAR(50)  NOT NULL,
        OOO_ROOMS        INT           NULL,          -- OutOfOrder
        OS_ROOMS         INT           NULL,          -- OutOfService
        AVAIL_ROOM       INT           NULL,          -- AvailableRooms (physical - occ - OOO - OS)
        OOO_BEDS         INT           NULL,
        OS_BEDS          INT           NULL,
        PHYSICAL_BEDS    INT           NULL,          -- PhysicalRooms (bed-level physical count)
        -- Audit
        BATCH_ID         UNIQUEIDENTIFIER NULL,       -- BatchId
        LOADED_AT        DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_OOO_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY        NVARCHAR(100) NULL
            CONSTRAINT DF_ra_OOO_LoadedBy DEFAULT (SUSER_SNAME())
    );
    PRINT 'Table [ra].[OOO] created.';
END
ELSE
    PRINT 'Table [ra].[OOO] already exists — skipped.';
GO

IF OBJECT_ID(N'ra.OOO', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'UX_ra_OOO_NaturalKey'
                     AND object_id = OBJECT_ID(N'ra.OOO'))
BEGIN
    CREATE UNIQUE INDEX UX_ra_OOO_NaturalKey
        ON ra.OOO (RESORT, BUSINESS_DATE, ROOM_CLASS);
    PRINT 'Index [UX_ra_OOO_NaturalKey] created.';
END
GO
