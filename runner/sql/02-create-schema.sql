-- =====================================================================
-- tlpp-runner - schema basico para testes de integracao
-- Tabelas Z_TST_* com prefixo para indicar que sao de teste
--
-- O banco-destino vem do parametro -d do sqlcmd (chamado por
-- New-TestDatabase.ps1 com -d PROTHEUS_TST_<projeto>). NAO use USE aqui -
-- senao todas as tabelas vao parar no banco errado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Z_TST_CLIENTE - mock simplificado de SA1 para testes
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.Z_TST_CLIENTE', 'U') IS NULL
BEGIN
    PRINT 'Criando Z_TST_CLIENTE...';
    CREATE TABLE dbo.Z_TST_CLIENTE (
        R_E_C_N_O_  INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        A1_FILIAL   CHAR(2)     NOT NULL DEFAULT '01',
        A1_COD      CHAR(6)     NOT NULL,
        A1_LOJA     CHAR(2)     NOT NULL DEFAULT '01',
        A1_CGC      CHAR(14)    NOT NULL,
        A1_NOME     CHAR(40)    NOT NULL,
        A1_NREDUZ   CHAR(20)    NULL,
        D_E_L_E_T_  CHAR(1)     NOT NULL DEFAULT ''
    );
    CREATE INDEX IX_Z_TST_CLIENTE_CGC ON dbo.Z_TST_CLIENTE (A1_FILIAL, A1_CGC, D_E_L_E_T_);
    CREATE INDEX IX_Z_TST_CLIENTE_COD ON dbo.Z_TST_CLIENTE (A1_FILIAL, A1_COD, A1_LOJA, D_E_L_E_T_);
END
ELSE
    PRINT 'Z_TST_CLIENTE ja existe';
GO

-- ---------------------------------------------------------------------
-- Z_TST_PEDIDO - exemplo cabeca de pedido (estilo SC5)
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.Z_TST_PEDIDO', 'U') IS NULL
BEGIN
    PRINT 'Criando Z_TST_PEDIDO...';
    CREATE TABLE dbo.Z_TST_PEDIDO (
        R_E_C_N_O_  INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        C5_FILIAL   CHAR(2)     NOT NULL DEFAULT '01',
        C5_NUM      CHAR(6)     NOT NULL,
        C5_CLIENTE  CHAR(6)     NOT NULL,
        C5_LOJA     CHAR(2)     NOT NULL DEFAULT '01',
        C5_EMISSAO  CHAR(8)     NOT NULL,
        C5_VLRTOT   NUMERIC(14,2) NOT NULL DEFAULT 0,
        C5_VLRDESC  NUMERIC(14,2) NOT NULL DEFAULT 0,
        D_E_L_E_T_  CHAR(1)     NOT NULL DEFAULT ''
    );
    CREATE INDEX IX_Z_TST_PEDIDO_NUM ON dbo.Z_TST_PEDIDO (C5_FILIAL, C5_NUM, D_E_L_E_T_);
END
ELSE
    PRINT 'Z_TST_PEDIDO ja existe';
GO

PRINT '';
PRINT 'Tabelas Z_TST_* no banco corrente:';
SELECT t.name, p.rows AS row_count
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name LIKE 'Z\_TST\_%' ESCAPE '\'
ORDER BY t.name;
GO
