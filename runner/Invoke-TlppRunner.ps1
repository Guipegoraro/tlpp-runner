<#
.SYNOPSIS
    Cliente do endpoint REST do tlpp-runner.

.DESCRIPTION
    Apos o redesign global, vive no plugin. Le config global em
    ~/.claude/tlpp-tdd/config.ps1 + .tlpp-tdd.json do projeto atual.
    Quando ProjectName esta setado (.tlpp-tdd.json com `name`), passa
    como ambient context pro AppServer (que usa em u_tecTstConn).

.PARAMETER Function
    Nome da funcao a executar (Main ou User Function).

.PARAMETER ArgString
    Argumentos como string literal AdvPL separados por virgula. Ex: '"type:suite","unit"'

.PARAMETER Ping
    Health check em /runner/ping.

.PARAMETER CheckExists
    Verifica se a funcao existe no RPO.

.PARAMETER Junit
    Quando setado e a funcao executada eh tlpp.probat.run, parseia o
    JUnit XML resultante e mostra resumo passou/falhou.

.PARAMETER Quiet
    Suprime headers [runner] e JSON expandido. Imprime apenas 1 linha:
    "<funcao>: result=<.T./.F.> dur=<X>s" - util para LLM consumir
    minimizando tokens. Falhas ainda sao mostradas com detalhe.

.PARAMETER ProjectRoot
    Override do diretorio do projeto (afeta leitura de .tlpp-tdd.json).
    Default: $env:CLAUDE_PROJECT_DIR ou cwd.

.EXAMPLE
    .\Invoke-TlppRunner.ps1 -Ping
    .\Invoke-TlppRunner.ps1 -Function "u_tecAssertReset"
    .\Invoke-TlppRunner.ps1 -Function "u_test_xxx" -Quiet
    .\Invoke-TlppRunner.ps1 -Function "tlpp.probat.run" -Junit
#>
param(
    [Parameter(Mandatory=$false)][string]$Function,
    [Parameter(Mandatory=$false)][string]$ArgString = '',
    [Parameter(Mandatory=$false)][switch]$Ping,
    [Parameter(Mandatory=$false)][switch]$CheckExists,
    [Parameter(Mandatory=$false)][switch]$Junit,
    [Parameter(Mandatory=$false)][switch]$Quiet,
    [Parameter(Mandatory=$false)][string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'

# ANTES do dot-source: a cascata le o .tlpp-tdd.json na hora de carregar, entao
# ajustar $cfg.ProjectRoot depois seria tarde - ProjectName/TestDb ja teriam
# vindo do cwd e o projeto-alvo seria ignorado sem aviso.
if ($ProjectRoot) { $TlppProjectRootOverride = (Resolve-Path $ProjectRoot).Path }
. (Join-Path $PSScriptRoot 'runner.config.ps1')
. (Join-Path $PSScriptRoot 'InstanceControl.ps1')
. (Join-Path $PSScriptRoot 'HttpRetry.ps1')
$cfg = $TlppRunner

# Instancia dedicada (#34): sobe on-demand antes de QUALQUER chamada REST.
# No-op silencioso pra projeto sem isolamento. Fica antes dos tres modos (-Ping,
# -CheckExists, exec) porque todos falam com o mesmo endpoint.
$null = Start-IsolatedInstanceIfNeeded -Config $cfg

$pair  = "$($cfg.User):$($cfg.Password)"
$bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
$basic = [Convert]::ToBase64String($bytes)
$headers = @{
    'Authorization' = "Basic $basic"
    'Content-Type'  = 'application/json'
}

# Retry - o HTTPREST cai a CADA compilacao (nao so com @Get/@Post) e volta no
# proximo ciclo do [ONSTART] RefreshRate: ~5s com o RefreshRate=2 que o setup
# grava, ate ~2 min num appserver.ini com RefreshRate=120. O budget longo cobre
# o pior caso; "connection refused" nessa janela nao e falha definitiva.
#
# Backoff ASSIMETRICO: esperar 2 minutos por um AppServer DESLIGADO e so
# castigo. Entao a espera longa depende do AppServer estar VIVO.
#
# A sonda e a porta TCP do AppServer ($cfg.Port, tipicamente 1268), NAO a do
# REST. Medido: durante o restart do HTTPREST a 8401 fica fechada a janela
# inteira ("deleting server, HTTPREST" no console.log), enquanto a 1268 aceita
# o tempo todo. Sondar a 8401 daria sempre "fechada" e o budget cairia no curto
# - exatamente o caso que este backoff existe pra cobrir.
#
#   AppServer responde na TCP (REST reiniciando) -> insiste ate LongWaitSec
#   AppServer nao responde (processo morto)      -> desiste em ShortWaitSec
function Test-PortOpen {
    <# Connect() SINCRONO em IPv4 explicito, de proposito:
       - BeginConnect/ConnectAsync NAO sinalizam neste ambiente (PowerShell 7 +
         .NET no Windows): dao timeout tanto pra porta aberta quanto fechada, o
         que fazia esta funcao retornar $false SEMPRE e travar o budget no curto.
       - Resolver 'localhost' tenta IPv6 primeiro e paga ~2s antes do fallback;
         com 127.0.0.1 a resposta e de 1-70ms pra porta aberta. #>
    param([string]$HostName, [int]$Port)
    if ([string]::IsNullOrWhiteSpace($HostName) -or $HostName -eq 'localhost') { $HostName = '127.0.0.1' }
    $client = New-Object System.Net.Sockets.TcpClient
    try   { $client.Connect($HostName, $Port); return $true }
    catch { return $false }
    finally { $client.Dispose() }
}

function Invoke-WithRetry {
    param(
        $Block,
        [int]$DelaySec = 3,
        [int]$LongWaitSec = 180,   # RefreshRate=120 deixa o REST fora ate ~2 min; folga pra maquina lenta
        [int]$ShortWaitSec = 12,   # AppServer morto: reporta rapido
        [string]$ProbeHost,
        [int]$ProbePort
    )
    if (-not $ProbeHost) { $ProbeHost = $cfg.Server }
    if (-not $ProbePort) { $ProbePort = $cfg.Port }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return & $Block
        } catch {
            # Classificacao por TIPO (+ regex como fallback) - ver
            # runner/HttpRetry.ps1. Casar so a mensagem deixava este backoff
            # MORTO em PowerShell 5.1 pt-BR ("Nao e possivel conectar-se ao
            # servidor remoto" nao casa 'refused|connection').
            $isConnRefused = Test-TransientConnError -ErrorObject $_
            if (-not $isConnRefused) { throw }

            # Reavaliado a cada tentativa (nao e sticky): se o AppServer cair no
            # meio da espera, o budget encolhe e paramos de insistir a toa.
            $appServerUp = Test-PortOpen -HostName $ProbeHost -Port $ProbePort
            $budget = if ($appServerUp) { $LongWaitSec } else { $ShortWaitSec }

            if ($sw.Elapsed.TotalSeconds -ge $budget) {
                $why = if ($appServerUp) { "AppServer vivo mas o REST nao voltou em ${budget}s" }
                       else { "AppServer nao responde em ${ProbeHost}:${ProbePort} ha ${budget}s - parece desligado" }
                Write-Host "[runner] desistindo: $why" -ForegroundColor Red
                throw
            }
            $state = if ($appServerUp) { 'REST reiniciando' } else { "AppServer sem resposta em ${ProbeHost}:${ProbePort}" }
            Write-Host ("[runner] {0} (tentativa {1}, {2:n0}s/{3}s)" -f $state, $attempt, $sw.Elapsed.TotalSeconds, $budget) -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaySec
        }
    }
}

function Write-AssertFails {
    <# Uma linha por assert falho do `asserts.fails` da resposta do /runner/exec. #>
    param($Asserts)
    if ($Asserts -and $Asserts.fails) {
        foreach ($f in @($Asserts.fails)) { Write-Host "  FAIL: $f" -ForegroundColor Red }
    }
}

function Show-Error {
    <# Erro de request em texto legivel. O corpo da resposta vem de ErrorDetails
       no PowerShell 7 (HttpResponseMessage nao tem GetResponseStream) e do
       stream da resposta no 5.1. Erro de execucao da funcao (`error=runtime`)
       sai como mensagem + pilha + asserts registrados ate o erro. #>
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    if (-not $ex.Response) {
        Write-Host "[runner] $($ex.Message)" -ForegroundColor Red
        return 0
    }
    $code = 0
    try { $code = [int]$ex.Response.StatusCode } catch {}
    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    } elseif ($ex.Response.PSObject.Methods['GetResponseStream']) {
        try { $body = (New-Object System.IO.StreamReader($ex.Response.GetResponseStream())).ReadToEnd() } catch {}
    }
    Write-Host "[runner] HTTP $code" -ForegroundColor Red
    $j = $null
    if ($body) { try { $j = $body | ConvertFrom-Json } catch {} }
    if ($j -and $j.error -eq 'runtime') {
        Write-Host "$($j.function): ERRO $($j.message)" -ForegroundColor Red
        if ($j.stack) {
            $j.stack -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 15 |
                ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
        Write-AssertFails $j.asserts
    } elseif ($body) {
        Write-Host $body
    }
    return $code
}

if ($Ping) {
    $url = "$($cfg.BaseUrl)/runner/ping"
    if (-not $Quiet) { Write-Host "[runner] GET $url" -ForegroundColor Cyan }
    try {
        $resp = Invoke-WithRetry { Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec $cfg.PingTimeoutSec }
        Write-Host "[runner] PING OK" -ForegroundColor Green
        $resp | ConvertTo-Json -Depth 5
        exit 0
    } catch {
        Show-Error $_ | Out-Null
        exit 1
    }
}

if ($CheckExists) {
    if (-not $Function) { Write-Error "-Function obrigatorio com -CheckExists"; exit 2 }
    $url = "$($cfg.BaseUrl)/runner/func?name=$Function"
    if (-not $Quiet) { Write-Host "[runner] GET $url" -ForegroundColor Cyan }
    try {
        $resp = Invoke-WithRetry { Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec $cfg.PingTimeoutSec }
        $resp | ConvertTo-Json -Depth 5
        exit $(if ($resp.exists) { 0 } else { 1 })
    } catch {
        Show-Error $_ | Out-Null
        exit 1
    }
}

if (-not $Function) {
    Write-Error "Use -Ping, -CheckExists ou informe -Function"
    exit 2
}

# Monta body. API ignora campos que nao conhece - back-compat com versoes
# antigas de tecRunrApi.
#
# projectName e per-project (so existe com .tlpp-tdd.json). Ja testDbAlias e o
# endpoint do DBAccess sao config de MAQUINA e vao sempre que resolvidos - sem
# isso um projeto sem .tlpp-tdd.json nao recebe host/porta e o servidor cai no
# default 7890 de tecRunrCtx.tlpp, quebrando u_tecTstConn com NO_CONNECTION.
$bodyObj = [ordered]@{
    function  = $Function
    argString = $ArgString
}
if ($cfg.ProjectName) {
    $bodyObj.projectName = $cfg.ProjectName
}
# testDbAlias = "MSSQL/<TestDb>" - TestDb derivado de ProjectName em
# runner.config.ps1, com fallback 'PROTHEUS_TST' quando nao ha projeto.
if ($cfg.TestDb) {
    $bodyObj.testDbAlias = "MSSQL/$($cfg.TestDb)"
}
if ($cfg.DbAccessHost) { $bodyObj.dbAccessHost = $cfg.DbAccessHost }
if ($cfg.DbAccessPort) { $bodyObj.dbAccessPort = [int]$cfg.DbAccessPort }
$body = $bodyObj | ConvertTo-Json -Compress

$url = "$($cfg.BaseUrl)/runner/exec"
if (-not $Quiet) {
    Write-Host "[runner] POST $url" -ForegroundColor Cyan
    Write-Host "[runner] body: $body" -ForegroundColor DarkGray
}

try {
    $resp = Invoke-WithRetry { Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -TimeoutSec $cfg.ExecTimeoutSec }
    if ($Quiet) {
        $dur = [math]::Round([double]$resp.duration, 3)
        $color = if ($resp.result -eq '.T.') { 'Green' } else { 'Red' }
        $sum = if ($resp.asserts) { " asserts=$($resp.asserts.passed)ok/$($resp.asserts.failed)fail" } else { '' }
        Write-Host "$($resp.function): result=$($resp.result) dur=${dur}s$sum" -ForegroundColor $color
        Write-AssertFails $resp.asserts
    } else {
        Write-Host "[runner] OK function=$($resp.function) duration=$($resp.duration)s result=$($resp.result)" -ForegroundColor Green
        $resp | ConvertTo-Json -Depth 5
    }

    # Se for tlpp.probat.run e -Junit, tenta parsear o JUnit XML
    if ($Junit -or $Function -eq 'tlpp.probat.run') {
        $xmlFile = $null
        if ($cfg.ProbatXmlDir -and (Test-Path $cfg.ProbatXmlDir)) {
            $xmlFile = Get-ChildItem -Path $cfg.ProbatXmlDir -Filter 'results*robat.xml' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }
        }
        if ($xmlFile) {
            [xml]$xml = Get-Content $xmlFile
            $total = [int]$xml.testsuites.tests
            $ok = [int]$xml.testsuites.ok
            $fail = [int]$xml.testsuites.failures
            $skip = [int]$xml.testsuites.skipped
            $color = if ($fail -eq 0) { 'Green' } else { 'Red' }
            Write-Host ""
            Write-Host "=== PROBAT JUnit: $ok/$total OK | failures=$fail skipped=$skip ===" -ForegroundColor $color
            if ($fail -gt 0) {
                $xml.testsuites.testsuite.testcase | Where-Object { $_.failure } | ForEach-Object {
                    Write-Host "  FAIL: $($_.name) - $($_.failure.message)" -ForegroundColor Red
                }
            }
        }
    }
    exit 0
} catch {
    Show-Error $_ | Out-Null
    exit 1
}
