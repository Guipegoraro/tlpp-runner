<#
.SYNOPSIS
    Teste de regressao do Set-DBAccessAlias.ps1 - issue #17.

.DESCRIPTION
    Logica pura contra um dbaccess.ini falso em $env:TEMP. Nao precisa de
    DBAccess, SQL Server nem AppServer. Roda em CI headless.

    Cobre duas armadilhas que ja quebraram ambiente de dev:

      D1  ENCODING. As chaves `password=` guardam senha cifrada pelo dbaccesscfg
          com bytes >0x7F. A versao anterior lia com `-Encoding ASCII` e
          regravava com ASCIIEncoding, trocando cada byte alto por '?' - o que
          destruia a autenticacao de TODOS os aliases ja existentes no arquivo.
          Encontrado ao rodar a #17 num ini real que tinha 18 desses bytes.

      D2  CREDENCIAL. Com ConnectionMode=2 o DBAccess IGNORA `user=`/`password=`
          da secao; quem autentica e o UID=/PWD= dentro da ConnectionString. A
          versao anterior nao os escrevia, gerando alias que sobe mas nao loga
          ("Falha de logon do usuario ''").

    Cenarios:
      A1  bytes >0x7F preservados byte a byte
      A2  senha cifrada de secao pre-existente intacta
      A3  credencial herdada de alias existente vai pra ConnectionString
      A4  -ConnectionUser/-ConnectionPassword explicitos tem prioridade
      A5  sem credencial pra herdar -> avisa (nao falha silencioso)
      A6  idempotente: rodar 2x nao duplica secao
      A7  backup criado antes de alterar
      A8  senha do SQL nao aparece no stdout (ia pro transcript/log da sessao)
      A9  saida mostra PWD mascarado, arquivo mantem a senha real
      A10 diff do caminho de divergencia tambem mascara
      A11 senha curta vira *** inteiro

    Exit 0 se nenhum check reprovar, 1 caso contrario.
#>
$ErrorActionPreference = 'Continue'
$root   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script = Join-Path $root 'runner\install\Set-DBAccessAlias.ps1'
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

# Senha "cifrada" com bytes altos, como o dbaccesscfg gera
$senhaCifrada = [string]([char]0xC0 + [char]0xEC + [char]0xEF + [char]0xF4 + [char]0xF1 + [char]0xF2)

function New-FakeIni {
    param([string]$Path, [switch]$SemAliasExistente)
    $s  = "[General]`r`n[SERVICE]`r`n[MSSQL]`r`nuser=sa`r`npassword=$senhaCifrada`r`n"
    if (-not $SemAliasExistente) {
        $s += "[MSSQL/PROTHEUS_TST]`r`nuser=sa`r`nConnectionMode=2`r`n"
        $s += "ConnectionString=DRIVER={SQL Server Native Client 11.0};SERVER=x;DATABASE=PROTHEUS_TST;UID=sa;PWD=segredo123`r`n"
    }
    [System.IO.File]::WriteAllText($Path, $s, $latin1)
}

$sandbox = Join-Path $env:TEMP ('tlpp-dba-test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

try {
    Write-Host "`n=== Test-DBAccessAlias ===" -ForegroundColor Cyan

    # --- A1/A2/A3: encoding preservado + credencial herdada ---
    $ini = Join-Path $sandbox 'a.ini'
    New-FakeIni -Path $ini
    $altosAntes = ([System.IO.File]::ReadAllBytes($ini) | Where-Object { $_ -gt 0x7F }).Count

    & $script -DbAccessIniPath $ini -DbName 'PROTHEUS_TST_X' -SqlInstance 'localhost\INST' *>&1 | Out-Null

    $bytes = [System.IO.File]::ReadAllBytes($ini)
    $txt   = $latin1.GetString($bytes)
    $altosDepois = ($bytes | Where-Object { $_ -gt 0x7F }).Count

    Assert-True "A1 bytes >0x7F preservados ($altosAntes -> $altosDepois)" ($altosAntes -eq $altosDepois -and $altosAntes -gt 0)
    Assert-True 'A2 senha cifrada pre-existente intacta' ($txt -match [regex]::Escape("password=$senhaCifrada"))
    Assert-True 'A3 credencial herdada foi pra ConnectionString' ($txt -match 'DATABASE=PROTHEUS_TST_X;UID=sa;PWD=segredo123')

    # --- A4: parametros explicitos tem prioridade sobre a heranca ---
    $ini4 = Join-Path $sandbox 'b.ini'
    New-FakeIni -Path $ini4
    & $script -DbAccessIniPath $ini4 -DbName 'PROTHEUS_TST_Y' -SqlInstance 'localhost\INST' `
              -ConnectionUser 'outro' -ConnectionPassword 'pw999' *>&1 | Out-Null
    $txt4 = $latin1.GetString([System.IO.File]::ReadAllBytes($ini4))
    Assert-True 'A4 -ConnectionUser/-Password tem prioridade' ($txt4 -match 'DATABASE=PROTHEUS_TST_Y;UID=outro;PWD=pw999')

    # --- A5: sem nada pra herdar -> avisa em vez de gerar alias mudo ---
    $ini5 = Join-Path $sandbox 'c.ini'
    New-FakeIni -Path $ini5 -SemAliasExistente
    $out5 = (& $script -DbAccessIniPath $ini5 -DbName 'PROTHEUS_TST_Z' -SqlInstance 'localhost\INST' *>&1 | Out-String)
    Assert-True 'A5 avisa quando nao ha credencial pra herdar' ($out5 -match 'AVISO' -and $out5 -match 'NAO autenticar')

    # --- A6: idempotencia ---
    $out6 = (& $script -DbAccessIniPath $ini -DbName 'PROTHEUS_TST_X' -SqlInstance 'localhost\INST' *>&1 | Out-String)
    $txt6 = $latin1.GetString([System.IO.File]::ReadAllBytes($ini))
    $ocorrencias = ([regex]::Matches($txt6, [regex]::Escape('[MSSQL/PROTHEUS_TST_X]'))).Count
    Assert-True "A6 rodar 2x nao duplica a secao (ocorrencias=$ocorrencias)" ($ocorrencias -eq 1)
    Assert-True 'A6 segunda execucao reporta "ja presente"' ($out6 -match 'ja presente')

    # --- A7: backup antes de alterar ---
    Assert-True 'A7 backup do ini criado' ((Get-ChildItem -Path $sandbox -Filter 'a.ini.bak.*' -File).Count -ge 1)

    # --- A8/A9: a senha do SQL nao pode ir pro stdout (transcript/log) ---
    $ini8 = Join-Path $sandbox 'd.ini'
    New-FakeIni -Path $ini8
    $out8 = (& $script -DbAccessIniPath $ini8 -DbName 'PROTHEUS_TST_W' -SqlInstance 'localhost\INST' `
                       -ConnectionUser 'sa' -ConnectionPassword 'segredo123' *>&1 | Out-String)
    Assert-True 'A8 saida NAO contem a senha em claro' ($out8 -notmatch 'segredo123')
    Assert-True 'A9 saida mostra o PWD mascarado'      ($out8 -match 'PWD=se\*\*\*3')
    # A senha REAL tem de continuar indo pro arquivo - mascarar e so exibicao
    $txt8 = $latin1.GetString([System.IO.File]::ReadAllBytes($ini8))
    Assert-True 'A9 ini gravado mantem a senha real'   ($txt8 -match 'UID=sa;PWD=segredo123')

    # --- A10: caminho de divergencia tambem imprime diff - mascarar os dois lados ---
    # O catch tem de ficar DENTRO do pipeline: se o throw escapar, a atribuicao
    # nunca acontece e o que ja foi impresso (o diff) se perde - o check passaria
    # por vazio, falso-verde.
    $out10 = (& {
        try {
            & $script -DbAccessIniPath $ini8 -DbName 'PROTHEUS_TST_W' -SqlInstance 'outra\INST' `
                      -ConnectionUser 'sa' -ConnectionPassword 'segredo123'
        } catch { $_.Exception.Message }
    } *>&1 | Out-String)
    Assert-True 'A10 diff de divergencia nao vaza senha' ($out10 -match 'diverge' -and $out10 -notmatch 'segredo123')

    # --- A11: senha curta vira mascara total, sem vazar prefixo ---
    $ini11 = Join-Path $sandbox 'e.ini'
    New-FakeIni -Path $ini11 -SemAliasExistente
    $out11 = (& $script -DbAccessIniPath $ini11 -DbName 'PROTHEUS_TST_V' -SqlInstance 'localhost\INST' `
                        -ConnectionUser 'sa' -ConnectionPassword 'ab1' *>&1 | Out-String)
    Assert-True 'A11 senha curta exibida como ***' ($out11 -match 'PWD=\*\*\*' -and $out11 -notmatch 'PWD=ab1')

} catch {
    # Sem isso um erro terminante do script sob teste pularia todos os asserts e
    # o resumo sairia "tudo OK" com $fail=0 - falso-verde.
    Add-Result 'FAIL' "excecao inesperada: $($_.Exception.Message)"
} finally {
    Remove-Item -Path $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($fail -eq 0) { Write-Host "Test-DBAccessAlias: tudo OK" -ForegroundColor Green; exit 0 }
Write-Host "Test-DBAccessAlias: $fail check(s) reprovaram" -ForegroundColor Red
exit 1
