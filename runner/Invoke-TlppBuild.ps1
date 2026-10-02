<#
.SYNOPSIS
    Compila fontes TLPP/AdvPL/PRW via advpls.exe cli (sem precisar do TDS-VSCode aberto).

.DESCRIPTION
    Gera um script INI dinamico com authentication + compile e invoca
    advpls.exe no modo cli. Substitui o Ctrl+F9 do TDS-VSCode na automacao
    de TDD com Claude Code.

    Apos o redesign global, este script vive no plugin e compila fontes
    do PROJETO ATUAL (cwd ou $env:CLAUDE_PROJECT_DIR). O caminho do advpls,
    includes e credenciais vem da config global em ~/.claude/tlpp-tdd/config.ps1.

.PARAMETER File
    Caminho de um arquivo .tlpp / .prw / .prx a compilar. Pode repetir.
    Resolvido relativo ao cwd, fallback pra ProjectRoot.

.PARAMETER All
    Compila todos os fontes em src/, mocks/, test/ do projeto atual.

.PARAMETER Recompile
    Forca recompilacao (default: True - sempre recompila pra TDD).

.PARAMETER WithExamples
    Quando combinado com -All, inclui examples/ no build (se existir).

.PARAMETER ProjectRoot
    Override do diretorio do projeto. Default: $env:CLAUDE_PROJECT_DIR ou cwd.

.PARAMETER Force
    Ignora o cache de build e compila mesmo que o fonte ja esteja no RPO com
    este conteudo. Use quando desconfiar que o cache esta mentindo.

.NOTES
    CACHE DE BUILD (issue #29): qualquer compilacao derruba o HTTPREST ate o
    proximo ciclo do [ONSTART] RefreshRate (~5s com RefreshRate=2, ate ~2 min
    com 120) - e `recompile=F` nao evita, o advpls compila do mesmo jeito.
    Por isso fontes ja compilados com o mesmo conteudo sao PULADOS: se todos
    forem pulados, o advpls nao roda e nao ha janela de indisponibilidade.
    Detalhes da invalidacao em runner/BuildCache.ps1.

.EXAMPLE
    .\Invoke-TlppBuild.ps1 -File "src\tecMinha.tlpp"
    .\Invoke-TlppBuild.ps1 -All
    .\Invoke-TlppBuild.ps1 -All -WithExamples
    .\Invoke-TlppBuild.ps1 -File "src\tecMinha.tlpp" -Force
#>
param(
    [Parameter(Mandatory=$false)][string[]]$File,
    [Parameter(Mandatory=$false)][switch]$All,
    [Parameter(Mandatory=$false)][switch]$WithExamples,
    [Parameter(Mandatory=$false)][bool]$Recompile = $true,
    [Parameter(Mandatory=$false)][string]$ProjectRoot,
    [Parameter(Mandatory=$false)][switch]$Force
)

$ErrorActionPreference = 'Stop'

# Carrega config (defaults + global ~/.claude/tlpp-tdd/config.ps1 + project .tlpp-tdd.json + legacy)
# Override ANTES do dot-source: a cascata le o .tlpp-tdd.json durante o load,
# entao ajustar $cfg.ProjectRoot depois nao afeta ProjectName/TestDb.
if ($ProjectRoot) { $TlppProjectRootOverride = (Resolve-Path $ProjectRoot).Path }
. (Join-Path $PSScriptRoot 'runner.config.ps1')
. (Join-Path $PSScriptRoot 'BuildCache.ps1')
. (Join-Path $PSScriptRoot 'BuildTemp.ps1')
. (Join-Path $PSScriptRoot 'InstanceControl.ps1')
$cfg = $TlppRunner

# --- Validacao basica ---
if (-not $cfg.AdvplsPath -or -not (Test-Path $cfg.AdvplsPath)) {
    Write-Error "advpls.exe nao encontrado em: '$($cfg.AdvplsPath)'. Configure em ~/.claude/tlpp-tdd/config.ps1 ou rode /tlpp-tdd-setup."
    exit 99
}
if (-not $cfg.Includes -or -not (Test-Path $cfg.Includes)) {
    Write-Error "Includes nao encontrado em: '$($cfg.Includes)'. Configure ProtheusRoot em ~/.claude/tlpp-tdd/config.ps1."
    exit 99
}

# --- Instancia dedicada (#34): sobe on-demand ANTES de tocar advpls/REST ---
# No-op silencioso quando o projeto nao e isolado. Precisa vir antes do oraculo
# RPO (que fala REST) e do advpls (que fala na porta TCP): sem a instancia de pe
# o oraculo daria $null a toa e o advpls falharia com connection refused.
$null = Start-IsolatedInstanceIfNeeded -Config $cfg

# --- Resolve lista de fontes (a partir do PROJETO, nao do plugin) ---
$files = @()
if ($All) {
    $roots = @('src', 'mocks', 'test')
    if ($WithExamples) { $roots += 'examples' }
    foreach ($r in $roots) {
        $p = Join-Path $cfg.ProjectRoot $r
        if (Test-Path $p) {
            $files += Get-ChildItem -Path $p -Recurse -Include '*.tlpp','*.prw','*.prx','*.prg' -ErrorAction SilentlyContinue |
                      Select-Object -ExpandProperty FullName
        }
    }
    if ($files.Count -eq 0) {
        # Projeto sem src/mocks/test - busca .tlpp/.prw na raiz mesmo (excluindo dirs especiais)
        $files += Get-ChildItem -Path $cfg.ProjectRoot -Recurse -Include '*.tlpp','*.prw','*.prx','*.prg' -ErrorAction SilentlyContinue |
                  Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|examples)\\' -or $WithExamples } |
                  Select-Object -ExpandProperty FullName
    }
} elseif ($File) {
    foreach ($f in $File) {
        if (Test-Path $f) {
            $files += (Resolve-Path $f).Path
        } else {
            # fallback: relativo ao ProjectRoot
            $tryRel = Join-Path $cfg.ProjectRoot $f
            if (Test-Path $tryRel) {
                $files += (Resolve-Path $tryRel).Path
            } else {
                Write-Error "Arquivo nao encontrado: $f (cwd=$($PWD.Path), ProjectRoot=$($cfg.ProjectRoot))"
                exit 2
            }
        }
    }
} else {
    Write-Error "Use -File <arquivo[,..]> ou -All"
    exit 2
}

if ($files.Count -eq 0) {
    Write-Host "[build] nada para compilar em $($cfg.ProjectRoot)" -ForegroundColor Yellow
    exit 0
}

# --- Cache: descarta fontes ja no RPO com este conteudo (issues #29 e #33) ---
# Compilar custa 68-93s de HTTPREST fora do ar, entao pular tem valor alto.
$skipped = @()
if (-not $Force) {
    $keep = @()
    # Colisao DENTRO do proprio build (-All com dois fontes de mesmo basename):
    # ambos disputam o mesmo slot do RPO, entao nenhum dos dois pode ser cacheado.
    $localDup = @{}
    foreach ($f in $files) {
        $prog = Get-ProgramName -Path $f
        if ($localDup.ContainsKey($prog)) { $localDup[$prog] += @($f) } else { $localDup[$prog] = @($f) }
    }

    # Guard 0 (issue #33): oraculo RPO. Pergunta ao proprio AppServer o que
    # esta compilado (u_tecApoStat/GetAPOInfo): dataFonte == mtime do disco
    # significa RPO atualizado, por objeto, sem depender do cache local e sem
    # invalidar em bloco quando o RPO muda por fora. Se o REST nao responder
    # (janela de restart, AppServer off, framework antigo sem u_tecApoStat),
    # retorna $null e caimos nos guards locais de sempre.
    $apoStat = Get-RpoApoStat -Config $cfg -FileNames ($files | ForEach-Object { [System.IO.Path]::GetFileName($_) })

    if ($apoStat) {
        foreach ($f in $files) {
            $prog = Get-ProgramName -Path $f
            if ($localDup[$prog].Count -gt 1) {
                $keep += $f
                if ($localDup[$prog][0] -eq $f) {
                    Write-Host "[build] AVISO: '$prog' tem mais de um fonte NESTE build - ambos gravam no mesmo slot do RPO:" -ForegroundColor Yellow
                    foreach ($d in $localDup[$prog]) { Write-Host "[build]        $d" -ForegroundColor Yellow }
                    Write-Host "[build]        o ultimo compilado vence. Renomeie um deles." -ForegroundColor Yellow
                }
            } elseif (Test-ApoFresh -ApoEntry $apoStat[[System.IO.Path]::GetFileName($f).ToUpperInvariant()] -DiskMtime (Get-Item $f).LastWriteTime) {
                $skipped += $f
            } else {
                $keep += $f
            }
        }
        $files = $keep
        if ($skipped.Count -gt 0) {
            Write-Host "[build] $($skipped.Count) fonte(s) ja no RPO com este conteudo (oraculo RPO) - pulando (use -Force pra ignorar)" -ForegroundColor DarkGray
            foreach ($s in $skipped) { Write-Host "  = $([System.IO.Path]::GetFileName($s))" -ForegroundColor DarkGray }
        }
    } else {
        # Fallback: guards locais (issue #29) - cache por hash + stamp do RPO
        $cache = Read-BuildCache
        $rpoChangedExternally = $false
        foreach ($f in $files) {
            $prog = Get-ProgramName -Path $f
            $verdict = Test-BuildCacheHit -Path $f -Config $cfg -Cache $cache
            if ($verdict.Reason -eq 'RPO alterado fora do runner') { $rpoChangedExternally = $true }

            if ($localDup[$prog].Count -gt 1) {
                # Sem isso o cache faria ping-pong: a cada build um dos dois da miss,
                # recompila e vira dono do slot - alternando o conteudo do RPO
                # indefinidamente. Melhor avisar e compilar os dois.
                $keep += $f
                if ($localDup[$prog][0] -eq $f) {
                    Write-Host "[build] AVISO: '$prog' tem mais de um fonte NESTE build - ambos gravam no mesmo slot do RPO:" -ForegroundColor Yellow
                    foreach ($d in $localDup[$prog]) { Write-Host "[build]        $d" -ForegroundColor Yellow }
                    Write-Host "[build]        o ultimo compilado vence. Renomeie um deles." -ForegroundColor Yellow
                }
            } elseif ($verdict.Hit) {
                $skipped += $f
            } else {
                $keep += $f
                # Colisao ENTRE projetos no RPO compartilhado e silenciosa por
                # natureza - avisar aqui e a unica chance do usuario perceber.
                if ($verdict.Owner) {
                    Write-Host "[build] AVISO: '$prog' no RPO veio de outro fonte:" -ForegroundColor Yellow
                    Write-Host "[build]        $($verdict.Owner)" -ForegroundColor Yellow
                    Write-Host "[build]        recompilando com a sua versao - a outra sera sobrescrita." -ForegroundColor Yellow
                }
            }
        }
        $files = $keep

        # RPO mexido por fora invalida o environment INTEIRO, nao so o arquivo
        # consultado: gravar o stamp novo mantendo as entradas antigas as
        # re-abencoaria, e o cache passaria a mentir sobre elas.
        if ($rpoChangedExternally) {
            Write-Host "[build] RPO alterado fora do runner - descartando o cache deste environment" -ForegroundColor DarkYellow
            try { Clear-BuildCacheEnvironment -Config $cfg } catch { }
        }

        if ($skipped.Count -gt 0) {
            Write-Host "[build] $($skipped.Count) fonte(s) ja no RPO com este conteudo (cache local) - pulando (use -Force pra ignorar o cache)" -ForegroundColor DarkGray
            foreach ($s in $skipped) { Write-Host "  = $([System.IO.Path]::GetFileName($s))" -ForegroundColor DarkGray }
        }
    }

    if ($files.Count -eq 0) {
        Write-Host "[build] OK (nada a compilar - HTTPREST intacto)" -ForegroundColor Green
        exit 0
    }
}

# --- Gera script INI em area temp (evita poluir projeto e race condition entre repos) ---
# Nomes por PID: dois projetos compilando ao mesmo tempo compartilhavam
# `last-build.ini`/`.log` - um sobrescrevia o INI do outro (compilando a lista
# de fontes errada) e o `Remove-Item` do log estourava com "file in use", que
# sob ErrorActionPreference='Stop' abortava o build inteiro.
$tmpDir = Join-Path $env:TEMP 'tlpp-tdd'
if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
$iniPath = Join-Path $tmpDir "build-$PID.ini"
$logPath = Join-Path $tmpDir "build-$PID.log"
if (Test-Path $logPath) { Remove-Item $logPath -Force -ErrorAction SilentlyContinue }

# Higiene ANTES de criar o novo INI. O INI carrega `psw=` em texto plano, entao
# resto de execucao que morreu antes do finally e senha exposta no %TEMP%.
# Heuristica em runner/BuildTemp.ps1: apaga PID morto, ou PID vivo com INI
# antigo (>1h - cobre reciclagem de PID); preserva INI recente de PID vivo,
# que pode ser um build concorrente de outro projeto.
$null = Remove-OrphanBuildIni -TmpDir $tmpDir
Remove-OldBuildLog -TmpDir $tmpDir

$programs = ($files -join ',')
$recompileFlag = if ($Recompile) { 'T' } else { 'F' }

$iniContent = @"
; Gerado automaticamente pelo Invoke-TlppBuild.ps1 - NAO EDITAR
logToFile=$logPath
showConsoleOutput=true

[authentication]
action=authentication
server=$($cfg.Server)
port=$($cfg.Port)
secure=$($cfg.Secure)
build=$($cfg.Build)
environment=$($cfg.Environment)
user=$($cfg.User)
psw=$($cfg.Password)

[compile]
action=compile
program=$programs
recompile=$recompileFlag
includes=$($cfg.Includes)
"@

# advpls cli exige INI em CP1252
[System.IO.File]::WriteAllText($iniPath, $iniContent, [System.Text.Encoding]::GetEncoding(1252))

# --- Executa advpls cli ---
Write-Host "[build] $($files.Count) fonte(s) -> advpls cli (proj=$([System.IO.Path]::GetFileName($cfg.ProjectRoot)))" -ForegroundColor Cyan
foreach ($f in $files) { Write-Host "  - $f" -ForegroundColor DarkGray }

# Invoke-AdvplsCli apaga o INI no finally - o arquivo tem a senha em texto
# plano e nao pode sobreviver nem a um compile que estoura.
$res    = Invoke-AdvplsCli -AdvplsPath $cfg.AdvplsPath -IniPath $iniPath
$output = $res.Output
$code   = $res.ExitCode

# Filtra ruido e mostra so o relevante
$output | ForEach-Object {
    $line = $_.ToString()
    if ($line -match '\[ERROR\]|\[WARN\]|\[SUCCESS\]|\[FATAL\]') {
        $color = switch -regex ($line) {
            '\[SUCCESS\]' { 'Green' }
            '\[WARN\]'    { 'Yellow' }
            '\[ERROR\]'   { 'Red' }
            '\[FATAL\]'   { 'Red' }
            default       { 'White' }
        }
        Write-Host $line -ForegroundColor $color
    } elseif ($line -match 'Starting build|Starting recompile|Recompile finished|All files compiled') {
        Write-Host $line -ForegroundColor Cyan
    }
}

if ($code -eq 0) {
    # So registra no cache o que REALMENTE compilou. Build parcial/falho nao
    # entra - cache mentindo custa mais caro que recompilar.
    try {
        Update-BuildCache -Paths $files -Config $cfg
    } catch {
        # Cache e otimizacao: falhar em grava-lo nao pode reprovar um build que deu certo.
        Write-Host "[build] aviso: nao foi possivel atualizar o cache de build ($($_.Exception.Message))" -ForegroundColor DarkYellow
    }
    Write-Host "[build] OK" -ForegroundColor Green
} else {
    Write-Host "[build] FAIL (exit $code) - veja log completo em $logPath" -ForegroundColor Red
    # RPO aberto por outro AppServer: so um processo por vez escreve no custom.rpo.
    # Quando a falha vem por aqui, o AppServer alvo ja derrubou os HTTP servers no
    # inicio do build e nao os religa: o REST fica fora ate reiniciar o AppServer.
    if (($output | Out-String) -match 'COMPILEERROR-300|Failed to open repository') {
        Write-Host "[build] o RPO esta aberto por OUTRO AppServer (mesmo custom.rpo). Feche o outro AppServer" -ForegroundColor Yellow
        Write-Host "[build] e reinicie este ($($cfg.Server):$($cfg.Port)): o REST dele so volta apos o restart." -ForegroundColor Yellow
    }
}
exit $code
