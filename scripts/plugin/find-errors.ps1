param([Parameter(Mandatory=$true)][string]$Path)
$err = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path).Path, [ref]$null, [ref]$err) | Out-Null
$err | ForEach-Object {
    $line = $_.Extent.StartLineNumber
    $col  = $_.Extent.StartColumnNumber
    $msg  = $_.Message
    Write-Host "line $line col $col : $msg"
}
