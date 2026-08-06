<#
.SYNOPSIS
    Sincroniza canonicos da raiz do repo para os espelhos em `.claude/`.

.DESCRIPTION
    Apos o reorg de 2026-05-12, a raiz do repo virou canonica (plugin distribuido
    via `/plugin install` espera o manifest e os componentes na raiz). `.claude/`
    permanece como ESPELHO para o dev in-repo conseguir usar skills/commands sem
    precisar instalar o plugin via file://.

    Roda esse script apos editar canonicos em `skills/` ou `commands/`.

    Os canonicos sao ENUMERADOS POR GLOB (skills/*/SKILL.md + commands/*.md), nao
    por lista fixa: skill/command novo passa a ser espelhado sozinho. Pra manter um
    canonico FORA do espelho, adicione em $excluded abaixo - a exclusao vira
    explicita em vez de silenciosa.

    Skills/commands deliberadamente SEM espelho em `.claude/`:
        - skills/tlpp-tdd-setup/        (setup + doctor - nao faz sentido in-repo)
        - skills/tlpp-tdd-project-init/ (idem - nao roda dentro do proprio repo do framework)
        - commands/tlpp-tdd-setup.md
        - commands/tlpp-tdd-project-init.md

.EXAMPLE
    .\scripts\plugin\sync.ps1
    .\scripts\plugin\sync.ps1 -DryRun
#>
param(
    [Parameter(Mandatory=$false)][switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# Canonicos deliberadamente SEM espelho em .claude/ (justificativa na .DESCRIPTION).
# Caminhos relativos a raiz do repo, separador '\'.
$excluded = @(
    'skills\tlpp-tdd-setup\SKILL.md'
    'skills\tlpp-tdd-project-init\SKILL.md'
    'commands\tlpp-tdd-setup.md'
    'commands\tlpp-tdd-project-init.md'
)

# Enumera canonicos por glob em vez de lista fixa - assim skill/command novo na
# raiz nao passa despercebido pelo sync nem pelo drift check do validate.ps1.
$canonical = @()
$skillsDir = Join-Path $root 'skills'
if (Test-Path $skillsDir) {
    $canonical += Get-ChildItem -Path $skillsDir -Filter 'SKILL.md' -Recurse -File |
        ForEach-Object { $_.FullName.Substring($root.Length + 1) }
}
$commandsDir = Join-Path $root 'commands'
if (Test-Path $commandsDir) {
    $canonical += Get-ChildItem -Path $commandsDir -Filter '*.md' -File |
        ForEach-Object { $_.FullName.Substring($root.Length + 1) }
}

# Mapeamento canonico (raiz) -> espelho (.claude/)
$pairs = @()
foreach ($rel in ($canonical | Sort-Object)) {
    if ($excluded -contains $rel) { continue }
    $pairs += @{ src = $rel; dst = (Join-Path '.claude' $rel) }
}

$changed = 0
foreach ($p in $pairs) {
    $srcPath = Join-Path $root $p.src
    $dstPath = Join-Path $root $p.dst

    if (-not (Test-Path $srcPath)) {
        Write-Host "[sync] WARN: canonico nao existe $($p.src)" -ForegroundColor Yellow
        continue
    }

    $dstDir = Split-Path $dstPath -Parent
    if (-not (Test-Path $dstDir)) {
        if ($DryRun) {
            Write-Host "[sync] (dry) criaria diretorio $dstDir" -ForegroundColor Cyan
        } else {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
    }

    $needsCopy = $true
    if (Test-Path $dstPath) {
        $srcBytes = [System.IO.File]::ReadAllBytes($srcPath)
        $dstBytes = [System.IO.File]::ReadAllBytes($dstPath)
        if ($srcBytes.Length -eq $dstBytes.Length) {
            $same = $true
            for ($i = 0; $i -lt $srcBytes.Length; $i++) {
                if ($srcBytes[$i] -ne $dstBytes[$i]) { $same = $false; break }
            }
            if ($same) { $needsCopy = $false }
        }
    }

    if ($needsCopy) {
        if ($DryRun) {
            Write-Host "[sync] (dry) $($p.src) -> $($p.dst)" -ForegroundColor Cyan
        } else {
            Copy-Item -Path $srcPath -Destination $dstPath -Force
            Write-Host "[sync] $($p.src) -> $($p.dst)" -ForegroundColor Green
        }
        $changed++
    }
}

# Orfaos: espelho que perdeu o canonico (skill/command renomeado ou removido na
# raiz). Sem isso o `.claude/` continua servindo uma versao morta pro dev in-repo.
#
# Contados SEPARADO de $changed: orfao exige remocao manual (nao vamos deletar
# arquivo por conta propria). Se somasse em $changed, o modo normal imprimiria
# "N arquivo(s) atualizados" e sairia 0 sem ter feito nada - o validate
# continuaria falhando e mandando rodar o sync, num laco sem saida.
$orfaos = @()
$expected = $pairs | ForEach-Object { $_.dst }
foreach ($dir in @('.claude\skills', '.claude\commands')) {
    $dirPath = Join-Path $root $dir
    if (-not (Test-Path $dirPath)) { continue }
    Get-ChildItem -Path $dirPath -Filter '*.md' -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length + 1)
        if ($expected -notcontains $rel) { $orfaos += $rel }
    }
}
foreach ($o in $orfaos) {
    Write-Host "[sync] ORFAO: $o nao tem canonico na raiz - remova o espelho ou restaure o canonico" -ForegroundColor Yellow
}

if ($changed -gt 0) {
    if ($DryRun) {
        Write-Host "[sync] $changed arquivo(s) seriam atualizados (rode sem -DryRun pra aplicar)." -ForegroundColor Yellow
    } else {
        Write-Host "[sync] $changed arquivo(s) atualizados." -ForegroundColor Green
    }
} elseif ($orfaos.Count -eq 0) {
    Write-Host "[sync] tudo sincronizado." -ForegroundColor DarkGray
}

# Exit 1 enquanto houver orfao: e estado que o sync NAO resolve sozinho, entao
# nao pode ser reportado como sucesso (senao o pre-commit/CI passariam por cima).
if ($orfaos.Count -gt 0) { exit 1 }
if ($changed -gt 0 -and $DryRun) { exit 1 }
exit 0
