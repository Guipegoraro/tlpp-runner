---
name: tlpp-tdd-setup
description: 'Configura, diagnostica e conserta o framework tlpp-tdd na maquina do usuario. Modo doctor: roda checklist completo (config global, paths Protheus, AppServer rodando, REST /runner/ping, framework no RPO, DBAccess, SQL) e classifica cada item como OK/FALTA/BROKEN com fix concreto. Modo setup: faz instalacao inicial (escolha AppServer dedicado vs reusar, compila framework no RPO, config global). Idempotente - re-rodar so executa o que esta faltando. Use SEMPRE que o usuario disser "tlpp-tdd nao funciona", "instalar tlpp-tdd", "setup tlpp", "configurar TDD ADVPL", "tlpp-tdd-setup", "consertar tlpp", "diagnosticar tlpp", "tlpp-tdd doctor", "erro no tlpp-tdd", ou quando ele tentar usar /tlpp-build|/tlpp-test e algo falhar (HTTP 0, funcao_nao_existe, advpls nao encontrado). NAO use pra criar banco de um projeto especifico - isso e /tlpp-tdd-project-init.'
---

You are running **setup + doctor** for the `tlpp-tdd` plugin on the user's machine. Two paths converge:

- **Setup mode**: first-time install. User has nothing configured yet.
- **Doctor mode**: something is broken. Diagnose what, fix what's fixable, instruct user for the rest.

Both modes start the same: **run the diagnose checklist**. Then triage.

**Language rule:** Skill in English so workflow rules carry. **All output to user must be in Portuguese** (PT-BR).

## Pre-flight

1. **Resolve `$RUNNER_INSTALL`**:
   - `$env:CLAUDE_PLUGIN_ROOT\runner\install` (plugin instalado)
   - `<plugin-repo>\runner\install` (rodando do clone)
   - Falha clara se nenhum existir.

2. **Resolve `$PLUGIN_ROOT`** = parent de `$RUNNER_INSTALL\..`.

## Phase 1 - Diagnose (sempre roda)

Faz checklist completo. Cada item: `[OK]` / `[FALTA]` / `[BROKEN: <motivo>]`. Reporta tudo ao user antes de propor fix.

### Checks

**1. Config global existe**
```powershell
$cfgPath = Join-Path $env:USERPROFILE '.claude\tlpp-tdd\config.ps1'
$check1 = Test-Path $cfgPath
```
- FALTA -> precisa setup. Vai Phase 3 (Setup completo).
- OK -> segue.

**2. Config global parses + carrega chaves essenciais**
```powershell
try {
    . (Join-Path $PLUGIN_ROOT 'runner\runner.config.ps1')  # carrega cascade ($PSScriptRoot e VAZIO em snippet ad-hoc)
    $gcfg = $TlppRunner
    $check2 = -not [string]::IsNullOrEmpty($gcfg.User) -and `
              -not [string]::IsNullOrEmpty($gcfg.Password) -and `
              -not [string]::IsNullOrEmpty($gcfg.BaseUrl)
} catch { $check2 = $false; $err2 = $_.Exception.Message }
```
- BROKEN -> mostra erro, oferece reedit do config.ps1 ou recriar via Write-GlobalConfig.

**3. ProtheusRoot valido**
```powershell
$check3 = $gcfg.ProtheusRoot -and (Test-Path $gcfg.ProtheusRoot)
```
- BROKEN -> path morto. Re-detecta via `Test-Environment.ps1`, pergunta confirmacao, regrava.

**4. AdvplsPath valido (binario existe)**
```powershell
$check4 = $gcfg.AdvplsPath -and (Test-Path $gcfg.AdvplsPath)
```
- BROKEN -> TDS-VSCode pode ter atualizado e mudou versao. Re-detecta via `Test-Environment.ps1` (busca `$env:USERPROFILE\.vscode\extensions\totvs.tds-vscode-*`).

**5. Includes valido**
```powershell
$check5 = $gcfg.Includes -and (Test-Path $gcfg.Includes)
```
- BROKEN -> deriva de ProtheusRoot e regrava.

**6. AppServer rodando + REST responde**
```powershell
$pingUrl = "$($gcfg.BaseUrl)/runner/ping"
$pair = "$($gcfg.User):$($gcfg.Password)"
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
try {
    $r = Invoke-RestMethod -Uri $pingUrl -Headers @{Authorization="Basic $basic"} -TimeoutSec 5
    $check6 = $r.status -eq 'ok'
} catch {
    $check6 = $false
    $err6 = $_.Exception.Message
}
```
- BROKEN: HTTP 0 / connection refused -> AppServer nao esta rodando. Instrucoes pro user iniciar manualmente (path em `$gcfg.AppServerIniPath` se setado).
- BROKEN: HTTP 401/403 -> senha errada. Re-pergunta admin password.
- BROKEN: HTTP 404 ou outro -> `[HTTPREST]` nao configurado no `.ini`. Roda `Set-AppServerRest.ps1`.

**7. Framework compilado no RPO**
```powershell
$execUrl = "$($gcfg.BaseUrl)/runner/exec"
$body = '{"function":"u_tecAssertReset"}'
try {
    $r = Invoke-RestMethod -Method Post -Uri $execUrl -Headers @{Authorization="Basic $basic";'Content-Type'='application/json'} -Body $body -TimeoutSec 10
    $check7 = $r.result -eq '.T.'
} catch {
    $check7 = $false
    $err7 = $_.Exception.Message
}
```
- BROKEN: 404 `funcao_nao_existe` -> framework nao compilou. Roda `Install-Framework-Global.ps1`.
- BROKEN: 500 runtime -> erro em fonte do framework. Mostra mensagem + recomenda recompilar.

**8. DBAccess rodando (opcional - so warning)**
```powershell
$check8 = $null -ne (Get-Process -Name 'dbaccess64' -ErrorAction SilentlyContinue)
```
- FALTA -> warning so. Testes unit funcionam sem DBAccess. Integracao precisa - instrucoes pra subir.

**9. SQL Server acessivel (opcional - so warning)**
```powershell
try {
    $auth = if ($gcfg.SqlAuth -eq 'Windows') { '-E' } else { "-U $($gcfg.SqlUser) -P $($gcfg.SqlPassword)" }
    & sqlcmd -S $gcfg.SqlInstance $auth -Q "SELECT 1" -h -1 2>&1 | Out-Null
    $check9 = $LASTEXITCODE -eq 0
} catch { $check9 = $false }
```
- FALTA -> warning. Sem SQL, project-init nao funciona. Instrucoes pra subir.

**10. Instancia isolada do projeto atual (#34 - so quando ha isolamento)**

Este check e PER-PROJETO: so roda se o `.tlpp-tdd.json` do cwd (ou
`$env:CLAUDE_PROJECT_DIR`) tiver a chave `isolation`. Projeto sem isolamento =
`n/a`, nao e falha.

```powershell
# O cascade JA deriva tudo quando ha isolation - nao remonte path na mao.
$pcfgDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }
$TlppProjectRootOverride = $pcfgDir      # ANTES do dot-source (pegadinha do PR #31)
. "$PLUGIN_ROOT\runner\runner.config.ps1"
$pcfg = $TlppRunner
$check10 = 'n/a'
if ($pcfg.IsolationBinDir) {
    $itens = @{
        arvore = Test-Path $pcfg.IsolationBinDir
        ini    = Test-Path (Join-Path $pcfg.IsolationBinDir 'appserver.ini')
        rpoDir = Test-Path $pcfg.IsolationApoDir
        noAr   = $false
    }
    . "$PLUGIN_ROOT\runner\InstanceControl.ps1"
    $itens.noAr = Test-TlppPortOpen -HostName 'localhost' -Port $pcfg.Port
}
```

Classificacao:

| Sintoma | Veredito | Fix |
|---|---|---|
| `isolation` no json mas `IsolationBinDir` nao existe | **BROKEN** | `New-IsolatedInstance.ps1` (recria a arvore; o RPO sobrevive se `apo_<nome>` ficou) |
| arvore existe mas sem `appserver.ini` | **BROKEN** | `New-IsolatedInstance.ps1 -Force` (regrava o ini com as portas do json) |
| `apo_<nome>` ausente | **BROKEN** | `New-IsolatedInstance.ps1 -Force` (recopia o RPO base) |
| porta TCP do json colide com outra instancia | **BROKEN** | Ver tabela de portas abaixo; realocar com `-TcpPort/-RestPort/-WebAppPort` + `-Force` |
| instancia PARADA (porta TCP fechada) | **OK, informativo** | Nao e erro: ela sobe on-demand no proximo `/tlpp-build`/`/tlpp-test` |
| framework desatualizado no RPO da instancia | **WARNING** | Oferecer recompile (abaixo) |

Conflito de portas - reservas declaradas por TODAS as instancias da maquina:

```powershell
# Glob, nao lista fixa: instancia nova de outro projeto aparece sozinha.
$binRoot = Join-Path $gcfg.ProtheusRoot 'Protheus\bin'
Get-ChildItem $binRoot -Directory -Filter 'appserver_*' | ForEach-Object {
    $ini = Join-Path $_.FullName 'appserver.ini'
    if (Test-Path $ini) { Write-Host "$($_.Name): $((Select-String -Path $ini -Pattern '^Port=' ).Line -join ' ')" }
}
```
Duas instancias com a MESMA porta = a segunda a subir falha (ou pior, uma
responde no lugar da outra). Nesta maquina, `1268/8401` = AppServer dev e
`1269/8402/8099` = DENK - **nenhum dos dois pode ser realocado**.

**Framework desatualizado na instancia (oraculo RPO, #33)**

O RPO da instancia e proprio, entao o framework compilado la envelhece sozinho
quando o plugin e atualizado. Detecte comparando o `dataFonte` que o RPO
registrou com o mtime dos fontes do plugin:

```powershell
. "$PLUGIN_ROOT\runner\BuildCache.ps1"
$fw = Get-ChildItem (Join-Path $PLUGIN_ROOT 'src'), (Join-Path $PLUGIN_ROOT 'mocks') `
      -Recurse -Include '*.tlpp' -File -ErrorAction SilentlyContinue
# Contra o BaseUrl da INSTANCIA ($pcfg, nao $gcfg)
$stat = Get-RpoApoStat -Config $pcfg -FileNames ($fw | ForEach-Object { $_.Name })
if ($null -eq $stat) {
    # REST fora do ar (instancia parada / restart) - inconclusivo, NAO e falha
} else {
    $velhos = $fw | Where-Object {
        -not (Test-ApoFresh -ApoEntry $stat[$_.Name.ToUpperInvariant()] -DiskMtime $_.LastWriteTime)
    }
}
```

Se `$velhos` nao esta vazio, ofereca (nao faca sozinho):

```
A instancia <NOME> tem <N> fonte(s) do framework desatualizado(s) no RPO:
  <lista>
Recompilar agora? Isso derruba o HTTPREST DESTA instancia por ~70s
(as outras nao sentem nada).
```

Comando do recompile - fontes do PLUGIN com a config do PROJETO:

```powershell
& "$PLUGIN_ROOT\runner\Invoke-TlppBuild.ps1" -ProjectRoot $pcfgDir -File ($velhos | ForEach-Object { $_.FullName })
```

### Reporte do diagnostico

Apresente em PT-BR formatado:

```
Diagnostico tlpp-tdd:

  [1] Config global              C:\Users\<u>\.claude\tlpp-tdd\config.ps1   [OK | FALTA]
  [2] Config valida (User,BaseUrl)                                          [OK | BROKEN: <erro>]
  [3] ProtheusRoot               <path>                                     [OK | BROKEN: nao existe]
  [4] advpls.exe                 <path>                                     [OK | BROKEN: nao existe]
  [5] Includes                   <path>                                     [OK | BROKEN: nao existe]
  [6] AppServer REST             <baseUrl>/runner/ping                      [OK | BROKEN: <http_code>]
  [7] Framework no RPO           u_tecAssertReset                           [OK | BROKEN: <funcao_nao_existe|runtime>]
  [8] DBAccess                   dbaccess64.exe rodando                     [OK | FALTA - warning]
  [9] SQL Server                 sqlcmd no <SqlInstance>                    [OK | FALTA - warning]
 [10] Instancia isolada          appserver_<nome> TCP=<n> REST=<n>          [n/a | OK | OK (parada) | BROKEN: <motivo> | WARNING: framework velho]

Resumo: <X/10 OK, Y bloqueantes, Z warnings>
```

## Phase 2 - Triage

Baseado no diagnostico, escolhe caminho:

| Estado | Acao |
|---|---|
| 9/9 OK (+ 10 n/a ou OK) | Reporta "tudo OK, voce nao precisa rodar nada" + exit |
| 7-8/9 OK, so warnings | "Setup ok pra unit tests; falta DBAccess/SQL pra integracao" + exit ou guia |
| Check 1 FALTA | Vai pra Phase 3 (Setup completo) |
| Checks 2-7 BROKEN, isolados | Phase 4 (Fix targeted) - aplica so o que falta/quebrou |
| Check 10 BROKEN/WARNING | Phase 4 - conserta so a instancia do projeto; NAO refaz o setup da maquina |
| >3 itens BROKEN | Pergunta "estado bem degradado - quer redo o setup do zero?" |

Mostre plano ao user e espere `pode/sim/vai`. Sempre.

## Phase 3 - Setup completo (caminho do user novo)

Use isso quando check 1 FALTA. Sequencia:

### 3.1 Detectar ambiente

```powershell
$envInfo = & "$RUNNER_INSTALL\Test-Environment.ps1"
```

Forma EXATA do objeto (nao invente campo - propriedade inexistente vira `$null`
silencioso e o config sai incompleto):

```
Tds          = { Found, Path, Version, AdvplsPath }
ProtheusRoot = '<path>'            # string na raiz; NAO existe $envInfo.Protheus.Root
AppServer    = { Found, Pid, Dir, Port, Ini, RpoPath }   # Port = [HTTPREST] do ini
DBAccess     = { Found, Pid, Port, Ini, Root }
Sql          = { Found, Instances, WinAuthWorks }        # Instances = [ {Name, Instance, Status} ]
Issues       = [ '<problema>', ... ]
```

Mostra resultado formatado em PT. Se issues bloqueantes, lista e pede pro user resolver.

### 3.2 Pergunta: AppServer dedicado vs reusar

```
O framework precisa de AppServer com rotas REST /runner/* habilitadas
e fontes tec* compilados no RPO. Duas opcoes:

  [A] Reusar AppServer dev existente (RECOMENDADO no setup)
      Compila framework no RPO atual + adiciona [HTTPREST] no .ini
      do AppServer principal (com backup). Funcional, mas o Ctrl+F9
      no TDS pode sobrescrever compilacoes do framework
      ocasionalmente, exigindo recompilar.

  [B] Instancia dedicada POR PROJETO (isolamento opt-in)
      Nao e feita aqui: e o /tlpp-tdd-project-init que oferece, via
      New-IsolatedInstance.ps1 - arvore appserver_<nome> + RPO proprio,
      portas alocadas por sondagem (nunca fixas). Compilar la nao
      derruba o HTTPREST dos outros projetos. Custo: ~1,45GB de disco
      por instancia (o tttm120.rpo PRECISA ser copiado - RPO
      compartilhado entre instancias que compilam nao funciona, o
      build exige lock exclusivo) + ~500MB de RAM ligada.

  Default: [A] agora; [B] depois, por projeto que precisar.
```

### 3.3 Instancia dedicada (modo B)

Nao ha passo manual aqui: aponte o user pro `/tlpp-tdd-project-init` do projeto
que quer isolamento, que oferece a criacao via `runner/install/New-IsolatedInstance.ps1`
(portas sondadas, ini gerado a partir do de origem, `-DryRun` disponivel).
Detalhes de custo/arquitetura: `docs/ARCHITECTURE.md` secao 4.1.

### 3.4 Modo A: reusar

```powershell
& "$RUNNER_INSTALL\Set-AppServerRest.ps1" `
    -AppServerIniPath $envInfo.AppServer.Ini `
    -RestPort $envInfo.AppServer.Port `
    -Environment 'DESENVOLVIMENTO'
```

`AppServer.Port` pode vir `$null` quando o ini ainda nao tem `[HTTPREST]` - nesse
caso passe a porta escolhida com o user (default 8401).

Pede restart do AppServer.

### 3.5 Config global

```powershell
& "$RUNNER_INSTALL\Write-GlobalConfig.ps1" -Settings @{
    User             = 'admin'
    Password         = $adminPwd            # Read-Host -AsSecureString -> ConvertTo plain
    ProtheusRoot     = $envInfo.ProtheusRoot
    AdvplsPath       = $envInfo.Tds.AdvplsPath
    Server           = 'localhost'
    Port             = $compilePort         # porta TCP [GENERAL] do AppServer reusado (modo A)
    BaseUrl          = "http://localhost:${restPort}/rest"
    Environment      = 'DESENVOLVIMENTO'
    SqlInstance      = ($envInfo.Sql.Instances | Where-Object { $_.Status -eq 'Running' } | Select-Object -First 1).Instance
    DbAccessHost     = 'localhost'
    DbAccessPort     = $envInfo.DBAccess.Port
    DbAccessIniPath  = $envInfo.DBAccess.Ini       # usado por /tlpp-tdd-project-init
    Includes         = (Join-Path $envInfo.ProtheusRoot 'Protheus\include')
    AppServerMode    = if ($modeIsDedicated) { 'dedicated' } else { 'reuse' }
    AppServerIniPath = $targetOrSourceIni
}
```

`BaseUrl User Password ProtheusRoot AdvplsPath Server Port Environment` sao
OBRIGATORIAS: passar qualquer uma nula/vazia faz o script FALHAR (throw) sem
gravar - de proposito, config incompleto quebrava so depois, no primeiro
`/tlpp-test`. Se a deteccao nao achou um desses valores, pergunte ao user antes
de chamar. As demais chaves seguem opcionais (nula = ignorada, com aviso).

### 3.6 Compile framework

```powershell
& "$RUNNER_INSTALL\Install-Framework-Global.ps1" -PluginRoot $PLUGIN_ROOT
```

### 3.7 Smoke

```powershell
& "$RUNNER_INSTALL\Invoke-Smoke.ps1"
```

### 3.8 Relatorio final

Mesma estrutura da `Phase 5 final report` abaixo.

## Phase 4 - Fix targeted (caminho do doctor)

Aplica fixes pontuais baseado em quais checks falharam:

### Check 2 BROKEN (config nao parses)
- Mostra erro
- Pergunta: "restaurar de backup mais recente em ~/.claude/tlpp-tdd/" ou "recriar do zero?"
- Se backup existe: copy + reparse
- Se recriar: vai pra Phase 3.5 (Write-GlobalConfig)

### Check 3 BROKEN (ProtheusRoot path morto)
```powershell
$envInfo = & "$RUNNER_INSTALL\Test-Environment.ps1"
& "$RUNNER_INSTALL\Write-GlobalConfig.ps1" -Settings @{
    ProtheusRoot = $envInfo.ProtheusRoot
    Includes     = (Join-Path $envInfo.ProtheusRoot 'Protheus\include')
} -Mode Merge
```

### Check 4 BROKEN (advpls nao existe)
```powershell
$envInfo = & "$RUNNER_INSTALL\Test-Environment.ps1"
& "$RUNNER_INSTALL\Write-GlobalConfig.ps1" -Settings @{
    AdvplsPath = $envInfo.Tds.AdvplsPath
} -Mode Merge
```

### Check 5 BROKEN (Includes invalido)
Como Check 3 - deriva de ProtheusRoot.

### Check 6 BROKEN, HTTP 0 / connection refused
- AppServer nao esta rodando.
- Mostra: "Inicie o AppServer em <AppServerIniPath ou inferido>. Comando exemplo: `cd <dir> && .\appsrvwin64.exe -console -ini=appserver.ini`. Quando subir, me responda 'pronto'."
- Apos 'pronto', re-roda check 6.

### Check 6 BROKEN, HTTP 401/403
- Senha errada.
- Re-pergunta admin password.
- Write-GlobalConfig -Merge.
- Re-roda check 6.

### Check 6 BROKEN, HTTP 404
- `[HTTPREST]` nao registrado.
- `Set-AppServerRest.ps1` + pede restart.

### Check 7 BROKEN (framework nao no RPO)
```powershell
& "$RUNNER_INSTALL\Install-Framework-Global.ps1" -PluginRoot $PLUGIN_ROOT
```

### Checks 8/9 FALTA
So instrucoes - "DBAccess (`dbaccess64.exe`) precisa estar rodando pra integracao. Sobe manualmente em <dir/dbaccess>". Skill nao inicia processos do user.

### Check 10 BROKEN (instancia isolada quebrada)

Sempre mostre o que vai acontecer antes. Nunca apague `apo_<nome>` - e o RPO com
os objetos compilados do projeto.

```powershell
$isoArgs = @{ ProjectRoot = $pcfgDir; Name = $pcfg.ProjectName; ProtheusRoot = $gcfg.ProtheusRoot }
if ($gcfg.DbAccessPort) { $isoArgs.TopPort = [int]$gcfg.DbAccessPort }

& "$RUNNER_INSTALL\New-IsolatedInstance.ps1" @isoArgs -Force -DryRun   # mostra o plano
# confirma, e so entao:
& "$RUNNER_INSTALL\New-IsolatedInstance.ps1" @isoArgs -Force
```

`-Force` regrava o `appserver.ini` (com backup) reaproveitando as portas ja
registradas no json, recopia o RPO base se faltar e **preserva** o `custom.rpo`.

Em conflito de porta, escolha portas novas explicitamente e avise que a
instancia precisa ser reiniciada (o processo velho continua com as antigas):

```powershell
& "$RUNNER_INSTALL\New-IsolatedInstance.ps1" @isoArgs -Force -TcpPort 1275 -RestPort 8410 -WebAppPort 8105
```

### Check 10 = instancia PARADA

Nao e defeito - o desenho e on-demand, sem auto-stop. Diga isso e siga:
"A instancia `<NOME>` esta parada. Ela sobe sozinha no proximo `/tlpp-build` ou
`/tlpp-test` deste projeto (`-console`, janela minimizada). Nada a consertar."

### Check 10 WARNING (framework velho no RPO da instancia)

Ofereca o recompile do Phase 1 check 10. Nunca recompile sem confirmar: custa
~70s de HTTPREST da instancia.

Apos cada fix, **re-roda o diagnose** e mostra novo estado. Quando 7/9 OK, parado.

## Phase 5 - Relatorio final

```
=== tlpp-tdd OK ===

Modo:               <Dedicado em appserver_tdd:8402 | Reusar AppServer principal:8401>
Config global:      C:\Users\<user>\.claude\tlpp-tdd\config.ps1
Framework no RPO:   tecAssert, tecWrap, tecMock, tecRunrApi, tecRunrCtx, tecRefl
Smoke test:         <X/3 OK>
Instancia isolada:  <n/a (projeto usa o compartilhado) | appserver_<nome> TCP=<n> REST=<n> - parada, sobe on-demand>
Warnings:           <ex: DBAccess nao rodando - precisa subir pra integracao>

Proximo passo:
  Pra qualquer projeto ADVPL/TLPP seu:
    /tlpp-build src/tecMinha.tlpp
    /tlpp-test  u_test_minha

  Pra integracao com banco em projeto especifico:
    /tlpp-tdd-project-init    (cria PROTHEUS_TST_<projeto> + alias + .tlpp-tdd.json)

  Pra rodar diagnostico de novo no futuro:
    /tlpp-tdd-setup           (re-executa essa skill - idempotente, so faz o que falta)
```

## Anti-patterns

| Erro | Sintoma | Fix |
|---|---|---|
| Sair direto pro Phase 3 sem rodar diagnose | Refaz tudo, sobrescreve config existente | SEMPRE diagnose primeiro |
| Logar senha no terminal | Vaza em transcript | Read-Host -AsSecureString + mask |
| Iniciar processo do user (AppServer) automatic | Pode dar conflito; user perde controle | Sempre INSTRUCT pro user iniciar manualmente |
| Pular restart AppServer apos mudar .ini | REST ainda nao tem rotas novas | Sempre esperar "pronto" antes do smoke |
| Output em ingles | Atrito | Sempre PT-BR ao user |
| Reusar AppServer sem avisar do conflito Ctrl+F9 | Surpresa quando RPO "perde" framework | Explicit no plano do Modo A |
| Sobrescrever config existente sem Merge | Apaga campos que user tinha | Write-GlobalConfig.ps1 default = Merge |
| Tratar instancia isolada parada como falha | User "conserta" o que nao esta quebrado | On-demand: sobe no proximo build/test |
| Apagar `apo_<nome>` pra "consertar" a instancia | Perde o RPO compilado do projeto | `-Force` recria ini/RPO base e preserva o custom.rpo |
| Realocar porta de instancia alheia (ex: DENK 1269/8402/8099) | Derruba ambiente de outro projeto | So mexer em `appserver_<nome>` do projeto atual |
| Recompilar framework na instancia sem avisar | ~70s de REST fora sem o user esperar | Sempre oferecer e aguardar OK |

## Referencias

- `$RUNNER_INSTALL\Test-Environment.ps1` - detect read-only
- `$RUNNER_INSTALL\Set-AppServerRest.ps1` - rotas REST no .ini com backup
- `$RUNNER_INSTALL\Write-GlobalConfig.ps1` - ~/.claude/tlpp-tdd/config.ps1
- `$RUNNER_INSTALL\Install-Framework-Global.ps1` - compila framework no RPO
- `$RUNNER_INSTALL\New-IsolatedInstance.ps1` - instancia dedicada por projeto (#34)
- `$PLUGIN_ROOT\runner\InstanceControl.ps1` - `Start-IsolatedInstanceIfNeeded` / `Test-TlppPortOpen`
- `$RUNNER_INSTALL\Invoke-Smoke.ps1` - validacao final
- `$RUNNER_INSTALL\Backup-Ini.ps1` - helper de backup
