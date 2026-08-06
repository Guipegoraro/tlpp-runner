<#
.SYNOPSIS
    Detecta o ambiente local (TDS, AppServer, DBAccess, SQL Server) e
    retorna um objeto com o que achou e o que falta.

.DESCRIPTION
    Read-only - nao altera nada. Usado pelas skills tlpp-tdd-setup (machine-once)
    e tlpp-tdd-project-init pra detectar o ambiente local e perguntar so o que
    nao foi achado.

    Retorna um PSCustomObject com:
      - Tds              : { Found, Path, Version, AdvplsPath }
      - ProtheusRoot     : path detectado ou $null   (NAO existe .Protheus.Root)
      - AppServer        : { Found, Pid, Dir, Port, Ini, RpoPath }
      - DBAccess         : { Found, Pid, Port, Ini, Root }
      - Sql              : { Found, Instances, WinAuthWorks }
                           Instances = [ { Name, Instance, Status } ] - use
                           .Instances[N].Instance (NAO existe .PrimaryInstance)
      - Issues           : [ string... ] - problemas que bloqueiam install

.PARAMETER Json
    Emite JSON ao inves do objeto - util quando chamado por LLM.

.EXAMPLE
    $env = & .\Test-Environment.ps1
    $env | & .\Test-Environment.ps1 -Json   # emite JSON
#>
param(
    [Parameter(Mandatory=$false)][switch]$Json
)

$ErrorActionPreference = 'Continue'  # nao explode se algum item falhar

# ----- 1) TDS-VSCode -----
$tds = [ordered]@{
    Found      = $false
    Path       = $null
    Version    = $null
    AdvplsPath = $null
}
$tdsExts = Get-ChildItem -Path "$env:USERPROFILE\.vscode\extensions" -Directory -Filter 'totvs.tds-vscode-*' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending
if ($tdsExts) {
    $tdsLatest = $tdsExts[0]
    $advpls = Join-Path $tdsLatest.FullName 'node_modules\@totvs\tds-ls\bin\windows\advpls.exe'
    if (Test-Path $advpls) {
        $tds.Found      = $true
        $tds.Path       = $tdsLatest.FullName
        $tds.Version    = ($tdsLatest.Name -replace '^totvs\.tds-vscode-', '')
        $tds.AdvplsPath = $advpls
    }
}

# ----- 2) Protheus root -----
$protheusRoot = $null
foreach ($drive in @('C:', 'D:', 'E:')) {
    $candidates = Get-ChildItem -Path "$drive\TOTVS" -Directory -Filter 'Protheus_*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    if ($candidates -and (Test-Path (Join-Path $candidates[0].FullName 'Protheus\bin'))) {
        $protheusRoot = $candidates[0].FullName
        break
    }
}

# ----- 3) AppServer -----
$appServer = [ordered]@{
    Found = $false
    Pid   = $null
    Dir   = $null      # diretorio do binario (o que contem o appserver.ini)
    Port  = $null      # porta do [HTTPREST] lida do ini
    Ini   = $null
    RpoPath = $null
}
$appProcs = Get-Process -Name 'appserver*' -ErrorAction SilentlyContinue
if ($appProcs) {
    # heuristica: pega o que conseguir ler Path (alguns processos podem exigir admin)
    $appProc = $null
    foreach ($p in $appProcs) {
        try {
            $pPath = $p.Path
            if ($pPath) { $appProc = $p; break }
        } catch { continue }
    }
    $appPath = if ($appProc) { try { $appProc.Path } catch { $null } } else { $null }

    # Fallbacks quando o Path do processo e ilegivel (processo elevado ou
    # rodando como servico) - o caso COMUM, nao a excecao. Sem eles a deteccao
    # se dava por vencida e mandava "rode como Admin", travando o setup de quem
    # nao pode elevar.
    # 1) Layout conhecido sob ProtheusRoot - PRIMEIRO por ser deterministico.
    #    Prefere appserver_rest, que e quem serve /rest/runner/*.
    if (-not $appPath -and $protheusRoot) {
        foreach ($cand in @('Protheus\bin\appserver_rest\appserver.exe', 'Protheus\bin\appserver\appserver.exe')) {
            $try = Join-Path $protheusRoot $cand
            if (Test-Path $try) { $appPath = $try; break }
        }
    }
    # 2) Servico Windows apontando pro binario (Win32_Service.PathName nao exige
    #    elevacao, ao contrario de Process.Path).
    #    EXCLUI o License Server: ele tambem roda um appserver.exe e, sendo
    #    servico, aparece antes na consulta - resolver por ele apontaria o ini
    #    do TOTVSLicenseVirtual, que nao tem [HTTPREST] e nao serve /rest.
    if (-not $appPath) {
        $svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
               Where-Object { $_.PathName -match 'appserver.*\.exe' -and $_.PathName -notmatch 'License' } |
               Select-Object -First 1
        if ($svc -and $svc.PathName -match '([A-Za-z]:\\[^"]*appserver[^"]*\.exe)') {
            $appPath = $matches[1]
        }
    }

    if ($appPath) {
        $appServer.Found = $true
        $appServer.Pid   = $appProc.Id
        $appDir = Split-Path $appPath -Parent
        # Dir e o diretorio do binario detectado - e dele que a skill de setup
        # copia a arvore quando o usuario escolhe AppServer dedicado.
        $appServer.Dir   = $appDir
        $appServer.Ini   = Join-Path $appDir 'appserver.ini'
        if (Test-Path $appServer.Ini) {
            # tenta extrair porta REST do .ini
            $iniContent = Get-Content $appServer.Ini -ErrorAction SilentlyContinue
            $httpRestSection = $false
            foreach ($line in $iniContent) {
                if ($line -match '^\s*\[HTTPREST\]') { $httpRestSection = $true; continue }
                if ($line -match '^\s*\[' -and $httpRestSection) { $httpRestSection = $false }
                if ($httpRestSection -and $line -match '^\s*Port\s*=\s*(\d+)') {
                    $appServer.Port = [int]$matches[1]
                }
            }
            # RpoPath: SourcePath dentro da Environment correta (default: primeira)
            foreach ($line in $iniContent) {
                if ($line -match '^\s*SourcePath\s*=\s*(.+)') {
                    $appServer.RpoPath = $matches[1].Trim()
                    break
                }
            }
        }
    }
}

# ----- 4) DBAccess -----
$dba = [ordered]@{
    Found = $false
    Pid   = $null
    Port  = $null
    Ini   = $null
    Root  = $null
}
$dbaProcs = Get-Process -Name 'dbaccess*' -ErrorAction SilentlyContinue
if ($dbaProcs) {
    $dbaProc = $null
    foreach ($p in $dbaProcs) {
        try {
            $pPath = $p.Path
            if ($pPath) { $dbaProc = $p; break }
        } catch { continue }
    }
    $dbaPath = if ($dbaProc) { try { $dbaProc.Path } catch { $null } } else { $null }

    # Mesmos fallbacks do AppServer: processo elevado/servico e o caso comum.
    if (-not $dbaPath) {
        $svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
               Where-Object { $_.PathName -match 'dbaccess.*\.exe' } | Select-Object -First 1
        if ($svc -and $svc.PathName -match '([A-Za-z]:\\[^"]*dbaccess[^"]*\.exe)') {
            $dbaPath = $matches[1]
        }
    }
    if (-not $dbaPath -and $protheusRoot) {
        foreach ($cand in @('TOTVSDBAccess\windows\dbaccess64.exe', 'TOTVSDBAccess\windows\dbaccess.exe')) {
            $try = Join-Path $protheusRoot $cand
            if (Test-Path $try) { $dbaPath = $try; break }
        }
    }

    if ($dbaPath) {
        $dba.Found = $true
        $dba.Pid   = $dbaProc.Id
        $dba.Root  = Split-Path $dbaPath -Parent
        $dba.Ini   = Join-Path $dba.Root 'dbaccess.ini'
        if (Test-Path $dba.Ini) {
            $iniContent = Get-Content $dba.Ini -ErrorAction SilentlyContinue
            foreach ($line in $iniContent) {
                if ($line -match '^\s*Port\s*=\s*(\d+)') {
                    $dba.Port = [int]$matches[1]
                    break
                }
            }
        }
    }
}

# ----- 5) SQL Server -----
$sql = [ordered]@{
    Found        = $false
    Instances    = @()
    WinAuthWorks = $false
}
$sqlServices = Get-Service -Name 'MSSQL$*' -ErrorAction SilentlyContinue
if (-not $sqlServices) {
    $sqlServices = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
}
if ($sqlServices) {
    foreach ($svc in $sqlServices) {
        $instance = if ($svc.Name -eq 'MSSQLSERVER') { 'localhost' } else { 'localhost\' + ($svc.Name -replace '^MSSQL\$', '') }
        $sql.Instances += @{ Name = $svc.Name; Instance = $instance; Status = $svc.Status.ToString() }
    }
    $sql.Found = $true

    # Testa Windows Auth na primeira instancia ativa
    $running = $sql.Instances | Where-Object { $_.Status -eq 'Running' } | Select-Object -First 1
    if ($running) {
        $sqlcmd = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
        if ($sqlcmd) {
            try {
                $out = & sqlcmd.exe -S $running.Instance -E -l 5 -Q 'SELECT 1' 2>&1
                if ($LASTEXITCODE -eq 0) { $sql.WinAuthWorks = $true }
            } catch { }
        }
    }
}

# ----- 6) Issues -----
$issues = @()
if (-not $tds.Found)        { $issues += 'TDS-VSCode com totvs.tds-vscode-* nao encontrado em ~/.vscode/extensions' }
if (-not $protheusRoot)     { $issues += 'Diretorio Protheus_* nao encontrado em C:\TOTVS / D:\TOTVS / E:\TOTVS' }
if (-not $appServer.Found) {
    if ($appProcs) {
        $issues += "Processo appserver*.exe detectado ($($appProcs.Count)) mas sem acesso ao Path/Ini - rode esta skill como Admin OU informe os caminhos manualmente"
    } else {
        $issues += 'Processo appserver*.exe nao esta rodando - suba o AppServer dev antes de continuar'
    }
}
if (-not $dba.Found) {
    if ($dbaProcs) {
        $issues += "Processo dbaccess*.exe detectado ($($dbaProcs.Count)) mas sem acesso ao Path/Ini - rode esta skill como Admin OU informe os caminhos manualmente"
    } else {
        $issues += 'Processo dbaccess*.exe nao esta rodando - suba o DBAccess antes de continuar'
    }
}
if (-not $sql.Found)        { $issues += 'Nenhum servico MSSQL$* / MSSQLSERVER encontrado' }
if ($sql.Found -and -not $sql.WinAuthWorks) { $issues += 'Windows Auth no SQL Server falhou (init perguntara sa+senha)' }

# ----- 7) Result -----
$result = [ordered]@{
    Tds          = $tds
    ProtheusRoot = $protheusRoot
    AppServer    = $appServer
    DBAccess     = $dba
    Sql          = $sql
    Issues       = $issues
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
} else {
    [pscustomobject]$result
}
