<#
.SYNOPSIS
    Validacao sintatica de todos os arquivos do plugin/install + drift check entre canonico e mirror.

.DESCRIPTION
    Roda em pre-commit ou CI. Verifica:
      1. PowerShell parse OK em scripts do framework
      2. JSON valido em plugin.json, .claude/settings.json
      3. SKILL.md frontmatter (name + description presentes)
      4. Links relativos de arquivo em todos os .md apontam pra alvo existente
      5. Schema do plugin (claude plugin validate, se o CLI estiver no PATH)
      6. Drift entre raiz canonica e mirror em .claude/ (roda sync -DryRun)

    Exit 0 se tudo OK, 1 se qualquer falha.
#>
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# Enumerado por glob, nao por lista fixa: script novo em runner/ ou scripts/
# entra sozinho na checagem. Uma lista fixa aqui deixaria arquivo novo
# passar sem parse check - o mesmo falso-verde que o sync.ps1 tinha.
$scripts = @()
foreach ($dir in @('runner', 'scripts')) {
    $p = Join-Path $root $dir
    if (Test-Path $p) {
        $scripts += Get-ChildItem -Path $p -Filter '*.ps1' -Recurse -File |
            ForEach-Object { $_.FullName.Substring($root.Length + 1) }
    }
}
$scripts = $scripts | Sort-Object

$fail = 0
Write-Host '=== PowerShell parse check ===' -ForegroundColor Cyan
foreach ($s in $scripts) {
    $path = Join-Path $root $s
    if (-not (Test-Path $path)) { Write-Host "SKIP $s (nao existe)" -ForegroundColor DarkYellow; continue }
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Write-Host "FAIL $s" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "  $($_.Message)" -ForegroundColor Red }
        $fail++
    } else {
        Write-Host "OK   $s" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '=== JSON validate ===' -ForegroundColor Cyan
$jsons = @('.claude-plugin\plugin.json', '.claude\settings.json')
foreach ($j in $jsons) {
    $path = Join-Path $root $j
    if (-not (Test-Path $path)) { Write-Host "SKIP $j (nao existe)" -ForegroundColor DarkYellow; continue }
    try {
        $null = Get-Content $path -Raw | ConvertFrom-Json
        Write-Host "OK   $j" -ForegroundColor Green
    } catch {
        Write-Host "FAIL $j  -> $($_.Exception.Message)" -ForegroundColor Red
        $fail++
    }
}

Write-Host ''
Write-Host '=== SKILL.md frontmatter check ===' -ForegroundColor Cyan
$skills = Get-ChildItem -Path $root -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\node_modules\\' }
foreach ($sk in $skills) {
    $rel = $sk.FullName.Substring($root.Length).TrimStart('\','/')
    $content = Get-Content $sk.FullName -Raw
    if ($content -notmatch '(?ms)^\s*---\s*\n(?<fm>.*?)\n\s*---\s*\n') {
        Write-Host "FAIL $rel  -> sem frontmatter YAML" -ForegroundColor Red
        $fail++
        continue
    }
    $fm = $matches['fm']
    $hasName = $fm -match '(?m)^\s*name:\s*\S+'
    $hasDesc = $fm -match '(?m)^\s*description:\s*\S+'
    if (-not $hasName -or -not $hasDesc) {
        Write-Host "FAIL $rel  -> falta name ou description no frontmatter" -ForegroundColor Red
        $fail++
    } else {
        Write-Host "OK   $rel" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '=== Link check (links relativos de arquivo nos .md) ===' -ForegroundColor Cyan
# Doc que aponta pra arquivo que nao existe e defeito silencioso: ninguem clica
# no link do README em pre-commit. Enumerado por glob (nao por lista fixa), entao
# doc novo entra sozinho. Escopo: links RELATIVOS de arquivo - http(s)/#ancora/
# mailto ficam de fora (nao da pra resolver em disco). Ancora em arquivo
# (arquivo.md#secao) valida apenas o arquivo.
$mdSkip = '^(node_modules|\.claude|\.git)[\\/]'
$mdFiles = Get-ChildItem -Path $root -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName.Substring($root.Length).TrimStart('\', '/') -notmatch $mdSkip }
$linkFail = 0
$linkCount = 0
foreach ($md in $mdFiles) {
    $rel = $md.FullName.Substring($root.Length).TrimStart('\', '/')
    $content = Get-Content $md.FullName -Raw
    if (-not $content) { continue }
    $bad = @()
    foreach ($m in [regex]::Matches($content, '\]\(([^)\s]+)\)')) {
        $target = $m.Groups[1].Value
        if ($target -match '^(https?:|mailto:|#|<)') { continue }
        $file = ($target -split '#')[0]
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        $linkCount++
        # Resolve contra o diretorio do proprio .md (link relativo do markdown).
        if (-not (Test-Path (Join-Path $md.DirectoryName $file))) { $bad += $target }
    }
    if ($bad.Count -gt 0) {
        Write-Host "FAIL $rel" -ForegroundColor Red
        $bad | ForEach-Object { Write-Host "  alvo inexistente: $_" -ForegroundColor Red }
        $linkFail++
    }
}
if ($linkFail -eq 0) {
    Write-Host "OK   $($mdFiles.Count) arquivo(s) .md, $linkCount link(s) relativo(s)" -ForegroundColor Green
} else {
    Write-Host "FAIL $linkFail arquivo(s) .md com link quebrado" -ForegroundColor Red
    $fail += $linkFail
}

Write-Host ''
Write-Host '=== Schema check (claude plugin validate) ===' -ForegroundColor Cyan
# Os checks acima sao SINTATICOS (JSON parseia? frontmatter existe?). So o CLI
# valida contra o schema real do Claude Code - foi ele que pegou os 4 defeitos
# do PR #36 (repository objeto, hooks.json sem wrapper, YAML com ':' sem aspas)
# que passavam ilesos por tudo aqui. Warnings nao reprovam (exit 0); erro sim.
$claudeCli = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCli) {
    & $claudeCli.Source plugin validate $root 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'FAIL schema do plugin invalido (ver erros acima)' -ForegroundColor Red
        $fail++
    } else {
        Write-Host 'OK   schema valido' -ForegroundColor Green
    }
} else {
    # Sem CLI no PATH (ex: hook de git com PATH minimo): o CI roda este mesmo
    # check com o CLI instalado, entao aqui e SKIP honesto, nao falso-verde.
    Write-Host 'SKIP claude CLI nao encontrado no PATH - o CI cobre este check' -ForegroundColor DarkYellow
}

Write-Host ''
Write-Host '=== Drift check (raiz canonica vs .claude/ mirror) ===' -ForegroundColor Cyan
$syncOut = & (Join-Path $PSScriptRoot 'sync.ps1') -DryRun
$syncOut | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL drift detectado - rode '.\scripts\plugin\sync.ps1' pra alinhar" -ForegroundColor Red
    $fail++
} else {
    Write-Host "OK   sem drift" -ForegroundColor Green
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Tudo OK.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$fail falha(s)." -ForegroundColor Red
    exit 1
}
