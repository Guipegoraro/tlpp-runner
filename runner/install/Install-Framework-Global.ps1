<#
.SYNOPSIS
    Compila os fontes do framework (tecAssert, tecWrap, tecMock, tecRunrApi,
    tecRunrCtx, tecRefl) no RPO do AppServer configurado. One-shot.

.DESCRIPTION
    Substituto do legacy Install-FrameworkFiles.ps1 (que copiava o framework
    pra dentro do projeto consumidor). Agora compilamos UMA VEZ no RPO
    compartilhado e qualquer projeto que use o plugin consome via /runner/exec.

    Usa Invoke-TlppBuild.ps1 do PROPRIO PLUGIN como compilador, mas aponta
    -ProjectRoot pro plugin root (onde estao os fontes src/, mocks/, test/).

.PARAMETER PluginRoot
    Raiz do plugin (onde vivem .claude-plugin/, src/, runner/). Default: 2 niveis acima do script.

.PARAMETER WithExamples
    Tambem compila examples/ (demos).

.PARAMETER WithTests
    Tambem compila test/ do plugin (testes do framework em si).

.PARAMETER DryRun
    Lista o que seria compilado, nao chama advpls.

.EXAMPLE
    .\Install-Framework-Global.ps1
    .\Install-Framework-Global.ps1 -WithTests
#>
param(
    [Parameter(Mandatory=$false)][string]$PluginRoot,
    [Parameter(Mandatory=$false)][switch]$WithExamples,
    [Parameter(Mandatory=$false)][switch]$WithTests,
    [Parameter(Mandatory=$false)][switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# PluginRoot default: 2 niveis acima (este script vive em <root>/runner/install/)
if (-not $PluginRoot) {
    $PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

$build = Join-Path $PluginRoot 'runner\Invoke-TlppBuild.ps1'
if (-not (Test-Path $build)) {
    throw "Invoke-TlppBuild.ps1 nao encontrado em $build - PluginRoot incorreto?"
}

# Determina dirs a compilar
$srcDir = Join-Path $PluginRoot 'src'
$mockDir = Join-Path $PluginRoot 'mocks'
$testDir = Join-Path $PluginRoot 'test'
$exDir = Join-Path $PluginRoot 'examples'

if (-not (Test-Path $srcDir)) {
    throw "src/ nao existe em $PluginRoot - PluginRoot incorreto?"
}

Write-Host "[install-fw] Compilando framework do plugin em $PluginRoot" -ForegroundColor Cyan
Write-Host "[install-fw] Alvos:" -ForegroundColor Cyan
Write-Host "  - src/   $(if (Test-Path $srcDir) { 'sim' } else { 'AUSENTE' })" -ForegroundColor White
Write-Host "  - mocks/ $(if (Test-Path $mockDir) { 'sim' } else { 'AUSENTE' })" -ForegroundColor White
if ($WithTests) { Write-Host "  - test/  $(if (Test-Path $testDir) { 'sim' } else { 'AUSENTE' })" -ForegroundColor White }
if ($WithExamples) { Write-Host "  - examples/ $(if (Test-Path $exDir) { 'sim' } else { 'AUSENTE' })" -ForegroundColor White }

if ($DryRun) {
    Write-Host "[install-fw] DryRun - listagem de fontes:" -ForegroundColor Yellow
    $roots = @($srcDir, $mockDir)
    if ($WithTests) { $roots += $testDir }
    if ($WithExamples) { $roots += $exDir }
    foreach ($r in $roots) {
        if (Test-Path $r) {
            Get-ChildItem -Path $r -Recurse -Include '*.tlpp','*.prw','*.prx','*.prg' -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Host "    $($_.FullName)" -ForegroundColor DarkGray }
        }
    }
    return
}

# Build args
$buildArgs = @{ ProjectRoot = $PluginRoot; All = $true }
if ($WithExamples) { $buildArgs.WithExamples = $true }

# Invoke. Se nao quer test/ no -All, precisamos compilar manualmente sem -All... mas
# Invoke-TlppBuild.ps1 -All ja inclui test/. Pra excluir test/, teria que listar -File
# explicitamente. Por ora, -All inclui tudo - documentado.
if (-not $WithTests) {
    Write-Host "[install-fw] AVISO: Invoke-TlppBuild.ps1 -All inclui test/ junto. Pra excluir, use -File em vez de -All." -ForegroundColor Yellow
}

Write-Host "[install-fw] -> $build -All ..." -ForegroundColor Cyan
& $build @buildArgs
$code = $LASTEXITCODE

if ($code -eq 0) {
    Write-Host "[install-fw] OK - framework compilado no RPO do AppServer configurado." -ForegroundColor Green
    Write-Host "[install-fw] Funcoes disponiveis em /rest/runner/exec: u_tecAssert*, u_tecMk*, u_tecCtx*, u_tecTstConn, u_tecHoje, etc." -ForegroundColor DarkGray
} else {
    Write-Host "[install-fw] FAIL (exit $code) - veja erros acima." -ForegroundColor Red
}
exit $code
