<#
.SYNOPSIS
    Higiene dos arquivos temporarios de build (build-<PID>.ini / .log).

.DESCRIPTION
    O Invoke-TlppBuild gera um INI temporario pro advpls cli contendo
    `psw=<senha em texto plano>` - e o unico formato que o advpls aceita.
    Enquanto esse INI ficava pra tras, a maquina acumulava dezenas de arquivos
    com a senha do Protheus em claro no %TEMP%.

    Duas defesas, ambas aqui pra poderem ser testadas offline (sem advpls):

      1. Invoke-AdvplsCli - roda o compilador dentro de try/finally e APAGA o
         INI no finally, mesmo quando o compile falha ou lanca excecao.

      2. Remove-OrphanBuildIni - varre restos de execucoes anteriores que
         morreram antes do finally (crash, kill, reboot).

    HEURISTICA DE ORFAO (o INI se chama build-<PID>.ini):

      - PID morto            -> orfao. Ninguem mais vai usar aquele arquivo.
      - PID vivo mas antigo  -> orfao. Cobre RECICLAGEM DE PID: o Windows
                                reaproveita PIDs, entao um INI de build morto
                                pode "parecer vivo" so porque outro processo
                                herdou o numero. Nenhum build real dura 1h.
      - PID vivo e recente   -> PRESERVA. Pode ser um build concorrente em
                                andamento (outro projeto compilando agora);
                                apagar o INI dele quebraria a compilacao.
      - PID desta sessao     -> PRESERVA (e o arquivo que estamos criando).

    So o .ini carrega segredo; o .log fica sujeito a uma limpeza mais folgada
    (dias), preservada em Remove-OldBuildLog.
#>

function Test-PidAlive {
    <# Default do -IsPidAlive. Isolado em funcao pra poder ser injetado no teste. #>
    param([Parameter(Mandatory=$true)][int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    return ($null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}

function Remove-OrphanBuildIni {
    <#
    .SYNOPSIS
        Apaga build-<PID>.ini orfaos (contem senha em texto plano).
    .PARAMETER TmpDir
        Diretorio dos temporarios (normalmente $env:TEMP\tlpp-tdd).
    .PARAMETER MaxAgeHours
        Idade a partir da qual o INI e considerado orfao mesmo com PID vivo
        (defesa contra reciclagem de PID). Default 1h.
    .PARAMETER CurrentPid
        PID a preservar sempre (o desta sessao).
    .PARAMETER IsPidAlive
        Scriptblock que recebe o PID e devolve $true/$false. Injetavel no teste.
    .OUTPUTS
        Caminhos removidos.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$TmpDir,
        [int]$MaxAgeHours = 1,
        [int]$CurrentPid = $PID,
        [scriptblock]$IsPidAlive
    )

    $removidos = @()
    if (-not (Test-Path $TmpDir)) { return $removidos }
    if (-not $IsPidAlive) { $IsPidAlive = { param($p) Test-PidAlive -ProcessId $p } }

    $limite = (Get-Date).AddHours(-1 * [Math]::Abs($MaxAgeHours))

    foreach ($f in (Get-ChildItem -Path $TmpDir -Filter 'build-*.ini' -File -ErrorAction SilentlyContinue)) {
        if ($f.BaseName -notmatch '^build-(\d+)$') { continue }
        $filePid = [int]$matches[1]
        if ($filePid -eq $CurrentPid) { continue }

        $vivo    = [bool](& $IsPidAlive $filePid)
        $antigo  = ($f.LastWriteTime -lt $limite)

        if ($vivo -and -not $antigo) { continue }   # build concorrente em andamento

        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $removidos += $f.FullName
        } catch {
            # Arquivo em uso por quem ainda esta compilando - tentamos na proxima.
        }
    }
    return $removidos
}

function Remove-OldBuildLog {
    <# Logs nao tem segredo: limpeza folgada, so pra nao acumular indefinidamente. #>
    param(
        [Parameter(Mandatory=$true)][string]$TmpDir,
        [int]$MaxAgeDays = 1
    )
    if (-not (Test-Path $TmpDir)) { return }
    Get-ChildItem -Path $TmpDir -Filter 'build-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1 * [Math]::Abs($MaxAgeDays)) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Invoke-AdvplsCli {
    <#
    .SYNOPSIS
        Chama o advpls cli garantindo que o INI (com a senha) seja apagado.
    .DESCRIPTION
        O Remove-Item mora no finally: compile que falha, advpls que nao existe
        ou Ctrl+C no meio nao podem deixar a senha pra tras.
    .PARAMETER Invoker
        Scriptblock alternativo (exe, ini) usado nos testes offline pra nao
        depender do advpls real. Em producao fica $null.
    .OUTPUTS
        [pscustomobject] com Output (linhas) e ExitCode.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$AdvplsPath,
        [Parameter(Mandatory=$true)][string]$IniPath,
        [scriptblock]$Invoker
    )
    try {
        if ($Invoker) {
            $out = & $Invoker $AdvplsPath $IniPath
        } else {
            $out = & $AdvplsPath cli $IniPath 2>&1
        }
        return [pscustomobject]@{ Output = $out; ExitCode = $global:LASTEXITCODE }
    } finally {
        Remove-Item -LiteralPath $IniPath -Force -ErrorAction SilentlyContinue
    }
}
