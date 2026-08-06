<#
.SYNOPSIS
    Classificacao de erro de conexao usada pelo backoff do Invoke-TlppRunner.

.DESCRIPTION
    O backoff assimetrico (espera longa quando o AppServer esta vivo e o
    HTTPREST so esta reiniciando, curta quando o processo esta morto) depende de
    distinguir "nao conectou" de "conectou e o servidor respondeu erro".

    A versao antiga classificava por MENSAGEM:

        $_.Exception.Message -match 'recusou|refused|connection|ConnectFailure'

    Isso e localizado. Em PowerShell 5.1 pt-BR a mensagem e "Nao e possivel
    conectar-se ao servidor remoto" - nenhum dos termos casa, entao TODA falha de
    conexao caia no `throw` imediato e o backoff nunca rodava: o usuario via
    "erro" a cada compilacao em vez de esperar o REST voltar.

    Aqui a decisao e por TIPO, que nao e traduzido:

      - System.Net.WebException com Status ConnectFailure/Timeout  (PS 5.1)
      - System.Net.Http.HttpRequestException                       (PS 7)
      - System.Net.Sockets.SocketException                         (aninhada)

    E percorre InnerException: Invoke-RestMethod/Invoke-WebRequest embrulham a
    excecao real dentro de um ErrorRecord e, no PS 7, dentro de outra excecao.

    Cuidado deliberado: HttpResponseException (PS 7, resposta HTTP 4xx/5xx)
    HERDA de HttpRequestException. Por isso a comparacao e por FullName EXATO -
    um 404 "funcao nao existe" precisa falhar na hora, nao insistir 180s.

    O regex antigo continua como FALLBACK, pro caso de excecao sem tipo util.
#>

function Get-ExceptionChain {
    <# Excecao + InnerExceptions (limite de profundidade contra ciclo). #>
    param($ErrorObject)
    $ex = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) { $ErrorObject.Exception } else { $ErrorObject }
    $chain = @()
    $cur = $ex
    while ($null -ne $cur -and $chain.Count -lt 8) {
        $chain += $cur
        $cur = $cur.InnerException
    }
    return $chain
}

function Test-TransientConnError {
    <# .T. quando o erro e "nao consegui falar com o servidor" (vale retry).
       .F. quando o servidor respondeu (HTTP 4xx/5xx) ou o erro e outro. #>
    param($ErrorObject)

    $chain = Get-ExceptionChain -ErrorObject $ErrorObject
    if ($chain.Count -eq 0) { return $false }

    $transientes = @([System.Net.WebExceptionStatus]::ConnectFailure,
                     [System.Net.WebExceptionStatus]::Timeout,
                     [System.Net.WebExceptionStatus]::NameResolutionFailure,
                     [System.Net.WebExceptionStatus]::SendFailure)

    foreach ($e in $chain) {
        # PS 7: HttpResponseException deriva de HttpRequestException - por isso
        # FullName exato, nao -is.
        if ($e.GetType().FullName -eq 'System.Net.Http.HttpRequestException') { return $true }
        if ($e -is [System.Net.Sockets.SocketException]) { return $true }
        if ($e -is [System.Net.WebException]) {
            if ($transientes -contains $e.Status) { return $true }
            # ProtocolError = servidor respondeu (404/500). Nao e transiente.
            if ($e.Status -eq [System.Net.WebExceptionStatus]::ProtocolError) { return $false }
        }
    }

    # Fallback por mensagem (mantido de proposito): cobre excecoes sem tipo util.
    # 'conectar-se' pega o pt-BR do PS 5.1; 'conectar' sozinho seria amplo demais.
    $msgs = ($chain | ForEach-Object { $_.Message }) -join ' | '
    return [bool]($msgs -match 'recusou|refused|connection|ConnectFailure|conectar-se|conectar ao servidor')
}
