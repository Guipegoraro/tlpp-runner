<#
.SYNOPSIS
    Adiciona alias [MSSQL/<DbName>] no dbaccess.ini com backup. Idempotente.

.DESCRIPTION
    Le o dbaccess.ini, verifica se ja tem a secao [MSSQL/<DbName>]. Se nao,
    cria backup e adiciona. Se ja existe e o conteudo bate, nao faz nada.
    Se existe mas diverge, mostra diff e pede confirmacao do chamador
    (skill init que invocou).

.PARAMETER DbAccessIniPath
    Caminho completo do dbaccess.ini.

.PARAMETER DbName
    Nome do banco no SQL Server (sem alias prefix).

.PARAMETER SqlInstance
    Instancia SQL Server (ex: 'localhost\PROTHEUS').

.PARAMETER SqlAuth
    'Windows' ou 'SqlServer' (default Windows).

.PARAMETER SqlUser
    Login (so se SqlAuth=SqlServer).

.PARAMETER SqlPasswordEncrypted
    Senha JA ENCRIPTADA pelo dbaccesscfg.exe. Grava a chave `password=` da secao.
    ATENCAO: com ConnectionMode=2 o DBAccess IGNORA essa chave - quem autentica
    e o UID/PWD dentro da ConnectionString (ver ConnectionUser/ConnectionPassword).

.PARAMETER ConnectionUser
    Login embutido na ConnectionString como UID=. Se omitido, herda de um alias
    [MSSQL/*] existente no mesmo ini.

.PARAMETER ConnectionPassword
    Senha embutida na ConnectionString como PWD= (texto plano - e o formato que o
    DBAccess aceita nesse modo; aceitavel em ambiente de dev local). Se omitida,
    herda junto com o ConnectionUser.

.NOTES
    Duas armadilhas deste arquivo, ambas ja causaram quebra em producao de dev:

    1. ENCODING. As chaves `password=` guardam senha cifrada com bytes >0x7F.
       Ler/gravar o ini em ASCII ou UTF-8 destroi esses bytes e derruba a
       autenticacao de TODOS os aliases ja existentes. Este script usa Latin1
       (28591), que mapeia 1:1 byte<->char.

    2. ConnectionMode=2 ignora `user=`/`password=` da secao. As credenciais tem
       de estar na ConnectionString (UID=/PWD=), senao o DBAccess loga
       "Falha de logon do usuario ''" mesmo com user= preenchido.

.PARAMETER DryRun
    Mostra mudancas sem aplicar.

.EXAMPLE
    .\Set-DBAccessAlias.ps1 -DbAccessIniPath 'C:\TOTVS\TOTVSDBAccess\windows\dbaccess.ini' `
                             -DbName 'PROTHEUS_TST_meuprojeto' `
                             -SqlInstance 'localhost\PROTHEUS'
#>
param(
    [Parameter(Mandatory=$true)][string]$DbAccessIniPath,
    [Parameter(Mandatory=$true)][string]$DbName,
    [Parameter(Mandatory=$true)][string]$SqlInstance,
    [Parameter(Mandatory=$false)][ValidateSet('Windows','SqlServer')][string]$SqlAuth = 'Windows',
    [Parameter(Mandatory=$false)][string]$SqlUser = 'sa',
    [Parameter(Mandatory=$false)][string]$SqlPasswordEncrypted,
    [Parameter(Mandatory=$false)][string]$ConnectionUser,
    [Parameter(Mandatory=$false)][string]$ConnectionPassword,
    [Parameter(Mandatory=$false)][switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $DbAccessIniPath)) {
    throw "dbaccess.ini nao encontrado: $DbAccessIniPath"
}

# Leitura preservando bytes - as chaves `password=` guardam senha cifrada com
# bytes >0x7F e ler como ASCII/UTF8 as destroi. Ver runner/install/IniIO.ps1.
. (Join-Path $PSScriptRoot 'IniIO.ps1')
$content = Read-IniLines -Path $DbAccessIniPath

$sectionName = "[MSSQL/$DbName]"

# CREDENCIAIS: com ConnectionMode=2 o DBAccess IGNORA as chaves `user=`/
# `password=` da secao - elas precisam estar embutidas na ConnectionString como
# UID=/PWD=. Sem isso o alias sobe mas nao autentica.
# Como a senha nao vem na config global (o SqlAuth de la e do sqlcmd, que usa
# Windows Auth), herdamos UID/PWD de um alias [MSSQL/*] que ja funciona neste
# mesmo ini - e o padrao que a maquina ja provou valido.
$credSuffix = ''
if ($ConnectionUser -and $ConnectionPassword) {
    $credSuffix = ";UID=$ConnectionUser;PWD=$ConnectionPassword"
} else {
    foreach ($l in $content) {
        if ($l -match '^\s*ConnectionString=.*;UID=([^;]+);PWD=([^;]*)\s*$') {
            $credSuffix = ";UID=$($matches[1]);PWD=$($matches[2])"
            Write-Host "[dba-alias] credenciais herdadas de um alias existente do ini" -ForegroundColor DarkGray
            break
        }
    }
}
if (-not $credSuffix) {
    Write-Host "[dba-alias] AVISO: nenhum UID/PWD embutido e nenhum alias existente pra herdar." -ForegroundColor Yellow
    Write-Host "[dba-alias]        Com ConnectionMode=2 o alias vai subir mas NAO autenticar" -ForegroundColor Yellow
    Write-Host "[dba-alias]        (TCLink falha). Passe -ConnectionUser/-ConnectionPassword." -ForegroundColor Yellow
}

$connStr = "DRIVER={SQL Server Native Client 11.0};SERVER=$SqlInstance;DATABASE=$DbName$credSuffix"

# EXIBICAO: a ConnectionString carrega PWD= em texto plano e este script imprime
# o plano/diff no stdout, que vai parar em transcript e log de sessao. O que vai
# pro arquivo continua sendo $connStr; so o que aparece no terminal e mascarado.
# Ver Get-MaskedConnString em runner/install/IniIO.ps1.
$connStrMasc = Get-MaskedConnString -ConnString $connStr

# Monta o trecho a adicionar
$newSection = @()
$newSection += $sectionName
$newSection += "user=$SqlUser"
if ($SqlAuth -eq 'SqlServer' -and $SqlPasswordEncrypted) {
    $newSection += "password=$SqlPasswordEncrypted"
}
$newSection += 'ConnectionMode=2'
$newSection += "ConnectionString=$connStr"
$newSection += ''  # linha em branco no fim

# Procura secao existente
$sectionLineIdx = -1
for ($i = 0; $i -lt $content.Count; $i++) {
    if ($content[$i].Trim() -eq $sectionName) {
        $sectionLineIdx = $i
        break
    }
}

if ($sectionLineIdx -ge 0) {
    # Ja existe - extrai secao atual
    $endIdx = $content.Count
    for ($j = $sectionLineIdx + 1; $j -lt $content.Count; $j++) {
        if ($content[$j] -match '^\s*\[.+\]\s*$') { $endIdx = $j; break }
    }
    $existing = $content[$sectionLineIdx..($endIdx - 1)]

    # Compara via dictionary key=value
    $existingMap = @{}
    foreach ($l in $existing[1..($existing.Count - 1)]) {
        if ($l -match '^\s*([^=]+?)\s*=\s*(.*)\s*$') {
            $existingMap[$matches[1]] = $matches[2]
        }
    }
    $existingConn = $existingMap['ConnectionString']
    if ($existingConn -eq $connStr) {
        Write-Host "[dba-alias] $sectionName ja presente e identico - nada a fazer." -ForegroundColor DarkGray
        return
    }

    Write-Host "[dba-alias] $sectionName ja existe mas diverge do esperado:" -ForegroundColor Yellow
    Write-Host "  Atual:    ConnectionString=$(Get-MaskedConnString -ConnString $existingConn)"
    Write-Host "  Esperado: ConnectionString=$connStrMasc"
    throw "Secao $sectionName existe com config diferente. Resolva manualmente ou apague a secao do .ini antes de re-rodar."
}

# Nao existe - adicionar
Write-Host "[dba-alias] Plano: adicionar secao $sectionName em $DbAccessIniPath" -ForegroundColor Cyan
Write-Host "  Trecho:"
foreach ($l in $newSection) { Write-Host "    $(Get-MaskedConnString -ConnString $l)" -ForegroundColor DarkGray }

if ($DryRun) {
    Write-Host "[dba-alias] DryRun - nada aplicado." -ForegroundColor Yellow
    return
}

# Backup
$bak = & (Join-Path $PSScriptRoot 'Backup-Ini.ps1') -Path $DbAccessIniPath
Write-Host "[dba-alias] Backup: $bak" -ForegroundColor DarkGray

# Anexa (com linha em branco antes). Grava preservando bytes pelo mesmo motivo
# da leitura: as senhas cifradas das outras secoes precisam sair intactas.
$newContent = @()
$newContent += $content
if ($content[-1].Trim() -ne '') { $newContent += '' }
$newContent += $newSection
Write-IniLines -Path $DbAccessIniPath -Lines $newContent

Write-Host "[dba-alias] OK - $sectionName adicionado. Reinicie o DBAccess pra carregar o alias." -ForegroundColor Green
