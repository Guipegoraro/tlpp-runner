<#
.SYNOPSIS
    Teste do cascade de configuracao (runner/runner.config.ps1) - issue #21.

.DESCRIPTION
    Logica pura: nao precisa de AppServer, sqlcmd nem config global real.
    O cascade nunca teve suite propria - e ja teve bug grave silencioso
    (-ProjectRoot ignorado, #17/PR #31). Cobre a resolucao per-project:

      R1  projeto vazio (sem .tlpp-tdd.json)     -> defaults + TestDb=PROTHEUS_TST
      R2  name no json                            -> TestDb=PROTHEUS_TST_<NAME>
      R3  testDb explicito                        -> vence a derivacao por name
      R4  schemaPath relativo no json             -> resolvido contra ProjectRoot
      R5  schemaPath ausente                      -> default <proj>\sql\schema.sql
      R6  layout dev-repo (runner\sql\02-...)     -> fallback pro schema do repo
      R7  schemaPath absoluto                     -> usado como esta
      R8  json invalido                           -> warning, defaults (sem excecao)

    Isolamento por projeto (#34) - a presenca de `isolation` no json e o gatilho:

      R9  isolation + ProtheusRoot  -> BaseUrl/Port/Environment/RpoCustom/bin da instancia
      R10 SEM isolation             -> nada muda (defaults intactos, IsolationBinDir vazio)
      R11 isolation sem `name`      -> IGNORADO (nome deriva env/bin/RPO), sem excecao
      R12 isolation + baseUrl expl. -> baseUrl explicito vence o derivado
      R13 isolation sem ProtheusRoot-> portas/environment derivam, paths ficam vazios

    BaseUrl com host localhost (fallback IPv6 custa ~2s por request):

      R14 config global com localhost  -> normalizado para 127.0.0.1
      R15 baseUrl do json com localhost -> normalizado (porta e path intactos)
      R16 host que so comeca com "localhost" -> intocado

    Sandbox: USERPROFILE temporario (sem config global) + copia do
    runner.config.ps1 (sem runner.config.local.ps1 legacy do repo por perto).

    Classificacao de erro de conexao (runner/HttpRetry.ps1) - o backoff
    assimetrico do Invoke-TlppRunner depende dela e estava MORTO em PS 5.1 pt-BR
    (casava so a mensagem, que e localizada):

      C1  WebException ConnectFailure com mensagem pt-BR -> transiente
      C2  WebException ProtocolError (HTTP 404/500)      -> NAO transiente
      C3  excecao embrulhada em ErrorRecord              -> transiente
      C4  SocketException como InnerException            -> transiente
      C5  HttpRequestException (PS 7)                    -> transiente
      C6  HttpResponseException (PS 7, deriva da C5)     -> NAO transiente
      C7  erro qualquer (bug de script)                  -> NAO transiente
      C8  fallback por mensagem ('recusou') preservado   -> transiente

    Exit 0 se nenhum check reprovar, 1 caso contrario.
#>
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

$fail = 0
function Add-Result([string]$tag, [string]$desc) {
    $color = switch ($tag) { 'PASS' {'Green'} 'FAIL' {'Red'} default {'DarkYellow'} }
    Write-Host ("  [{0}] {1}" -f $tag, $desc) -ForegroundColor $color
    if ($tag -eq 'FAIL') { $script:fail++ }
}
function Assert-Equal([string]$desc, $expected, $actual) {
    if ($expected -eq $actual) { Add-Result 'PASS' $desc }
    else { Add-Result 'FAIL' "$desc (esperado='$expected' obtido='$actual')" }
}

# Carrega o cascade num runspace LIMPO por cenario: o script usa variaveis
# script-scoped e $global:TlppRunner - reusar a sessao deixaria estado de um
# cenario vazar pro seguinte (o mesmo genero de falso-verde do sync.ps1).
function Invoke-Cascade([string]$RunnerDir, [string]$ProjectRoot) {
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript(@"
`$env:CLAUDE_PROJECT_DIR = ''
`$TlppProjectRootOverride = '$ProjectRoot'
. '$RunnerDir\runner.config.ps1'
`$TlppRunner
"@)
        $out = $ps.Invoke()
        return $out[0]
    } finally { $ps.Dispose() }
}

# --- Sandbox ---
$sandbox = Join-Path $env:TEMP ('tlpp-config-test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$runnerDir = Join-Path $sandbox 'runner'
New-Item -ItemType Directory -Path $runnerDir -Force | Out-Null
Copy-Item (Join-Path $root 'runner\runner.config.ps1') $runnerDir

$origHome = $env:USERPROFILE
$env:USERPROFILE = $sandbox   # sem ~/.claude/tlpp-tdd/config.ps1 -> defaults puros

function New-Proj([string]$nome, $json) {
    $p = Join-Path $sandbox $nome
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    if ($null -ne $json) { Set-Content -Path (Join-Path $p '.tlpp-tdd.json') -Value $json -Encoding UTF8 }
    return $p
}

# Config global do sandbox (USERPROFILE aponta pro sandbox). Necessaria nos
# cenarios de isolamento: os paths da instancia derivam de ProtheusRoot, que so
# existe no nivel global do cascade. Passar $null remove o arquivo.
function Set-GlobalCfg($conteudo) {
    $dir  = Join-Path $sandbox '.claude\tlpp-tdd'
    $path = Join-Path $dir 'config.ps1'
    if ($null -eq $conteudo) {
        if (Test-Path $path) { Remove-Item $path -Force }
        return
    }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -Path $path -Value $conteudo -Encoding UTF8
}

try {
    Write-Host "`n=== Test-RunnerConfig ===" -ForegroundColor Cyan

    # R1 - projeto vazio
    $proj = New-Proj 'vazio' $null
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R1 ProjectRoot respeitado (override)' $proj $cfg.ProjectRoot
    Assert-Equal 'R1 sem json: ProjectName vazio' '' $cfg.ProjectName
    Assert-Equal 'R1 sem json: TestDb fallback' 'PROTHEUS_TST' $cfg.TestDb

    # R2 - name deriva TestDb
    $proj = New-Proj 'comnome' '{ "name": "FOO" }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R2 name lido' 'FOO' $cfg.ProjectName
    Assert-Equal 'R2 TestDb derivado' 'PROTHEUS_TST_FOO' $cfg.TestDb

    # R3 - testDb explicito vence
    $proj = New-Proj 'testdbexpl' '{ "name": "FOO", "testDb": "MEU_BANCO" }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R3 testDb explicito vence a derivacao' 'MEU_BANCO' $cfg.TestDb

    # R4 - schemaPath relativo resolve contra ProjectRoot
    $proj = New-Proj 'schemarel' '{ "name": "FOO", "schemaPath": "db\\meu-schema.sql" }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R4 schemaPath relativo -> ProjectRoot' (Join-Path $proj 'db\meu-schema.sql') $cfg.SchemaPath

    # R5 - sem schemaPath: default <proj>\sql\schema.sql
    $proj = New-Proj 'schemadefault' '{ "name": "FOO" }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R5 default sql\schema.sql' (Join-Path $proj 'sql\schema.sql') $cfg.SchemaPath

    # R6 - layout dev-repo: runner\sql\02-create-schema.sql existente vence o default
    $proj = New-Proj 'devrepo' $null
    $devSql = Join-Path $proj 'runner\sql'
    New-Item -ItemType Directory -Path $devSql -Force | Out-Null
    Set-Content -Path (Join-Path $devSql '02-create-schema.sql') -Value '-- schema dev' -Encoding UTF8
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R6 dev-repo usa runner\sql\02-create-schema.sql' (Join-Path $proj 'runner\sql\02-create-schema.sql') $cfg.SchemaPath

    # R7 - schemaPath absoluto usado como esta
    $abs = Join-Path $sandbox 'compartilhado\schema.sql'
    $projJson = '{ "name": "FOO", "schemaPath": ' + ($abs | ConvertTo-Json) + ' }'
    $proj = New-Proj 'schemaabs' $projJson
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R7 schemaPath absoluto preservado' $abs $cfg.SchemaPath

    # R8 - json invalido: defaults sem excecao
    $proj = New-Proj 'jsonruim' '{ isso nao e json'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R8 json invalido -> ProjectName vazio' '' $cfg.ProjectName
    Assert-Equal 'R8 json invalido -> TestDb fallback' 'PROTHEUS_TST' $cfg.TestDb

    # ===== Isolamento por projeto (#34) =====
    # A partir daqui existe config global com ProtheusRoot - os paths da
    # instancia (bin, apo, RpoCustom) so podem derivar dele.
    $fakeProt = Join-Path $sandbox 'TOTVS'
    New-Item -ItemType Directory -Path $fakeProt -Force | Out-Null
    Set-GlobalCfg ("`$TlppRunner.ProtheusRoot = '" + $fakeProt + "'")

    # R9 - isolation deriva tudo
    $proj = New-Proj 'iso' '{ "name": "ISOPROJ", "isolation": { "tcpPort": 1271, "restPort": 8404, "webAppPort": 8101 } }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R9 BaseUrl na porta REST da instancia' 'http://127.0.0.1:8404/rest' $cfg.BaseUrl
    Assert-Equal 'R9 Port = porta TCP da instancia'      1271 $cfg.Port
    Assert-Equal 'R9 Environment = nome em maiusculas'   'ISOPROJ' $cfg.Environment
    Assert-Equal 'R9 IsolationBinDir'  (Join-Path $fakeProt 'Protheus\bin\appserver_isoproj') $cfg.IsolationBinDir
    Assert-Equal 'R9 IsolationApoDir'  (Join-Path $fakeProt 'protheus\apo_isoproj') $cfg.IsolationApoDir
    Assert-Equal 'R9 RpoCustom no RPO da instancia' (Join-Path $fakeProt 'protheus\apo_isoproj\custom.rpo') $cfg.RpoCustom
    Assert-Equal 'R9 ConsoleLogPath no bin da instancia' (Join-Path $fakeProt 'Protheus\bin\appserver_isoproj\console.log') $cfg.ConsoleLogPath
    Assert-Equal 'R9 WebApp exposto' 8101 $cfg.IsolationWebApp
    Assert-Equal 'R9 TestDb segue a derivacao normal' 'PROTHEUS_TST_ISOPROJ' $cfg.TestDb

    # R10 - projeto SEM isolation nao muda nada (regressao: o gatilho e a chave)
    $proj = New-Proj 'semiso' '{ "name": "SEMISO" }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R10 sem isolation: BaseUrl default'      'http://127.0.0.1:8401/rest' $cfg.BaseUrl
    Assert-Equal 'R10 sem isolation: Port default'         1268 $cfg.Port
    Assert-Equal 'R10 sem isolation: Environment default'  'DESENVOLVIMENTO' $cfg.Environment
    Assert-Equal 'R10 sem isolation: IsolationBinDir vazio' '' $cfg.IsolationBinDir
    Assert-Equal 'R10 sem isolation: ConsoleLogPath do appserver_rest' `
        (Join-Path $fakeProt 'Protheus\bin\appserver_rest\console.log') $cfg.ConsoleLogPath

    # R11 - isolation sem name: ignorado (sem o nome nao ha environment nem paths)
    $proj = New-Proj 'isosemnome' '{ "isolation": { "tcpPort": 1271, "restPort": 8404, "webAppPort": 8101 } }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R11 isolation sem name -> Port default'          1268 $cfg.Port
    Assert-Equal 'R11 isolation sem name -> BaseUrl default'       'http://127.0.0.1:8401/rest' $cfg.BaseUrl
    Assert-Equal 'R11 isolation sem name -> IsolationBinDir vazio' '' $cfg.IsolationBinDir

    # R12 - baseUrl explicito no MESMO json vence o derivado do isolamento
    $proj = New-Proj 'isobaseurl' '{ "name": "ISOB", "baseUrl": "http://127.0.0.1:9999/rest", "isolation": { "tcpPort": 1271, "restPort": 8404, "webAppPort": 8101 } }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R12 baseUrl explicito vence' 'http://127.0.0.1:9999/rest' $cfg.BaseUrl
    Assert-Equal 'R12 Port ainda vem do isolamento' 1271 $cfg.Port

    # R13 - sem ProtheusRoot: portas/environment derivam, paths ficam vazios
    Set-GlobalCfg $null
    $proj = New-Proj 'isosemroot' '{ "name": "ISOC", "isolation": { "tcpPort": 1272, "restPort": 8405, "webAppPort": 8102 } }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R13 sem ProtheusRoot: Port derivado'        1272 $cfg.Port
    Assert-Equal 'R13 sem ProtheusRoot: Environment derivado' 'ISOC' $cfg.Environment
    Assert-Equal 'R13 sem ProtheusRoot: IsolationBinDir vazio' '' $cfg.IsolationBinDir
    Assert-Equal 'R13 sem ProtheusRoot: RpoCustom vazio'       '' $cfg.RpoCustom

    # ===== BaseUrl localhost -> 127.0.0.1 =====
    # R14 - config global gravada com localhost
    Set-GlobalCfg "`$TlppRunner.BaseUrl = 'http://localhost:8401/rest'"
    $proj = New-Proj 'normglobal' '{ "name": "NORMG" }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R14 global localhost -> 127.0.0.1' 'http://127.0.0.1:8401/rest' $cfg.BaseUrl

    # R15 - baseUrl explicito do json com localhost
    Set-GlobalCfg $null
    $proj = New-Proj 'normjson' '{ "name": "NORMJ", "baseUrl": "http://localhost:9001/rest" }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R15 json localhost -> 127.0.0.1' 'http://127.0.0.1:9001/rest' $cfg.BaseUrl

    # R16 - so o host exato e trocado
    $proj = New-Proj 'normhost' '{ "name": "NORMH", "baseUrl": "http://localhost-dev:9002/rest" }'
    $cfg = Invoke-Cascade $runnerDir $proj
    Assert-Equal 'R16 host localhost-dev intocado' 'http://localhost-dev:9002/rest' $cfg.BaseUrl

    # ===== Classificacao de erro de conexao (backoff do Invoke-TlppRunner) =====
    . (Join-Path $root 'runner\HttpRetry.ps1')

    # C1 - o caso que estava quebrado: PS 5.1 pt-BR nao diz "refused"
    $c1 = [System.Net.WebException]::new(
        'Nao e possivel conectar-se ao servidor remoto',
        [System.Net.WebExceptionStatus]::ConnectFailure)
    Assert-Equal 'C1 ConnectFailure pt-BR -> transiente' $true (Test-TransientConnError -ErrorObject $c1)

    # C2 - servidor RESPONDEU: 404 de funcao inexistente nao pode esperar 180s
    $c2 = [System.Net.WebException]::new(
        'The remote server returned an error: (404) Not Found.',
        $null, [System.Net.WebExceptionStatus]::ProtocolError, $null)
    Assert-Equal 'C2 ProtocolError (404) -> NAO transiente' $false (Test-TransientConnError -ErrorObject $c2)

    # C3 - Invoke-RestMethod entrega ErrorRecord, nao a excecao crua
    $rec = New-Object System.Management.Automation.ErrorRecord(
        $c1, 'conn', [System.Management.Automation.ErrorCategory]::ConnectionError, $null)
    Assert-Equal 'C3 ErrorRecord desembrulhado' $true (Test-TransientConnError -ErrorObject $rec)

    # C4 - SocketException aninhada, mensagem de fora sem nenhuma pista
    $sock  = [System.Net.Sockets.SocketException]::new(10061)
    $embru = [System.InvalidOperationException]::new('falha generica', $sock)
    Assert-Equal 'C4 SocketException aninhada' $true (Test-TransientConnError -ErrorObject $embru)

    # C5/C6 - PS 7: HttpResponseException DERIVA de HttpRequestException
    $c5 = [System.Net.Http.HttpRequestException]::new('No connection could be made')
    Assert-Equal 'C5 HttpRequestException -> transiente' $true (Test-TransientConnError -ErrorObject $c5)
    $tipoResp = 'Microsoft.PowerShell.Commands.HttpResponseException' -as [type]
    if ($tipoResp) {
        $httpResp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
        $c6 = $tipoResp::new('Response status code does not indicate success: 404 (Not Found).', $httpResp)
        Assert-Equal 'C6 HttpResponseException (404) -> NAO transiente' $false (Test-TransientConnError -ErrorObject $c6)
    } else {
        Add-Result 'SKIP' 'C6 HttpResponseException indisponivel nesta edicao do PowerShell'
    }

    # C7 - bug de script nao pode virar retry de 3 minutos
    Assert-Equal 'C7 erro qualquer -> NAO transiente' $false `
        (Test-TransientConnError -ErrorObject ([System.ArgumentException]::new('parametro invalido')))

    # C8 - fallback por mensagem segue valendo (excecao sem tipo util)
    Assert-Equal 'C8 fallback por mensagem' $true `
        (Test-TransientConnError -ErrorObject ([System.Exception]::new('O destino recusou a conexao')))

    # ===== Write-GlobalConfig: chave obrigatoria nula nao pode passar batido =====
    # Tudo com -DryRun (nao grava). USERPROFILE ja esta no sandbox de qualquer forma.
    $wcfg = Join-Path $root 'runner\install\Write-GlobalConfig.ps1'
    function Test-Wcfg($settings) {
        try { & $wcfg -Settings $settings -DryRun *>&1 | Out-Null; return $null }
        catch { return $_.Exception.Message }
    }

    $erro = Test-Wcfg @{ User='admin'; Password='pw'; ProtheusRoot=$null }
    Assert-Equal 'W1 ProtheusRoot nulo -> falha' $true ($null -ne $erro -and $erro -match 'ProtheusRoot')

    $erro = Test-Wcfg @{ User='admin'; Password='   ' }
    Assert-Equal 'W2 Password em branco -> falha' $true ($null -ne $erro -and $erro -match 'Password')

    $erro = Test-Wcfg @{ AdvplsPath=$null; Port=$null }
    Assert-Equal 'W3 erro lista TODAS as chaves faltando' $true `
        ($null -ne $erro -and $erro -match 'AdvplsPath' -and $erro -match 'Port')

    $erro = Test-Wcfg @{ ProtheusRoot='C:\TOTVS\Protheus_x'; SqlInstance=$null }
    Assert-Equal 'W4 chave opcional nula segue tolerada' $null $erro

    # W5 - regressao do parse: `.Add('{0}={1}' -f $k, $v)` sem parenteses extras
    # fazia a virgula virar separador de argumento e o script explodia em toda
    # chamada com valor real. Aqui basta uma chave sair no conteudo gerado.
    $saidaW = (& $wcfg -Settings @{ ProtheusRoot='C:\TOTVS\Protheus_x' } -DryRun *>&1 | Out-String)
    Assert-Equal 'W5 gera linha do TlppRunner sem erro de formatacao' $true `
        ($saidaW -match [regex]::Escape("`$TlppRunner.ProtheusRoot = 'C:\TOTVS\Protheus_x'"))

} catch {
    # Erro terminante nao pode virar "tudo OK" com fail=0 - falso-verde.
    Add-Result 'FAIL' "excecao inesperada: $($_.Exception.Message)"
} finally {
    $env:USERPROFILE = $origHome
    Remove-Item -Path $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($fail -eq 0) { Write-Host "Test-RunnerConfig: tudo OK" -ForegroundColor Green; exit 0 }
Write-Host "Test-RunnerConfig: $fail check(s) reprovaram" -ForegroundColor Red
exit 1
