<#
.SYNOPSIS
    Teste do New-IsolatedInstance.ps1 - isolamento por projeto (issue #34).

.DESCRIPTION
    Logica pura: ProtheusRoot FALSO em $env:TEMP (arvore minima com arquivos
    dummy de bytes). NAO sobe appserver, NAO chama advpls, NAO copia 485MB.

    Cenarios:
      S1  nome invalido -> excecao (nada criado)
      S2  -DryRun nao toca em nada (mas ja mostra as portas escolhidas)
      S3  alocacao pula porta RESERVADA em ini de outra instancia
      S4  alocacao pula porta EM USO (listener de verdade no proprio teste)
      S5  ini gerado: environment, as 3 portas, SourcePath/RpoCustom, TOPALias
      S6  ini gravado sem BOM (Latin1 28591, como o resto do repo)
      S7  arvore copiada: subdiretorio vem, console.log e ini original NAO vem
      S8  RPO base copiado byte a byte; custom.rpo NAO e criado (AppServer cria)
      S9  isolation gravado no .tlpp-tdd.json PRESERVANDO chaves desconhecidas
      S10 idempotencia: re-rodar sem -Force nao altera nada e mantem as portas
      S11 -Force repara o ini (com backup) reaproveitando as portas do json
      S12 -SeedCustomFrom copia o custom.rpo; nao sobrescreve o que ja existe
      S13 sem RPO base no SourceApo -> excecao (instancia nao funcionaria)
      S14 json sem isolation -> portas vem do PROPRIO ini (regressao 8.3 vs longo)
      S15 InstanceControl: os tres caminhos que NAO sobem processo

    NOTA sobre o S15: Start-IsolatedInstanceIfNeeded so e exercitado nos casos em
    que ele NAO chama Start-Process (sem isolamento / porta ja aberta / arvore
    incompleta). Subir appserver de verdade e trabalho pro ambiente real.

    Exit 0 se nenhum check reprovar, 1 caso contrario.
#>
$ErrorActionPreference = 'Continue'
$root   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script = Join-Path $root 'runner\install\New-IsolatedInstance.ps1'
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
. (Join-Path $root 'runner\InstanceControl.ps1')

$fail = 0
function Add-Result([string]$tag, [string]$desc) {
    $color = switch ($tag) { 'PASS' {'Green'} 'FAIL' {'Red'} default {'DarkYellow'} }
    Write-Host ("  [{0}] {1}" -f $tag, $desc) -ForegroundColor $color
    if ($tag -eq 'FAIL') { $script:fail++ }
}
function Assert-True([string]$desc, $cond) {
    if ($cond) { Add-Result 'PASS' $desc } else { Add-Result 'FAIL' $desc }
}
function Assert-Equal([string]$desc, $expected, $actual) {
    if ($expected -eq $actual) { Add-Result 'PASS' $desc }
    else { Add-Result 'FAIL' "$desc (esperado='$expected' obtido='$actual')" }
}

# O script escreve muito com Write-Host; o UNICO objeto que vai pro pipeline e o
# resumo. Filtrar por propriedade em vez de pegar [0] evita que output futuro
# (ou de um script chamado) passe por resumo e produza falso-verde.
function Invoke-Iso {
    $out = & $script @args
    return ($out | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'BinDir' } | Select-Object -Last 1)
}

$sandbox = Join-Path $env:TEMP ('tlpp-iso-test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$prot    = Join-Path $sandbox 'TOTVS'
$binRoot = Join-Path $prot 'Protheus\bin'
$srcBin  = Join-Path $binRoot 'appserver_rest'
$srcApo  = Join-Path $prot 'protheus\apo'
$listener = $null

try {
    Write-Host "`n=== Test-IsolatedInstance ===" -ForegroundColor Cyan

    # ---------------- Sandbox: ProtheusRoot falso ----------------
    New-Item -ItemType Directory -Path (Join-Path $srcBin 'lib') -Force | Out-Null
    New-Item -ItemType Directory -Path $srcApo -Force | Out-Null

    # appserver.ini da instancia-FONTE (nao deve ser copiado - o novo e gerado).
    # TOP* presentes: e daqui que a instancia nova HERDA o banco de SISTEMA.
    [System.IO.File]::WriteAllText((Join-Path $srcBin 'appserver.ini'),
        "[DESENVOLVIMENTO]`r`nSourcePath=$srcApo`r`nStartSysInDB=1`r`nTOPDataBase=MSSQL`r`nTOPServer=sqlhost`r`nTOPALias=BancoSistemaDev`r`nTOPPort=7899`r`n`r`n[GENERAL]`r`napp_environment=DESENVOLVIMENTO`r`n`r`n[TCP]`r`nPort=1268`r`n`r`n[HTTPREST]`r`nPort=8401`r`n", $latin1)
    # dummies: exe, dll em subdir e um console.log que NAO deve viajar
    [System.IO.File]::WriteAllBytes((Join-Path $srcBin 'appserver.exe'), [byte[]](1,2,3,4))
    [System.IO.File]::WriteAllBytes((Join-Path $srcBin 'lib\alguma.dll'), [byte[]](9,9,9))
    [System.IO.File]::WriteAllText((Join-Path $srcBin 'console.log'), 'log da outra instancia', $latin1)

    # RPO base dummy (o real tem ~957MB e PRECISA ser copiado - hardlink refutado no spike)
    $rpoBytes = [byte[]](10..40)
    [System.IO.File]::WriteAllBytes((Join-Path $srcApo 'tttm120.rpo'), $rpoBytes)
    # custom.rpo do ambiente compartilhado: NAO entra na copia automatica
    [System.IO.File]::WriteAllBytes((Join-Path $srcApo 'custom.rpo'), [byte[]](77,78,79))

    # Outra instancia (fake) reservando exatamente as portas-base -> a alocacao
    # tem de pular. Cenario real: DENK em 1269/8402/8099, desligada na hora do init.
    $fakeInst = Join-Path $binRoot 'appserver_vizinho'
    New-Item -ItemType Directory -Path $fakeInst -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fakeInst 'appserver.ini'),
        "[VIZINHO]`r`nSourcePath=x`r`n`r`n[TCP]`r`nPort=1270`r`n`r`n[HTTPREST]`r`nPort=8403`r`n`r`n[WEBAPP]`r`nPort=8100`r`n", $latin1)

    function New-Proj([string]$nome, [string]$json) {
        $p = Join-Path $sandbox $nome
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        if ($json) { [System.IO.File]::WriteAllText((Join-Path $p '.tlpp-tdd.json'), $json, [System.Text.UTF8Encoding]::new($false)) }
        return $p
    }

    # ---------------- S1: nome invalido ----------------
    $proj = New-Proj 'ruim' $null
    $threw = $false
    try { Invoke-Iso -ProjectRoot $proj -Name 'meu-proj' -ProtheusRoot $prot -DryRun *>&1 | Out-Null }
    catch { $threw = $true }
    Assert-True 'S1 nome invalido rejeitado' $threw
    Assert-True 'S1 nada criado apos rejeicao' (-not (Test-Path (Join-Path $binRoot 'appserver_meu-proj')))

    # ---------------- S2/S3: DryRun + portas reservadas ----------------
    $proj = New-Proj 'p1' '{ "name": "P1" }'
    $dry = Invoke-Iso -ProjectRoot $proj -Name 'P1' -ProtheusRoot $prot -DryRun
    Assert-True 'S2 DryRun devolve resumo'            ($null -ne $dry)
    Assert-True 'S2 DryRun nao cria o bin'            (-not (Test-Path (Join-Path $binRoot 'appserver_p1')))
    Assert-True 'S2 DryRun nao cria o apo'            (-not (Test-Path (Join-Path $prot 'protheus\apo_p1')))
    Assert-True 'S2 DryRun nao grava isolation'       ((Get-Content (Join-Path $proj '.tlpp-tdd.json') -Raw) -notmatch 'isolation')
    Assert-Equal 'S2 environment = nome em maiusculas' 'P1' $dry.Environment

    Assert-True "S3 TCP pulou 1270 (reservada pelo vizinho): $($dry.TcpPort)"       ($dry.TcpPort -ne 1270 -and $dry.TcpPort -ge 1270)
    Assert-True "S3 HTTPREST pulou 8403 (reservada): $($dry.RestPort)"              ($dry.RestPort -ne 8403 -and $dry.RestPort -ge 8403)
    Assert-True "S3 WEBAPP pulou 8100 (reservada): $($dry.WebAppPort)"              ($dry.WebAppPort -ne 8100 -and $dry.WebAppPort -ge 8100)

    # ---------------- S4: porta EM USO tambem e pulada ----------------
    # Bind de verdade (sem appserver): a sondagem tem de enxergar isso, senao
    # duas instancias brigariam pela mesma porta na primeira subida.
    $busy = $dry.TcpPort
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $busy)
    $listener.Start()
    $dry2 = Invoke-Iso -ProjectRoot (New-Proj 'p2' '{ "name": "P2" }') -Name 'P2' -ProtheusRoot $prot -DryRun
    Assert-True "S4 porta em uso ($busy) pulada -> $($dry2.TcpPort)" ($dry2.TcpPort -ne $busy)
    $listener.Stop(); $listener = $null

    # ---------------- S5..S9: criacao de verdade ----------------
    # json com chave desconhecida + schemaPath: o isolation nao pode apagar nada
    $proj = New-Proj 'p3' '{ "name": "P3", "schemaPath": "db\\x.sql", "chaveFutura": {"a": 1} }'
    $res = Invoke-Iso -ProjectRoot $proj -Name 'P3' -ProtheusRoot $prot -TopAlias 'PROTHEUS_TST_P3'
    Assert-True 'S5 criacao devolve resumo' ($null -ne $res)
    Assert-True 'S5 Created=true'           ($res.Created)

    $iniTxt = $latin1.GetString([System.IO.File]::ReadAllBytes($res.IniPath))
    Assert-True 'S5 ini tem secao do environment' ($iniTxt -match '(?m)^\[P3\]')
    Assert-True 'S5 ini tem app_environment'      ($iniTxt -match '(?m)^app_environment=P3\s*$')
    Assert-True 'S5 ini tem porta TCP'            ($iniTxt -match "(?ms)^\[TCP\].*?^Port=$($res.TcpPort)\s*$")
    Assert-True 'S5 ini tem porta HTTPREST'       ($iniTxt -match "(?ms)^\[HTTPREST\].*?^Port=$($res.RestPort)\s*$")
    Assert-True 'S5 ini tem porta WEBAPP'         ($iniTxt -match "(?ms)^\[WEBAPP\].*?^Port=$($res.WebAppPort)\s*$")
    Assert-True 'S5 ini aponta SourcePath no apo da instancia' ($iniTxt -match ('(?m)^SourcePath=' + [regex]::Escape($res.ApoDir) + '\s*$'))
    Assert-True 'S5 ini aponta RpoCustom no apo da instancia'  ($iniTxt -match ('(?m)^RpoCustom=' + [regex]::Escape((Join-Path $res.ApoDir 'custom.rpo')) + '\s*$'))
    Assert-True 'S5 ini tem TOPALias do banco do projeto'      ($iniTxt -match '(?m)^TOPALias=PROTHEUS_TST_P3\s*$')
    Assert-True 'S5 ini mantem RootPath compartilhado'         ($iniTxt -match ('(?m)^RootPath=' + [regex]::Escape((Join-Path $prot 'protheus_data')) + '\s*$'))
    Assert-True 'S5 ini declara HTTPURI /rest'                 ($iniTxt -match '(?m)^URL=/rest\s*$')

    $iniBytes = [System.IO.File]::ReadAllBytes($res.IniPath)
    $temBom = ($iniBytes.Length -ge 3 -and $iniBytes[0] -eq 0xEF -and $iniBytes[1] -eq 0xBB -and $iniBytes[2] -eq 0xBF)
    Assert-True 'S6 ini gravado sem BOM' (-not $temBom)

    Assert-True 'S7 arvore copiada (exe)'            (Test-Path (Join-Path $res.BinDir 'appserver.exe'))
    Assert-True 'S7 arvore copiada (subdiretorio)'   (Test-Path (Join-Path $res.BinDir 'lib\alguma.dll'))
    Assert-True 'S7 console.log da fonte NAO copiado' (-not (Test-Path (Join-Path $res.BinDir 'console.log')))
    Assert-True 'S7 ini NAO e o da fonte (nao tem [DESENVOLVIMENTO])' ($iniTxt -notmatch '\[DESENVOLVIMENTO\]')

    $rpoDst = Join-Path $res.ApoDir 'tttm120.rpo'
    Assert-True 'S8 RPO base copiado' (Test-Path $rpoDst)
    if (Test-Path $rpoDst) {
        $dstBytes = [System.IO.File]::ReadAllBytes($rpoDst)
        $igual = $dstBytes.Length -eq $rpoBytes.Length
        if ($igual) { for ($i = 0; $i -lt $rpoBytes.Length; $i++) { if ($dstBytes[$i] -ne $rpoBytes[$i]) { $igual = $false; break } } }
        Assert-True 'S8 RPO base copiado byte a byte' $igual
    }
    Assert-True 'S8 custom.rpo NAO criado (AppServer cria na 1a compilacao)' (-not (Test-Path (Join-Path $res.ApoDir 'custom.rpo')))

    $pj = Get-Content (Join-Path $proj '.tlpp-tdd.json') -Raw | ConvertFrom-Json
    Assert-Equal 'S9 isolation.tcpPort gravado'    $res.TcpPort    $pj.isolation.tcpPort
    Assert-Equal 'S9 isolation.restPort gravado'   $res.RestPort   $pj.isolation.restPort
    Assert-Equal 'S9 isolation.webAppPort gravado' $res.WebAppPort $pj.isolation.webAppPort
    Assert-Equal 'S9 name preservado'              'P3'            $pj.name
    Assert-Equal 'S9 schemaPath preservado'        'db\x.sql'      $pj.schemaPath
    Assert-Equal 'S9 chave desconhecida preservada' 1              $pj.chaveFutura.a

    # ---------------- S10: idempotencia sem -Force ----------------
    $iniMd5Antes = (Get-FileHash $res.IniPath -Algorithm MD5).Hash
    $jsonAntes   = Get-Content (Join-Path $proj '.tlpp-tdd.json') -Raw
    $res2 = Invoke-Iso -ProjectRoot $proj -Name 'P3' -ProtheusRoot $prot
    Assert-True  'S10 re-rodar nao recria (Created=false)' (-not $res2.Created)
    Assert-Equal 'S10 ini intacto'   $iniMd5Antes (Get-FileHash $res.IniPath -Algorithm MD5).Hash
    Assert-Equal 'S10 json intacto'  $jsonAntes   (Get-Content (Join-Path $proj '.tlpp-tdd.json') -Raw)
    Assert-Equal 'S10 portas preservadas (TCP)'  $res.TcpPort  $res2.TcpPort
    Assert-Equal 'S10 portas preservadas (REST)' $res.RestPort $res2.RestPort

    # ---------------- S11: -Force repara o ini reaproveitando as portas ----------------
    [System.IO.File]::WriteAllText($res.IniPath, "[QUEBRADO]`r`n", $latin1)
    $res3 = Invoke-Iso -ProjectRoot $proj -Name 'P3' -ProtheusRoot $prot -Force
    $iniTxt3 = $latin1.GetString([System.IO.File]::ReadAllBytes($res.IniPath))
    Assert-True  'S11 -Force marca Repaired'         ($res3.Repaired)
    Assert-True  'S11 -Force regrava o ini'          ($iniTxt3 -match '(?m)^\[P3\]')
    Assert-Equal 'S11 -Force mantem a porta TCP do json' $res.TcpPort  $res3.TcpPort
    Assert-Equal 'S11 -Force mantem a porta REST do json' $res.RestPort $res3.RestPort
    Assert-True  'S11 -Force fez backup do ini anterior' `
        ((Get-ChildItem -Path $res.BinDir -Filter 'appserver.ini.bak.*' -File -ErrorAction SilentlyContinue).Count -ge 1)
    Assert-True  'S11 RPO base nao foi recopiado a toa (mesmo tamanho)' `
        ((Get-Item $rpoDst).Length -eq $rpoBytes.Length)

    # ---------------- S12: -SeedCustomFrom ----------------
    $proj4 = New-Proj 'p4' '{ "name": "P4" }'
    $seed  = Join-Path $srcApo 'custom.rpo'
    $res4  = Invoke-Iso -ProjectRoot $proj4 -Name 'P4' -ProtheusRoot $prot -SeedCustomFrom $seed
    $custom4 = Join-Path $res4.ApoDir 'custom.rpo'
    Assert-True 'S12 custom.rpo semeado' (Test-Path $custom4)
    if (Test-Path $custom4) {
        Assert-Equal 'S12 custom.rpo semeado com o tamanho da origem' (Get-Item $seed).Length (Get-Item $custom4).Length
    }
    # Nao sobrescreve: apos compilar, o custom.rpo da instancia e o ativo do projeto
    [System.IO.File]::WriteAllBytes($custom4, [byte[]](1..20))
    Invoke-Iso -ProjectRoot $proj4 -Name 'P4' -ProtheusRoot $prot -SeedCustomFrom $seed -Force | Out-Null
    Assert-Equal 'S12 custom.rpo existente NAO sobrescrito' 20 (Get-Item $custom4).Length

    # ---------------- S14: json sem isolation -> portas vem do PROPRIO ini ----------------
    # REGRESSAO: a exclusao do proprio ini da lista de reservados comparava
    # CAMINHO, e o FullName do Get-ChildItem vem em forma longa enquanto o
    # caminho montado por Join-Path preserva a forma curta 8.3 - nunca batia. A
    # instancia entrava na propria lista e um reparo realocava tudo, deixando o
    # ini apontando pra portas diferentes das que o projeto ja usava.
    $isoAntes = Get-Content (Join-Path $proj4 '.tlpp-tdd.json') -Raw | ConvertFrom-Json
    [System.IO.File]::WriteAllText((Join-Path $proj4 '.tlpp-tdd.json'), '{ "name": "P4" }', [System.Text.UTF8Encoding]::new($false))
    $res5 = Invoke-Iso -ProjectRoot $proj4 -Name 'P4' -ProtheusRoot $prot -Force
    Assert-Equal 'S14 TCP reaproveitada do proprio ini'      $isoAntes.isolation.tcpPort    $res5.TcpPort
    Assert-Equal 'S14 HTTPREST reaproveitada do proprio ini' $isoAntes.isolation.restPort   $res5.RestPort
    Assert-Equal 'S14 WEBAPP reaproveitada do proprio ini'   $isoAntes.isolation.webAppPort $res5.WebAppPort
    $isoDepois = Get-Content (Join-Path $proj4 '.tlpp-tdd.json') -Raw | ConvertFrom-Json
    Assert-Equal 'S14 isolation regravado no json' $isoAntes.isolation.tcpPort $isoDepois.isolation.tcpPort

    # ---------------- S13: SourceApo sem RPO base ----------------
    $apoVazio = Join-Path $sandbox 'apo-vazio'
    New-Item -ItemType Directory -Path $apoVazio -Force | Out-Null
    $threw = $false
    try { Invoke-Iso -ProjectRoot (New-Proj 'p5' '{ "name": "P5" }') -Name 'P5' -ProtheusRoot $prot -SourceApo $apoVazio -DryRun *>&1 | Out-Null }
    catch { $threw = $true }
    Assert-True 'S13 SourceApo sem *.rpo -> excecao' $threw

    # ---------------- S15: InstanceControl sem subir processo ----------------
    # a) projeto sem isolamento: NO-OP silencioso (caminho mais comum - todo
    #    build/test de projeto nao isolado passa por aqui)
    $r = Start-IsolatedInstanceIfNeeded -Config @{ Port = 1268; Server = 'localhost' }
    Assert-True  'S15a sem isolamento -> nao inicia' (-not $r.Started)
    Assert-Equal 'S15a motivo'                       'projeto sem isolamento' $r.Reason

    # b) porta TCP ja aceitando conexao = instancia de pe -> nao sobe um segundo
    #    processo (dois no mesmo RPO = lock garantido)
    $portOcupada = 1
    for ($p = 1400; $p -lt 1500; $p++) {
        try {
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $p)
            $listener.Start(); $portOcupada = $p; break
        } catch { $listener = $null }
    }
    if ($portOcupada -eq 1) {
        Add-Result 'SKIP' 'S15b nao consegui abrir porta pra simular instancia viva'
    } else {
        $r = Start-IsolatedInstanceIfNeeded -Config @{
            Port = $portOcupada; Server = 'localhost'; IsolationBinDir = $srcBin
            Environment = 'P1'; BaseUrl = "http://localhost:$portOcupada/rest"
        }
        Assert-True 'S15b instancia de pe -> nao inicia'          (-not $r.Started)
        Assert-True 'S15b motivo cita que ja esta rodando'        ($r.Reason -match 'ja rodando')
    }
    if ($listener) { $listener.Stop(); $listener = $null }

    # c) isolamento declarado com arvore incompleta: avisa e devolve, NAO lanca
    #    (falhar aqui nao pode reprovar um build)
    $vazio = Join-Path $sandbox 'bin-vazio'
    New-Item -ItemType Directory -Path $vazio -Force | Out-Null
    $threw = $false
    try {
        # 6>$null descarta so o Write-Host (stream de informacao); o objeto de
        # retorno continua vindo pelo stream de sucesso.
        $r = Start-IsolatedInstanceIfNeeded -Config @{
            Port = 65000; Server = 'localhost'; IsolationBinDir = $vazio
            Environment = 'P9'; BaseUrl = 'http://localhost:65001/rest'
        } 6>$null
    } catch { $threw = $true }
    Assert-True 'S15c arvore incompleta -> sem excecao' (-not $threw)
    Assert-True 'S15c arvore incompleta -> nao inicia'  ($r -and -not $r.Started)

    # ---------------- S16: TOP do environment HERDADO da origem ----------------
    # O environment da instancia precisa do banco de SISTEMA (StartSysInDB=1) -
    # o mesmo do ini-fonte. O banco de teste do projeto e outro canal (TCLink).
    # Sem -TopAlias, o gerado tem que herdar TOPALias/TOPServer/TOPPort da fonte,
    # e NUNCA apontar pro PROTHEUS_TST_<NAME>.
    $proj = New-Proj 'p16' '{ "name": "P16" }'
    $res16 = Invoke-Iso -ProjectRoot $proj -Name 'P16' -ProtheusRoot $prot
    $ini16 = [System.IO.File]::ReadAllText((Join-Path $binRoot 'appserver_p16\appserver.ini'))
    Assert-True 'S16 TOPALias herdado da origem'          ($ini16 -match '(?m)^TOPALias=BancoSistemaDev\s*$')
    Assert-True 'S16 TOPServer herdado'                   ($ini16 -match '(?m)^TOPServer=sqlhost\s*$')
    Assert-True 'S16 TOPPort herdado'                     ($ini16 -match '(?m)^TOPPort=7899\s*$')
    Assert-True 'S16 environment NAO aponta pro banco de teste' ($ini16 -notmatch 'TOPALias=PROTHEUS_TST')

    # origem SEM TOPALias: falha explicita (chute de banco de sistema e pior)
    $srcSem = Join-Path $binRoot 'appserver_semtop'
    New-Item -ItemType Directory -Path $srcSem -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $srcSem 'appserver.ini'),
        "[DEV]`r`nSourcePath=$srcApo`r`n`r`n[TCP]`r`nPort=1500`r`n", $latin1)
    [System.IO.File]::WriteAllBytes((Join-Path $srcSem 'appserver.exe'), [byte[]](1,2))
    $threw = $false
    try { Invoke-Iso -ProjectRoot (New-Proj 'p17' '{ "name": "P17" }') -Name 'P17' -ProtheusRoot $prot -SourceBin $srcSem -DryRun *>&1 | Out-Null }
    catch { $threw = $true }
    Assert-True 'S16 origem sem TOPALias -> erro claro (sem chute)' $threw

} catch {
    # Sem isso uma excecao terminante pularia os asserts restantes e o resumo
    # sairia "tudo OK" com $fail=0 - falso-verde.
    Add-Result 'FAIL' "excecao inesperada: $($_.Exception.Message)"
} finally {
    if ($listener) { try { $listener.Stop() } catch { } }
    Remove-Item -Path $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($fail -eq 0) { Write-Host "Test-IsolatedInstance: tudo OK" -ForegroundColor Green; exit 0 }
Write-Host "Test-IsolatedInstance: $fail check(s) reprovaram" -ForegroundColor Red
exit 1
