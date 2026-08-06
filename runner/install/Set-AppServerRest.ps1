<#
.SYNOPSIS
    Garante que o AppServer tem rotas REST /rest/runner/* habilitadas no
    appserver.ini, com backup.

.DESCRIPTION
    Verifica/adiciona as secoes [HTTPREST] e a configuracao do servico HTTP
    necessaria pra /runner/ping|func|exec funcionarem. Idempotente.

    Dois caminhos:
      - secao [HTTPREST] AUSENTE  -> grava o bloco REST completo
        ([HTTPJOB]/[ONSTART]/[HTTPV11]/[HTTPREST]/[HTTPURI]), pulando as secoes
        de apoio que o ini ja tiver. So [HTTPREST] nao faz o servidor responder
        /rest - falta o [HTTPURI] com URL=/rest.
      - secao [HTTPREST] EXISTENTE -> update IN-PLACE de Port/Environment/Enable,
        preservando comentarios, ordem e as demais chaves (SECURITY, URIs, etc).

    Nunca reporta "atualizado" sem ter mudado byte: o conteudo final e comparado
    com o original antes de backupear/gravar.

    NAO mexe na secao [Environments] / [DESENVOLVIMENTO] do usuario - so adiciona
    a config REST que o framework precisa.

.PARAMETER AppServerIniPath
    Caminho do appserver.ini.

.PARAMETER RestPort
    Porta do HTTPREST (default 8401).

.PARAMETER Environment
    Nome do environment Protheus onde as rotas registram (default DESENVOLVIMENTO).

.PARAMETER EnableProbat
    Se passado, tambem habilita TESTS_DISCOVERY_MODE / [PROBAT] block.

.PARAMETER DryRun
    Mostra o diff sem aplicar.

.EXAMPLE
    .\Set-AppServerRest.ps1 -AppServerIniPath 'C:\TOTVS\Protheus_241011\bin\appserver_rest\appserver.ini'
#>
param(
    [Parameter(Mandatory=$true)][string]$AppServerIniPath,
    [Parameter(Mandatory=$false)][int]$RestPort = 8401,
    [Parameter(Mandatory=$false)][string]$Environment = 'DESENVOLVIMENTO',
    [Parameter(Mandatory=$false)][switch]$EnableProbat,
    [Parameter(Mandatory=$false)][switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $AppServerIniPath)) {
    throw "appserver.ini nao encontrado: $AppServerIniPath"
}

# Leitura preservando bytes: o appserver.ini costuma ter comentarios acentuados
# em UTF-8 (16 bytes >0x7F no ini de referencia). Ler/gravar em ASCII trocaria
# cada um por '?'. Ver runner/install/IniIO.ps1.
. (Join-Path $PSScriptRoot 'IniIO.ps1')
$content = Read-IniLines -Path $AppServerIniPath
$plannedChanges = @()

# Chaves que o framework EXIGE em [HTTPREST]. Sao as unicas mexidas in-place
# quando a secao ja existe - SECURITY, URIs e qualquer chave do usuario ficam
# como estao (o ini e do usuario, nao nosso).
$restKeys = [ordered]@{
    'Port'        = "$RestPort"
    'Environment' = $Environment
    'Enable'      = '1'
}

# Bloco REST completo pra quando a secao NAO existe: so [HTTPREST] nao faz o
# AppServer servir /rest - precisa de [HTTPURI] (URL=/rest), [HTTPV11] e
# [ONSTART] com o job HTTP. Template compartilhado com New-IsolatedInstance.ps1.
$restBlock = New-RestSectionLines -Environment $Environment -RestPort $RestPort -Security 1 `
                                  -ExtraRestKeys ([ordered]@{ 'Environment' = $Environment; 'Enable' = '1' })

# ---------------------------------------------------------------------------
# Plano (o que sera de fato mudado)
# ---------------------------------------------------------------------------

# 1) [HTTPREST] - update in-place quando existe, criacao completa quando nao
$needsHttpRest = -not (Test-IniSection -Lines $content -Section 'HTTPREST')
if ($needsHttpRest) {
    $novas = @($restBlock.Keys | Where-Object { -not (Test-IniSection -Lines $content -Section $_) })
    $plannedChanges += ("Adicionar secao(oes) " + (($novas | ForEach-Object { "[$_]" }) -join ' ') +
                        " (HTTPREST Port=$RestPort, Environment=$Environment, Enable=1, URIs=HTTPURI)")
} else {
    $ajustado = Set-IniSectionKeys -Lines $content -Section 'HTTPREST' -Keys $restKeys
    if (($ajustado -join "`n") -ne ($content -join "`n")) {
        $plannedChanges += "Ajustar [HTTPREST] in-place: Port=$RestPort, Environment=$Environment, Enable=1"
    }
    # Secoes de apoio podem faltar mesmo com [HTTPREST] presente.
    $faltando = @('HTTPURI','HTTPV11','ONSTART','HTTPJOB') |
        Where-Object { -not (Test-IniSection -Lines $content -Section $_) }
    if ($faltando.Count -gt 0) {
        $plannedChanges += ("Adicionar secao(oes) de apoio " + (($faltando | ForEach-Object { "[$_]" }) -join ' '))
    }
}

# 2) Secao [GENERAL] - ConsoleLog (so adiciona se nao existe)
$general = @()
$genBounds = Get-IniSectionBounds -Lines $content -Section 'GENERAL'
if ($genBounds) { $general = $content[$genBounds.Start..$genBounds.End] }
$hasConsoleLog = $general | Where-Object { $_ -match '^\s*ConsoleLog\s*=' }
if (-not $hasConsoleLog) {
    $plannedChanges += "[GENERAL] ConsoleLog=1 (necessario pro framework ler [ASSERT_FAIL] do log)"
}

# 3) PROBAT (opcional)
if ($EnableProbat -and -not (Test-IniSection -Lines $content -Section 'PROBAT')) {
    $plannedChanges += "Adicionar secao [PROBAT] (TESTS_DISCOVERY_MODE=0)"
}

# Plano
if ($plannedChanges.Count -eq 0) {
    Write-Host "[appsrv-rest] $AppServerIniPath ja esta configurado corretamente." -ForegroundColor DarkGray
    return
}

Write-Host "[appsrv-rest] Plano de mudancas em ${AppServerIniPath}:" -ForegroundColor Cyan
foreach ($c in $plannedChanges) { Write-Host "  - $c" -ForegroundColor White }
Write-Host "  Razao: o framework expoe /rest/runner/ping|func|exec na porta $RestPort do env $Environment." -ForegroundColor DarkGray

if ($DryRun) {
    Write-Host "[appsrv-rest] DryRun - nada aplicado." -ForegroundColor Yellow
    return
}

# Aplica as mudancas EM MEMORIA primeiro: so backupeia/grava se o resultado
# for de fato diferente do arquivo atual (ver guard no fim).
$newContent = New-Object System.Collections.Generic.List[string]
$newContent.AddRange([string[]]$content)

if ($needsHttpRest) {
    # Secao ausente: grava o bloco REST completo, pulando as secoes de apoio que
    # o usuario ja tem (duplicar [ONSTART] quebraria o ini dele).
    foreach ($sec in @($restBlock.Keys)) {
        if (Test-IniSection -Lines $newContent.ToArray() -Section $sec) { continue }
        if ($newContent.Count -gt 0 -and $newContent[-1].Trim() -ne '') { $newContent.Add('') }
        $newContent.Add("[$sec]")
        foreach ($l in $restBlock[$sec]) { $newContent.Add($l) }
        $newContent.Add('')
    }
} else {
    # Secao existente: update in-place das chaves obrigatorias, preservando o
    # resto (era exatamente o que faltava - o script anunciava "Ajustar
    # [HTTPREST]" e nao mexia em nada).
    $newContent.Clear()
    $newContent.AddRange([string[]](Set-IniSectionKeys -Lines $content -Section 'HTTPREST' -Keys $restKeys))
    foreach ($sec in @('HTTPJOB','ONSTART','HTTPV11','HTTPURI')) {
        if (Test-IniSection -Lines $newContent.ToArray() -Section $sec) { continue }
        if ($newContent.Count -gt 0 -and $newContent[-1].Trim() -ne '') { $newContent.Add('') }
        $newContent.Add("[$sec]")
        foreach ($l in $restBlock[$sec]) { $newContent.Add($l) }
        $newContent.Add('')
    }
}

if (-not $hasConsoleLog) {
    # acha [GENERAL] ou cria
    $genIdx = -1
    for ($i = 0; $i -lt $newContent.Count; $i++) {
        if ($newContent[$i] -match '^\s*\[GENERAL\]\s*$') { $genIdx = $i; break }
    }
    if ($genIdx -ge 0) {
        $newContent.Insert($genIdx + 1, 'ConsoleLog=1')
    } else {
        $newContent.Add('')
        $newContent.Add('[GENERAL]')
        $newContent.Add('ConsoleLog=1')
    }
}

if ($EnableProbat) {
    if (-not (Test-IniSection -Lines $newContent.ToArray() -Section 'PROBAT')) {
        $newContent.Add('')
        $newContent.Add('[PROBAT]')
        $newContent.Add('TESTS_DISCOVERY_MODE=0')
    }
}

# Guard anti-falso-"atualizado": se o plano nao produziu diferenca real, nao
# backupeia, nao grava e NAO diz que atualizou. Foi assim que o bug antigo
# passava batido - anunciava "Ajustar [HTTPREST]" e terminava em verde sem ter
# mudado um byte.
if (($newContent.ToArray() -join "`n") -eq ($content -join "`n")) {
    Write-Host "[appsrv-rest] Nada a mudar - $AppServerIniPath ja esta configurado." -ForegroundColor DarkGray
    return
}

$bak = & (Join-Path $PSScriptRoot 'Backup-Ini.ps1') -Path $AppServerIniPath
Write-Host "[appsrv-rest] Backup: $bak" -ForegroundColor DarkGray

Write-IniLines -Path $AppServerIniPath -Lines $newContent.ToArray()

Write-Host "[appsrv-rest] OK - $AppServerIniPath atualizado. REINICIE o AppServer pra carregar as mudancas." -ForegroundColor Green
