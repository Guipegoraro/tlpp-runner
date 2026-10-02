<#
.SYNOPSIS
    Leitura/escrita de arquivos .ini preservando bytes.

.DESCRIPTION
    Os .ini do Protheus/DBAccess NAO sao ASCII:

      - `dbaccess.ini` guarda em `password=` a senha cifrada pelo dbaccesscfg,
        com bytes >0x7F. Destrui-los derruba a autenticacao de TODOS os aliases
        ("Falha de logon do usuario ''").
      - `appserver.ini` costuma ter comentarios acentuados gravados em UTF-8.

    Ler com `-Encoding ASCII` e regravar troca cada byte alto por '?'. Ler como
    UTF-8 e regravar troca por U+FFFD. Os dois corrompem em silencio.

    Latin1 (28591) mapeia 1:1 byte<->char em toda a faixa 0x00-0xFF, entao o
    round-trip devolve os bytes originais QUALQUER que seja o encoding real do
    arquivo - o conteudo nao precisa ser interpretado, so preservado.

    Este helper existe porque o mesmo defeito ja apareceu em dois scripts
    diferentes (Set-DBAccessAlias.ps1 e Set-AppServerRest.ps1). Use-o em vez de
    Get-Content/Set-Content ao mexer em .ini.

.EXAMPLE
    . (Join-Path $PSScriptRoot 'IniIO.ps1')
    $linhas = Read-IniLines -Path $ini
    $linhas += '[NOVA]'
    Write-IniLines -Path $ini -Lines $linhas
#>

# Intervalo (s) em que o AppServer confere os jobs do [ONSTART] e relanca os que
# morreram. Toda compilacao derruba os HTTP servers (BuildKillUsers=1 mata o job
# HTTP_START), e o REST so volta no proximo ciclo: com 120 a janela medida e de
# ~92s apos o fim do build, com 10 de ~11s e com 2 de ~5s (o piso e a propria
# inicializacao do REST). Vale para o template e para o ajuste in-place.
$script:RestRefreshRate = 2

$script:IniEncoding = [System.Text.Encoding]::GetEncoding(28591)   # Latin1: byte<->char 1:1

function Read-IniLines {
    <# Le o .ini como array de linhas, preservando todo byte. #>
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { throw "IniIO: arquivo nao encontrado: $Path" }
    return ($script:IniEncoding.GetString([System.IO.File]::ReadAllBytes($Path)) -split "`r?`n")
}

function Get-MaskedSecret {
    <# Mascara um segredo pra EXIBICAO. Mesmo padrao do Write-GlobalConfig.ps1:
       2 primeiros chars + '***' + ultimo; segredo curto vira '***' inteiro. #>
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value.Length -ge 4) { return $Value.Substring(0, 2) + '***' + $Value.Substring($Value.Length - 1) }
    if ($Value.Length -eq 0) { return '' }
    return '***'
}

function Get-MaskedConnString {
    <# Mascara o PWD= de uma ConnectionString do dbaccess.ini pra EXIBICAO.

       A string REAL continua indo pro arquivo - so a saida no terminal muda.
       Sem isso a senha do SQL vazava pro stdout e, dai, pro transcript/log da
       sessao e pro historico da ferramenta que chamou o script. #>
    param([string]$ConnString)
    if ([string]::IsNullOrEmpty($ConnString)) { return $ConnString }

    $saida = $ConnString
    # Percorre de tras pra frente: substituir por indice invalida os offsets
    # dos matches seguintes se formos na ordem direta.
    $matchesPwd = [regex]::Matches($ConnString, '(?i)PWD=([^;]*)')
    for ($i = $matchesPwd.Count - 1; $i -ge 0; $i--) {
        $g = $matchesPwd[$i].Groups[1]
        if ($g.Length -eq 0) { continue }
        $saida = $saida.Substring(0, $g.Index) + (Get-MaskedSecret -Value $g.Value) + $saida.Substring($g.Index + $g.Length)
    }
    return $saida
}

function Get-IniSectionBounds {
    <# Indices [Start..End] da secao (Start = a linha do cabecalho, End = ultima
       linha antes do proximo cabecalho). $null se a secao nao existe. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory=$true)][string]$Section
    )
    $hdr = '^\s*\[' + [regex]::Escape($Section) + '\]\s*$'
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $hdr) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = $Lines.Count - 1
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\[.+\]\s*$') { $end = $i - 1; break }
    }
    return [pscustomobject]@{ Start = $start; End = $end }
}

function Test-IniSection {
    <# .T./.F. pra existencia da secao. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory=$true)][string]$Section
    )
    return ($null -ne (Get-IniSectionBounds -Lines $Lines -Section $Section))
}

function Set-IniSectionKeys {
    <# Update IN-PLACE das chaves de uma secao existente, preservando todo o
       resto do arquivo (comentarios, ordem, outras chaves, outras secoes).

       - chave presente com valor diferente -> a LINHA e reescrita
       - chave presente com o mesmo valor    -> intocada (nao normaliza espacos,
         pra nao gerar diff cosmetico e nem falso "atualizado")
       - chave ausente                       -> inserida no fim da secao (antes
         das linhas em branco que separam da proxima secao)

       Devolve o novo array de linhas. Lanca se a secao nao existe - criar secao
       e trabalho de quem chama (ver New-RestSectionLines). #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory=$true)][string]$Section,
        [Parameter(Mandatory=$true)][System.Collections.IDictionary]$Keys
    )
    if (-not (Test-IniSection -Lines $Lines -Section $Section)) {
        throw "IniIO: secao [$Section] nao existe - nao da pra atualizar in-place."
    }
    $out = New-Object System.Collections.Generic.List[string]
    $out.AddRange([string[]]$Lines)

    foreach ($k in @($Keys.Keys)) {
        $val = "$($Keys[$k])"
        # Recalcula os limites a cada chave: uma insercao anterior desloca tudo.
        $b   = Get-IniSectionBounds -Lines $out.ToArray() -Section $Section
        $rx  = '^\s*' + [regex]::Escape($k) + '\s*='
        $idx = -1
        for ($i = $b.Start + 1; $i -le $b.End; $i++) {
            if ($out[$i] -match $rx) { $idx = $i; break }
        }
        if ($idx -ge 0) {
            $atual = ($out[$idx] -split '=', 2)[1]
            if ($null -eq $atual) { $atual = '' }
            if ($atual.Trim() -ne $val) { $out[$idx] = "$k=$val" }
        } else {
            $last = $b.End
            while ($last -gt $b.Start -and [string]::IsNullOrWhiteSpace($out[$last])) { $last-- }
            $out.Insert($last + 1, "$k=$val")
        }
    }
    return $out.ToArray()
}

function New-RestSectionLines {
    <# Bloco COMPLETO de secoes que fazem o AppServer servir /rest/*.
       Fonte unica do template: usado pelo New-IsolatedInstance.ps1 (#34) e pelo
       Set-AppServerRest.ps1 quando a secao nao existe. So [HTTPREST] nao basta:
       sem [HTTPURI]/[HTTPV11]/[ONSTART] o servidor nao responde /rest.

       Devolve um hashtable ordenado secao -> linhas de chave (sem o cabecalho),
       pra quem chama decidir quais secoes adicionar (nunca duplicar uma que ja
       exista no ini do usuario). #>
    param(
        [Parameter(Mandatory=$true)][string]$Environment,
        [Parameter(Mandatory=$true)][int]$RestPort,
        [Parameter(Mandatory=$false)][int]$Security = 1,
        [Parameter(Mandatory=$false)][System.Collections.IDictionary]$ExtraRestKeys
    )
    $rest = [ordered]@{
        'Port'     = "$RestPort"
        'URIs'     = 'HTTPURI'
        'SECURITY' = "$Security"
    }
    if ($ExtraRestKeys) {
        foreach ($k in @($ExtraRestKeys.Keys)) { $rest[$k] = "$($ExtraRestKeys[$k])" }
    }
    $restLines = @()
    foreach ($k in @($rest.Keys)) { $restLines += ('{0}={1}' -f $k, $rest[$k]) }

    return [ordered]@{
        'HTTPJOB'  = @('Main=HTTP_START', "Environment=$Environment")
        'ONSTART'  = @('Jobs=HTTPJOB', "RefreshRate=$script:RestRefreshRate")
        'HTTPV11'  = @('Enable=1', 'Sockets=HTTPREST')
        'HTTPREST' = $restLines
        'HTTPURI'  = @('URL=/rest', 'PrepareIn=99,01', 'Instances=1,2', 'AllowOrigin=*', 'CORSEnable=1', 'Stateless=1')
    }
}

function ConvertTo-IniLines {
    <# Achata o mapa de New-RestSectionLines em linhas de .ini (cabecalho +
       chaves + linha em branco por secao). #>
    param(
        [Parameter(Mandatory=$true)][System.Collections.IDictionary]$Sections
    )
    $lines = @()
    foreach ($s in @($Sections.Keys)) {
        $lines += "[$s]"
        $lines += $Sections[$s]
        $lines += ''
    }
    return $lines
}

function Write-IniLines {
    <# Grava o .ini a partir de um array de linhas, com CRLF (padrao Windows/TOTVS).

       AllowEmptyString/AllowEmptyCollection sao obrigatorios: .ini tem linhas em
       branco separando secoes e o binder de [string[]] rejeita elemento vazio
       por padrao ("Cannot bind argument to parameter 'Lines' because it is an
       empty string"). #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
    )
    [System.IO.File]::WriteAllText($Path, ($Lines -join "`r`n"), $script:IniEncoding)
}
