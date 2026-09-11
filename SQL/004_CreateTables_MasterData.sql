/* =====================================================================
   OPERA R&A Data Loader — 004_CreateTables_MasterData.sql
   Purpose : Create the seven master / dimension tables (SCD Type 2):
               ra.DIM_TrxCodes     (financial transaction codes)
               ra.DIM_RoomTypes    (room type labels)
               ra.DIM_MarketCodes  (market segment)         [MarketSegments]
               ra.DIM_RateCodes    (rate codes)
               ra.DIM_SourceCodes  (source of reservation)  [PRIORITY/required]
               ra.DIM_Channels     (distribution channel)   [OPTIONAL, separate]
               ra.Hotels           (property configuration)
   Target  : Microsoft SQL Server (T-SQL)
   Depends : 001_CreateSchema.sql (schema 'ra')
   Notes   : Idempotent — safe to re-run. Each object guarded with
             IF OBJECT_ID(...) IS NULL. These are the MERGE targets for
             SqlWriter.psm1 Write-MasterData (Write-DIM) SCD2 logic.

   ---------------------------------------------------------------------
   DIM_* NAMING RECONCILIATION (IMPORTANT — single consistent target):
     tasks.md's script-004 summary line lists the friendlier aliases
       ra.MarketSegments / ra.ReservationSources / ra.Channels,
     but the authoritative master-data mapping tasks (Task 13) and design.md
     specify the DIM_* names. This script uses the DIM_* names as the single
     canonical MERGE target so downstream Write-MasterData tasks are unambiguous:
       ra.MarketSegments      == ra.DIM_MarketCodes   (market segment)
       ra.ReservationSources  == ra.DIM_SourceCodes   (source of reservation)
       ra.Channels            == ra.DIM_Channels       (distribution channel)
     SourceCodes and Channels are TWO INDEPENDENT lists and are NEVER merged:
       - DIM_SourceCodes = SOURCE OF RESERVATION (booking origin). REQUIRED.
       - DIM_Channels    = DISTRIBUTION CHANNEL (GDS/OTA/Direct/Web/CRO). OPTIONAL.

   SCD Type 2 columns on every dimension:
       VALID_FROM  DATE NOT NULL           (EffectiveFrom)
       VALID_TO    DATE NULL               (EffectiveTo — NULL = open/current)
       IS_CURRENT  BIT  NOT NULL DEFAULT 1 (IsCurrent)
   Natural key for SCD2 MERGE: RESORT + <code column> + VALID_FROM

   COLUMN ALIASES (business name -> authoritative column):
       HotelCode                 -> RESORT
       ChainCode                 -> CHAIN_CODE
       TrxCode                   -> TRX_CODE
       TrxName                   -> TRX_NAME
       TrxGroup                  -> TC_GROUP
       TrxType                   -> TC_SUBGROUP
       RevenueYN                 -> REVENUE_YN
       IncludedInRoomRevenueYN   -> ROOM_REVENUE_YN
       IncludedInPackageYN       -> PACKAGE_YN
       IsActive                  -> IS_ACTIVE
       RoomTypeLabel             -> ROOM_CATEGORY_LABEL
       Description               -> DESCRIPTION
       RoomClass                 -> ROOM_CLASS
       PhysicalRoomCount         -> PHYSICAL_ROOM_COUNT
       Code                      -> CODE
       RateCategory              -> RATE_CATEGORY
       SegmentGroup              -> SEGMENT_GROUP

   -- GenAI-generated code — reviewed and approved by: <name> <date>
   ===================================================================== */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   ra.DIM_TrxCodes — financial transaction codes (SCD Type 2).
   Natural key: RESORT + TRX_CODE + VALID_FROM
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.DIM_TrxCodes', N'U') IS NULL
BEGIN
    CREATE TABLE ra.DIM_TrxCodes
    (
        TrxCodeKey       BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_DIM_TrxCodes PRIMARY KEY CLUSTERED,
        RESORT           NVARCHAR(20)  NOT NULL,      -- HotelCode
        CHAIN_CODE       NVARCHAR(20)  NULL,
        TRX_CODE         NVARCHAR(20)  NOT NULL,      -- TrxCode
        TRX_NAME         NVARCHAR(200) NULL,          -- TrxName (description)
        TC_GROUP         NVARCHAR(100) NULL,          -- TrxGroup (ROOM, FB, PAY, TAX, PKG, MISC)
        TC_SUBGROUP      NVARCHAR(100) NULL,          -- TrxType (100, 200, TAX4, PKG)
        FT_SUBTYPE       NVARCHAR(10)  NULL,          -- C / FC (hardcoded per group)
        REVENUE_YN       CHAR(1)       NOT NULL
            CONSTRAINT DF_ra_DIM_TrxCodes_RevenueYN DEFAULT ('N'),           -- RevenueYN
        ROOM_REVENUE_YN  CHAR(1)       NOT NULL
            CONSTRAINT DF_ra_DIM_TrxCodes_RoomRevenueYN DEFAULT ('N'),       -- IncludedInRoomRevenueYN
        PACKAGE_YN       CHAR(1)       NOT NULL
            CONSTRAINT DF_ra_DIM_TrxCodes_PackageYN DEFAULT ('N'),           -- IncludedInPackageYN
        IS_ACTIVE        BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_TrxCodes_IsActive DEFAULT (1),              -- IsActive
        FLAG             CHAR(1)       NOT NULL
            CONSTRAINT DF_ra_DIM_TrxCodes_Flag DEFAULT ('N'),                -- N=active Y=deleted
        VALID_FROM       DATE          NOT NULL
            CONSTRAINT DF_ra_DIM_TrxCodes_ValidFrom DEFAULT (CAST(SYSUTCDATETIME() AS DATE)),
        VALID_TO         DATE          NULL,
        IS_CURRENT       BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_TrxCodes_IsCurrent DEFAULT (1),
        -- Audit
        BATCH_ID         UNIQUEIDENTIFIER NULL,
        LOADED_AT        DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_DIM_TrxCodes_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY        NVARCHAR(100) NULL
            CONSTRAINT DF_ra_DIM_TrxCodes_LoadedBy DEFAULT (SUSER_SNAME()),
        CONSTRAINT UX_ra_DIM_TrxCodes_NK UNIQUE (RESORT, TRX_CODE, VALID_FROM)
    );
    PRINT 'Table [ra].[DIM_TrxCodes] created.';
END
ELSE
    PRINT 'Table [ra].[DIM_TrxCodes] already exists — skipped.';
GO

/* ---------------------------------------------------------------------
   ra.DIM_RoomTypes — room type labels (SCD Type 2).
   Natural key: RESORT + ROOM_CATEGORY_LABEL + VALID_FROM
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.DIM_RoomTypes', N'U') IS NULL
BEGIN
    CREATE TABLE ra.DIM_RoomTypes
    (
        RoomTypeKey         BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_DIM_RoomTypes PRIMARY KEY CLUSTERED,
        RESORT              NVARCHAR(20)  NOT NULL,   -- HotelCode
        CHAIN_CODE          NVARCHAR(20)  NULL,
        ROOM_CATEGORY_LABEL NVARCHAR(20)  NOT NULL,   -- RoomTypeLabel (e.g. DB1, DS1, WB1)
        DESCRIPTION         NVARCHAR(200) NULL,       -- Description
        ROOM_CLASS          NVARCHAR(50)  NULL,       -- RoomClass
        PHYSICAL_ROOM_COUNT INT           NULL,       -- PhysicalRoomCount
        IS_ACTIVE           BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_RoomTypes_IsActive DEFAULT (1),
        FLAG                CHAR(1)       NOT NULL
            CONSTRAINT DF_ra_DIM_RoomTypes_Flag DEFAULT ('N'),
        VALID_FROM          DATE          NOT NULL
            CONSTRAINT DF_ra_DIM_RoomTypes_ValidFrom DEFAULT (CAST(SYSUTCDATETIME() AS DATE)),
        VALID_TO            DATE          NULL,
        IS_CURRENT          BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_RoomTypes_IsCurrent DEFAULT (1),
        -- Audit
        BATCH_ID            UNIQUEIDENTIFIER NULL,
        LOADED_AT           DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_DIM_RoomTypes_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY           NVARCHAR(100) NULL
            CONSTRAINT DF_ra_DIM_RoomTypes_LoadedBy DEFAULT (SUSER_SNAME()),
        CONSTRAINT UX_ra_DIM_RoomTypes_NK UNIQUE (RESORT, ROOM_CATEGORY_LABEL, VALID_FROM)
    );
    PRINT 'Table [ra].[DIM_RoomTypes] created.';
END
ELSE
    PRINT 'Table [ra].[DIM_RoomTypes] already exists — skipped.';
GO

/* ---------------------------------------------------------------------
   ra.DIM_MarketCodes — market segment (SCD Type 2).  [alias: ra.MarketSegments]
   Natural key: RESORT + CODE + VALID_FROM
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.DIM_MarketCodes', N'U') IS NULL
BEGIN
    CREATE TABLE ra.DIM_MarketCodes
    (
        MarketCodeKey    BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_DIM_MarketCodes PRIMARY KEY CLUSTERED,
        RESORT           NVARCHAR(20)  NOT NULL,      -- HotelCode
        CHAIN_CODE       NVARCHAR(20)  NULL,
        CODE             NVARCHAR(50)  NOT NULL,      -- Code (MARKETCODE)
        DESCRIPTION      NVARCHAR(200) NULL,          -- Description
        SEGMENT_GROUP    NVARCHAR(100) NULL,          -- SegmentGroup
        IS_ACTIVE        BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_MarketCodes_IsActive DEFAULT (1),
        FLAG             CHAR(1)       NOT NULL
            CONSTRAINT DF_ra_DIM_MarketCodes_Flag DEFAULT ('N'),
        VALID_FROM       DATE          NOT NULL
            CONSTRAINT DF_ra_DIM_MarketCodes_ValidFrom DEFAULT (CAST(SYSUTCDATETIME() AS DATE)),
        VALID_TO         DATE          NULL,
        IS_CURRENT       BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_MarketCodes_IsCurrent DEFAULT (1),
        -- Audit
        BATCH_ID         UNIQUEIDENTIFIER NULL,
        LOADED_AT        DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_DIM_MarketCodes_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY        NVARCHAR(100) NULL
            CONSTRAINT DF_ra_DIM_MarketCodes_LoadedBy DEFAULT (SUSER_SNAME()),
        CONSTRAINT UX_ra_DIM_MarketCodes_NK UNIQUE (RESORT, CODE, VALID_FROM)
    );
    PRINT 'Table [ra].[DIM_MarketCodes] created.';
END
ELSE
    PRINT 'Table [ra].[DIM_MarketCodes] already exists — skipped.';
GO

/* ---------------------------------------------------------------------
   ra.DIM_RateCodes — rate codes (SCD Type 2).
   Natural key: RESORT + CODE + VALID_FROM
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.DIM_RateCodes', N'U') IS NULL
BEGIN
    CREATE TABLE ra.DIM_RateCodes
    (
        RateCodeKey      BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_DIM_RateCodes PRIMARY KEY CLUSTERED,
        RESORT           NVARCHAR(20)  NOT NULL,      -- HotelCode
        CHAIN_CODE       NVARCHAR(20)  NULL,
        CODE             NVARCHAR(50)  NOT NULL,      -- Code (RATE_CODE)
        DESCRIPTION      NVARCHAR(200) NULL,          -- Description
        RATE_CATEGORY    NVARCHAR(100) NULL,          -- RateCategory
        RATE_CLASS       NVARCHAR(100) NULL,
        IS_ACTIVE        BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_RateCodes_IsActive DEFAULT (1),
        FLAG             CHAR(1)       NOT NULL
            CONSTRAINT DF_ra_DIM_RateCodes_Flag DEFAULT ('N'),
        VALID_FROM       DATE          NOT NULL
            CONSTRAINT DF_ra_DIM_RateCodes_ValidFrom DEFAULT (CAST(SYSUTCDATETIME() AS DATE)),
        VALID_TO         DATE          NULL,
        IS_CURRENT       BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_RateCodes_IsCurrent DEFAULT (1),
        -- Audit
        BATCH_ID         UNIQUEIDENTIFIER NULL,
        LOADED_AT        DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_DIM_RateCodes_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY        NVARCHAR(100) NULL
            CONSTRAINT DF_ra_DIM_RateCodes_LoadedBy DEFAULT (SUSER_SNAME()),
        CONSTRAINT UX_ra_DIM_RateCodes_NK UNIQUE (RESORT, CODE, VALID_FROM)
    );
    PRINT 'Table [ra].[DIM_RateCodes] created.';
END
ELSE
    PRINT 'Table [ra].[DIM_RateCodes] already exists — skipped.';
GO

/* ---------------------------------------------------------------------
   ra.DIM_SourceCodes — SOURCE OF RESERVATION (SCD Type 2).
   [alias: ra.ReservationSources]  *** PRIORITY / REQUIRED dimension ***
   INDEPENDENT from ra.DIM_Channels — never merged.
   Natural key: RESORT + CODE + VALID_FROM
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.DIM_SourceCodes', N'U') IS NULL
BEGIN
    CREATE TABLE ra.DIM_SourceCodes
    (
        SourceCodeKey    BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_DIM_SourceCodes PRIMARY KEY CLUSTERED,
        RESORT           NVARCHAR(20)  NOT NULL,      -- HotelCode
        CHAIN_CODE       NVARCHAR(20)  NULL,
        CODE             NVARCHAR(50)  NOT NULL,      -- Code (SOURCE_CODE — booking origin)
        DESCRIPTION      NVARCHAR(200) NULL,          -- Description
        IS_ACTIVE        BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_SourceCodes_IsActive DEFAULT (1),
        FLAG             CHAR(1)       NOT NULL
            CONSTRAINT DF_ra_DIM_SourceCodes_Flag DEFAULT ('N'),
        VALID_FROM       DATE          NOT NULL
            CONSTRAINT DF_ra_DIM_SourceCodes_ValidFrom DEFAULT (CAST(SYSUTCDATETIME() AS DATE)),
        VALID_TO         DATE          NULL,
        IS_CURRENT       BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_SourceCodes_IsCurrent DEFAULT (1),
        -- Audit
        BATCH_ID         UNIQUEIDENTIFIER NULL,
        LOADED_AT        DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_DIM_SourceCodes_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY        NVARCHAR(100) NULL
            CONSTRAINT DF_ra_DIM_SourceCodes_LoadedBy DEFAULT (SUSER_SNAME()),
        CONSTRAINT UX_ra_DIM_SourceCodes_NK UNIQUE (RESORT, CODE, VALID_FROM)
    );
    PRINT 'Table [ra].[DIM_SourceCodes] created.';
END
ELSE
    PRINT 'Table [ra].[DIM_SourceCodes] already exists — skipped.';
GO

/* ---------------------------------------------------------------------
   ra.DIM_Channels — DISTRIBUTION CHANNEL (SCD Type 2).
   [alias: ra.Channels]  *** OPTIONAL / best-effort dimension ***
   INDEPENDENT from ra.DIM_SourceCodes — never merged. (GDS/OTA/Direct/Web/CRO)
   Natural key: RESORT + CODE + VALID_FROM
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.DIM_Channels', N'U') IS NULL
BEGIN
    CREATE TABLE ra.DIM_Channels
    (
        ChannelKey       BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_DIM_Channels PRIMARY KEY CLUSTERED,
        RESORT           NVARCHAR(20)  NOT NULL,      -- HotelCode
        CHAIN_CODE       NVARCHAR(20)  NULL,
        CODE             NVARCHAR(50)  NOT NULL,      -- Code (CHANNEL — distribution channel)
        DESCRIPTION      NVARCHAR(200) NULL,          -- Description
        IS_ACTIVE        BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_Channels_IsActive DEFAULT (1),
        FLAG             CHAR(1)       NOT NULL
            CONSTRAINT DF_ra_DIM_Channels_Flag DEFAULT ('N'),
        VALID_FROM       DATE          NOT NULL
            CONSTRAINT DF_ra_DIM_Channels_ValidFrom DEFAULT (CAST(SYSUTCDATETIME() AS DATE)),
        VALID_TO         DATE          NULL,
        IS_CURRENT       BIT           NOT NULL
            CONSTRAINT DF_ra_DIM_Channels_IsCurrent DEFAULT (1),
        -- Audit
        BATCH_ID         UNIQUEIDENTIFIER NULL,
        LOADED_AT        DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_DIM_Channels_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY        NVARCHAR(100) NULL
            CONSTRAINT DF_ra_DIM_Channels_LoadedBy DEFAULT (SUSER_SNAME()),
        CONSTRAINT UX_ra_DIM_Channels_NK UNIQUE (RESORT, CODE, VALID_FROM)
    );
    PRINT 'Table [ra].[DIM_Channels] created.';
END
ELSE
    PRINT 'Table [ra].[DIM_Channels] already exists — skipped.';
GO

/* ---------------------------------------------------------------------
   ra.Hotels — property configuration master.
   Natural key: RESORT (one current row per hotel).
   Note: this master carries a UNIQUE RESORT (not SCD2 versioned per design.md).
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'ra.Hotels', N'U') IS NULL
BEGIN
    CREATE TABLE ra.Hotels
    (
        HotelKey         BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ra_Hotels PRIMARY KEY CLUSTERED,
        RESORT           NVARCHAR(20)  NOT NULL,      -- HotelCode
        CHAIN_CODE       NVARCHAR(20)  NULL,
        DISPLAY_NAME     NVARCHAR(200) NULL,
        CITY             NVARCHAR(100) NULL,
        COUNTRY          NVARCHAR(50)  NULL,
        CURRENCY_CODE    NVARCHAR(10)  NULL,
        TIME_ZONE_ID     NVARCHAR(100) NULL,
        NIGHT_AUDIT_HOUR TINYINT       NULL,
        NIGHT_AUDIT_MIN  TINYINT       NULL,
        IS_ACTIVE        BIT           NOT NULL
            CONSTRAINT DF_ra_Hotels_IsActive DEFAULT (1),
        -- Audit
        BATCH_ID         UNIQUEIDENTIFIER NULL,
        LOADED_AT        DATETIME2(3)  NOT NULL
            CONSTRAINT DF_ra_Hotels_LoadedAt DEFAULT (SYSUTCDATETIME()),
        LOADED_BY        NVARCHAR(100) NULL
            CONSTRAINT DF_ra_Hotels_LoadedBy DEFAULT (SUSER_SNAME()),
        CONSTRAINT UX_ra_Hotels_Resort UNIQUE (RESORT)
    );
    PRINT 'Table [ra].[Hotels] created.';
END
ELSE
    PRINT 'Table [ra].[Hotels] already exists — skipped.';
GO
