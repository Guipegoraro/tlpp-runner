<#
.SYNOPSIS
    Cria uma instancia AppServer DEDICADA a um projeto - RPO, portas e
    appserver.ini proprios (issue #34).

.DESCRIPTION
    Isolamento opt-in: projeto que quer compilar sem derrubar o HTTPREST dos
    outros (issue #29 - qualquer compilacao derruba o REST ate o proximo ciclo do RefreshRate) ganha
    a sua propria instancia:

      <ProtheusRoot>\Protheus\bin\appserver_<nome>\   (copia de appserver_rest)
      <ProtheusRoot>\protheus\apo_<nome>\             (RPO proprio)

    O `RootPath` (protheus_data), o DBAccess e o License Server continuam
    COMPARTILHADOS - o que se isola e o repositorio de objetos e as portas.

    FATOS MEDIDOS NO SPIKE (29/07/2026) que moldam este script:

      1. O RPO padrao (`tttm120.rpo`, ~957 MB) NAO pode ser compartilhado entre
         instancias que COMPILAM. Hardlink foi refutado: servir funciona, mas o
         build falha com lock ("cannot access the file ... DEFAULT"). Por isso
         aqui se COPIA o(s) .rpo base de `<ProtheusRoot>\protheus\apo\`.
      2. O `custom.rpo` NAO precisa ser criado: o AppServer cria sozinho na
         primeira compilacao se o path do `RpoCustom` nao existir. Semear com um
         custom.rpo existente e opcional (-SeedCustomFrom).
      3. Compilar na instancia isolada nao afeta as outras (0 downtime medido na
         8401).
      4. O processo PRECISA subir com `-console`; sem isso ele sai em silencio.
         Quem sobe e o `runner/InstanceControl.ps1` (on-demand, no build/test).

    Portas sao alocadas na criacao e gravadas no `.tlpp-tdd.json` do projeto,
    em `isolation: { tcpPort, restPort, webAppPort }`. A presenca desse objeto
    e o que marca o projeto como isolado para o cascade (`runner.config.ps1`).

    IDEMPOTENTE: instancia ja existente nao e destruida. Sem `-Force`, apenas
    reporta e sai. Com `-Force`, regrava o appserver.ini (com backup) e o json,
    preservando o `custom.rpo` ja compilado.

.PARAMETER ProjectRoot
    Raiz do projeto (onde vive/vai viver o .tlpp-tdd.json).

.PARAMETER Name
    Nome do projeto. Valida [A-Z][A-Z0-9_]{0,19}. Deriva:
      environment  = <NAME em maiusculas>
      bin da inst. = appserver_<name em minusculas>
      RPO da inst. = apo_<name em minusculas>

.PARAMETER ProtheusRoot
    Raiz da instalacao Protheus (a que contem Protheus\bin e protheus\apo).

.PARAMETER SourceBin
    Arvore do AppServer a copiar. Default <ProtheusRoot>\Protheus\bin\appserver_rest.

.PARAMETER SourceApo
    Diretorio com o(s) RPO base a copiar. Default <ProtheusRoot>\protheus\apo.

.PARAMETER SeedCustomFrom
    Copia um custom.rpo existente pra instancia nova (opcional). Omitido = RPO
    custom limpo, criado pelo AppServer na primeira compilacao.

.PARAMETER TopAlias
    Alias DBAccess do banco do ENVIRONMENT da instancia. Default: HERDADO do
    appserver.ini de origem (SourceBin). ATENCAO: este e o banco de SISTEMA
    (dicionarios SX*, StartSysInDB=1) - NAO e o banco de teste do projeto.
    O banco de teste (PROTHEUS_TST_<NAME>) continua acessado via TCLink pelos
    helpers de integracao, exatamente como no AppServer dev compartilhado.
    Apontar o environment pro banco de teste (que so tem Z_TST_*) faria a
    instancia tentar criar/nao achar as tabelas de sistema no boot.

.PARAMETER TopServer
.PARAMETER TopDatabase
    Servidor e driver do DBAccess. Default: herdados do ini de origem
    (fallback localhost/MSSQL).

.PARAMETER TopPort
    Porta do DBAccess (compartilhado). Default: herdada do ini de origem
    (fallback 7892).

.PARAMETER TcpPort
.PARAMETER RestPort
.PARAMETER WebAppPort
    Fixam a porta em vez de alocar. Uteis pra reparo e pra teste deterministico.

.PARAMETER DryRun
    Mostra o plano (inclusive as portas escolhidas) e NAO toca em nada.

.PARAMETER Force
    Repara instancia existente: regrava appserver.ini (com backup) e o json.

.OUTPUTS
    PSCustomObject com Name, Environment, BinDir, ApoDir, IniPath, TcpPort,
    RestPort, WebAppPort, TopAlias, Created, Repaired, DryRun.

.EXAMPLE
    .\New-IsolatedInstance.ps1 -ProjectRoot C:\projetos\meu -Name MEUPROJ `
        -ProtheusRoot 'C:\TOTVS\Protheus_241011' -DryRun

.EXAMPLE
    .\New-IsolatedInstance.ps1 -ProjectRoot C:\projetos\meu -Name MEUPROJ `
        -ProtheusRoot 'C:\TOTVS\Protheus_241011' `
        -SeedCustomFrom 'C:\TOTVS\Protheus_241011\protheus\apo\custom.rpo'
#>
param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$ProtheusRoot,
    [Parameter(Mandatory=$false)][string]$SourceBin,
    [Parameter(Mandatory=$false)][string]$SourceApo,
    [Parameter(Mandatory=$false)][string]$SeedCustomFrom,
    [Parameter(Mandatory=$false)][string]$TopAlias,
    [Parameter(Mandatory=$false)][string]$TopServer,
    [Parameter(Mandatory=$false)][string]$TopDatabase,
    [Parameter(Mandatory=$false)][int]$TopPort = 0,
    [Parameter(Mandatory=$false)][int]$TcpPort = 0,
    [Parameter(Mandatory=$false)][int]$RestPort = 0,
    [Parameter(Mandatory=$false)][int]$WebAppPort = 0,
    [Parameter(Mandatory=$false)][switch]$DryRun,
    [Parameter(Mandatory=$false)][switch]$Force
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'IniIO.ps1')

# Bases de alocacao. Nesta maquina: 1268/8401 = AppServer dev compartilhado,
# 1269/8402/8099 = DENK (instancia de projeto que NAO pode ser tocada). As bases
# abaixo comecam DEPOIS disso; a sondagem cuida do resto.
$script:BaseTcp    = 1270
$script:BaseRest   = 8403
$script:BaseWebApp = 8100
$script:PortScan   = 200     # tentativas por faixa antes de desistir

# ---------------------------------------------------------------------------
# Portas
# ---------------------------------------------------------------------------

function Test-PortFree {
    <# Tenta BINDAR a porta em vez de consultar tabela de conexoes: nao depende
       de Get-NetTCPConnection (ausente em ambientes reduzidos) e cobre tanto
       socket em 0.0.0.0 quanto em 127.0.0.1 - no Windows o bind e exclusivo,
       entao qualquer um dos dois faz este bind falhar. #>
    param([Parameter(Mandatory=$true)][int]$Port)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { } }
    }
}

function Get-IniPortMap {
    <# Le as portas declaradas num appserver.ini: secao -> porta.
       So [TCP], [HTTPREST] e [WEBAPP] tem porta que nos interessa
       (MultiProtocolPort de [Drivers] e flag, nao porta). #>
    param([Parameter(Mandatory=$true)][string]$Path)
    $map = @{}
    try { $lines = Read-IniLines -Path $Path } catch { return $map }
    $cur = ''
    foreach ($l in $lines) {
        if ($l -match '^\s*\[(.+?)\]\s*$') { $cur = $matches[1].ToUpperInvariant(); continue }
        if (@('TCP','HTTPREST','WEBAPP') -contains $cur -and $l -match '^\s*Port\s*=\s*(\d+)') {
            if (-not $map.ContainsKey($cur)) { $map[$cur] = [int]$matches[1] }
        }
    }
    return $map
}

function Get-SourceTopConfig {
    <# Le a config TOP (DBAccess) do environment do appserver.ini de ORIGEM.
       E dela que a instancia nova herda TOPALias/TOPServer/TOPDataBase/TOPPort:
       o environment precisa do banco de SISTEMA (dicionarios, StartSysInDB=1),
       que e o mesmo do ambiente-fonte - o banco de teste do projeto e outro
       canal (TCLink nos helpers). Environment identificado pelo
       app_environment do [GENERAL]; fallback: primeira secao com SourcePath. #>
    param([Parameter(Mandatory=$true)][string]$Path)
    $top = @{ Alias = ''; Server = ''; Database = ''; Port = 0 }
    try { $lines = Read-IniLines -Path $Path } catch { return $top }

    $sections = [ordered]@{}
    $cur = ''
    $envFromGeneral = ''
    foreach ($l in $lines) {
        if ($l -match '^\s*\[(.+?)\]\s*$') {
            $cur = $matches[1].ToUpperInvariant()
            if (-not $sections.Contains($cur)) { $sections[$cur] = @{} }
            continue
        }
        if (-not $cur) { continue }
        if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $k = $matches[1].ToUpperInvariant()
            if (-not $sections[$cur].ContainsKey($k)) { $sections[$cur][$k] = $matches[2] }
            if ($cur -eq 'GENERAL' -and $k -eq 'APP_ENVIRONMENT') { $envFromGeneral = $matches[2].ToUpperInvariant() }
        }
    }

    $envSec = $null
    if ($envFromGeneral -and $sections.Contains($envFromGeneral)) {
        $envSec = $sections[$envFromGeneral]
    } else {
        foreach ($name in $sections.Keys) {
            if ($sections[$name].ContainsKey('SOURCEPATH')) { $envSec = $sections[$name]; break }
        }
    }
    if ($envSec) {
        if ($envSec.ContainsKey('TOPALIAS'))    { $top.Alias    = $envSec['TOPALIAS'] }
        if ($envSec.ContainsKey('TOPSERVER'))   { $top.Server   = $envSec['TOPSERVER'] }
        if ($envSec.ContainsKey('TOPDATABASE')) { $top.Database = $envSec['TOPDATABASE'] }
        $n = 0
        if ($envSec.ContainsKey('TOPPORT') -and [int]::TryParse($envSec['TOPPORT'], [ref]$n)) { $top.Port = $n }
    }
    return $top
}

function Get-ReservedInstancePorts {
    <# Portas RESERVADAS por outras instancias, mesmo que estejam desligadas.
       Sem isso a sondagem entregaria a porta da instancia parada do vizinho e
       as duas brigariam na primeira vez que subissem juntas.

       Enumeracao por glob (appserver_*): instancia nova de outro projeto passa
       a ser respeitada sozinha, sem editar lista nenhuma.

       O `ExcludeDirName` e o NOME do diretorio, nao o caminho: comparar caminho
       aqui nao funciona - o FullName do Get-ChildItem vem sempre em forma longa
       enquanto um caminho montado com Join-Path preserva a forma curta 8.3
       ('C:\Users\GUILHE~1\...'), e as duas strings nunca batem. O efeito era a
       instancia entrar na propria lista de reservados: um reparo sem portas no
       json fugia das SUAS proprias portas e realocava tudo. #>
    param(
        [Parameter(Mandatory=$true)][string]$BinRoot,
        [Parameter(Mandatory=$false)][string]$ExcludeDirName
    )
    $res = @()
    if (-not (Test-Path $BinRoot)) { return $res }
    $dirs = Get-ChildItem -Path $BinRoot -Directory -Filter 'appserver_*' -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        if ($ExcludeDirName -and ($d.Name -ieq $ExcludeDirName)) { continue }
        $ini = Join-Path $d.FullName 'appserver.ini'
        if (-not (Test-Path $ini)) { continue }
        $map = Get-IniPortMap -Path $ini
        foreach ($p in $map.Values) { $res += [int]$p }
    }
    return ($res | Sort-Object -Unique)
}

function Find-FreePort {
    param(
        [Parameter(Mandatory=$true)][int]$Start,
        [Parameter(Mandatory=$false)][int[]]$Reserved = @(),
        [Parameter(Mandatory=$false)][string]$Label = 'porta'
    )
    for ($p = $Start; $p -lt ($Start + $script:PortScan); $p++) {
        if ($Reserved -contains $p) { continue }
        if (Test-PortFree -Port $p) { return $p }
    }
    throw "Nao achei $Label livre entre $Start e $($Start + $script:PortScan - 1). Libere portas ou passe a porta explicitamente."
}

# ---------------------------------------------------------------------------
# Copia da arvore
# ---------------------------------------------------------------------------

function Copy-InstanceTree {
    <# Copia a arvore do AppServer excluindo o appserver.ini original (o novo e
       gerado do template, com as portas e o RPO da instancia) e os logs da
       instancia-fonte (console.log e estado dela, nao nosso). #>
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Target
    )
    $excluded = @('appserver.ini', 'console.log')
    $robo = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if ($robo) {
        & $robo.Source $Source $Target /E /XF 'appserver.ini' 'console.log' '*.log' `
            /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
        # robocopy: 0-7 = sucesso (0 = nada a copiar, 1 = copiou, etc); >=8 = erro
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy falhou (exit $LASTEXITCODE) copiando $Source -> $Target"
        }
        $global:LASTEXITCODE = 0
        return
    }
    # Fallback sem robocopy: mais lento, mesmo resultado.
    Write-Host "[iso] robocopy ausente - copiando com Copy-Item (mais lento)" -ForegroundColor DarkYellow
    if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
    $srcLen = (Resolve-Path $Source).Path.TrimEnd('\').Length + 1
    Get-ChildItem -Path $Source -Recurse -File | ForEach-Object {
        if ($excluded -contains $_.Name.ToLowerInvariant()) { return }
        if ($_.Extension -ieq '.log') { return }
        $rel = $_.FullName.Substring($srcLen)
        $dst = Join-Path $Target $rel
        $dstDir = Split-Path $dst -Parent
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -Path $_.FullName -Destination $dst -Force
    }
}

# ---------------------------------------------------------------------------
# Template do appserver.ini (validado no spike)
# ---------------------------------------------------------------------------

function New-InstanceIniContent {
    <# Caminhos ABSOLUTOS de proposito: SourcePath/RpoCustom relativos dependem
       do diretorio de trabalho de quem sobe o processo, e o InstanceControl
       tambem le o RpoCustom (via cascade) pra carimbar o RPO do cache. #>
    param(
        [Parameter(Mandatory=$true)][string]$EnvName,
        [Parameter(Mandatory=$true)][string]$ApoDir,
        [Parameter(Mandatory=$true)][string]$BinDir,
        [Parameter(Mandatory=$true)][string]$RootPath,
        [Parameter(Mandatory=$true)][string]$Alias,
        [Parameter(Mandatory=$true)][string]$TopSrv,
        [Parameter(Mandatory=$true)][string]$TopDb,
        [Parameter(Mandatory=$true)][int]$TopPort,
        [Parameter(Mandatory=$true)][int]$Tcp,
        [Parameter(Mandatory=$true)][int]$Rest,
        [Parameter(Mandatory=$true)][int]$WebApp
    )
    $lines = @(
        "; appserver.ini da instancia isolada $EnvName - gerado por New-IsolatedInstance.ps1 (#34)"
        "; RootPath/DBAccess/License seguem COMPARTILHADOS; RPO e portas sao exclusivos."
        ''
        "[$EnvName]"
        "SourcePath=$ApoDir"
        "RootPath=$RootPath"
        'StartPath=\system\'
        "RpoCustom=$ApoDir\custom.rpo"
        'RpoDb=top'
        'RpoLanguage=multi'
        'RpoVersion=120'
        'LocalFiles=CTREE'
        'localdbextension=.dtc'
        'StartSysInDB=1'
        'topmemomega=50'
        "TOPDataBase=$TopDb"
        "TOPServer=$TopSrv"
        "TOPALias=$Alias"
        "TOPPort=$TopPort"
        ''
        '[GENERAL]'
        'ConsoleLog=1'
        "ConsoleFile=$BinDir\console.log"
        "app_environment=$EnvName"
        'BuildKillUsers=1'
        'MAXSTRINGSIZE=100'
        ''
        '[Drivers]'
        'Active=TCP'
        'MultiProtocolPortSecure=0'
        'MultiProtocolPort=1'
        ''
        '[TCP]'
        'TYPE=TCPIP'
        "Port=$Tcp"
        ''
        '[LICENSECLIENT]'
        'server=localhost'
        'port=5555'
        ''
        # Bloco REST (HTTPJOB/ONSTART/HTTPV11/HTTPREST/HTTPURI): fonte unica em
        # IniIO.ps1, compartilhada com o Set-AppServerRest.ps1.
        (ConvertTo-IniLines -Sections (New-RestSectionLines -Environment $EnvName -RestPort $Rest -Security 1))
        '[WEBAPP]'
        "Port=$WebApp"
        ''
        '[WebApp/webapp]'
        'MPP='
        ''
    )
    return $lines
}

# ---------------------------------------------------------------------------
# Validacao
# ---------------------------------------------------------------------------

if ($Name -notmatch '^[A-Z][A-Z0-9_]{0,19}$') {
    throw "New-IsolatedInstance: nome invalido '$Name'. Use [A-Z][A-Z0-9_]{0,19} (caixa alta, comeca com letra, max 20 chars)."
}
if (-not (Test-Path $ProjectRoot)) {
    throw "New-IsolatedInstance: ProjectRoot nao existe: $ProjectRoot"
}
if (-not (Test-Path $ProtheusRoot)) {
    throw "New-IsolatedInstance: ProtheusRoot nao existe: $ProtheusRoot"
}

$slug     = $Name.ToLowerInvariant()
$envName  = $Name.ToUpperInvariant()
$binRoot  = Join-Path $ProtheusRoot 'Protheus\bin'
$binName  = 'appserver_' + $slug
$binDir   = Join-Path $binRoot $binName
$apoDir   = Join-Path $ProtheusRoot ('protheus\apo_' + $slug)
$iniPath  = Join-Path $binDir 'appserver.ini'
$rootPath = Join-Path $ProtheusRoot 'protheus_data'

if (-not $SourceBin) { $SourceBin = Join-Path $binRoot 'appserver_rest' }
if (-not $SourceApo) { $SourceApo = Join-Path $ProtheusRoot 'protheus\apo' }

if (-not (Test-Path $SourceBin)) {
    throw "New-IsolatedInstance: SourceBin nao existe: $SourceBin (passe -SourceBin apontando pra arvore do AppServer)"
}
if (-not (Test-Path $SourceApo)) {
    throw "New-IsolatedInstance: SourceApo nao existe: $SourceApo (e de la que vem o RPO padrao - passe -SourceApo)"
}
if ($SeedCustomFrom -and -not (Test-Path $SeedCustomFrom)) {
    throw "New-IsolatedInstance: -SeedCustomFrom nao existe: $SeedCustomFrom"
}

# TOP (DBAccess) do ENVIRONMENT: herdado do ini de origem. E o banco de SISTEMA
# (dicionarios, StartSysInDB=1) - nao confundir com o banco de teste do projeto,
# que continua via TCLink nos helpers (mesmo desenho do AppServer dev).
$srcTop = Get-SourceTopConfig -Path (Join-Path $SourceBin 'appserver.ini')
if (-not $TopAlias) {
    if ($srcTop.Alias) {
        $TopAlias = $srcTop.Alias
    } else {
        # Sem alias na origem nao ha default seguro: o environment nao sobe sem
        # banco de sistema. Falhar aqui e mais honesto que gravar um chute.
        throw "New-IsolatedInstance: nao achei TOPALias no ini de origem ($SourceBin\appserver.ini). Passe -TopAlias com o alias do banco de SISTEMA do ambiente (o mesmo do AppServer dev)."
    }
}
if (-not $TopServer)   { $TopServer   = if ($srcTop.Server)   { $srcTop.Server }   else { 'localhost' } }
if (-not $TopDatabase) { $TopDatabase = if ($srcTop.Database) { $srcTop.Database } else { 'MSSQL' } }
if ($TopPort -le 0)    { $TopPort     = if ($srcTop.Port -gt 0) { $srcTop.Port }   else { 7892 } }

# RPO(s) base a copiar. Enumerado por glob: instalacao com outro nome de RPO
# (tttp120, tttm140...) entra sozinha. custom*.rpo NAO entra - ele e por
# instancia, e semear e decisao explicita (-SeedCustomFrom).
$baseRpos = @(Get-ChildItem -Path $SourceApo -Filter '*.rpo' -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notmatch '^(?i)custom' })
if ($baseRpos.Count -eq 0) {
    throw "New-IsolatedInstance: nenhum RPO base (*.rpo) em $SourceApo. A instancia nao funciona sem o RPO padrao."
}

# ---------------------------------------------------------------------------
# Estado atual + resolucao das portas
# ---------------------------------------------------------------------------

$iniExists      = Test-Path $iniPath
$binExists      = Test-Path $binDir
$instanceExists = $binExists -and $iniExists

# Portas ja registradas, em ordem de autoridade:
#   1. parametro explicito
#   2. isolation do .tlpp-tdd.json (o que o cascade usa hoje)
#   3. appserver.ini da propria instancia
#   4. sondagem
$jsonPath = Join-Path $ProjectRoot '.tlpp-tdd.json'
$jsonIso  = $null
if (Test-Path $jsonPath) {
    try {
        $pj = Get-Content $jsonPath -Raw | ConvertFrom-Json
        if ($pj.isolation) { $jsonIso = $pj.isolation }
    } catch {
        Write-Host "[iso] aviso: $jsonPath ilegivel ($($_.Exception.Message)) - portas serao realocadas" -ForegroundColor DarkYellow
    }
}
$iniMap = if ($iniExists) { Get-IniPortMap -Path $iniPath } else { @{} }

# O ini da PROPRIA instancia nao pode entrar em "reservado": senao um reparo
# alocaria portas novas fugindo das dela mesma.
$reservedOthers = @(Get-ReservedInstancePorts -BinRoot $binRoot -ExcludeDirName $binName)
$reserved       = @($reservedOthers)

function Resolve-Port {
    param(
        [int]$Explicit,
        $FromJson,
        $FromIni,
        [int]$Base,
        [int[]]$Reserved,
        [string]$Label
    )
    if ($Explicit -gt 0) { return $Explicit }
    $n = 0
    if ($FromJson -and [int]::TryParse("$FromJson", [ref]$n) -and $n -gt 0) { return $n }
    if ($FromIni  -and [int]::TryParse("$FromIni",  [ref]$n) -and $n -gt 0) { return $n }
    return (Find-FreePort -Start $Base -Reserved $Reserved -Label $Label)
}

# As tres faixas nao se sobrepoem, mas cada porta escolhida entra em $reserved
# de qualquer forma - assim um -TcpPort explicito na faixa do REST nao acaba
# alocado duas vezes.
$portTcp = Resolve-Port -Explicit $TcpPort -FromJson $(if ($jsonIso) { $jsonIso.tcpPort }) `
                        -FromIni $iniMap['TCP'] -Base $script:BaseTcp `
                        -Reserved $reserved -Label 'porta TCP'
$reserved += $portTcp
$portRest = Resolve-Port -Explicit $RestPort -FromJson $(if ($jsonIso) { $jsonIso.restPort }) `
                         -FromIni $iniMap['HTTPREST'] -Base $script:BaseRest `
                         -Reserved $reserved -Label 'porta HTTPREST'
$reserved += $portRest
$portWeb = Resolve-Port -Explicit $WebAppPort -FromJson $(if ($jsonIso) { $jsonIso.webAppPort }) `
                        -FromIni $iniMap['WEBAPP'] -Base $script:BaseWebApp `
                        -Reserved $reserved -Label 'porta WEBAPP'

$result = [pscustomobject]@{
    Name        = $Name
    Environment = $envName
    BinDir      = $binDir
    ApoDir      = $apoDir
    IniPath     = $iniPath
    TcpPort     = $portTcp
    RestPort    = $portRest
    WebAppPort  = $portWeb
    TopAlias    = $TopAlias
    Created     = $false
    Repaired    = $false
    DryRun      = [bool]$DryRun
}

# ---------------------------------------------------------------------------
# Plano
# ---------------------------------------------------------------------------

$totalMb = [math]::Round((($baseRpos | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)

Write-Host "[iso] Instancia isolada '$Name' (environment $envName)" -ForegroundColor Cyan
Write-Host "  bin       : $binDir  (copia de $SourceBin)" -ForegroundColor White
Write-Host "  RPO       : $apoDir  (+ $($baseRpos.Count) RPO base, ~${totalMb}MB)" -ForegroundColor White
Write-Host "  RootPath  : $rootPath  (COMPARTILHADO)" -ForegroundColor White
Write-Host "  portas    : TCP=$portTcp  HTTPREST=$portRest  WEBAPP=$portWeb" -ForegroundColor White
Write-Host "  environment DB: $TopDatabase/$TopAlias via DBAccess $TopServer`:$TopPort (banco de SISTEMA, herdado da origem)" -ForegroundColor White
Write-Host "  banco de teste: PROTHEUS_TST_$envName via TCLink nos helpers (inalterado)" -ForegroundColor White
if ($SeedCustomFrom) {
    Write-Host "  custom.rpo: semeado de $SeedCustomFrom" -ForegroundColor White
} else {
    Write-Host "  custom.rpo: limpo (o AppServer cria na 1a compilacao)" -ForegroundColor White
}
if ($reservedOthers.Count -gt 0) {
    Write-Host "  reservadas por outras instancias: $($reservedOthers -join ', ')" -ForegroundColor DarkGray
}

if ($DryRun) {
    Write-Host "[iso] DryRun - nada criado, nada copiado." -ForegroundColor Yellow
    return $result
}

if ($instanceExists -and -not $Force) {
    Write-Host "[iso] instancia JA EXISTE - nada alterado (idempotente)." -ForegroundColor Green
    if (-not $jsonIso) {
        Write-Host "[iso] AVISO: $jsonPath nao tem 'isolation' - o projeto NAO vai usar esta instancia." -ForegroundColor Yellow
        Write-Host "[iso]        rode de novo com -Force pra registrar as portas no json." -ForegroundColor Yellow
    }
    return $result
}
$result.Repaired = [bool]($instanceExists -and $Force)

# ---------------------------------------------------------------------------
# Execucao
# ---------------------------------------------------------------------------

# 1. Arvore do AppServer
Write-Host "[iso] copiando arvore do AppServer (pode levar minutos - ~485MB no layout padrao)..." -ForegroundColor Cyan
Copy-InstanceTree -Source $SourceBin -Target $binDir

# 2. RPO base. Copia so o que falta - re-rodar com -Force nao recopia 957MB.
if (-not (Test-Path $apoDir)) { New-Item -ItemType Directory -Path $apoDir -Force | Out-Null }
foreach ($rpo in $baseRpos) {
    $dst = Join-Path $apoDir $rpo.Name
    if ((Test-Path $dst) -and ((Get-Item $dst).Length -eq $rpo.Length)) {
        Write-Host "[iso] $($rpo.Name) ja presente com o mesmo tamanho - pulando" -ForegroundColor DarkGray
        continue
    }
    Write-Host "[iso] copiando $($rpo.Name) ($([math]::Round($rpo.Length/1MB,1))MB)..." -ForegroundColor Cyan
    Copy-Item -Path $rpo.FullName -Destination $dst -Force
}

# 3. custom.rpo (opcional). NUNCA sobrescreve um custom.rpo ja compilado.
if ($SeedCustomFrom) {
    $customDst = Join-Path $apoDir 'custom.rpo'
    if (Test-Path $customDst) {
        Write-Host "[iso] custom.rpo ja existe em $apoDir - NAO sobrescrito (tem objetos compilados)" -ForegroundColor Yellow
    } else {
        Copy-Item -Path $SeedCustomFrom -Destination $customDst -Force
        Write-Host "[iso] custom.rpo semeado de $SeedCustomFrom" -ForegroundColor Green
    }
}

# 4. appserver.ini novo. Latin1 (28591) igual ao IniIO: mapeia 1:1 byte<->char
#    e nao introduz BOM, que o AppServer nao le. Aqui o ini e GERADO (nao
#    editado), entao nao ha bytes de usuario a preservar - so o encoding importa.
if ($iniExists) {
    $bak = & (Join-Path $PSScriptRoot 'Backup-Ini.ps1') -Path $iniPath
    Write-Host "[iso] backup do ini anterior: $bak" -ForegroundColor DarkGray
}
$iniLines = New-InstanceIniContent -EnvName $envName -ApoDir $apoDir -BinDir $binDir `
    -RootPath $rootPath -Alias $TopAlias -TopSrv $TopServer -TopDb $TopDatabase -TopPort $TopPort `
    -Tcp $portTcp -Rest $portRest -WebApp $portWeb
Write-IniLines -Path $iniPath -Lines $iniLines
Write-Host "[iso] $iniPath gravado" -ForegroundColor Green

# 5. Registra o isolamento no .tlpp-tdd.json (preservando chaves desconhecidas)
$wproj = Join-Path $PSScriptRoot 'Write-ProjectConfig.ps1'
$wprojArgs = @{
    ProjectRoot = $ProjectRoot
    Name        = $Name
    Isolation   = @{ tcpPort = $portTcp; restPort = $portRest; webAppPort = $portWeb }
}
if ($Force) { $wprojArgs.Force = $true }
& $wproj @wprojArgs | Out-Null

$result.Created = -not $result.Repaired

Write-Host "[iso] OK - instancia '$Name' pronta." -ForegroundColor Green
Write-Host "[iso] Ela sobe SOZINHA no primeiro /tlpp-build ou /tlpp-test do projeto (-console, sem auto-stop)." -ForegroundColor DarkGray
Write-Host "[iso] Pra subir na mao: cd '$binDir'; .\appserver.exe -console -ini=appserver.ini" -ForegroundColor DarkGray
return $result
