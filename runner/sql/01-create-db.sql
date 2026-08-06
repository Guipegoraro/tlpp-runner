-- =====================================================================
-- tlpp-runner - cria database de teste PROTHEUS_TST
-- Idempotente: pode ser executado varias vezes
-- =====================================================================

USE master;
GO

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'PROTHEUS_TST')
BEGIN
    PRINT 'Criando database PROTHEUS_TST...';
    CREATE DATABASE PROTHEUS_TST
        COLLATE Latin1_General_100_BIN;
END
ELSE
BEGIN
    PRINT 'Database PROTHEUS_TST ja existe';
END
GO

ALTER DATABASE PROTHEUS_TST SET RECOVERY SIMPLE;
GO

PRINT '';
PRINT 'Database PROTHEUS_TST:';
SELECT name, state_desc, recovery_model_desc, collation_name
FROM sys.databases
WHERE name = 'PROTHEUS_TST';
GO
