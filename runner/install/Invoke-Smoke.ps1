<#
.SYNOPSIS
    Smoke test final apos install: ping + compile + 1 funcao + 1 assert.

.DESCRIPTION
    Executa 4 verificacoes rapidas. Saida limpa, exit 0 se tudo OK.

.EXAMPLE
    .\Invoke-Smoke.ps1
#>
param()

$ErrorActionPreference = 'Continue'

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'runner.config.ps1')
$cfg = $TlppRunner

$runnerScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-TlppRunner.ps1'
$buildScript  = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-TlppBuild.ps1'

$fail = 0

Write-Host "=== Smoke test do framework tlpp-tdd ===" -ForegroundColor Cyan

# 1) Ping REST
Write-Host "1) Ping REST ($($cfg.BaseUrl)/runner/ping)..." -ForegroundColor DarkGray
& $runnerScript -Ping
if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: REST nao respondeu" -ForegroundColor Red; $fail++ } else { Write-Host "  OK" -ForegroundColor Green }

# 2) Compile do framework (src + mocks + test - sem examples)
Write-Host "2) Compilando framework..." -ForegroundColor DarkGray
& $buildScript -All 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: compile retornou $LASTEXITCODE" -ForegroundColor Red; $fail++ } else { Write-Host "  OK" -ForegroundColor Green }

# 3) tecAssertReset (sanity do framework de asserts)
Write-Host "3) u_tecAssertReset..." -ForegroundColor DarkGray
& $runnerScript -Function 'u_tecAssertReset' -Quiet
if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: u_tecAssertReset" -ForegroundColor Red; $fail++ } else { Write-Host "  OK" -ForegroundColor Green }

# 4) tecHoje (sanity dos wrappers)
Write-Host "4) u_tecHoje..." -ForegroundColor DarkGray
& $runnerScript -Function 'u_tecHoje' -Quiet
if ($LASTEXITCODE -ne 0) { Write-Host "  FAIL: u_tecHoje" -ForegroundColor Red; $fail++ } else { Write-Host "  OK" -ForegroundColor Green }

Write-Host ""
if ($fail -eq 0) {
    Write-Host "Smoke test OK - framework operacional." -ForegroundColor Green
    exit 0
} else {
    Write-Host "Smoke test FAIL - $fail problema(s). Veja saida acima." -ForegroundColor Red
    exit 1
}
