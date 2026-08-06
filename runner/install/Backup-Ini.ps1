<#
.SYNOPSIS
    Helper de backup pra arquivos .ini antes de editar.

.DESCRIPTION
    Cria copia <arquivo>.bak.<timestamp> no mesmo diretorio. Retorna
    o caminho do backup. Idempotente: se o conteudo nao mudou em
    relacao ao ultimo backup desta sessao, nao cria duplicata.

.PARAMETER Path
    Caminho do .ini a backupear.

.EXAMPLE
    $bak = & .\Backup-Ini.ps1 -Path 'C:\TOTVS\appserver.ini'
    # $bak = 'C:\TOTVS\appserver.ini.bak.20260512-103045'
#>
param(
    [Parameter(Mandatory=$true)][string]$Path
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Path)) {
    throw "Backup-Ini: arquivo nao encontrado: $Path"
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bakPath = "$Path.bak.$timestamp"

# Idempotencia: se ja existe backup com mesmo tamanho do arquivo atual nos ultimos 60s, reutiliza
$cutoff = (Get-Date).AddSeconds(-60)
$srcLen = (Get-Item $Path).Length
$recentBak = Get-ChildItem -Path (Split-Path $Path -Parent) -Filter "$(Split-Path $Path -Leaf).bak.*" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt $cutoff -and $_.Length -eq $srcLen } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($recentBak) {
    # comparacao byte-a-byte (Get-FileHash nem sempre disponivel em ambientes constrained)
    $srcBytes = [System.IO.File]::ReadAllBytes($Path)
    $bakBytes = [System.IO.File]::ReadAllBytes($recentBak.FullName)
    $same = $srcBytes.Length -eq $bakBytes.Length
    if ($same) {
        for ($i = 0; $i -lt $srcBytes.Length; $i++) {
            if ($srcBytes[$i] -ne $bakBytes[$i]) { $same = $false; break }
        }
    }
    if ($same) {
        Write-Host "[backup] reusando $($recentBak.Name) (mesmo conteudo, criado ha < 60s)" -ForegroundColor DarkGray
        return $recentBak.FullName
    }
}

Copy-Item -Path $Path -Destination $bakPath -Force
Write-Host "[backup] $Path -> $bakPath" -ForegroundColor DarkGray
return $bakPath
