<#
.SYNOPSIS
    Ciclo de vida da instancia AppServer dedicada de um projeto (issue #34).

.DESCRIPTION
    Projeto com `isolation` no `.tlpp-tdd.json` roda contra a SUA instancia
    (RPO, portas e appserver.ini proprios - criada por
    `runner/install/New-IsolatedInstance.ps1`). Este arquivo sobe essa instancia
    ON-DEMAND: o primeiro build/test do projeto acorda o AppServer se a porta TCP
    dele nao responder.

    Decisoes fechadas:
      - ON-DEMAND, sem auto-stop. Derrubar a instancia no fim do comando pagaria
        o boot inteiro a cada teste; e um AppServer parado nao atrapalha ninguem
        (custo e ~500MB de RAM enquanto ligado).
      - SEMPRE com `-console`. Medido no spike: sem `-console` o processo sai em
        silencio, sem log e sem porta.
      - NO-OP SILENCIOSO quando o projeto nao e isolado. Este arquivo e
        dot-sourced por TODO build/test, inclusive dos projetos que usam o
        AppServer dev compartilhado.
      - NUNCA lanca excecao. Falhar aqui nao pode reprovar um build: quem
        chama segue e cai nos erros normais de conexao, que dizem mais.

.EXAMPLE
    . (Join-Path $PSScriptRoot 'InstanceControl.ps1')
    $r = Start-IsolatedInstanceIfNeeded -Config $cfg
    if ($r.Started) { Write-Host $r.Reason }
#>

function Test-TlppPortOpen {
    <# Connect() SINCRONO em IPv4 explicito - mesmo motivo do Invoke-TlppRunner:
       BeginConnect/ConnectAsync nao sinalizam neste ambiente (PowerShell 7 +
       .NET no Windows) e 'localhost' paga ~2s tentando IPv6 antes do fallback.

       Nome distinto de propositio: este arquivo e dot-sourced dentro do
       Invoke-TlppRunner.ps1, que tem o seu proprio Test-PortOpen. Nomes iguais
       fariam um sobrescrever o outro conforme a ordem do dot-source. #>
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [Parameter(Mandatory=$true)][int]$Port
    )
    if ([string]::IsNullOrWhiteSpace($HostName) -or $HostName -eq 'localhost') { $HostName = '127.0.0.1' }
    $client = New-Object System.Net.Sockets.TcpClient
    try   { $client.Connect($HostName, $Port); return $true }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-IsolatedInstanceExe {
    <# Acha o executavel do AppServer na arvore da instancia.

       Enumerado por glob e nao por caminho fixo: o binario muda de nome entre
       releases/layouts (appserver.exe, appsrvwin64.exe...). Ordem de
       preferencia primeiro, glob depois. #>
    param([Parameter(Mandatory=$true)][string]$BinDir)
    if (-not (Test-Path $BinDir)) { return $null }
    foreach ($cand in @('appserver.exe', 'appsrvwin64.exe')) {
        $p = Join-Path $BinDir $cand
        if (Test-Path $p) { return $p }
    }
    $found = Get-ChildItem -Path $BinDir -Filter 'appsrv*.exe' -File -ErrorAction SilentlyContinue |
             Sort-Object Name | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Start-IsolatedInstanceIfNeeded {
    <#
    .SYNOPSIS
        Sobe a instancia dedicada do projeto se ela nao estiver de pe.
    .OUTPUTS
        PSCustomObject: Started (bool), Reason (string).
    #>
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$false)][int]$WaitSec = 90,
        [Parameter(Mandatory=$false)][int]$PollSec = 3
    )
    $out = { param($started, $reason) [pscustomobject]@{ Started = [bool]$started; Reason = $reason } }

    # Projeto sem isolamento: nada a fazer. Caminho MAIS COMUM - fica silencioso.
    if (-not $Config -or -not $Config.IsolationBinDir) {
        return (& $out $false 'projeto sem isolamento')
    }

    $binDir  = $Config.IsolationBinDir
    $tcpPort = [int]$Config.Port
    $srv     = if ($Config.Server) { $Config.Server } else { 'localhost' }

    if ($tcpPort -le 0) {
        Write-Host "[inst] isolamento declarado mas sem porta TCP no cascade - ignorando" -ForegroundColor DarkYellow
        return (& $out $false 'porta TCP nao resolvida')
    }

    # Ja de pe? A sonda e a porta TCP (nao a do REST): durante o restart do
    # HTTPREST apos uma compilacao a porta REST fica fechada a janela inteira
    # enquanto a TCP aceita - sondar a REST aqui faria subir um SEGUNDO processo
    # sobre o mesmo RPO, com lock garantido.
    if (Test-TlppPortOpen -HostName $srv -Port $tcpPort) {
        return (& $out $false "instancia ja rodando em ${srv}:${tcpPort}")
    }

    $exe = Get-IsolatedInstanceExe -BinDir $binDir
    $ini = Join-Path $binDir 'appserver.ini'
    if (-not $exe -or -not (Test-Path $ini)) {
        Write-Host "[inst] projeto isolado, mas a arvore da instancia esta incompleta:" -ForegroundColor Yellow
        Write-Host "[inst]   bin: $binDir  (exe=$(if ($exe) { 'ok' } else { 'AUSENTE' }), ini=$(if (Test-Path $ini) { 'ok' } else { 'AUSENTE' }))" -ForegroundColor Yellow
        Write-Host "[inst]   rode /tlpp-tdd-project-init (ou New-IsolatedInstance.ps1) pra recriar." -ForegroundColor Yellow
        return (& $out $false 'arvore da instancia ausente ou incompleta')
    }

    # `-console` e obrigatorio: sem ele o processo sai em silencio (medido).
    # Minimizado pra nao roubar o foco do usuario a cada build.
    Write-Host "[inst] subindo instancia isolada '$($Config.Environment)' ($exe)..." -ForegroundColor Cyan
    try {
        Start-Process -FilePath $exe -ArgumentList '-console', '-ini=appserver.ini' `
            -WorkingDirectory $binDir -WindowStyle Minimized | Out-Null
    } catch {
        Write-Host "[inst] falha ao iniciar: $($_.Exception.Message)" -ForegroundColor Red
        return (& $out $false "falha ao iniciar: $($_.Exception.Message)")
    }

    # Espera o REST responder - nao basta a TCP abrir: as rotas /rest/runner/*
    # sobem depois, pelo [ONSTART]/HTTPJOB. Quem espera aqui poupa o chamador de
    # um "connection refused" que nao significa erro nenhum.
    # Porta pelo parser de URI: um regex ':(\d+)' pegaria o ':1' de um host IPv6
    # literal ([::1]). Porta implicita (sem ':<n>' no BaseUrl) fica 0.
    $restPort = 0
    try {
        $uri = [uri]$Config.BaseUrl
        if (-not $uri.IsDefaultPort) { $restPort = $uri.Port }
    } catch { $restPort = 0 }
    if ($restPort -le 0) {
        Write-Host "[inst] iniciada (sem porta REST no BaseUrl - nao vou esperar o REST)" -ForegroundColor DarkYellow
        return (& $out $true 'iniciada sem espera do REST')
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $WaitSec) {
        if (Test-TlppPortOpen -HostName $srv -Port $restPort) {
            Write-Host ("[inst] REST de pe em ${srv}:${restPort} ({0:n0}s)" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
            return (& $out $true "iniciada e REST respondendo em ${restPort}")
        }
        Write-Host ("[inst] aguardando REST em ${srv}:${restPort} ({0:n0}s/${WaitSec}s)" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        Start-Sleep -Seconds $PollSec
    }
    # Nao e erro fatal: o chamador tenta e reporta o erro real (com corpo HTTP).
    Write-Host "[inst] iniciada, mas o REST nao respondeu em ${WaitSec}s - veja $binDir\console.log" -ForegroundColor Yellow
    return (& $out $true "iniciada, REST sem resposta em ${WaitSec}s")
}
