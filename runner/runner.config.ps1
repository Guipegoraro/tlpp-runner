# =====================================================================
# tlpp-runner - loader de configuracao (VERSIONADO)
# =====================================================================
# Carrega config em cascata:
#   1. Defaults neutros (este arquivo)
#   2. Global  ~/.claude/tlpp-tdd/config.ps1     (per-machine, sensivel)
#   3. Project <project-root>/.tlpp-tdd.json     (per-project: nome, banco)
#   4. Legacy  <runner>/runner.config.local.ps1  (back-compat, vai sair em 1.0)
#
# Ordem: ultimo a tocar uma chave vence. Defaults nunca sobrescrevem.
# =====================================================================

$script:TlppRunner = [ordered]@{
    # ----- REST (Invoke-TlppRunner.ps1) -----
    # 127.0.0.1 e nao localhost: ver a normalizacao do BaseUrl no fim do arquivo.
    BaseUrl  = 'http://127.0.0.1:8401/rest'
    User     = 'admin'
    Password = ''

    # ----- Raiz do Protheus (deriva Includes / ConsoleLogPath / ProbatXmlDir) -----
    ProtheusRoot = ''

    # RPO do environment em uso. Usado pelo cache de build pra detectar
    # compilacao feita por fora (TDS, RPO recriado). Opcional: vazio faz o
    # BuildCache tentar <ProtheusRoot>\protheus\apo\custom.rpo.
    # PREENCHA se a maquina tem mais de um environment/RPO (ex. `apo\` para
    # DESENVOLVIMENTO e `apo_denk\` para DENK) - senao o cache carimba o RPO
    # errado e o guard de alteracao externa fica inutil. O valor esta na chave
    # `RpoCustom` da secao do environment no appserver.ini.
    RpoCustom = ''

    # ----- advpls cli (Invoke-TlppBuild.ps1) -----
    AdvplsPath  = ''
    Server      = 'localhost'
    Port        = 1268
    Secure      = 0
    Build       = 'AUTO'
    Environment = 'DESENVOLVIMENTO'
    Includes    = ''

    # ----- Empresa/filial (PrepareIn) -----
    Company = '99'
    Branch  = '01'

    # ----- Timeouts -----
    PingTimeoutSec  = 10
    ExecTimeoutSec  = 300
    BuildTimeoutSec = 120

    # ----- MSSQL (banco de teste / integracao via TCLink) -----
    SqlInstance     = 'localhost'
    SqlAuth         = 'Windows'
    SqlUser         = ''
    SqlPassword     = ''
    TrustServerCert = $true
    DbAccessHost    = 'localhost'
    DbAccessPort    = 7890

    # ----- Per-project (lidos de .tlpp-tdd.json se existir) -----
    # ProjectName eh a chave que deriva TestDb = PROTHEUS_TST_<ProjectName>
    ProjectName = ''
    TestDb      = ''   # se vazio e ProjectName setado, vira PROTHEUS_TST_<NAME>
    SchemaPath  = ''   # schema SQL versionado do projeto (/tlpp-table, #21);
                       # vazio deriva: runner\sql\02-create-schema.sql se existir
                       # (layout dev do tlpp-runner), senao <projeto>\sql\schema.sql

    # ----- Caminhos do AppServer (derivados de ProtheusRoot) -----
    ConsoleLogPath = ''
    ProbatXmlDir   = ''

    # ----- Isolamento por projeto (#34, opt-in) -----
    # Preenchidos SO quando o .tlpp-tdd.json tem o objeto `isolation`. Vazio =
    # projeto usa o AppServer dev compartilhado (comportamento historico).
    # IsolationBinDir e o que o runner/InstanceControl.ps1 consulta pra decidir
    # se sobe instancia on-demand.
    IsolationBinDir  = ''
    IsolationApoDir  = ''
    IsolationRest    = 0
    IsolationTcp     = 0
    IsolationWebApp  = 0

    # ----- Caminhos (auto, nao editar) -----
    PluginRoot  = (Split-Path $PSScriptRoot -Parent)   # raiz do plugin (onde vive este arquivo)
    ProjectRoot = ''   # cwd do user; preenchido abaixo
}

# 2. Global (~/.claude/tlpp-tdd/config.ps1)
$globalConfig = Join-Path $env:USERPROFILE '.claude\tlpp-tdd\config.ps1'
if (Test-Path $globalConfig) {
    $TlppRunner = $script:TlppRunner   # exposto pro arquivo global
    . $globalConfig
}

# 3. Project (.tlpp-tdd.json no diretorio do projeto)
#
# Precedencia: override do chamador > CLAUDE_PROJECT_DIR > cwd.
#
# O override existe porque este arquivo e DOT-SOURCED: quem chama nao consegue
# passar parametro. Sem ele, um script com -ProjectRoot so conseguia ajustar a
# propriedade DEPOIS desta secao ja ter lido o .tlpp-tdd.json do diretorio
# errado - entao ProjectName/TestDb vinham do cwd e o projeto-alvo era ignorado
# em silencio (o teste rodava contra PROTHEUS_TST em vez do banco do projeto).
# Quem usa: Invoke-TlppRunner.ps1 e Invoke-TlppBuild.ps1, setando
# $TlppProjectRootOverride antes do dot-source.
$projectRoot = if ($TlppProjectRootOverride) { $TlppProjectRootOverride }
               elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR }
               else { (Get-Location).Path }
$script:TlppRunner.ProjectRoot = $projectRoot
$projectConfig = Join-Path $projectRoot '.tlpp-tdd.json'
$projIsolation = $null      # objeto `isolation` do json; derivado no fim (#34)
$projBaseUrl   = ''         # baseUrl EXPLICITO do json: vence o derivado do isolamento
if (Test-Path $projectConfig) {
    try {
        $pj = Get-Content $projectConfig -Raw | ConvertFrom-Json
        if ($pj.name)       { $script:TlppRunner.ProjectName = $pj.name }
        if ($pj.testDb)     { $script:TlppRunner.TestDb      = $pj.testDb }
        if ($pj.baseUrl)    { $script:TlppRunner.BaseUrl     = $pj.baseUrl; $projBaseUrl = $pj.baseUrl }
        if ($pj.schemaPath) { $script:TlppRunner.SchemaPath  = $pj.schemaPath }
        if ($pj.isolation)  { $projIsolation = $pj.isolation }
    } catch {
        Write-Warning "[tlpp-tdd] falha ao ler $projectConfig - $($_.Exception.Message)"
    }
}

# 4. Legacy local config (back-compat enquanto migra)
$localConfig = Join-Path $PSScriptRoot 'runner.config.local.ps1'
if (Test-Path $localConfig) {
    $TlppRunner = $script:TlppRunner
    . $localConfig
}

# =====================================================================
# Derivados
# =====================================================================

# Isolamento por projeto (#34) - PRIMEIRO dos derivados, de proposito.
#
# A presenca do objeto `isolation` no .tlpp-tdd.json e o unico gatilho: projeto
# sem ele nao passa por NADA daqui, e continua apontando pro AppServer dev
# compartilhado. Vem antes dos outros derivados porque preenche ConsoleLogPath e
# RpoCustom - os `if (-not ...)` abaixo entao respeitam o valor da instancia em
# vez de carimbar o do ambiente compartilhado.
#
# Ordem de forca: isolamento vence os defaults globais (BaseUrl/Port/Environment
# do ~/.claude/tlpp-tdd/config.ps1), mas um `baseUrl` EXPLICITO no mesmo json
# vence o isolamento - e override deliberado, mais especifico.
if ($projIsolation) {
    $isoName = $script:TlppRunner.ProjectName
    if (-not $isoName) {
        Write-Warning "[tlpp-tdd] $projectConfig tem 'isolation' sem 'name' - isolamento IGNORADO (o nome deriva environment/bin/RPO da instancia)."
    } else {
        $isoSlug = $isoName.ToLowerInvariant()
        $isoTcp  = 0; $isoRest = 0; $isoWeb = 0
        [void][int]::TryParse("$($projIsolation.tcpPort)",    [ref]$isoTcp)
        [void][int]::TryParse("$($projIsolation.restPort)",   [ref]$isoRest)
        [void][int]::TryParse("$($projIsolation.webAppPort)", [ref]$isoWeb)

        $script:TlppRunner.Environment     = $isoName.ToUpperInvariant()
        $script:TlppRunner.IsolationTcp    = $isoTcp
        $script:TlppRunner.IsolationRest   = $isoRest
        $script:TlppRunner.IsolationWebApp = $isoWeb

        if ($isoTcp  -gt 0) { $script:TlppRunner.Port    = $isoTcp }
        if ($isoRest -gt 0) { $script:TlppRunner.BaseUrl = "http://127.0.0.1:$isoRest/rest" }

        if ($script:TlppRunner.ProtheusRoot) {
            $script:TlppRunner.IsolationBinDir = Join-Path $script:TlppRunner.ProtheusRoot ('Protheus\bin\appserver_' + $isoSlug)
            $script:TlppRunner.IsolationApoDir = Join-Path $script:TlppRunner.ProtheusRoot ('protheus\apo_' + $isoSlug)
            $script:TlppRunner.RpoCustom       = Join-Path $script:TlppRunner.IsolationApoDir 'custom.rpo'
            $script:TlppRunner.ConsoleLogPath  = Join-Path $script:TlppRunner.IsolationBinDir 'console.log'
        } else {
            Write-Warning "[tlpp-tdd] isolamento declarado mas ProtheusRoot vazio - sem RpoCustom/bin da instancia (rode /tlpp-tdd-setup)."
        }

        if ($projBaseUrl) { $script:TlppRunner.BaseUrl = $projBaseUrl }
    }
}

# BaseUrl com host `localhost` vira 127.0.0.1. O .NET resolve localhost para ::1
# primeiro e o AppServer escuta so em IPv4: cada request paga ~2s de fallback
# (medido: /runner/exec em ~2s com localhost, ~10ms com 127.0.0.1). Normaliza
# aqui para valer tambem para config global e .tlpp-tdd.json ja gravados.
# So http: em https o certificado e emitido para "localhost" e nao valida 127.0.0.1.
$script:TlppRunner.BaseUrl = $script:TlppRunner.BaseUrl -replace '^(http://)localhost(?=[:/]|$)', '${1}127.0.0.1'

if (-not $script:TlppRunner.Includes -and $script:TlppRunner.ProtheusRoot) {
    $script:TlppRunner.Includes = Join-Path $script:TlppRunner.ProtheusRoot 'Protheus\include'
}
if (-not $script:TlppRunner.ConsoleLogPath -and $script:TlppRunner.ProtheusRoot) {
    $script:TlppRunner.ConsoleLogPath = Join-Path $script:TlppRunner.ProtheusRoot 'Protheus\bin\appserver_rest\console.log'
}
if (-not $script:TlppRunner.ProbatXmlDir -and $script:TlppRunner.ProtheusRoot) {
    $script:TlppRunner.ProbatXmlDir = Join-Path $script:TlppRunner.ProtheusRoot 'protheus_data\system'
}
# Banco de teste: se nao explicitado e ProjectName setado, deriva PROTHEUS_TST_<NAME>
if (-not $script:TlppRunner.TestDb -and $script:TlppRunner.ProjectName) {
    $script:TlppRunner.TestDb = "PROTHEUS_TST_$($script:TlppRunner.ProjectName.ToUpper())"
}
# Fallback ultimo: PROTHEUS_TST puro (compat com tlpp-runner dev em si)
if (-not $script:TlppRunner.TestDb) {
    $script:TlppRunner.TestDb = 'PROTHEUS_TST'
}
# Schema SQL do projeto (#21): relativo resolve contra ProjectRoot; vazio deriva
# do layout - repo dev do tlpp-runner tem runner\sql\02-create-schema.sql, projeto
# consumidor ganha o default sql\schema.sql (criado pelo /tlpp-table no 1o uso).
if ($script:TlppRunner.SchemaPath) {
    if (-not [System.IO.Path]::IsPathRooted($script:TlppRunner.SchemaPath)) {
        $script:TlppRunner.SchemaPath = Join-Path $script:TlppRunner.ProjectRoot $script:TlppRunner.SchemaPath
    }
} else {
    $devSchema = Join-Path $script:TlppRunner.ProjectRoot 'runner\sql\02-create-schema.sql'
    $script:TlppRunner.SchemaPath = if (Test-Path $devSchema) { $devSchema }
                                    else { Join-Path $script:TlppRunner.ProjectRoot 'sql\schema.sql' }
}

$global:TlppRunner = $script:TlppRunner
