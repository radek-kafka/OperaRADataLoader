/* =====================================================================
   OPERA R&A Data Loader — 005_CreateIndexes.sql
   Purpose : Create secondary (non-unique) performance indexes to support
             common query, join and MERGE-lookup patterns:
               - RESORT (HotelCode) filtering
               - date columns: BUSINESS_DATE / SNAPSHOT_DATE / CONSIDERED_DATE
                 / InventoryDate (BUSINESS_DATE on ra.OOO)
               - BATCH_ID (batch/run lookups)
               - RESV_NAME_ID (RES <-> FIN join)
               - TRX_CODE (FIN <-> DIM_TrxCodes join)
               - IS_CURRENT (SCD2 current-version filtering)
   Target  : Microsoft SQL Server (T-SQL)
   Depends : 001–004 (schema + all tables)
   Notes   : Idempotent — each index guarded with
             IF NOT EXISTS (sys.indexes ...) so re-runs are safe.
             The UNIQUE natural-key indexes/constraints are defined in
             002/003/004 alongside the tables; this file adds the
             supporting non-unique indexes only.

   -- GenAI-generated code — reviewed and approved by: <name> <date>
   ===================================================================== */

SET NOCOUNT ON;
GO

/* ============================ dbo.LoadLog ============================ */
IF OBJECT_ID(N'dbo.LoadLog', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_LoadLog_Batch' AND object_id = OBJECT_ID(N'dbo.LoadLog'))
    CREATE INDEX IX_LoadLog_Batch ON dbo.LoadLog (BatchId);
GO
IF OBJECT_ID(N'dbo.LoadLog', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_LoadLog_Hotel_Query' AND object_id = OBJECT_ID(N'dbo.LoadLog'))
    CREATE INDEX IX_LoadLog_Hotel_Query ON dbo.LoadLog (HotelCode, QueryType, StartTime);
GO

/* ============================== ra.RES ============================== */
IF OBJECT_ID(N'ra.RES', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_RES_Hotel_BusinessDate' AND object_id = OBJECT_ID(N'ra.RES'))
    CREATE INDEX IX_ra_RES_Hotel_BusinessDate ON ra.RES (RESORT, BUSINESS_DATE);
GO
IF OBJECT_ID(N'ra.RES', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_RES_ResvNameId' AND object_id = OBJECT_ID(N'ra.RES'))
    CREATE INDEX IX_ra_RES_ResvNameId ON ra.RES (RESV_NAME_ID);
GO
IF OBJECT_ID(N'ra.RES', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_RES_Batch' AND object_id = OBJECT_ID(N'ra.RES'))
    CREATE INDEX IX_ra_RES_Batch ON ra.RES (BATCH_ID);
GO

/* ============================== ra.FIN ============================== */
IF OBJECT_ID(N'ra.FIN', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_FIN_Hotel_BusinessDate' AND object_id = OBJECT_ID(N'ra.FIN'))
    CREATE INDEX IX_ra_FIN_Hotel_BusinessDate ON ra.FIN (RESORT, BUSINESS_DATE);
GO
IF OBJECT_ID(N'ra.FIN', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_FIN_ResvNameId' AND object_id = OBJECT_ID(N'ra.FIN'))
    CREATE INDEX IX_ra_FIN_ResvNameId ON ra.FIN (RESV_NAME_ID);
GO
IF OBJECT_ID(N'ra.FIN', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_FIN_TrxCode' AND object_id = OBJECT_ID(N'ra.FIN'))
    CREATE INDEX IX_ra_FIN_TrxCode ON ra.FIN (TRX_CODE);
GO
IF OBJECT_ID(N'ra.FIN', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_FIN_Batch' AND object_id = OBJECT_ID(N'ra.FIN'))
    CREATE INDEX IX_ra_FIN_Batch ON ra.FIN (BATCH_ID);
GO

/* ============================== ra.OTB ============================== */
IF OBJECT_ID(N'ra.OTB', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_OTB_Hotel_Snapshot' AND object_id = OBJECT_ID(N'ra.OTB'))
    CREATE INDEX IX_ra_OTB_Hotel_Snapshot ON ra.OTB (RESORT, SNAPSHOT_DATE);
GO
IF OBJECT_ID(N'ra.OTB', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_OTB_Considered' AND object_id = OBJECT_ID(N'ra.OTB'))
    CREATE INDEX IX_ra_OTB_Considered ON ra.OTB (RESORT, CONSIDERED_DATE);
GO
IF OBJECT_ID(N'ra.OTB', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_OTB_Batch' AND object_id = OBJECT_ID(N'ra.OTB'))
    CREATE INDEX IX_ra_OTB_Batch ON ra.OTB (BATCH_ID);
GO

/* ============================== ra.BLK ============================== */
IF OBJECT_ID(N'ra.BLK', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_BLK_Hotel_Snapshot' AND object_id = OBJECT_ID(N'ra.BLK'))
    CREATE INDEX IX_ra_BLK_Hotel_Snapshot ON ra.BLK (RESORT, SNAPSHOT_DATE);
GO
IF OBJECT_ID(N'ra.BLK', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_BLK_Considered' AND object_id = OBJECT_ID(N'ra.BLK'))
    CREATE INDEX IX_ra_BLK_Considered ON ra.BLK (RESORT, CONSIDERED_DATE);
GO
IF OBJECT_ID(N'ra.BLK', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_BLK_Batch' AND object_id = OBJECT_ID(N'ra.BLK'))
    CREATE INDEX IX_ra_BLK_Batch ON ra.BLK (BATCH_ID);
GO

/* ============================== ra.RMN ============================== */
IF OBJECT_ID(N'ra.RMN', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_RMN_Hotel' AND object_id = OBJECT_ID(N'ra.RMN'))
    CREATE INDEX IX_ra_RMN_Hotel ON ra.RMN (RESORT);
GO
IF OBJECT_ID(N'ra.RMN', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_RMN_Batch' AND object_id = OBJECT_ID(N'ra.RMN'))
    CREATE INDEX IX_ra_RMN_Batch ON ra.RMN (BATCH_ID);
GO

/* ============================== ra.OOO ============================== */
-- InventoryDate == BUSINESS_DATE on ra.OOO
IF OBJECT_ID(N'ra.OOO', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_OOO_Hotel_InventoryDate' AND object_id = OBJECT_ID(N'ra.OOO'))
    CREATE INDEX IX_ra_OOO_Hotel_InventoryDate ON ra.OOO (RESORT, BUSINESS_DATE);
GO
IF OBJECT_ID(N'ra.OOO', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_OOO_Batch' AND object_id = OBJECT_ID(N'ra.OOO'))
    CREATE INDEX IX_ra_OOO_Batch ON ra.OOO (BATCH_ID);
GO

/* ===================== Master / Dimension tables ===================== */
-- Current-version lookups (IS_CURRENT) + code lookups per hotel.

/* ra.DIM_TrxCodes */
IF OBJECT_ID(N'ra.DIM_TrxCodes', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_DIM_TrxCodes_Current' AND object_id = OBJECT_ID(N'ra.DIM_TrxCodes'))
    CREATE INDEX IX_ra_DIM_TrxCodes_Current ON ra.DIM_TrxCodes (RESORT, TRX_CODE, IS_CURRENT);
GO

/* ra.DIM_RoomTypes */
IF OBJECT_ID(N'ra.DIM_RoomTypes', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_DIM_RoomTypes_Current' AND object_id = OBJECT_ID(N'ra.DIM_RoomTypes'))
    CREATE INDEX IX_ra_DIM_RoomTypes_Current ON ra.DIM_RoomTypes (RESORT, ROOM_CATEGORY_LABEL, IS_CURRENT);
GO

/* ra.DIM_MarketCodes */
IF OBJECT_ID(N'ra.DIM_MarketCodes', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_DIM_MarketCodes_Current' AND object_id = OBJECT_ID(N'ra.DIM_MarketCodes'))
    CREATE INDEX IX_ra_DIM_MarketCodes_Current ON ra.DIM_MarketCodes (RESORT, CODE, IS_CURRENT);
GO

/* ra.DIM_RateCodes */
IF OBJECT_ID(N'ra.DIM_RateCodes', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_DIM_RateCodes_Current' AND object_id = OBJECT_ID(N'ra.DIM_RateCodes'))
    CREATE INDEX IX_ra_DIM_RateCodes_Current ON ra.DIM_RateCodes (RESORT, CODE, IS_CURRENT);
GO

/* ra.DIM_SourceCodes */
IF OBJECT_ID(N'ra.DIM_SourceCodes', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_DIM_SourceCodes_Current' AND object_id = OBJECT_ID(N'ra.DIM_SourceCodes'))
    CREATE INDEX IX_ra_DIM_SourceCodes_Current ON ra.DIM_SourceCodes (RESORT, CODE, IS_CURRENT);
GO

/* ra.DIM_Channels */
IF OBJECT_ID(N'ra.DIM_Channels', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_DIM_Channels_Current' AND object_id = OBJECT_ID(N'ra.DIM_Channels'))
    CREATE INDEX IX_ra_DIM_Channels_Current ON ra.DIM_Channels (RESORT, CODE, IS_CURRENT);
GO

/* ra.Hotels */
IF OBJECT_ID(N'ra.Hotels', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_ra_Hotels_Chain' AND object_id = OBJECT_ID(N'ra.Hotels'))
    CREATE INDEX IX_ra_Hotels_Chain ON ra.Hotels (CHAIN_CODE);
GO
