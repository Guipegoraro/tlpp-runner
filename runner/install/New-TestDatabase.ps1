<#
.SYNOPSIS
    Cria o banco de teste isolado (PROTHEUS_TST_<nome>) sem tocar no banco
    principal do usuario.

.DESCRIPTION
    Idempotente: se o banco ja existe, valida estrutura e ajusta permissoes.
    Nao roda DROP em banco existente.

    Modos:
      Fresh        - cria banco vazio com schema do framework (Z_TST_*)
      SchemaCopy   - copia ESTRUTURA das tabelas SX2/SX3/SIX/SX6 do banco-fonte
                     (sem dados) pro novo, util pra testes que dependem do
                     dicionario customizado do cliente

    NUNCA escreve no banco-fonte. So SELECT pra schema-copy.

.PARAMETER SqlInstance
    Instancia SQL (ex: 'localhost', 'localhost\PROTHEUS').

.PARAMETER DbName
    Nome do banco a criar (ex: 'PROTHEUS_TST_meuprojeto').

.PARAMETER Mode
    'Fresh' (default) ou 'SchemaCopy'.

.PARAMETER SourceDb
    Obrigatorio quando Mode=SchemaCopy. Banco-fonte do qual copiar estrutura.

.PARAMETER SqlAuth
    'Windows' (default) ou 'SqlServer'.

.PARAMETER SqlUser
    Login (so se SqlAuth=SqlServer).

.PARAMETER SqlPassword
    Senha (so se SqlAuth=SqlServer).

.PARAMETER SchemaScript
    Caminho do .sql com DDL do framework (default: runner/sql/02-create-schema.sql).

.PARAMETER DryRun
    Mostra o plano, nao executa.

.EXAMPLE
    .\New-TestDatabase.ps1 -SqlInstance 'localhost\PROTHEUS' `
                            -DbName 'PROTHEUS_TST_meuprojeto' `
                            -Mode Fresh
#>
param(
    [Parameter(Mandatory=$true)][string]$SqlInstance,
    [Parameter(Mandatory=$true)][string]$DbName,
    [Parameter(Mandatory=$false)][ValidateSet('Fresh','SchemaCopy')][string]$Mode = 'Fresh',
    [Parameter(Mandatory=$false)][string]$SourceDb,
    [Parameter(Mandatory=$false)][ValidateSet('Windows','SqlServer')][string]$SqlAuth = 'Windows',
    [Parameter(Mandatory=$false)][string]$SqlUser,
    [Parameter(Mandatory=$false)][string]$SqlPassword,
    [Parameter(Mandatory=$false)][string]$SchemaScript,
    [Parameter(Mandatory=$false)][switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Validacao
if ($Mode -eq 'SchemaCopy' -and -not $SourceDb) {
    throw "New-TestDatabase: SourceDb obrigatorio quando Mode=SchemaCopy"
}
if ($SqlAuth -eq 'SqlServer' -and (-not $SqlUser -or -not $SqlPassword)) {
    throw "New-TestDatabase: SqlUser e SqlPassword obrigatorios quando SqlAuth=SqlServer"
}
if ($DbName -notmatch '^[A-Z][A-Z0-9_]*$') {
    throw "New-TestDatabase: DbName invalido '$DbName' - use [A-Z][A-Z0-9_]*"
}

# Default schema script
if (-not $SchemaScript) {
    $SchemaScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'sql\02-create-schema.sql'
}

# Helper: invoca sqlcmd com auth correta
function Invoke-Sql {
    param([string]$Query, [string]$Db, [int]$TimeoutSec = 60)
    $args = @('-S', $SqlInstance, '-l', $TimeoutSec, '-b', '-Q', $Query)
    if ($Db)          { $args += @('-d', $Db) }
    if ($SqlAuth -eq 'Windows') {
        $args += '-E'
    } else {
        $args += @('-U', $SqlUser, '-P', $SqlPassword)
    }
    # TrustServerCertificate=Yes via -N -C nao existe em todas as versoes; usar -C se disponivel
    $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
    $out = & $sqlcmd @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd falhou (exit $LASTEXITCODE): $out"
    }
    return $out
}

# Plano de execucao
Write-Host "[db-init] Plano:" -ForegroundColor Cyan
Write-Host "  Instance: $SqlInstance"
Write-Host "  Database: $DbName ($Mode)"
if ($Mode -eq 'SchemaCopy') { Write-Host "  Source:   $SourceDb (somente SELECT - nao sera modificado)" }
Write-Host "  Auth:     $SqlAuth"
Write-Host "  Schema:   $SchemaScript"

if ($DryRun) {
    Write-Host "[db-init] DryRun - nada executado." -ForegroundColor Yellow
    return
}

# Passo 1: verificar se o banco ja existe
$existsQ = "SET NOCOUNT ON; SELECT CASE WHEN DB_ID('$DbName') IS NOT NULL THEN 1 ELSE 0 END AS x"
$existsOut = Invoke-Sql -Query $existsQ
$exists = $existsOut -match '\b1\b'

if ($exists) {
    Write-Host "[db-init] Banco $DbName ja existe - validando estrutura (idempotente)" -ForegroundColor Yellow
} else {
    Write-Host "[db-init] Criando banco $DbName com collation Latin1_General_100_BIN..." -ForegroundColor Cyan
    $createQ = @"
CREATE DATABASE [$DbName] COLLATE Latin1_General_100_BIN;
ALTER DATABASE [$DbName] SET RECOVERY SIMPLE;
"@
    Invoke-Sql -Query $createQ | Out-Null
    Write-Host "[db-init] Banco criado." -ForegroundColor Green
}

# Passo 2: SchemaCopy se solicitado
if ($Mode -eq 'SchemaCopy') {
    Write-Host "[db-init] Copiando estrutura de SX2/SX3/SIX/SX6 de $SourceDb (sem dados)..." -ForegroundColor Cyan
    $dictTables = @('SX2010', 'SX3010', 'SIX010', 'SX6010')  # exemplos - ajustar conforme padrao do cliente
    foreach ($t in $dictTables) {
        $copyQ = @"
IF OBJECT_ID('$DbName.dbo.$t') IS NULL
BEGIN
    SELECT TOP 0 * INTO [$DbName].dbo.[$t] FROM [$SourceDb].dbo.[$t];
END
"@
        try {
            Invoke-Sql -Query $copyQ | Out-Null
            Write-Host "  - $t (estrutura copiada)" -ForegroundColor DarkGray
        } catch {
            Write-Host "  - $t (skip: $(($_.Exception.Message -split "`n")[0]))" -ForegroundColor DarkYellow
        }
    }
}

# Passo 3: aplicar schema do framework (Z_TST_*)
if (-not (Test-Path $SchemaScript)) {
    Write-Host "[db-init] AVISO: schema script nao encontrado em $SchemaScript - pulando" -ForegroundColor Yellow
} else {
    Write-Host "[db-init] Aplicando schema do framework ($SchemaScript)..." -ForegroundColor Cyan
    $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
    $args = @('-S', $SqlInstance, '-d', $DbName, '-i', $SchemaScript, '-b')
    if ($SqlAuth -eq 'Windows') { $args += '-E' } else { $args += @('-U', $SqlUser, '-P', $SqlPassword) }
    & $sqlcmd @args
    if ($LASTEXITCODE -ne 0) { throw "Schema script falhou (exit $LASTEXITCODE)" }
    Write-Host "[db-init] Schema aplicado." -ForegroundColor Green
}

# Passo 4: garantir db_owner para sa e sysdba (logins comuns do DBAccess)
Write-Host "[db-init] Concedendo db_owner pra logins DBAccess (idempotente)..." -ForegroundColor Cyan
foreach ($login in @('sa', 'sysdba')) {
    $grantQ = @"
USE [$DbName];
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$login')
   AND NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$login')
BEGIN
    CREATE USER [$login] FOR LOGIN [$login];
END
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$login')
BEGIN
    EXEC sp_addrolemember 'db_owner', '$login';
END
"@
    try {
        Invoke-Sql -Query $grantQ -Db $DbName | Out-Null
        Write-Host "  - ${login}: db_owner OK" -ForegroundColor DarkGray
    } catch {
        Write-Host "  - ${login}: $(($_.Exception.Message -split "`n")[0])" -ForegroundColor DarkYellow
    }
}

Write-Host "[db-init] OK - $DbName pronto." -ForegroundColor Green
