<#
.SYNOPSIS
    Teste de regressao do Set-AppServerRest.ps1 - issue #19.

.DESCRIPTION
    Logica pura contra um appserver.ini falso em $env:TEMP. Nao precisa de
    AppServer nem Protheus. Roda em CI headless.

    Motivacao: o script edita o appserver.ini do usuario. A versao anterior lia
    com `-Encoding ASCII` e regravava com ASCIIEncoding - mesmo defeito que
    destruia senhas no dbaccess.ini (#17). Aqui o dano e menor (os bytes altos
    costumam estar em COMENTARIOS acentuados, nao em credenciais), mas continua
    sendo corrupcao silenciosa do arquivo do usuario: o ini de referencia desta
    maquina tem 16 bytes >0x7F em 4 comentarios.

    Cenarios:
      B1  bytes >0x7F preservados byte a byte
      B2  comentario acentuado permanece legivel
      B3  adiciona [HTTPREST] quando ausente
      B4  idempotente: com bloco REST completo nao altera o arquivo
      B5  -DryRun nao escreve nada
      B6  backup criado antes de alterar

    Bloco REST completo + update in-place (onda 1 da revisao pre-release): o
    script anunciava "Ajustar [HTTPREST]" mas NAO tinha codigo de update - com a
    secao presente e errada (porta divergente, Enable=0) ele terminava em verde
    sem mudar nada. E a secao que ele CRIAVA era incompleta: sem [HTTPURI]
    (URL=/rest), [HTTPV11] e [ONSTART] o AppServer nao serve /rest.

      B7  secao ausente -> cria tambem [HTTPURI]/[HTTPV11]/[ONSTART]/[HTTPJOB]
      B8  porta errada  -> corrigida IN-PLACE, demais chaves preservadas
      B9  Enable=0      -> vira Enable=1 sem duplicar a secao
      B10 secao ja correta -> nao grava, nao backupeia, nao diz "atualizado"
      B11 [ONSTART] preexistente do usuario nao e duplicado
      B12 Environment divergente -> corrigido in-place

    Exit 0 se nenhum check reprovar, 1 caso contrario.
#>
$ErrorActionPreference = 'Continue'
$root   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script = Join-Path $root 'runner\install\Set-AppServerRest.ps1'
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

$fail = 0
function Add-Result([string]$tag, [string]$desc) {
    $color = switch ($tag) { 'PASS' {'Green'} 'FAIL' {'Red'} default {'DarkYellow'} }
    Write-Host ("  [{0}] {1}" -f $tag, $desc) -ForegroundColor $color
    if ($tag -eq 'FAIL') { $script:fail++ }
}
function Assert-True([string]$desc, $cond) {
    if ($cond) { Add-Result 'PASS' $desc } else { Add-Result 'FAIL' $desc }
}

# Comentario acentuado em UTF-8, como no appserver.ini real
$comentario = ';Configurando o servi' + [char]0xC3 + [char]0xA7 + 'o que ir' + [char]0xC3 + [char]0xA1 + ' rodar'

function New-FakeIni {
    <# -ComHttpRest: bloco REST COMPLETO e correto (o que o script grava hoje
       quando a secao falta) - e o unico estado que deve ser no-op.
       -HttpRestParcial: passa as linhas de [HTTPREST] a usar (cenarios de
       secao existente porem errada). #>
    param([string]$Path, [switch]$ComHttpRest, [string[]]$HttpRestParcial, [switch]$ComOnStartDoUsuario)
    $s = "[DESENVOLVIMENTO]`r`nSourcePath=C:\x\apo`r`nRootPath=C:\x\data`r`n`r`n"
    $s += "$comentario`r`n[GENERAL]`r`nConsoleLog=1`r`n"
    if ($ComOnStartDoUsuario) {
        $s += "`r`n[ONSTART]`r`nJobs=MEUJOB`r`nRefreshRate=60`r`n"
    }
    if ($ComHttpRest) {
        $s += "`r`n[HTTPJOB]`r`nMain=HTTP_START`r`nEnvironment=DESENVOLVIMENTO`r`n"
        if (-not $ComOnStartDoUsuario) {
            $s += "`r`n[ONSTART]`r`nJobs=HTTPJOB`r`nRefreshRate=120`r`n"
        }
        $s += "`r`n[HTTPV11]`r`nEnable=1`r`nSockets=HTTPREST`r`n"
        $s += "`r`n[HTTPREST]`r`nPort=8401`r`nURIs=HTTPURI`r`nSECURITY=1`r`nEnvironment=DESENVOLVIMENTO`r`nEnable=1`r`n"
        $s += "`r`n[HTTPURI]`r`nURL=/rest`r`nPrepareIn=99,01`r`nInstances=1,2`r`nAllowOrigin=*`r`nCORSEnable=1`r`nStateless=1`r`n"
    } elseif ($HttpRestParcial) {
        $s += "`r`n[HTTPREST]`r`n" + (($HttpRestParcial -join "`r`n")) + "`r`n"
        $s += "`r`n[WEBAPP]`r`nPort=8100`r`n"
    }
    [System.IO.File]::WriteAllText($Path, $s, $latin1)
}

function New-Caso([string]$nome) {
    # Um diretorio por cenario: os asserts de backup precisam contar .bak SO do
    # proprio cenario.
    $d = Join-Path $sandbox $nome
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return (Join-Path $d 'appserver.ini')
}

$sandbox = Join-Path $env:TEMP ('tlpp-appsrv-test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

try {
    Write-Host "`n=== Test-AppServerRest ===" -ForegroundColor Cyan

    # --- B1/B2/B3: encoding preservado + secao adicionada ---
    $ini = Join-Path $sandbox 'appserver.ini'
    New-FakeIni -Path $ini
    $altosAntes = ([System.IO.File]::ReadAllBytes($ini) | Where-Object { $_ -gt 0x7F }).Count

    & $script -AppServerIniPath $ini -RestPort 8401 -Environment 'DESENVOLVIMENTO' *>&1 | Out-Null

    $bytes = [System.IO.File]::ReadAllBytes($ini)
    $txt   = $latin1.GetString($bytes)
    $altosDepois = ($bytes | Where-Object { $_ -gt 0x7F }).Count

    Assert-True "B1 bytes >0x7F preservados ($altosAntes -> $altosDepois)" ($altosAntes -eq $altosDepois -and $altosAntes -gt 0)
    Assert-True 'B2 comentario acentuado intacto' ($txt -match [regex]::Escape($comentario))
    Assert-True 'B3 secao [HTTPREST] adicionada' ($txt -match '(?m)^\[HTTPREST\]' -and $txt -match '(?m)^Port=8401')

    # --- B4: idempotencia ---
    $ini4 = Join-Path $sandbox 'idem.ini'
    New-FakeIni -Path $ini4 -ComHttpRest
    $md5Antes = (Get-FileHash $ini4 -Algorithm MD5).Hash
    & $script -AppServerIniPath $ini4 -RestPort 8401 -Environment 'DESENVOLVIMENTO' *>&1 | Out-Null
    $md5Depois = (Get-FileHash $ini4 -Algorithm MD5).Hash
    Assert-True 'B4 ja configurado -> arquivo nao muda' ($md5Antes -eq $md5Depois)

    # --- B5: DryRun nao escreve ---
    $ini5 = Join-Path $sandbox 'dry.ini'
    New-FakeIni -Path $ini5
    $md5Dry = (Get-FileHash $ini5 -Algorithm MD5).Hash
    & $script -AppServerIniPath $ini5 -RestPort 8401 -Environment 'DESENVOLVIMENTO' -DryRun *>&1 | Out-Null
    Assert-True 'B5 -DryRun nao altera o arquivo' ($md5Dry -eq (Get-FileHash $ini5 -Algorithm MD5).Hash)

    # --- B6: backup ---
    Assert-True 'B6 backup criado' ((Get-ChildItem -Path $sandbox -Filter 'appserver.ini.bak.*' -File).Count -ge 1)

    # --- B7: secao ausente -> bloco REST COMPLETO ---
    # Sem [HTTPURI] o AppServer sobe e nao responde /rest: o ini fica "com
    # HTTPREST" e o setup termina verde com o runner inutilizavel.
    $ini7 = New-Caso 'completo'
    New-FakeIni -Path $ini7
    & $script -AppServerIniPath $ini7 -RestPort 8401 -Environment 'DESENVOLVIMENTO' *>&1 | Out-Null
    $t7 = $latin1.GetString([System.IO.File]::ReadAllBytes($ini7))
    Assert-True 'B7 criou [HTTPURI] com URL=/rest' ($t7 -match '(?m)^\[HTTPURI\]' -and $t7 -match '(?m)^URL=/rest\s*$')
    Assert-True 'B7 criou [HTTPV11] com Sockets=HTTPREST' ($t7 -match '(?m)^\[HTTPV11\]' -and $t7 -match '(?m)^Sockets=HTTPREST\s*$')
    Assert-True 'B7 criou [ONSTART] com Jobs=HTTPJOB' ($t7 -match '(?m)^\[ONSTART\]' -and $t7 -match '(?m)^Jobs=HTTPJOB\s*$')
    Assert-True 'B7 [HTTPREST] declara URIs=HTTPURI' ($t7 -match '(?m)^URIs=HTTPURI\s*$')
    # Re-rodar sobre o resultado nao pode mudar mais nada (idempotencia real).
    $md5b7 = (Get-FileHash $ini7 -Algorithm MD5).Hash
    & $script -AppServerIniPath $ini7 -RestPort 8401 -Environment 'DESENVOLVIMENTO' *>&1 | Out-Null
    Assert-True 'B7 2a passada e no-op' ($md5b7 -eq (Get-FileHash $ini7 -Algorithm MD5).Hash)

    # --- B8: porta errada -> corrigida IN-PLACE preservando o resto ---
    $ini8 = New-Caso 'portaerrada'
    New-FakeIni -Path $ini8 -HttpRestParcial @('Port=9999','Environment=DESENVOLVIMENTO','Enable=1','SECURITY=1','MinhaChave=deusuario')
    & $script -AppServerIniPath $ini8 -RestPort 8401 -Environment 'DESENVOLVIMENTO' *>&1 | Out-Null
    $t8 = $latin1.GetString([System.IO.File]::ReadAllBytes($ini8))
    Assert-True 'B8 porta corrigida pra 8401' ($t8 -match '(?m)^Port=8401\s*$')
    Assert-True 'B8 porta antiga sumiu'       ($t8 -notmatch '(?m)^Port=9999\s*$')
    Assert-True 'B8 chave do usuario preservada' ($t8 -match '(?m)^MinhaChave=deusuario\s*$')
    Assert-True 'B8 SECURITY do usuario preservada' ($t8 -match '(?m)^SECURITY=1\s*$')
    Assert-True 'B8 [WEBAPP] seguinte intacta' ($t8 -match '(?m)^\[WEBAPP\]' -and $t8 -match '(?m)^Port=8100\s*$')
    Assert-True 'B8 uma unica secao [HTTPREST]' ((([regex]::Matches($t8, '(?m)^\[HTTPREST\]')).Count) -eq 1)
    Assert-True 'B8 backup gerado' ((Get-ChildItem -Path (Split-Path $ini8 -Parent) -Filter 'appserver.ini.bak.*' -File).Count -ge 1)

    # --- B9: Enable=0 -> Enable=1 ---
    $ini9 = New-Caso 'enablezero'
    New-FakeIni -Path $ini9 -HttpRestParcial @('Port=8401','Environment=DESENVOLVIMENTO','Enable=0')
    & $script -AppServerIniPath $ini9 -RestPort 8401 -Environment 'DESENVOLVIMENTO' *>&1 | Out-Null
    $t9 = $latin1.GetString([System.IO.File]::ReadAllBytes($ini9))
    Assert-True 'B9 Enable=1 aplicado'   ($t9 -match '(?m)^Enable=1\s*$')
    Assert-True 'B9 Enable=0 removido'   ($t9 -notmatch '(?m)^Enable=0\s*$')

    # --- B10: ja correto -> nao grava, nao backupeia, nao diz "atualizado" ---
    $ini10 = New-Caso 'jacorreto'
    New-FakeIni -Path $ini10 -ComHttpRest
    $md5_10 = (Get-FileHash $ini10 -Algorithm MD5).Hash
    $saida10 = (& $script -AppServerIniPath $ini10 -RestPort 8401 -Environment 'DESENVOLVIMENTO' *>&1 | Out-String)
    Assert-True 'B10 arquivo nao muda' ($md5_10 -eq (Get-FileHash $ini10 -Algorithm MD5).Hash)
    Assert-True 'B10 sem backup inutil' ((Get-ChildItem -Path (Split-Path $ini10 -Parent) -Filter 'appserver.ini.bak.*' -File).Count -eq 0)
    Assert-True 'B10 nao reporta "atualizado"' ($saida10 -notmatch 'atualizado')

    # --- B11: [ONSTART] do usuario nao pode ser duplicado ---
    $ini11 = New-Caso 'onstartusuario'
    New-FakeIni -Path $ini11 -ComOnStartDoUsuario
    & $script -AppServerIniPath $ini11 -RestPort 8401 -Environment 'DESENVOLVIMENTO' *>&1 | Out-Null
    $t11 = $latin1.GetString([System.IO.File]::ReadAllBytes($ini11))
    Assert-True 'B11 uma unica secao [ONSTART]' ((([regex]::Matches($t11, '(?m)^\[ONSTART\]')).Count) -eq 1)
    Assert-True 'B11 Jobs do usuario preservado' ($t11 -match '(?m)^Jobs=MEUJOB\s*$')

    # --- B12: Environment divergente corrigido in-place ---
    $ini12 = New-Caso 'envdivergente'
    New-FakeIni -Path $ini12 -HttpRestParcial @('Port=8401','Environment=OUTROENV','Enable=1')
    & $script -AppServerIniPath $ini12 -RestPort 8401 -Environment 'DESENVOLVIMENTO' *>&1 | Out-Null
    $t12 = $latin1.GetString([System.IO.File]::ReadAllBytes($ini12))
    Assert-True 'B12 Environment corrigido' ($t12 -match '(?m)^Environment=DESENVOLVIMENTO\s*$' -and $t12 -notmatch '(?m)^Environment=OUTROENV\s*$')

} catch {
    # Sem isso um erro terminante do script sob teste pularia todos os asserts e
    # o resumo sairia "tudo OK" com $fail=0 - falso-verde.
    Add-Result 'FAIL' "excecao inesperada: $($_.Exception.Message)"
} finally {
    Remove-Item -Path $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($fail -eq 0) { Write-Host "Test-AppServerRest: tudo OK" -ForegroundColor Green; exit 0 }
Write-Host "Test-AppServerRest: $fail check(s) reprovaram" -ForegroundColor Red
exit 1
