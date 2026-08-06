-- =====================================================================
-- tlpp-runner - reset de dados de teste
-- Trunca todas as tabelas Z_TST_*
--
-- O banco-destino vem do parametro -d do sqlcmd (db-setup.ps1 passa
-- -d PROTHEUS_TST). NAO use USE aqui - mesma razao do 02-create-schema.sql:
-- amarrar o banco no script impede reaproveita-lo em PROTHEUS_TST_<projeto>.
-- =====================================================================

DECLARE @sql NVARCHAR(MAX) = '';

SELECT @sql = @sql + 'TRUNCATE TABLE dbo.' + QUOTENAME(t.name) + ';' + CHAR(13)
FROM sys.tables t
WHERE t.name LIKE 'Z\_TST\_%' ESCAPE '\';

IF LEN(@sql) > 0
BEGIN
    PRINT 'Truncando tabelas:';
    PRINT @sql;
    EXEC sp_executesql @sql;
END
ELSE
BEGIN
    PRINT 'Nenhuma tabela Z_TST_* encontrada';
END
GO
