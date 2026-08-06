<#
.SYNOPSIS
    Escreve <projeto>/.tlpp-tdd.json com nome do projeto + overrides per-project.

.DESCRIPTION
    Idempotente. Se ja existe e Name conflita, pergunta (a menos que -Force).
    Mantem chaves desconhecidas (extensoes futuras).

.PARAMETER ProjectRoot
    Diretorio raiz do projeto (onde grava .tlpp-tdd.json).

.PARAMETER Name
    Nome do projeto - deriva PROTHEUS_TST_<NAME>.
    Validado: [A-Z][A-Z0-9_]{0,19}.

.PARAMETER TestDb
    Override do nome do banco de teste (opcional - default: PROTHEUS_TST_<Name>).

.PARAMETER BaseUrl
    Override do URL do AppServer REST (opcional - default vem do global config).

.PARAMETER SchemaPath
    Caminho do schema SQL versionado do projeto (opcional - default do cascade:
    sql/schema.sql relativo ao projeto). Relativo resolve contra ProjectRoot.

.PARAMETER Isolation
    Hashtable/objeto com as portas da instancia DEDICADA do projeto (#34):
    `@{ tcpPort=1270; restPort=8403; webAppPort=8100 }`. A PRESENCA da chave
    `isolation` no json e o que marca o projeto como isolado para o cascade -
    quem escreve normalmente e o `New-IsolatedInstance.ps1`. Omitir NAO remove
    um isolamento ja gravado (chaves desconhecidas/ausentes sao preservadas).

.PARAMETER Force
    Sobrescreve sem perguntar mesmo se Name conflita.

.EXAMPLE
    .\Write-ProjectConfig.ps1 -ProjectRoot C:\projetos\meu-projeto -Name MEUPROJ
    .\Write-ProjectConfig.ps1 -ProjectRoot C:\projetos\meu-projeto -Name MEUPROJ -SchemaPath db\schema.sql
    .\Write-ProjectConfig.ps1 -ProjectRoot C:\projetos\meu-projeto -Name MEUPROJ -Isolation @{ tcpPort=1270; restPort=8403; webAppPort=8100 }
#>
param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$false)][string]$TestDb,
    [Parameter(Mandatory=$false)][string]$BaseUrl,
    [Parameter(Mandatory=$false)][string]$SchemaPath,
    [Parameter(Mandatory=$false)]$Isolation,
    [Parameter(Mandatory=$false)][switch]$Force
)

$ErrorActionPreference = 'Stop'

if ($Name -notmatch '^[A-Z][A-Z0-9_]{0,19}$') {
    throw "Nome de projeto invalido: '$Name'. Use [A-Z][A-Z0-9_]{0,19} (caixa alta, comeca com letra, max 20 chars)."
}

if (-not (Test-Path $ProjectRoot)) {
    throw "ProjectRoot nao existe: $ProjectRoot"
}

$configPath = Join-Path $ProjectRoot '.tlpp-tdd.json'

# Le existente preservando chaves desconhecidas
$obj = $null
if (Test-Path $configPath) {
    try {
        $obj = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($obj.name -and $obj.name -ne $Name -and -not $Force) {
            throw "Projeto '$($obj.name)' ja registrado em $configPath. Use -Force pra sobrescrever para '$Name'."
        }
    } catch {
        if (-not $Force) { throw "Falha ao ler $configPath - $($_.Exception.Message). Use -Force pra sobrescrever." }
        $obj = $null
    }
}

if (-not $obj) { $obj = [pscustomobject]@{} }

# Adiciona/atualiza membros sem destruir existentes
$set = {
    param($o, $k, $v)
    if ($null -eq $v) { return }
    if ($o.PSObject.Properties.Name -contains $k) {
        $o.$k = $v
    } else {
        Add-Member -InputObject $o -MemberType NoteProperty -Name $k -Value $v -Force
    }
}
& $set $obj 'name' $Name
if ($TestDb)     { & $set $obj 'testDb'     $TestDb }
if ($BaseUrl)    { & $set $obj 'baseUrl'    $BaseUrl }
if ($SchemaPath) { & $set $obj 'schemaPath' $SchemaPath }

# Isolamento (#34): normalizado pra um objeto com as TRES portas como inteiro.
# Normalizar aqui (e nao confiar no que veio) evita gravar porta como string -
# o cascade compara/monta URL com o valor e string funcionaria por acidente ate
# alguem fazer aritmetica. Aceita hashtable ou PSCustomObject.
if ($Isolation) {
    $pick = {
        param($src, $key)
        $v = $null
        if ($src -is [hashtable]) { $v = $src[$key] } else { $v = $src.$key }
        $n = 0
        if ($null -ne $v -and [int]::TryParse("$v", [ref]$n) -and $n -gt 0) { return $n }
        return $null
    }
    $tcp = & $pick $Isolation 'tcpPort'
    $rst = & $pick $Isolation 'restPort'
    $web = & $pick $Isolation 'webAppPort'
    if (-not $tcp -or -not $rst -or -not $web) {
        throw "Write-ProjectConfig: -Isolation precisa de tcpPort, restPort e webAppPort numericos (>0). Recebido: $($Isolation | ConvertTo-Json -Compress)"
    }
    & $set $obj 'isolation' ([pscustomobject]@{ tcpPort = $tcp; restPort = $rst; webAppPort = $web })
}

$json = $obj | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($configPath, $json + "`r`n", [System.Text.UTF8Encoding]::new($false))

Write-Host "[wproj] $configPath ($Name)" -ForegroundColor Green
$obj | ConvertTo-Json -Depth 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
