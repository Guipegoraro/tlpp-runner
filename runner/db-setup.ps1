<#
.SYNOPSIS
    Cria e configura o database de teste (PROTHEUS_TST ou o do projeto) para integracao.

.DESCRIPTION
    Executa os scripts SQL do framework (runner/sql/ do plugin) e, se existir,
    o schema versionado do PROJETO ($TlppRunner.SchemaPath, ver issue #21) via
    sqlcmd. Usa autenticacao Windows (-E). Idempotente.

    O banco-alvo vem do cascade ($TlppRunner.TestDb): PROTHEUS_TST no repo dev,
    PROTHEUS_TST_<NOME> em projeto consumidor com .tlpp-tdd.json. O banco de
    projeto e criado pelo /tlpp-tdd-project-init - aqui so o PROTHEUS_TST base
    e criado (01-create-db.sql e hardcoded nele).

.PARAMETER Instance
    Instancia SQL. Default: lido de runner.config.ps1 ($TlppRunner.SqlInstance)

.PARAMETER Reset
    Apos criar/garantir o schema, trunca todos os dados de teste (Z_TST_*).

.PARAMETER ProjectRoot
    Override do diretorio do projeto. Default: $env:CLAUDE_PROJECT_DIR ou cwd.

.EXAMPLE
    .\db-setup.ps1
    .\db-setup.ps1 -Reset
    .\db-setup.ps1 -Instance "localhost\OUTRA_INSTANCIA"
    .\db-setup.ps1 -ProjectRoot C:\projetos\meu-projeto
#>
param(
    [Parameter(Mandatory=$false)][string]$Instance,
    [Parameter(Mandatory=$false)][switch]$Reset,
    [Parameter(Mandatory=$false)][string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'

# Override ANTES do dot-source: a cascata le o .tlpp-tdd.json durante o load
# (mesma pegadinha do -ProjectRoot em Invoke-TlppBuild/Runner, PR #31).
if ($ProjectRoot) { $TlppProjectRootOverride = (Resolve-Path $ProjectRoot).Path }
. (Join-Path $PSScriptRoot 'runner.config.ps1')
$cfg = $TlppRunner

if (-not $Instance) { $Instance = $cfg.SqlInstance }

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Error "sqlcmd nao encontrado no PATH. Instale o Microsoft Command Line Utilities for SQL Server."
    exit 99
}

$sqlDir   = Join-Path $PSScriptRoot 'sql'
$targetDb = $cfg.TestDb

# Database: cada `sqlcmd -i` e uma CONEXAO NOVA, entao o contexto nao atravessa
# scripts - quem precisa de banco-destino recebe `-d`. O 01 tem `USE master`
# proprio (cria o banco) e roda sem `-d`; o 02 perdeu o `USE PROTHEUS_TST`
# hardcoded pra poder servir tambem ao New-TestDatabase.ps1 (que passa
# `-d PROTHEUS_TST_<projeto>`), entao AQUI ele precisa do `-d` explicito. Sem
# isso as Z_TST_* iam para o banco default do login (tipicamente master).
$scripts = @()
if ($targetDb -eq 'PROTHEUS_TST') {
    # So o banco base e criavel aqui; banco de projeto e do /tlpp-tdd-project-init
    $scripts += @{ Name = 'create-db'; File = (Join-Path $sqlDir '01-create-db.sql'); Database = $null }
}
$scripts += @{ Name = 'create-schema'; File = (Join-Path $sqlDir '02-create-schema.sql'); Database = $targetDb }
if ($Reset) {
    $scripts += @{ Name = 'reset-data'; File = (Join-Path $sqlDir '99-reset.sql'); Database = $targetDb }
}

# Schema versionado do PROJETO (#21): aplicado por ultimo, no mesmo banco.
# No repo dev do tlpp-runner, SchemaPath resolve pro proprio 02-create-schema.sql
# do plugin - nesse caso ja rodou acima, nao duplica.
if ($cfg.SchemaPath -and (Test-Path $cfg.SchemaPath)) {
    $projSchema = (Resolve-Path $cfg.SchemaPath).Path
    $frameworkSchema = (Resolve-Path (Join-Path $sqlDir '02-create-schema.sql')).Path
    if ($projSchema -ne $frameworkSchema) {
        $scripts += @{ Name = 'project-schema'; File = $projSchema; Database = $targetDb }
    }
}

Write-Host "[db-setup] instancia: $Instance | banco: $targetDb" -ForegroundColor Cyan

foreach ($s in $scripts) {
    $path = $s.File
    if (-not (Test-Path $path)) { Write-Error "Script nao encontrado: $path"; exit 1 }
    $alvo = if ($s.Database) { " -> $($s.Database)" } else { '' }
    Write-Host "`n[db-setup] executando $([System.IO.Path]::GetFileName($path))$alvo..." -ForegroundColor Cyan
    if ($s.Database) {
        & sqlcmd -S $Instance -E -d $s.Database -i $path -b
    } else {
        & sqlcmd -S $Instance -E -i $path -b
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[db-setup] FAIL no script $([System.IO.Path]::GetFileName($path)) (exit $LASTEXITCODE)" -ForegroundColor Red
        if ($s.Database -and $s.Database -ne 'PROTHEUS_TST') {
            Write-Host "[db-setup] banco '$($s.Database)' existe? Se nao, rode /tlpp-tdd-project-init pra criar." -ForegroundColor Yellow
        }
        exit $LASTEXITCODE
    }
}

Write-Host "`n[db-setup] OK - $targetDb configurado" -ForegroundColor Green
Write-Host ""
Write-Host "Proximos passos para conectar pelo AppServer:" -ForegroundColor Yellow
Write-Host "  1. No appserver.ini do AppServer REST, adicione environment TST" -ForegroundColor Gray
Write-Host "     apontando TOPAlias=PROTHEUS_TST (ver docs/DATABASE-SETUP.md)" -ForegroundColor Gray
Write-Host "  2. Reinicie o AppServer REST" -ForegroundColor Gray
Write-Host "  3. Compile teste de integracao com /tlpp-build" -ForegroundColor Gray
