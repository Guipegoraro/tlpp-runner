<#
.SYNOPSIS
    Saida legivel das respostas do /runner/exec (usada pelo Invoke-TlppRunner).

.DESCRIPTION
    Em arquivo proprio para ter teste sem AppServer (scripts/test/Test-RunnerConfig.ps1,
    cenarios O*): recebe o ErrorRecord/objeto de resposta e so escreve no host.
#>

function Write-AssertFails {
    <# Uma linha por assert falho do `asserts.fails` da resposta do /runner/exec. #>
    param($Asserts)
    if ($Asserts -and $Asserts.fails) {
        foreach ($f in @($Asserts.fails)) { Write-Host "  FAIL: $f" -ForegroundColor Red }
    }
}

function Show-Error {
    <# Erro de request em texto legivel. O corpo da resposta vem de ErrorDetails
       no PowerShell 7 (HttpResponseMessage nao tem GetResponseStream) e do
       stream da resposta no 5.1. Erro de execucao da funcao (`error=runtime`)
       sai como mensagem + pilha + asserts registrados ate o erro. #>
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    if (-not $ex.Response) {
        Write-Host "[runner] $($ex.Message)" -ForegroundColor Red
        return 0
    }
    $code = 0
    try { $code = [int]$ex.Response.StatusCode } catch {}
    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    } elseif ($ex.Response.PSObject.Methods['GetResponseStream']) {
        try { $body = (New-Object System.IO.StreamReader($ex.Response.GetResponseStream())).ReadToEnd() } catch {}
    }
    Write-Host "[runner] HTTP $code" -ForegroundColor Red
    $j = $null
    if ($body) { try { $j = $body | ConvertFrom-Json } catch {} }
    if ($j -and $j.error -eq 'runtime') {
        Write-Host "$($j.function): ERRO $($j.message)" -ForegroundColor Red
        if ($j.stack) {
            $j.stack -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 15 |
                ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
        Write-AssertFails $j.asserts
    } elseif ($body) {
        Write-Host $body
    }
    return $code
}
