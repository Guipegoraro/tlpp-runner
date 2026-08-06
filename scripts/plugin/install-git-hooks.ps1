<#
.SYNOPSIS
    Instala o git pre-commit hook que roda scripts/plugin/validate.ps1 (issue #23).

.DESCRIPTION
    Escreve um pre-commit (sh) em .git/hooks/ que invoca validate.ps1 via pwsh
    (fallback powershell). Se validate falhar, o commit e bloqueado. O escape
    hatch nativo do git continua valendo: 'git commit --no-verify' pula o hook.

    Idempotente: se ja existe um pre-commit nosso, sobrescreve. Se existe um
    pre-commit de terceiros, faz backup em pre-commit.bak antes (salvo -Force).

    O hooks dir e resolvido via 'git rev-parse --git-path hooks', entao funciona
    tambem em worktrees (onde .git e um arquivo, nao um diretorio).

.PARAMETER Force
    Sobrescreve sem fazer backup de um pre-commit pre-existente de terceiros.

.EXAMPLE
    pwsh .\scripts\plugin\install-git-hooks.ps1
#>
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# --- Resolve o diretorio de hooks (suporta worktree) ---
Push-Location $root
try {
    $isRepo = (& git rev-parse --is-inside-work-tree 2>$null)
    if ($isRepo -ne 'true') { Write-Error "Nao e um repositorio git: $root"; exit 1 }
    $hooksDir = (& git rev-parse --git-path hooks 2>$null)
} finally {
    Pop-Location
}
if (-not $hooksDir) { Write-Error "Nao consegui resolver o hooks dir (git rev-parse)."; exit 1 }
if (-not [System.IO.Path]::IsPathRooted($hooksDir)) { $hooksDir = Join-Path $root $hooksDir }
if (-not (Test-Path $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }

$preCommit = Join-Path $hooksDir 'pre-commit'
$marker    = 'tlpp-runner:install-git-hooks'

# --- Backup de pre-commit de terceiros ---
if ((Test-Path $preCommit) -and -not $Force) {
    $existing = Get-Content $preCommit -Raw -ErrorAction SilentlyContinue
    if ($existing -and $existing -notmatch [regex]::Escape($marker)) {
        $bak = "$preCommit.bak"
        Copy-Item $preCommit $bak -Force
        Write-Host "[install-git-hooks] pre-commit de terceiros encontrado -> backup em $bak" -ForegroundColor Yellow
    }
}

# --- Conteudo do hook (sh; LF obrigatorio, sem BOM) ---
$hookBody = @"
#!/bin/sh
# $marker (issue #23) - roda validate.ps1; bloqueia o commit se falhar.
# Pular intencionalmente: git commit --no-verify
root="`$(git rev-parse --show-toplevel)"
if command -v pwsh >/dev/null 2>&1; then
  PS=pwsh
elif command -v powershell >/dev/null 2>&1; then
  PS=powershell
else
  echo "[pre-commit] PowerShell (pwsh/powershell) nao encontrado - validate pulado" >&2
  exit 0
fi
"`$PS" -NoProfile -ExecutionPolicy Bypass -File "`$root/scripts/plugin/validate.ps1"
status=`$?
if [ `$status -ne 0 ]; then
  echo "" >&2
  echo "[pre-commit] validate.ps1 falhou (exit `$status). Commit bloqueado." >&2
  echo "[pre-commit] Corrija os erros acima, ou use 'git commit --no-verify' para pular." >&2
  exit 1
fi
exit 0
"@

# Normaliza LF e grava UTF-8 sem BOM (sh nao tolera CRLF nem BOM)
$hookBody = $hookBody -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($preCommit, $hookBody, (New-Object System.Text.UTF8Encoding($false)))

# Marca executavel quando aplicavel (POSIX/WSL). No Windows o git ja roda o hook.
if ($IsLinux -or $IsMacOS) { & chmod +x $preCommit 2>$null }

Write-Host "[install-git-hooks] pre-commit instalado: $preCommit" -ForegroundColor Green
Write-Host "[install-git-hooks] roda scripts/plugin/validate.ps1 a cada commit. Pular: git commit --no-verify" -ForegroundColor DarkGray
exit 0
