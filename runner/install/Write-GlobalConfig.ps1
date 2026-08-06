<#
.SYNOPSIS
    Escreve/atualiza ~/.claude/tlpp-tdd/config.ps1 (config global per-machine).

.DESCRIPTION
    Cria o arquivo ou MERGE com o existente preservando chaves nao fornecidas.
    Idempotente. Senha mascarada no log (so mostra prefixo).

    Chave OBRIGATORIA passada com valor nulo/vazio e ERRO (throw), nao "pula em
    silencio": gravar config incompleto fazia o setup terminar verde e o runner
    quebrar depois. Obrigatorias: BaseUrl, User, Password, ProtheusRoot,
    AdvplsPath, Server, Port, Environment. As demais continuam opcionais.

.PARAMETER Settings
    Hashtable com chaves do TlppRunner pra setar/atualizar. Exemplo:
        @{
            User='admin'; Password='senha';
            ProtheusRoot='C:\TOTVS\Protheus_241011';
            AdvplsPath='...\advpls.exe';
            BaseUrl='http://localhost:8401/rest';
            SqlInstance='localhost\PROTHEUSTESTE';
            DbAccessPort=7892
        }

.PARAMETER Mode
    'Merge' (default): preserva chaves nao fornecidas em $Settings.
    'Overwrite': substitui o arquivo inteiro.

.PARAMETER DryRun
    Mostra o conteudo que seria escrito, nao grava.

.EXAMPLE
    .\Write-GlobalConfig.ps1 -Settings @{ User='admin'; Password='pw'; ProtheusRoot='C:\TOTVS\Protheus_241011' }
#>
param(
    [Parameter(Mandatory=$true)][hashtable]$Settings,
    [Parameter(Mandatory=$false)][ValidateSet('Merge','Overwrite')][string]$Mode = 'Merge',
    [Parameter(Mandatory=$false)][switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$configDir  = Join-Path $env:USERPROFILE '.claude\tlpp-tdd'
$configPath = Join-Path $configDir 'config.ps1'

# Merge com existente
$current = [ordered]@{}
if ($Mode -eq 'Merge' -and (Test-Path $configPath)) {
    # Parser rudimentar: lê linhas `$TlppRunner.<key> = <value>` e captura chave -> valor literal
    $rx = '^\s*\$TlppRunner\.(?<k>\w+)\s*=\s*(?<v>.+?)\s*$'
    foreach ($line in (Get-Content $configPath -ErrorAction SilentlyContinue)) {
        if ($line -match $rx) {
            $current[$Matches.k] = $Matches.v
        }
    }
}

# Chaves LOAD-BEARING: sem elas o runner nao fala com o AppServer nem compila.
# Se o chamador PASSAR uma delas com valor nulo/vazio (tipico: deteccao de
# ambiente falhou e o campo veio $null), falhar aqui e obrigatorio - a versao
# antiga pulava a chave em silencio, o setup terminava "ok" e a quebra so
# aparecia depois, no primeiro /tlpp-test, com config incompleto.
# Chaves fora desta lista (SqlInstance, DbAccess*, Company, Branch...) sao
# opcionais: nulas continuam sendo ignoradas, com aviso.
$requiredKeys = @('BaseUrl','User','Password','ProtheusRoot','AdvplsPath','Server','Port','Environment')

$missing = @()
foreach ($k in $Settings.Keys) {
    if ($requiredKeys -notcontains $k) { continue }
    $v = $Settings[$k]
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace("$v")) { $missing += $k }
}
if ($missing.Count -gt 0) {
    # Write-Error com $ErrorActionPreference='Stop' ja seria terminante e comeria
    # o texto do throw - por isso so o throw, que carrega a orientacao completa.
    $lista = ($missing | Sort-Object) -join ', '
    throw "[wcfg] chave(s) obrigatoria(s) com valor nulo/vazio: $lista. Nao vou gravar config incompleto (o arquivo atual ficou intacto) - detecte ou pergunte esses valores e chame de novo."
}

# Sobrescreve / adiciona com novos valores
foreach ($k in $Settings.Keys) {
    $v = $Settings[$k]
    if ($null -eq $v) {
        Write-Host "[wcfg] ignorando '$k' (valor nulo, chave opcional)" -ForegroundColor DarkYellow
        continue
    }
    # Encode pra literal PowerShell
    if     ($v -is [bool])    { $current[$k] = '$' + ($v.ToString().ToLower()) }
    elseif ($v -is [int])     { $current[$k] = "$v" }
    elseif ($v -is [decimal]) { $current[$k] = "$v" }
    else {
        # string: escape de aspas simples
        $s = "$v".Replace("'", "''")
        $current[$k] = "'$s'"
    }
}

# Monta conteudo
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# =====================================================================')
$lines.Add('# tlpp-tdd - configuracao GLOBAL (per-machine)')
$lines.Add('# =====================================================================')
$lines.Add('# Gerado por Write-GlobalConfig.ps1. Pode ser editado manualmente.')
$lines.Add('# Carregado por runner/runner.config.ps1 em cascade.')
$lines.Add(('# Atualizado em: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
$lines.Add('# =====================================================================')
$lines.Add('')

# Ordem preferencial pra leitura
$preferredOrder = @(
    'BaseUrl','User','Password',
    'ProtheusRoot','RpoCustom','AdvplsPath','Server','Port','Secure','Build','Environment',
    'SqlInstance','SqlAuth','SqlUser','SqlPassword','TrustServerCert',
    'DbAccessHost','DbAccessPort','DbAccessIniPath',
    'Company','Branch',
    'AppServerMode','AppServerIniPath'
)

# Os parenteses EXTRA em .Add((...)) sao load-bearing: dentro da lista de
# argumentos de um metodo a virgula SEPARA ARGUMENTOS, entao `.Add('{0}={1}' -f
# $k, $v)` virava Add(('{0}={1}' -f $k), $v) e explodia com "Error formatting a
# string: Index ... less than the size of the argument list" em TODA chamada
# real (so o -DryRun de config vazio escapava).
$emitted = @{}
foreach ($k in $preferredOrder) {
    if ($current.Contains($k)) {
        $lines.Add(('$TlppRunner.{0} = {1}' -f $k, $current[$k]))
        $emitted[$k] = $true
    }
}
# Resto (chaves novas / custom)
foreach ($k in $current.Keys) {
    if (-not $emitted.ContainsKey($k)) {
        $lines.Add(('$TlppRunner.{0} = {1}' -f $k, $current[$k]))
    }
}

$content = ($lines -join "`r`n") + "`r`n"

# Plano
$action = if (Test-Path $configPath) { 'atualizar' } else { 'criar' }
Write-Host "[wcfg] Vai $action ${configPath}:" -ForegroundColor Cyan
foreach ($k in $Settings.Keys) {
    $maskV = if ($k -match '(?i)password|secret|token') {
        $orig = "$($Settings[$k])"
        if ($orig.Length -ge 4) { $orig.Substring(0, 2) + '***' + $orig.Substring($orig.Length - 1) } else { '***' }
    } else {
        "$($Settings[$k])"
    }
    Write-Host "  - $k = $maskV" -ForegroundColor White
}

if ($DryRun) {
    Write-Host "[wcfg] DryRun - nada gravado. Conteudo seria:" -ForegroundColor Yellow
    Write-Host $content
    return
}

if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($configPath, $content, [System.Text.UTF8Encoding]::new($false))
Write-Host "[wcfg] OK - $configPath gravado ($($current.Count) chaves)" -ForegroundColor Green
