<#
.SYNOPSIS
    Teste do cache de build (runner/BuildCache.ps1) - issue #29 - e da higiene
    do INI temporario com senha (runner/BuildTemp.ps1).

.DESCRIPTION
    Logica pura: nao precisa de AppServer nem advpls. Roda em CI headless.

    Cenarios:
      C1  fonte nunca compilado                -> MISS
      C2  fonte compilado, conteudo igual      -> HIT
      C3  fonte compilado, conteudo alterado   -> MISS
      C4  slot ocupado por OUTRO fonte homonimo-> MISS + reporta o dono
          (dois projetos com o mesmo MT410ROT.tlpp no RPO compartilhado)
      C5  environment diferente                -> MISS (slot distinto)
      C6  RPO alterado por fora                -> MISS (guard de rpoStamp)
      C7  JSON corrompido                      -> MISS, sem excecao
      C8  nome de programa e case-insensitive  -> HIT
      C19-C24  INI temporario (contem `psw=` em texto plano): apagado apos
          compile OK, apos compile FALHO e apos excecao; orfao de PID morto ou
          antigo removido; INI recente de PID vivo (build concorrente)
          preservado.

    Usa um HOME temporario pra nao tocar o cache real do usuario.

    Exit 0 se nenhum check reprovar, 1 caso contrario.
#>
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $root 'runner\BuildCache.ps1')
. (Join-Path $root 'runner\BuildTemp.ps1')

$fail = 0
function Add-Result([string]$tag, [string]$desc) {
    $color = switch ($tag) { 'PASS' {'Green'} 'FAIL' {'Red'} default {'DarkYellow'} }
    Write-Host ("  [{0}] {1}" -f $tag, $desc) -ForegroundColor $color
    if ($tag -eq 'FAIL') { $script:fail++ }
}
function Assert-Equal([string]$desc, $expected, $actual) {
    if ($expected -eq $actual) { Add-Result 'PASS' $desc }
    else { Add-Result 'FAIL' "$desc (esperado='$expected' obtido='$actual')" }
}

# --- Sandbox: HOME temporario + fontes falsos ---
$sandbox  = Join-Path $env:TEMP ('tlpp-cache-test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$projA    = Join-Path $sandbox 'projA\src'
$projB    = Join-Path $sandbox 'projB\src'
$fakeApo  = Join-Path $sandbox 'protheus\protheus\apo'
New-Item -ItemType Directory -Path $projA, $projB, $fakeApo -Force | Out-Null

$origHome = $env:USERPROFILE
$env:USERPROFILE = $sandbox

$rpo = Join-Path $fakeApo 'custom.rpo'
Set-Content -Path $rpo -Value 'rpo-v1' -Encoding UTF8

$cfgA = @{ Server='localhost'; Port=1268; Environment='DESENVOLVIMENTO'; ProtheusRoot=(Join-Path $sandbox 'protheus') }
$cfgB = @{ Server='localhost'; Port=1268; Environment='HOMOLOGACAO';     ProtheusRoot=(Join-Path $sandbox 'protheus') }

# Mesmo NOME de programa em dois projetos - o cenario de ponto de entrada
$srcA = Join-Path $projA 'MT410ROT.tlpp'
$srcB = Join-Path $projB 'MT410ROT.tlpp'
Set-Content -Path $srcA -Value 'user function MT410ROT() // versao projeto A' -Encoding UTF8
Set-Content -Path $srcB -Value 'user function MT410ROT() // versao projeto B' -Encoding UTF8

try {
    Write-Host "`n=== Test-BuildCache ===" -ForegroundColor Cyan
    Clear-BuildCache

    # C1 - nunca compilado
    $r = Test-BuildCacheHit -Path $srcA -Config $cfgA
    Assert-Equal 'C1 fonte nunca compilado -> MISS' $false $r.Hit

    # C2 - compilado, inalterado
    Update-BuildCache -Paths @($srcA) -Config $cfgA
    $r = Test-BuildCacheHit -Path $srcA -Config $cfgA
    Assert-Equal 'C2 compilado + inalterado -> HIT' $true $r.Hit

    # C3 - conteudo alterado
    Set-Content -Path $srcA -Value 'user function MT410ROT() // A editado' -Encoding UTF8
    $r = Test-BuildCacheHit -Path $srcA -Config $cfgA
    Assert-Equal 'C3 conteudo alterado -> MISS' $false $r.Hit
    Assert-Equal 'C3 motivo' 'conteudo alterado' $r.Reason

    # C4 - colisao entre projetos: projB pede o mesmo slot que projA ocupa
    Update-BuildCache -Paths @($srcA) -Config $cfgA     # projA (re)ocupa o slot
    $r = Test-BuildCacheHit -Path $srcB -Config $cfgA
    Assert-Equal 'C4 slot de outro projeto -> MISS' $false $r.Hit
    Assert-Equal 'C4 motivo' 'slot ocupado por outro fonte' $r.Reason
    Assert-Equal 'C4 reporta o dono do slot' $srcA $r.Owner

    # C5 - environment diferente e outro slot
    $r = Test-BuildCacheHit -Path $srcA -Config $cfgB
    Assert-Equal 'C5 outro environment -> MISS' $false $r.Hit

    # C6 - RPO mexido por fora
    Start-Sleep -Milliseconds 1100          # garante mtime distinto
    Set-Content -Path $rpo -Value 'rpo-v2-compilado-pelo-TDS' -Encoding UTF8
    $r = Test-BuildCacheHit -Path $srcA -Config $cfgA
    Assert-Equal 'C6 RPO alterado por fora -> MISS' $false $r.Hit
    Assert-Equal 'C6 motivo' 'RPO alterado fora do runner' $r.Reason

    # C7 - JSON corrompido nao explode
    Set-Content -Path (Get-BuildCachePath) -Value '{ isso nao e json' -Encoding UTF8
    $threw = $false
    try { $r = Test-BuildCacheHit -Path $srcA -Config $cfgA } catch { $threw = $true }
    Assert-Equal 'C7 JSON corrompido nao lanca excecao' $false $threw
    Assert-Equal 'C7 JSON corrompido -> MISS' $false $r.Hit

    # C8 - resolucao do slot ignora case do basename.
    # Em outro PROJETO (mesmo diretorio nao serve: no Windows 'mt410rot.tlpp' e
    # 'MT410ROT.tlpp' sao o mesmo arquivo). Se o lookup fosse case-sensitive,
    # 'mt410rot' nao acharia o slot 'MT410ROT' e daria HIT indevido.
    Clear-BuildCache
    Update-BuildCache -Paths @($srcA) -Config $cfgA
    $srcLower = Join-Path $projB 'mt410rot.tlpp'
    Set-Content -Path $srcLower -Value 'user function MT410ROT() // versao projeto B' -Encoding UTF8
    $r = Test-BuildCacheHit -Path $srcLower -Config $cfgA
    Assert-Equal 'C8 basename case-insensitive resolve o mesmo slot' 'slot ocupado por outro fonte' $r.Reason
    Assert-Equal 'C8 dono continua sendo o projeto A' $srcA $r.Owner

    # C9 - REGRESSAO: alteracao externa do RPO nao pode ser "re-abencoada".
    # Cenario: cache tem A e B; TDS compila por fora (stamp muda); usuario
    # compila SO A. Se Update-BuildCache gravar o stamp novo mantendo a entrada
    # de B, B volta a dar HIT apontando pra um RPO que nao e mais aquele.
    # E por isso que o chamador deve rodar Clear-BuildCacheEnvironment antes.
    Clear-BuildCache
    $srcOutro = Join-Path $projA 'OUTRO.tlpp'
    Set-Content -Path $srcOutro -Value 'user function OUTRO()' -Encoding UTF8
    Update-BuildCache -Paths @($srcA, $srcOutro) -Config $cfgA
    Assert-Equal 'C9 pre-condicao: OUTRO da HIT' $true (Test-BuildCacheHit -Path $srcOutro -Config $cfgA).Hit

    Start-Sleep -Milliseconds 1100
    Set-Content -Path $rpo -Value 'rpo-v3-compilado-pelo-TDS' -Encoding UTF8     # alteracao externa
    Assert-Equal 'C9 apos RPO externo: OUTRO da MISS' $false (Test-BuildCacheHit -Path $srcOutro -Config $cfgA).Hit

    Clear-BuildCacheEnvironment -Config $cfgA          # o que Invoke-TlppBuild faz ao detectar
    Update-BuildCache -Paths @($srcA) -Config $cfgA    # recompila SO A
    $r = Test-BuildCacheHit -Path $srcOutro -Config $cfgA
    Assert-Equal 'C9 OUTRO continua MISS apos rebuild de A' $false $r.Hit
    Assert-Equal 'C9 A (recompilado) da HIT' $true (Test-BuildCacheHit -Path $srcA -Config $cfgA).Hit

    # C10 - Clear-BuildCacheEnvironment nao afeta OUTROS environments
    Clear-BuildCache
    Update-BuildCache -Paths @($srcA) -Config $cfgA
    Update-BuildCache -Paths @($srcA) -Config $cfgB
    Clear-BuildCacheEnvironment -Config $cfgA
    Assert-Equal 'C10 env A limpo' $false (Test-BuildCacheHit -Path $srcA -Config $cfgA).Hit
    Assert-Equal 'C10 env B preservado' $true  (Test-BuildCacheHit -Path $srcA -Config $cfgB).Hit

    # C11 - lock ocupado por OUTRO PROCESSO: nao grava, em vez de gravar sem
    # lock e perder o update alheio.
    # Precisa ser outro processo: Mutex e REENTRANTE na mesma thread, entao
    # segurar o lock aqui e chamar Update-BuildCache logo abaixo apenas
    # re-adquiriria e o teste passaria sem testar nada.
    Clear-BuildCache
    Update-BuildCache -Paths @($srcA) -Config $cfgA
    $sinal = Join-Path $sandbox 'lock-pronto.txt'
    $job = Start-Job -ScriptBlock {
        param($sig)
        $m = New-Object System.Threading.Mutex($false, 'Global\tlpp-tdd-build-cache')
        [void]$m.WaitOne(5000)
        Set-Content -Path $sig -Value 'ok'
        Start-Sleep -Seconds 9        # > que os 5s de espera do Invoke-WithCacheLock
        $m.ReleaseMutex(); $m.Dispose()
    } -ArgumentList $sinal
    try {
        $esperou = 0
        while (-not (Test-Path $sinal) -and $esperou -lt 30) { Start-Sleep -Milliseconds 300; $esperou++ }
        if (-not (Test-Path $sinal)) {
            Add-Result 'SKIP' 'C11 job nao conseguiu segurar o lock - cenario nao exercitado'
        } else {
            $antes = Get-Content (Get-BuildCachePath) -Raw
            Update-BuildCache -Paths @($srcOutro) -Config $cfgA | Out-Null   # deve desistir
            $depois = Get-Content (Get-BuildCachePath) -Raw
            Assert-Equal 'C11 lock de outro processo: cache intacto' $antes $depois
        }
    } finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }

    # ===== Oraculo RPO (issue #33): logica pura de parse/decisao =====

    # C12 - parse do dataFonte real do GetAPOInfo ("YYYYMMDD HH:MM:SS")
    $dt = ConvertFrom-ApoDataFonte -DataFonte '20260511 16:22:27'
    Assert-Equal 'C12 parse dataFonte formato medido' ([datetime]'2026-05-11T16:22:27') $dt

    # C13 - formato alternativo da doc TDN ("HHMM:SS") tambem parseia
    $dt = ConvertFrom-ApoDataFonte -DataFonte '20260511 1622:27'
    Assert-Equal 'C13 parse dataFonte formato TDN' ([datetime]'2026-05-11T16:22:27') $dt

    # C14 - lixo/vazio/nulo -> $null, sem excecao
    Assert-Equal 'C14 dataFonte vazio -> null'   $null (ConvertFrom-ApoDataFonte -DataFonte '')
    Assert-Equal 'C14 dataFonte lixo -> null'    $null (ConvertFrom-ApoDataFonte -DataFonte 'nao-e-data')
    Assert-Equal 'C14 dataFonte so data parseia' ([datetime]'2026-05-11') (ConvertFrom-ApoDataFonte -DataFonte '20260511 ')

    # C15 - frescor: igual e +-2s = fresco; 3s = velho
    $base = [datetime]'2026-05-11T16:22:27'
    $entry = [pscustomobject]@{ exists = $true; dataFonte = '20260511 16:22:27' }
    Assert-Equal 'C15 mtime identico -> fresco'  $true  (Test-ApoFresh -ApoEntry $entry -DiskMtime $base)
    Assert-Equal 'C15 mtime +2s -> fresco'       $true  (Test-ApoFresh -ApoEntry $entry -DiskMtime $base.AddSeconds(2))
    Assert-Equal 'C15 mtime -2s -> fresco'       $true  (Test-ApoFresh -ApoEntry $entry -DiskMtime $base.AddSeconds(-2))
    Assert-Equal 'C15 mtime +3s -> velho'        $false (Test-ApoFresh -ApoEntry $entry -DiskMtime $base.AddSeconds(3))

    # C16 - ausente do RPO ou dataFonte invalido -> nunca fresco
    $ausente = [pscustomobject]@{ exists = $false; dataFonte = '' }
    Assert-Equal 'C16 exists=false -> velho' $false (Test-ApoFresh -ApoEntry $ausente -DiskMtime $base)
    $semData = [pscustomobject]@{ exists = $true; dataFonte = '' }
    Assert-Equal 'C16 dataFonte vazio -> velho' $false (Test-ApoFresh -ApoEntry $semData -DiskMtime $base)
    Assert-Equal 'C16 entry nulo -> velho' $false (Test-ApoFresh -ApoEntry $null -DiskMtime $base)

    # C17 - parse da resposta do u_tecApoStat (string result do /runner/exec)
    $raw = '{"programs":{"TECWRAP.TLPP":{"exists":true,"dataFonte":"20260511 16:22:27"},"NAOEXISTE999.TLPP":{"exists":false,"dataFonte":""}}}'
    $stat = ConvertFrom-ApoStatResult -ResultJson $raw
    Assert-Equal 'C17 programa existente presente'   $true ($null -ne $stat['TECWRAP.TLPP'])
    Assert-Equal 'C17 exists propagado'              $true $stat['TECWRAP.TLPP'].exists
    Assert-Equal 'C17 dataFonte propagado'           '20260511 16:22:27' $stat['TECWRAP.TLPP'].dataFonte
    Assert-Equal 'C17 inexistente presente'          $true ($null -ne $stat['NAOEXISTE999.TLPP'])
    Assert-Equal 'C17 inexistente exists=false'      $false $stat['NAOEXISTE999.TLPP'].exists
    Assert-Equal 'C17 json lixo -> null, sem excecao' $null (ConvertFrom-ApoStatResult -ResultJson '{nao json')

    # C18 - oraculo com REST inalcancavel: $null rapido, sem excecao (fallback)
    $cfgOff = @{ BaseUrl='http://127.0.0.1:1/rest'; User='x'; Password='y' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Get-RpoApoStat -Config $cfgOff -FileNames @('TECWRAP.TLPP')
    $sw.Stop()
    Assert-Equal 'C18 REST fora -> null (fallback pro cache)' $null $r
    Assert-Equal 'C18 falha rapida (<10s)' $true ($sw.Elapsed.TotalSeconds -lt 10)
    Assert-Equal 'C18 config sem BaseUrl -> null' $null (Get-RpoApoStat -Config @{} -FileNames @('X.TLPP'))

    # ===== INI temporario com senha (runner/BuildTemp.ps1) =====
    # O build-<PID>.ini tem `psw=` em texto plano. Antes ele NUNCA era apagado -
    # dezenas de arquivos com senha ficavam no %TEMP%.
    $tmpIni = Join-Path $sandbox 'tmpini'
    New-Item -ItemType Directory -Path $tmpIni -Force | Out-Null
    function New-FakeIniFile([string]$dir, [int]$fPid, [datetime]$mtime) {
        $p = Join-Path $dir "build-$fPid.ini"
        Set-Content -Path $p -Value "psw=segredo`r`n" -Encoding ASCII
        (Get-Item $p).LastWriteTime = $mtime
        return $p
    }

    # C19 - compile OK: INI some
    $ok = New-FakeIniFile $tmpIni 111 (Get-Date)
    $r = Invoke-AdvplsCli -AdvplsPath 'fake.exe' -IniPath $ok -Invoker {
        param($exe, $ini) $global:LASTEXITCODE = 0; 'ALL FILES COMPILED'
    }
    Assert-Equal 'C19 INI apagado apos compile OK' $false (Test-Path $ok)
    Assert-Equal 'C19 exit code propagado'         0     $r.ExitCode
    Assert-Equal 'C19 output propagado' 'ALL FILES COMPILED' ([string]$r.Output)

    # C20 - compile FALHO: INI some do mesmo jeito (era o vazamento mais comum)
    $bad = New-FakeIniFile $tmpIni 112 (Get-Date)
    $r = Invoke-AdvplsCli -AdvplsPath 'fake.exe' -IniPath $bad -Invoker {
        param($exe, $ini) $global:LASTEXITCODE = 1; '[ERROR] nao compilou'
    }
    Assert-Equal 'C20 INI apagado apos compile FALHO' $false (Test-Path $bad)
    Assert-Equal 'C20 exit code de falha propagado'   1     $r.ExitCode

    # C21 - advpls explode (exe inexistente, Ctrl+C): finally ainda apaga
    $boom = New-FakeIniFile $tmpIni 113 (Get-Date)
    $threw = $false
    try {
        Invoke-AdvplsCli -AdvplsPath 'fake.exe' -IniPath $boom -Invoker { throw 'advpls sumiu' } | Out-Null
    } catch { $threw = $true }
    Assert-Equal 'C21 excecao propagada'            $true  $threw
    Assert-Equal 'C21 INI apagado apos excecao'     $false (Test-Path $boom)

    # C22 - varredura de orfaos: PID morto sai, PID vivo recente fica
    $morto   = New-FakeIniFile $tmpIni 201 (Get-Date)
    $vivo    = New-FakeIniFile $tmpIni 202 (Get-Date)
    $meu     = New-FakeIniFile $tmpIni 203 (Get-Date)
    $vivoOld = New-FakeIniFile $tmpIni 204 (Get-Date).AddHours(-3)
    $naoPad  = Join-Path $tmpIni 'build-outra-coisa.ini'
    Set-Content -Path $naoPad -Value 'x' -Encoding ASCII

    # Injetado pra o teste nao depender de quais PIDs a maquina tem vivos agora.
    $alive = { param($p) $p -in @(202, 203, 204) }
    $null = Remove-OrphanBuildIni -TmpDir $tmpIni -CurrentPid 203 -MaxAgeHours 1 -IsPidAlive $alive

    Assert-Equal 'C22 orfao de PID morto removido'          $false (Test-Path $morto)
    Assert-Equal 'C22 INI recente de PID vivo preservado'   $true  (Test-Path $vivo)
    Assert-Equal 'C22 INI do proprio PID preservado'        $true  (Test-Path $meu)
    Assert-Equal 'C22 INI antigo (PID reciclado) removido'  $false (Test-Path $vivoOld)
    Assert-Equal 'C22 arquivo fora do padrao intocado'      $true  (Test-Path $naoPad)

    # C23 - checker default (Get-Process real): o PID desta sessao esta vivo.
    # CurrentPid=0 pra que a preservacao venha da liveness, nao da excecao do self.
    $selfIni = New-FakeIniFile $tmpIni $PID (Get-Date)
    $null = Remove-OrphanBuildIni -TmpDir $tmpIni -CurrentPid 0
    Assert-Equal 'C23 checker real: PID vivo preservado' $true (Test-Path $selfIni)

    # C24 - diretorio inexistente nao explode
    $threw = $false
    try { $null = Remove-OrphanBuildIni -TmpDir (Join-Path $sandbox 'nao-existe') } catch { $threw = $true }
    Assert-Equal 'C24 TmpDir inexistente -> sem excecao' $false $threw

} catch {
    # Sem isso um erro terminante pularia os asserts restantes e o resumo sairia
    # "tudo OK" com $fail=0 - falso-verde.
    Add-Result 'FAIL' "excecao inesperada: $($_.Exception.Message)"
} finally {
    $env:USERPROFILE = $origHome
    Remove-Item -Path $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($fail -eq 0) { Write-Host "Test-BuildCache: tudo OK" -ForegroundColor Green; exit 0 }
Write-Host "Test-BuildCache: $fail check(s) reprovaram" -ForegroundColor Red
exit 1
