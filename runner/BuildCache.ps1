<#
.SYNOPSIS
    Cache de build: evita chamar o advpls quando o fonte ja esta no RPO com o
    mesmo conteudo.

.DESCRIPTION
    Motivacao (issue #29): QUALQUER compilacao derruba o HTTPREST por 68-93s
    medidos - nao so as que tocam @Get/@Post. E `recompile=F` nao ajuda: o
    advpls compila do mesmo jeito. A unica forma de evitar a janela e nao
    invocar o advpls.

    O caso comum e desperdicio puro: /tlpp-build ja compilou o fonte, e entao
    /tlpp-test Modo 2 manda compilar de novo o mesmo arquivo inalterado.

    CHAVE DO CACHE E O NOME DO PROGRAMA, NAO O CAMINHO DO FONTE.

    O RPO e compartilhado entre projetos. Dois projetos podem ter cada um o seu
    `MT410ROT.tlpp` (ponto de entrada) com conteudos diferentes - ambos ocupam o
    MESMO slot `MT410ROT` no RPO, e o ultimo a compilar vence. Um cache indexado
    por caminho diria "o seu MT410ROT esta compilado" quando o que esta la e a
    versao do outro projeto. Indexando por nome de programa, o cache detecta a
    troca de dono do slot e forca a recompilacao (alem de avisar).

.NOTES
    Invalidacao em camadas:
      1. rpoStamp   - mtime+tamanho do custom.rpo. Se mudou por algo que nao foi
                      nosso build (compile pelo TDS, RPO recriado), invalida o
                      environment inteiro.
      2. hash       - SHA256 do conteudo do fonte.
      3. dono       - caminho do fonte que ocupa o slot. Divergiu = outro projeto.

    Acesso concorrente (dois projetos compilando ao mesmo tempo) e serializado
    por Mutex nomeado; JSON corrompido e tratado como cache vazio, nunca como
    erro fatal.
#>

$script:BuildCacheVersion = 1

function Get-BuildCachePath {
    <# Cache e GLOBAL de proposito: o RPO que ele modela e compartilhado entre
       projetos. Um cache por projeto nao teria como saber que outro projeto
       sobrescreveu o slot de um programa homonimo. #>
    $dir = Join-Path $env:USERPROFILE '.claude\tlpp-tdd'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'build-cache.json')
}

function Get-BuildCacheEnvKey {
    param([Parameter(Mandatory=$true)]$Config)
    # Identifica o RPO alvo. Mesmo fonte em environment diferente = slot diferente.
    return ('{0}:{1}|{2}' -f $Config.Server, $Config.Port, $Config.Environment).ToUpperInvariant()
}

function Get-ProgramName {
    <# Nome do programa no RPO: basename sem extensao, upper. E assim que o
       Protheus registra, e e por isso que dois projetos colidem. #>
    param([Parameter(Mandatory=$true)][string]$Path)
    return [System.IO.Path]::GetFileNameWithoutExtension($Path).ToUpperInvariant()
}

function Get-FileHashHex {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

function Get-RpoStamp {
    <# Impressao digital do custom.rpo. Best-effort: se o caminho nao for
       descobrivel, retorna null e o guard 1 fica simplesmente desligado -
       degradar pra hash-only e melhor do que falhar o build.

       ATENCAO - uma maquina pode ter MAIS DE UM RPO (um por environment; ex.
       `protheus\apo\` para DESENVOLVIMENTO e `protheus\apo_denk\` para DENK).
       O fallback por ProtheusRoot so acha o `apo\` padrao, entao num
       environment nao-padrao ele carimbaria o RPO ERRADO: o guard nunca veria
       um compile feito por fora e invalidaria a toa quando o outro RPO mudasse.

       Configure `RpoCustom` em ~/.claude/tlpp-tdd/config.ps1 apontando para o
       `custom.rpo` do environment em uso (o valor esta na chave `RpoCustom` da
       secao do environment no appserver.ini). #>
    param([Parameter(Mandatory=$true)]$Config)
    if ($Config.RpoCustom) {
        if (Test-Path $Config.RpoCustom) {
            $fi = Get-Item $Config.RpoCustom
            return ('{0}:{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length)
        }
        return $null   # configurado e invalido: desliga o guard em vez de mentir com outro RPO
    }
    if ($Config.ProtheusRoot) {
        foreach ($c in @('protheus\apo\custom.rpo', 'Protheus\apo\custom.rpo')) {
            $p = Join-Path $Config.ProtheusRoot $c
            if (Test-Path $p) {
                $fi = Get-Item $p
                return ('{0}:{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length)
            }
        }
    }
    return $null
}

function Read-BuildCache {
    $path = Get-BuildCachePath
    if (-not (Test-Path $path)) { return @{} }
    try {
        $raw = Get-Content -Path $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($obj.version -ne $script:BuildCacheVersion) { return @{} }   # formato antigo: descarta
        return $obj
    } catch {
        return @{}   # corrompido = cache vazio, nunca erro fatal
    }
}

function Invoke-WithCacheLock {
    <# Serializa leitura-modificacao-escrita entre processos. Dois projetos
       compilando ao mesmo tempo nao podem perder atualizacao um do outro.

       Se o lock NAO for obtido, a acao e ABORTADA em vez de rodar sem lock.
       Escrever sem lock reintroduz exatamente o lost-update que o mutex existe
       pra impedir. O custo de nao gravar e uma recompilacao redundante depois
       (seguro); o custo de um cache corrompido e teste rodando contra RPO
       errado (nao seguro). #>
    param([Parameter(Mandatory=$true)][scriptblock]$Action)
    $mutex = New-Object System.Threading.Mutex($false, 'Global\tlpp-tdd-build-cache')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(5000) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }  # dono morreu: lock e nosso
        if (-not $held) {
            Write-Host "[build] cache: lock ocupado por outro processo - pulando gravacao (sem risco, so recompila depois)" -ForegroundColor DarkYellow
            return $null
        }
        return (& $Action)
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Clear-BuildCacheEnvironment {
    <# Descarta TODAS as entradas de um environment.

       Chamado quando se detecta que o RPO mudou fora do runner (compile pelo
       TDS, RPO recriado). Sem isso, `Update-BuildCache` gravaria o stamp novo
       mantendo as entradas antigas - e elas voltariam a ser consideradas
       validas na proxima consulta, mesmo referindo-se a um RPO que ja nao
       existe. Dar miss so no arquivo consultado nao basta: as OUTRAS entradas
       ficariam re-abencoadas pelo stamp novo. #>
    param([Parameter(Mandatory=$true)]$Config)
    Invoke-WithCacheLock -Action {
        $cache  = Read-BuildCache
        $envKey = Get-BuildCacheEnvKey -Config $Config
        $envs   = ConvertTo-BuildCacheEnvTable -Cache $cache
        if ($envs.ContainsKey($envKey)) { $envs.Remove($envKey) }
        Write-BuildCacheFile -Environments $envs
    }
}

function Test-BuildCacheHit {
    <#
    .SYNOPSIS
        Decide se um fonte pode pular a compilacao.
    .OUTPUTS
        Hashtable: Hit (bool), Reason (string), Owner (caminho que ocupa o slot,
        quando o miss for por troca de dono).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$false)]$Cache
    )
    if (-not $Cache) { $Cache = Read-BuildCache }

    $envKey  = Get-BuildCacheEnvKey -Config $Config
    $program = Get-ProgramName -Path $Path
    $hash    = Get-FileHashHex -Path $Path
    if (-not $hash) { return @{ Hit = $false; Reason = 'fonte ilegivel' } }

    $envNode = $null
    if ($Cache.environments) { $envNode = $Cache.environments.$envKey }
    if (-not $envNode) { return @{ Hit = $false; Reason = 'sem cache para este environment' } }

    # Guard 1: RPO mexido por fora (compile pelo TDS, RPO recriado)
    $stamp = Get-RpoStamp -Config $Config
    if ($stamp -and $envNode.rpoStamp -and $stamp -ne $envNode.rpoStamp) {
        return @{ Hit = $false; Reason = 'RPO alterado fora do runner' }
    }

    $entry = $null
    if ($envNode.programs) { $entry = $envNode.programs.$program }
    if (-not $entry) { return @{ Hit = $false; Reason = 'programa nunca compilado por aqui' } }

    # Guard 2: outro fonte ocupa o slot deste programa (colisao entre projetos)
    if ($entry.source -and $entry.source -ne $Path) {
        return @{ Hit = $false; Reason = 'slot ocupado por outro fonte'; Owner = $entry.source }
    }

    # Guard 3: conteudo mudou
    if ($entry.hash -ne $hash) { return @{ Hit = $false; Reason = 'conteudo alterado' } }

    return @{ Hit = $true; Reason = 'ja compilado com este conteudo' }
}

function ConvertTo-BuildCacheEnvTable {
    <# ConvertFrom-Json devolve PSCustomObject (imutavel na pratica); normaliza
       pra hashtable aninhada mutavel. #>
    param($Cache)
    $envs = @{}
    if ($Cache -and $Cache.environments) {
        foreach ($p in $Cache.environments.PSObject.Properties) {
            $progs = @{}
            if ($p.Value.programs) {
                foreach ($q in $p.Value.programs.PSObject.Properties) { $progs[$q.Name] = $q.Value }
            }
            $envs[$p.Name] = @{ rpoStamp = $p.Value.rpoStamp; programs = $progs }
        }
    }
    return $envs
}

function Write-BuildCacheFile {
    param([Parameter(Mandatory=$true)]$Environments)
    $out = @{ version = $script:BuildCacheVersion; environments = $Environments }
    $tmp = (Get-BuildCachePath) + '.tmp'
    $out | ConvertTo-Json -Depth 8 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination (Get-BuildCachePath) -Force   # troca atomica
}

function Update-BuildCache {
    <# Registra os fontes compilados com sucesso e o novo estado do RPO.

       PRE-REQUISITO: se houve alteracao externa do RPO, o chamador ja deve ter
       rodado Clear-BuildCacheEnvironment. Esta funcao grava o stamp novo, o que
       revalidaria entradas antigas que nao correspondem mais ao RPO. #>
    param(
        [Parameter(Mandatory=$true)][string[]]$Paths,
        [Parameter(Mandatory=$true)]$Config
    )
    Invoke-WithCacheLock -Action {
        $envKey = Get-BuildCacheEnvKey -Config $Config
        $envs   = ConvertTo-BuildCacheEnvTable -Cache (Read-BuildCache)
        if (-not $envs.ContainsKey($envKey)) { $envs[$envKey] = @{ rpoStamp = $null; programs = @{} } }

        foreach ($path in $Paths) {
            $hash = Get-FileHashHex -Path $path
            if (-not $hash) { continue }
            $envs[$envKey].programs[(Get-ProgramName -Path $path)] = @{
                hash   = $hash
                source = $path
                at     = (Get-Date).ToString('o')
            }
        }
        # Stamp DEPOIS do build: e o estado do RPO que estes fontes produziram
        $envs[$envKey].rpoStamp = Get-RpoStamp -Config $Config

        Write-BuildCacheFile -Environments $envs
    }
}

function Clear-BuildCache {
    $path = Get-BuildCachePath
    if (Test-Path $path) { Remove-Item $path -Force }
}

# =============================================================================
# Oraculo RPO (issue #33)
# =============================================================================
# Em vez de MODELAR o RPO com cache local (que invalida o environment inteiro
# a qualquer mudanca externa), PERGUNTA ao proprio AppServer o que esta la:
# u_tecApoStat (src/tecRunrRpo.tlpp) devolve, por programa, o mtime do
# arquivo-fonte registrado na compilacao (GetAPOInfo). dataFonte == mtime do
# disco (+-2s) significa que o RPO ja contem o conteudo atual do arquivo.
#
# O oraculo e UPGRADE, nunca dependencia: qualquer falha (REST na janela de
# restart, AppServer desligado, framework sem u_tecApoStat no RPO) retorna
# $null e o chamador cai nos guards locais de sempre.

function ConvertFrom-ApoDataFonte {
    <# Converte o dataFonte do u_tecApoStat ("YYYYMMDD HH:MM:SS") em [datetime].
       Aceita tambem "YYYYMMDD HHMM:SS" (formato citado na TDN do GetAPOInfo) e
       data sem hora. Qualquer coisa fora disso: $null, nunca excecao. #>
    param([string]$DataFonte)
    if ([string]::IsNullOrWhiteSpace($DataFonte)) { return $null }
    $s = $DataFonte.Trim()
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $none = [System.Globalization.DateTimeStyles]::None
    foreach ($fmt in @('yyyyMMdd HH:mm:ss', 'yyyyMMdd HHmm:ss', 'yyyyMMdd')) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($s, $fmt, $inv, $none, [ref]$dt)) { return $dt }
    }
    return $null
}

function Test-ApoFresh {
    <# Decide se o RPO ja contem o conteudo atual do fonte: o dataFonte do RPO
       (mtime do arquivo na compilacao) bate com o mtime atual do disco.
       Tolerancia de 2s cobre arredondamento de filesystem. #>
    param(
        [Parameter(Mandatory=$false)]$ApoEntry,
        [Parameter(Mandatory=$true)][datetime]$DiskMtime,
        [Parameter(Mandatory=$false)][int]$ToleranceSeconds = 2
    )
    if (-not $ApoEntry -or -not $ApoEntry.exists) { return $false }
    $rpoTime = ConvertFrom-ApoDataFonte -DataFonte ([string]$ApoEntry.dataFonte)
    if ($null -eq $rpoTime) { return $false }
    return ([math]::Abs(($DiskMtime - $rpoTime).TotalSeconds) -le $ToleranceSeconds)
}

function ConvertFrom-ApoStatResult {
    <# Parseia o `result` (string JSON) do u_tecApoStat em hashtable
       NOME -> @{ exists; dataFonte }. JSON invalido: $null, nunca excecao. #>
    param([string]$ResultJson)
    if ([string]::IsNullOrWhiteSpace($ResultJson)) { return $null }
    try {
        $obj = $ResultJson | ConvertFrom-Json -ErrorAction Stop
    } catch { return $null }
    if (-not $obj -or -not $obj.PSObject.Properties['programs']) { return $null }
    $stat = @{}
    foreach ($p in $obj.programs.PSObject.Properties) {
        $stat[$p.Name.ToUpperInvariant()] = $p.Value
    }
    return $stat
}

function Get-RpoApoStat {
    <# Consulta u_tecApoStat via /runner/exec para uma lista de basenames
       (COM extensao, como o RPO registra: "TECWRAP.TLPP"). Best-effort:
       qualquer falha retorna $null e o chamador usa os guards locais.
       Timeout curto de proposito - na janela de restart do HTTPREST a porta
       recusa rapido, e esperar aqui atrasaria o build sem ganho. #>
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string[]]$FileNames
    )
    if (-not $Config.BaseUrl -or -not $Config.User) { return $null }
    if ($FileNames.Count -eq 0) { return $null }
    try {
        $b64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Config.User):$($Config.Password)"))
        $list = ($FileNames | ForEach-Object { $_.ToUpperInvariant() }) -join ','
        $body = @{ function = 'u_tecApoStat'; argString = '"' + $list + '"' } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Method Post -Uri "$($Config.BaseUrl)/runner/exec" `
            -Headers @{ Authorization = "Basic $b64" } -ContentType 'application/json' `
            -Body $body -TimeoutSec 5 -ErrorAction Stop
        return (ConvertFrom-ApoStatResult -ResultJson ([string]$resp.result))
    } catch {
        return $null
    }
}
