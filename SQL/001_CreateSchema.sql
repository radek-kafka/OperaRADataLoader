/* =====================================================================
   OPERA R&A Data Loader — 001_CreateSchema.sql
   Purpose : Create the 'ra' schema that owns all reporting/analytics tables.
             Operational logging (dbo.LoadLog) intentionally lives in dbo.
   Target  : Microsoft SQL Server (T-SQL)
   Notes   : Idempotent — safe to re-run. Guarded with IF NOT EXISTS.
             CREATE SCHEMA must be the first statement in its batch, so it is
             executed via EXEC() inside the guard.

   -- GenAI-generated code — reviewed and approved by: <name> <date>
   ===================================================================== */

SET NOCOUNT ON;
GO

-- ---------------------------------------------------------------------
-- Schema: ra  (all analytics/reporting tables: RES, FIN, OTB, BLK,
--              RMN, OOO, DIM_* dimensions, Hotels)
-- Schema: dbo (used for the operational LoadLog table only)
-- ---------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'ra')
BEGIN
    EXEC('CREATE SCHEMA ra');
    PRINT 'Schema [ra] created.';
END
ELSE
BEGIN
    PRINT 'Schema [ra] already exists — skipped.';
END
GO
