# tlpp-tdd - arquitetura, fluxo, possibilidades e limitacoes

Documento de referencia completo apos o redesign global de 2026-05-15.

## 1. Visao geral

`tlpp-tdd` e um **Claude Code plugin global** que entrega:

1. Um **framework de teste TDD** (`src/tec*.tlpp` + `mocks/tecMock.tlpp`) compilado **UMA VEZ** no RPO do AppServer dev — fica disponivel pra qualquer projeto da maquina.
2. **Slash commands** (`/tlpp-build`, `/tlpp-test`, `/tlpp-exec`, `/tlpp-table`, `/tlpp-tdd`, `/tlpp-tdd-setup`, `/tlpp-tdd-project-init`) que rodam scripts PowerShell do plugin contra o cwd do projeto.
3. **Skill `tlpp-tdd`** pra loop autonomo red->green->refactor com brainstorming sistematico de edge cases.
4. **Skill `tlpp-tdd-setup`** (machine-once + doctor mode) pra configurar/diagnosticar/consertar.
5. **Skill `tlpp-tdd-project-init`** pra setup per-project (so banco + alias + `.tlpp-tdd.json`).

```
+--------------------------------------------------------------+
|                          MAQUINA                              |
|  +-------------------+    +----------------------------+      |
|  | AppServer dev     |    | ~/.claude/tlpp-tdd/         |     |
|  |  port 8401 REST   |    |   config.ps1                |     |
|  |  port 1268 TDS    |    |    User/Password            |     |
|  |  RPO compartilhado|<-->|    ProtheusRoot/AdvplsPath  |     |
|  |   tec*.tlpp       |    |    SqlInstance/DBAccess     |     |
|  |   mocks/tecMock   |    +----------------------------+      |
|  +-------------------+                                        |
|                                                               |
|  +-------------------+  +-------------------+ +-------------+ |
|  | projeto A         |  | projeto B         | | projeto C   | |
|  | .tlpp-tdd.json    |  | .tlpp-tdd.json    | | (sem json)  | |
|  | "name": "PROJA"   |  | "name": "PROJB"   | |             | |
|  | src/, test/       |  | src/, test/       | | src/, test/ | |
|  |                   |  |                   | |             | |
|  | PROTHEUS_TST_PROJA|  | PROTHEUS_TST_PROJB| | (sem banco) | |
|  +-------------------+  +-------------------+ +-------------+ |
+--------------------------------------------------------------+
```

## 2. Setup machine-once (`/tlpp-tdd-setup`)

Rodado **uma vez por maquina**. Idempotente — re-rodar funciona como doctor.

### Fluxo

```
1. Diagnose (9 checks, sempre roda)
   1.1 Config global existe?           ~/.claude/tlpp-tdd/config.ps1
   1.2 Config parses + User/Password/BaseUrl
   1.3 ProtheusRoot valido
   1.4 AdvplsPath aponta pra .exe que existe
   1.5 Includes valido
   1.6 AppServer REST /runner/ping responde
   1.7 Framework no RPO (u_tecAssertReset == .T.)
   1.8 DBAccess rodando (warning)
   1.9 SQL acessivel (warning)

2. Triage
   - 9/9 OK -> exit
   - check 1 FALTA -> setup completo
   - 2-7 isolados BROKEN -> fix targeted
   - varios BROKEN -> oferece redo

3. Setup completo (caminho user novo)
   3.1 Test-Environment.ps1 (read-only detect)
   3.2 Pergunta: AppServer dedicado vs reusar
   3.3 Se dedicado: copy <ProtheusRoot>/bin/appserver_rest -> appserver_tdd
       + adjust ports (REST 8402, compile 1269)
   3.4 Set-AppServerRest.ps1 - configura [HTTPREST] com backup
   3.5 Write-GlobalConfig.ps1 - gera ~/.claude/tlpp-tdd/config.ps1
   3.6 Install-Framework-Global.ps1 - compila framework no RPO
   3.7 Invoke-Smoke.ps1 - smoke test

4. Fix targeted (caminho doctor)
   - Path morto -> re-detecta + Write-GlobalConfig -Merge
   - HTTP 0 -> instrui user a subir AppServer
   - HTTP 401 -> re-pergunta senha
   - HTTP 404 -> Set-AppServerRest.ps1
   - Framework fora do RPO -> Install-Framework-Global.ps1
```

### O que muda na maquina

| Recurso | Mudanca | Backup |
|---|---|---|
| `<ProtheusRoot>/bin/appserver_*/appserver.ini` | `[HTTPREST]` (Port=8401/8402, Enable=1, Environment=DESENVOLVIMENTO) + `[GENERAL] ConsoleLog=1` | `.bak.<timestamp>` |
| `<ProtheusRoot>/bin/appserver_tdd/` (Modo Dedicado) | Copia ~80MB de appserver_rest | n/a (dir novo) |
| AppServer RPO | Compila `tecAssert`, `tecRunrApi`, `tecRunrCtx`, `tecWrap`, `tecRefl`, `tecMock` | n/a (RPO file) |
| `~/.claude/tlpp-tdd/config.ps1` | Cria com credenciais + paths | nao tem auto-backup (Write-GlobalConfig -Mode Merge preserva chaves) |

## 3. Setup per-project (`/tlpp-tdd-project-init`)

Rodado **uma vez por projeto** que vai usar testes de integracao com banco.

### Fluxo

```
1. Pre-flight: ~/.claude/tlpp-tdd/config.ps1 existe?
2. Pergunta nome do projeto (regex [A-Z][A-Z0-9_]{0,19})
2b. Pergunta ISOLAMENTO (opt-in, default nao) e, se sim, o seed do custom.rpo
    (limpo vs copiar o do ambiente dev) - detalhes na secao 4.1
3. New-TestDatabase.ps1 - cria PROTHEUS_TST_<NOME> + schema + grants
4. Set-DBAccessAlias.ps1 - adiciona [MSSQL/PROTHEUS_TST_<NOME>] no dbaccess.ini
5. Write-ProjectConfig.ps1 - grava <projeto>/.tlpp-tdd.json com {"name": "<NOME>"}
5b. (se isolado) New-IsolatedInstance.ps1 - arvore + RPO + ini + isolation no json,
    sobe a instancia e compila o framework do plugin NELA, smoke /runner/ping
6. Pede restart do DBAccess
7. Smoke: chama u_tecCtxTestDbAlias - deve retornar MSSQL/PROTHEUS_TST_<NOME>
```

### O que muda no projeto

| Recurso | Mudanca |
|---|---|
| `<projeto>/.tlpp-tdd.json` | Arquivo novo: `{"name": "MEUPROJ"}` (+ `isolation` se isolado) |
| SQL Server | Banco novo `PROTHEUS_TST_MEUPROJ` |
| `dbaccess.ini` | Secao `[MSSQL/PROTHEUS_TST_MEUPROJ]` (com backup) |
| (so se isolado) `<ProtheusRoot>\Protheus\bin\appserver_<nome>\` | Instancia nova (~485MB) |
| (so se isolado) `<ProtheusRoot>\protheus\apo_<nome>\` | RPO proprio (~960MB) |

**ZERO arquivos do framework copiados.** Projeto fica com:
- `.tlpp-tdd.json` (1 arquivo de 30 bytes)
- `src/` + `test/` (que voce cria)

## 4. Fluxo de uso normal (TDD loop)

Depois do setup:

```
1. /tlpp-tdd "criar funcao tecMinha que ..."
   -> Invoca skill tlpp-tdd
   -> Skill gera teste em test/unit/tecMinhaTst.tlpp:
        @TestFixture()
        user function test_tecMinha()
            u_tecAssertReset()
            u_tecAssertEq(...)
        return u_tecAssertsOk()
   -> /tlpp-test u_test_tecMinha: compila o teste + roda -> result=.F. (red)
   -> Skill implementa src/tecMinha.tlpp
   -> /tlpp-test u_test_tecMinha: recompila + roda -> result=.T. (green)
   -> Skill rerodar testes vizinhos (sanity)
   -> Loop pra proxima edge case ate cobrir tudo
```

### Cascade de config

Toda invocacao do `Invoke-TlppRunner.ps1` ou `Invoke-TlppBuild.ps1` carrega `runner.config.ps1` que cascadeia:

```
1. Defaults neutros               (em runner/runner.config.ps1)
2. ~/.claude/tlpp-tdd/config.ps1  (global per-machine)
3. <cwd>/.tlpp-tdd.json           (per-project: name -> testDb derivacao)
4. <plugin>/runner/runner.config.local.ps1  (legacy back-compat, se existir)
```

Ultimo a setar vence. Defaults nunca sobrescrevem.

### Fields per-project (`.tlpp-tdd.json`)

```json
{
  "name": "MEUPROJ",                       // obrigatorio. Deriva PROTHEUS_TST_MEUPROJ
  "testDb": "PROTHEUS_CUSTOM_NAME",        // opcional. Override do banco derivado
  "baseUrl": "http://127.0.0.1:8402/rest", // opcional. Override do BaseUrl global
  "schemaPath": "sql/schema.sql",          // opcional. Schema SQL versionado do projeto (#21)
  "isolation": {                           // opcional. Instancia dedicada (#34) - ver secao 4.1
    "tcpPort": 1270,
    "restPort": 8403,
    "webAppPort": 8100
  }
}
```

### Schema SQL versionado do projeto (`schemaPath`)

`/tlpp-table` mantem as tabelas permanentes de teste num arquivo SQL do PROJETO
(nao do plugin). Resolucao pelo cascade (`$TlppRunner.SchemaPath`):

1. `schemaPath` do `.tlpp-tdd.json` (relativo resolve contra a raiz do projeto);
2. senao, `runner\sql\02-create-schema.sql` **se existir** (layout do proprio repo tlpp-runner);
3. senao, default `<projeto>\sql\schema.sql` (criado pelo `/tlpp-table` no primeiro uso).

O `db-setup.ps1` do plugin aplica o schema do framework e depois o do projeto,
ambos no banco do cascade (`$TlppRunner.TestDb`). O banco de projeto
(`PROTHEUS_TST_<NOME>`) precisa existir antes - quem cria e o
`/tlpp-tdd-project-init`.

## 4.1 Isolamento por projeto (opt-in, #34)

Por padrao todos os projetos da maquina compartilham o AppServer dev (RPO e
portas). Isso e simples e barato, mas tem um custo real: **qualquer compilacao
derruba o HTTPREST** (#29) ate o proximo ciclo do `[ONSTART] RefreshRate` (~13s
com `RefreshRate=2`, ate ~2 min com 120) — e derruba pra todo mundo. Quem compila
com frequencia atrapalha quem esta so rodando teste.

O isolamento resolve dando ao projeto uma instancia inteira sua.

### Quando usar

| Situacao | Recomendacao |
|---|---|
| Um projeto ativo na maquina, TDD tranquilo | **Nao isolar.** Compartilhado basta |
| Dois ou mais devs/agentes compilando na mesma maquina | **Isolar** o mais ativo |
| Projeto com ponto de entrada homonimo de outro (`MT410ROT.tlpp`) | **Isolar** - RPO separado acaba com a briga de slot (ver `runner/BuildCache.ps1`) |
| Projeto que precisa de environment/dicionario proprio | **Isolar** |
| Disco apertado (< 3 GB livres) | Nao isolar - sao ~1,45 GB por instancia |

### Custo por instancia

| Recurso | Custo | Por que |
|---|---|---|
| Disco - arvore do AppServer | ~485 MB | copia de `appserver_rest` (binarios, libs) |
| Disco - RPO padrao | ~960 MB | `tttm120.rpo` **precisa ser copiado**. Hardlink foi REFUTADO no spike: servir funciona, mas compilar falha com lock (`cannot access the file ... DEFAULT`) |
| Disco - `custom.rpo` | cresce com o projeto | criado pelo proprio AppServer na 1a compilacao |
| RAM | ~500 MB | so enquanto a instancia estiver ligada |
| **Total disco** | **~1,45 GB** | |

Compartilhados (NAO duplicam): `protheus_data` (RootPath), DBAccess (7892),
License Server (5555), `Protheus\include`.

### Layout

```
<ProtheusRoot>\
  Protheus\bin\appserver_rest\      <- AppServer dev compartilhado (1268/8401)
  Protheus\bin\appserver_denk\      <- instancia do projeto DENK    (1269/8402/8099)
  Protheus\bin\appserver_<nome>\    <- instancia nova: exe + appserver.ini + console.log
  protheus\apo\                     <- RPO compartilhado (tttm120.rpo + custom.rpo)
  protheus\apo_<nome>\              <- RPO da instancia (copia do tttm120 + custom proprio)
  protheus_data\                    <- COMPARTILHADO (RootPath, StartPath=\system\)
```

O nome do environment e o nome do projeto em MAIUSCULAS; os diretorios usam o
nome em minusculas.

### Portas

Tres por instancia, alocadas na criacao e gravadas no `.tlpp-tdd.json`:

| Papel | Base da busca | Uso |
|---|---|---|
| TCP | 1270 | `advpls cli` (compilacao) e sonda de "instancia viva" |
| HTTPREST | 8403 | `/rest/runner/{ping,func,exec}` |
| WEBAPP | 8100 | WebApp/MPP (nao usado pelo framework, mas o ini exige) |

A sondagem pula porta em uso (bind de teste) **e** porta reservada no
`appserver.ini` de outra instancia — instancia desligada tambem tem direito a
sua porta. Nesta maquina, `1268/8401` (dev) e `1269/8402/8099` (DENK) sao
intocaveis.

### Ciclo de vida

- **On-demand**: `runner/InstanceControl.ps1` (`Start-IsolatedInstanceIfNeeded`)
  e chamado por `Invoke-TlppBuild.ps1` e `Invoke-TlppRunner.ps1`. Se a porta TCP
  nao aceita conexao, sobe o processo e espera a porta REST responder (ate 90s).
- **Sempre com `-console`.** Sem isso o AppServer sai em silencio (medido).
  Janela minimizada.
- **Sem auto-stop.** Derrubar no fim de cada comando pagaria o boot inteiro a
  cada teste. Pare na mao quando quiser a RAM de volta.
- **No-op silencioso** pra projeto sem `isolation` - o caminho comum nem percebe
  que o InstanceControl existe.

### Como o cascade enxerga

`runner.config.ps1`, ao ver `isolation` no `.tlpp-tdd.json`, deriva:

| Chave | Valor derivado |
|---|---|
| `BaseUrl` | `http://127.0.0.1:<restPort>/rest` |
| `Port` | `<tcpPort>` (o advpls compila nela) |
| `Environment` | `<NAME em maiusculas>` |
| `RpoCustom` | `<ProtheusRoot>\protheus\apo_<nome>\custom.rpo` |
| `ConsoleLogPath` | `<ProtheusRoot>\Protheus\bin\appserver_<nome>\console.log` |
| `IsolationBinDir` / `IsolationApoDir` | paths da instancia |

Um `baseUrl` explicito no mesmo json vence o derivado (override deliberado).
Sem `name`, o isolamento e ignorado com warning — o nome e o que deriva
environment, bin e RPO. `TestDb` continua `PROTHEUS_TST_<NOME>` como sempre.

### Framework no RPO da instancia

O RPO e novo: `u_tecAssert*`, `u_tecMk*`, `u_tecTstConn` nao existem la. O
`/tlpp-tdd-project-init` compila os fontes do **plugin** com a config do
**projeto**:

```powershell
& "$PLUGIN\runner\Invoke-TlppBuild.ps1" -ProjectRoot <projeto> -File <src\tec*.tlpp + mocks\*.tlpp do plugin>
```

Como o RPO da instancia envelhece sozinho quando o plugin e atualizado, o doctor
(`/tlpp-tdd-setup`, check 10) compara via oraculo RPO (#33) o `dataFonte` de cada
`tec*` no RPO com o mtime do fonte no plugin, e oferece recompilar.

### Compilacao explicita (sem hook de build)

O plugin NAO registra hook de recompilacao ao salvar. Motivo: toda escrita no
RPO derruba o HTTPREST por alguns segundos (secao Limitacoes), entao compilar a cada
Edit/Write penaliza o loop inteiro. O agente decide quando compilar, via
`/tlpp-build <arquivo>` ou `/tlpp-test` (que compila antes de rodar) - ambos
passam pelo guard do oraculo RPO/cache e pulam fontes inalterados.

## 5. Possibilidades

### O que da pra fazer

- **TDD funcao-a-funcao** sem TDS-VSCode aberto, sem Ctrl+F9 manual.
- **Mocks por wrapper**: codigo de producao chama `u_tecDbSeekFld`, `u_tecQryFirst`, `u_tecHttpReq` etc — testes substituem em memoria via `u_tecMkSql`, `u_tecMkBdSeek`, `u_tecMkHttp`.
- **Asserts customizados** (`u_tecAssert*`) que registram via REST de forma confiavel — `return u_tecAssertsOk()` reflete o resultado real.
- **Testes de integracao com banco isolado** (`PROTHEUS_TST_<projeto>`) - schema Z_TST_* + helpers de seed/truncate.
- **Tabelas ad-hoc** dentro de teste via `u_tecTstCreateTable`/`u_tecTstDropTable` (sem precisar SQL DDL no projeto).
- **Multiplos projetos na mesma maquina**: cada um com seu banco PROTHEUS_TST_<nome>, sem conflito de namespace TLPP (prefixo `tec` ja separa).
- **Doctor mode**: re-rodar `/tlpp-tdd-setup` quando algo quebrar - diagnostico classifica OK/FALTA/BROKEN com fix concreto.
- **Override per-project via JSON**: `testDb`, `baseUrl` overrideaveis sem mexer no global.
- **PROBAT integration**: `tlpp.probat.run` + suite via `Invoke-TlppRunner.ps1 -Function tlpp.probat.run -ArgString '"type:suite","unit"' -Junit`.
- **Reflection helpers** em `tecRefl.tlpp` pra introspeccao runtime.
- **HTTP testing** em codigo via `u_tecHttpReq` + asserts HTTP (`u_tecAssertHttpStatus`, `u_tecAssertHttpJsonField`).

### Convencoes recomendadas

- **Prefixo `tec`** em fontes do framework + projetos (3 chars, evita colisao).
- **Project-specific prefix em tabelas**: `Z_TST_PROJA_*`, `Z_TST_PROJB_*` pra evitar conflito se varios projetos rodam contra o mesmo AppServer.
- **Testes em `test/unit/`** (sem banco) e `test/integracao/` (com banco). Skill `tlpp-tdd` segue essa divisao.
- **`user function` sempre**, `function` regular precisa token JWT.

## 6. Limitacoes conhecidas

### Bloqueantes

- **`function` regular nao compila** sem token JWT do portal TOTVS. Sempre use `user function` ou `static function`.
- **`namespace` suprime alias `u_*` global**: arquivos com `namespace x.y.z` registram como `x.y.z.u_funcao` em vez de `u_funcao`. `/runner/exec` nao acha. Solucao: NAO usar namespace em modulos cujas funcoes sao chamadas externamente. Doc em CLAUDE.md > "Estilo TLPP".
- **`as anytype` nao existe**. Omitir `as` em parametros genericos.
- **`:= nil as <tipo>`** rejeitado por typing estrito. Inicializar com valor neutro.
- **Toda compilacao derruba o HTTPREST** (issue #29). O AppServer executa "Stopping all HTTP servers"; com `BuildKillUsers=1` o job `HTTP_START` do `[ONSTART]` morre, e o REST so volta no proximo ciclo do `[ONSTART] RefreshRate` - o intervalo em que o AppServer confere e relanca os jobs. O setup (template em `runner/install/IniIO.ps1`, `Set-AppServerRest.ps1`, `New-IsolatedInstance.ps1`) grava `RefreshRate=2`: o build leva ~7-8s e o REST responde ~5s depois do fim dele (janela total ~13s). Ini com `RefreshRate=120` deixa o REST fora ate ~2 min (~92s apos o fim do build); `/tlpp-tdd-setup` (doctor) ou `Set-AppServerRest.ps1` baixa o valor in-place, e o AppServer precisa ser reiniciado. Nao e especifico de `@Get/@Post`: fontes sem annotation derrubam igual, porque o gatilho e a escrita no RPO. `recompile=F` tambem nao evita, e compile que FALHA tambem derruba os HTTP servers. Mitigacoes: `Invoke-TlppBuild.ps1` pula fontes ja no RPO com o mesmo conteudo - guard 0 e o oraculo RPO (#33: `u_tecApoStat`/GetAPOInfo compara dataFonte com mtime do disco, por objeto), fallback e o cache local (`runner/BuildCache.ps1`); `-Force` ignora ambos. `Invoke-TlppRunner.ps1` usa backoff assimetrico - espera ate 180s quando a porta TCP aceita conexao (servidor reiniciando; cobre ini com RefreshRate alto), curta quando recusa (AppServer desligado).
- **Dois AppServers sobre o mesmo `custom.rpo`** (ex. o de desenvolvimento e o `appserver_rest` abertos juntos): a compilacao falha pelos dois com `COMPILEERROR-300 Failed to open repository ... used by another process`. Quando a falha vem pelo AppServer do REST, os HTTP servers dele ja cairam no inicio do build e so voltam reiniciando o AppServer. `Invoke-TlppBuild.ps1` detecta e imprime o diagnostico.
- **Mocks so cobrem codigo que passa pelos wrappers** em `tecWrap.tlpp`. Legado com `DbSelectArea`/`FWRest`/`GetMv` direto precisa refactor pra usar wrapper.
- **`FWRest` chamando proprio AppServer** -> deadlock/crash. Use `u_tecHttpReq` (usa HTTPQuote).
- **`ValType(JsonObject)` retorna `"J"`** nao `"O"`. Use `:hasProperty()` direto.
- **`Empty()` em JsonObject/array crasha** o thread. Use `u_tecAssertEmpty/NotEmpty` (tipo-aware).
- **Asserts custom `u_tecAssert*` nao registram testcase no PROBAT** - PROBAT espera `assertEquals` de `tlpp-probat.th`. Por isso preferimos `/tlpp-test <funcao>` direto via /runner/exec.

### Operacionais

- **Debugger TDS-VSCode segura o RPO** mesmo sem janela aberta - VSCode TOTVS extension mantem language server vivo. `BuildKillUsers=1` no `[General]` do appserver.ini ajuda mas nao mata sessoes de debugger. Fix: restart do AppServer ou fechar VSCode.
- **TDS-VSCode auto-respawn de advpls**: language server da extensao spawn 4 advpls.exe automaticos. Kill-os puro nao adianta (volta em segundos). `BuildKillUsers=1` lida quando podem ser mortos.
- **AppServer dedicado (Modo A do setup) - RPO inicialmente compartilhado com appserver_rest**. Isolamento completo (RPO + AppServer + banco, opt-in POR PROJETO) esta na secao 4.1: `/tlpp-tdd-project-init` oferece, `New-IsolatedInstance.ps1` cria, `InstanceControl.ps1` sobe on-demand.
- **Instancia isolada nao para sozinha** (por desenho: sem auto-stop). Fica ~500MB de RAM ligada ate voce fechar a janela do console.
- **Framework do RPO isolado envelhece sozinho** quando o plugin e atualizado - o RPO nao e compartilhado, entao um recompile no ambiente dev nao chega la. `/tlpp-tdd-setup` (check 10) detecta via oraculo RPO e oferece recompilar.
- **`tttm120.rpo` (~960MB) e COPIADO por instancia** - hardlink refutado no spike: servir funciona, mas compilar falha com lock (`cannot access the file ... DEFAULT`).
- **TCLink no `PROTHEUS_TST_<projeto>` exige permissao** do login DBAccess no banco. `New-TestDatabase.ps1 -Mode Fresh` ja cria grants pra sa + sysdba.
- **Reload de plugin no Claude Code** - apos mudar codigo do plugin (skills, commands, hooks), precisa de `/plugin reload` ou restart do Claude Code pra ver as mudancas.

### Convivencia

- **Skill `tlpp-tdd-setup` no in-repo dev**: `~/.claude/settings.json` tem `"tlpp-tdd@tlpp-local": false` no `.claude/settings.json` deste repo pra evitar conflito com mirror in-repo. So ativa o plugin em outros projetos.
- **PROBAT discovery (`type:suite=X`)** retorna 0/0 com `TESTS_DISCOVERY_MODE=0` no appserver.ini. Solucao: setar `TESTS_DISCOVERY_MODE=1` OU rodar `tlpp.probat.discovery()` antes OU usar `/tlpp-test <funcao>` direto (recomendado).
- **Encoding CP1252** obrigatorio em `.tlpp/.prw/.prx`. Use `mcp__file-tools__write_file` com `encoding=cp1252` ou `[System.IO.File]::WriteAllText($path, $content, [Text.Encoding]::GetEncoding(1252))`.

## 7. Cheatsheet de comandos

### Slash commands (Claude Code)

```
/tlpp-tdd-setup                           # one-shot machine + doctor
/tlpp-tdd-project-init                    # one-shot per-project (DB + .tlpp-tdd.json)
/tlpp-tdd "criar funcao foo que ..."      # loop TDD autonomo
/tlpp-build [arquivo|--all]               # compila via advpls cli
/tlpp-test <funcao|arquivo|suite>         # roda teste por nome (rota rapida)
/tlpp-exec <funcao> [args]                # exec user function arbitraria
/tlpp-table create <nome> "<cols>"        # adiciona tabela permanente ao schema do projeto (schemaPath)
```

### PowerShell scripts (uso direto, fora do Claude Code)

```powershell
# Setup
& "$PLUGIN\runner\install\Test-Environment.ps1"           # detect read-only
& "$PLUGIN\runner\install\Write-GlobalConfig.ps1" -Settings @{...}
& "$PLUGIN\runner\install\Set-AppServerRest.ps1" -AppServerIniPath ... -RestPort 8401
& "$PLUGIN\runner\install\Install-Framework-Global.ps1" -PluginRoot $PLUGIN

# Per-project
& "$PLUGIN\runner\install\New-TestDatabase.ps1" -SqlInstance ... -DbName ... -Mode Fresh
& "$PLUGIN\runner\install\Set-DBAccessAlias.ps1" -DbAccessIniPath ... -DbName ... -SqlInstance ...
& "$PLUGIN\runner\install\Write-ProjectConfig.ps1" -ProjectRoot $proj -Name MEUPROJ

# Per-project - instancia dedicada (#34). -DryRun mostra as portas sem copiar nada.
& "$PLUGIN\runner\install\New-IsolatedInstance.ps1" -ProjectRoot $proj -Name MEUPROJ -ProtheusRoot 'C:\TOTVS\Protheus_241011' -DryRun
& "$PLUGIN\runner\install\New-IsolatedInstance.ps1" -ProjectRoot $proj -Name MEUPROJ -ProtheusRoot 'C:\TOTVS\Protheus_241011' [-SeedCustomFrom <custom.rpo>] [-Force]

# Build/run
& "$PLUGIN\runner\Invoke-TlppBuild.ps1" -All [-WithExamples] [-ProjectRoot $proj]
& "$PLUGIN\runner\Invoke-TlppBuild.ps1" -File 'src/tecMinha.tlpp'
& "$PLUGIN\runner\Invoke-TlppRunner.ps1" -Ping
& "$PLUGIN\runner\Invoke-TlppRunner.ps1" -Function u_test_xxx -Quiet
& "$PLUGIN\runner\Invoke-TlppRunner.ps1" -Function u_test_xxx -CheckExists

# Validation (in-repo dev)
& "$PLUGIN\scripts\plugin\sync.ps1"                       # raiz canonica -> .claude/ mirror
& "$PLUGIN\scripts\plugin\validate.ps1"                   # parse + JSON + frontmatter + schema + drift
```

### Quick start dev in-repo (sem plugin instalado)

Pra trabalhar no proprio repo tlpp-runner sem passar pelo `/tlpp-tdd-setup`
(que e o caminho recomendado - detecta Protheus, configura `[HTTPREST]`,
compila o framework):

```powershell
# 1. Config global minima (NAO commitar - vive fora do repo)
$cfg = "$env:USERPROFILE\.claude\tlpp-tdd\config.ps1"
New-Item -ItemType Directory -Path (Split-Path $cfg -Parent) -Force | Out-Null
@'
$TlppRunner.User         = 'admin'
$TlppRunner.Password     = 'sua_senha'
$TlppRunner.ProtheusRoot = 'C:\TOTVS\Protheus_241011'
$TlppRunner.AdvplsPath   = "$env:USERPROFILE\.vscode\extensions\totvs.tds-vscode-2.0.16\node_modules\@totvs\tds-ls\bin\windows\advpls.exe"
'@ | Out-File $cfg -Encoding utf8

# 2. Com o AppServer REST de pe (porta 8401):
.\runner\Invoke-TlppBuild.ps1 -All            # compila framework + testes
.\runner\Invoke-TlppRunner.ps1 -Ping          # sanity check
.\runner\Invoke-TlppRunner.ps1 -Function u_tecAssertReset -Quiet
```

### Endpoint REST direto

```
POST http://127.0.0.1:8401/rest/runner/exec
Authorization: Basic admin:senha
Content-Type: application/json
Body: {
  "function": "u_test_xxx",
  "argString": "150,\"acme\"",
  "projectName": "MEUPROJ",                     // opcional
  "testDbAlias": "MSSQL/PROTHEUS_TST_MEUPROJ",   // opcional
  "dbAccessHost": "localhost",                  // opcional
  "dbAccessPort": 7890                          // opcional
}
```

## 8. Troubleshooting decision tree

```
/tlpp-build falha?
+- "advpls.exe nao encontrado" -> ~/.claude/tlpp-tdd/config.ps1 AdvplsPath errado
+- "Includes nao encontrado" -> ProtheusRoot errado (deve ter Protheus\include)
+- "[FATAL] @TestFixture not defined" -> falta #include "tlpp-probat.th"
+- "COMPILEERROR-300 Failed to open repository" -> RPO lock (debugger TDS aberto, ou
|    outro AppServer no mesmo custom.rpo -> fechar o outro e reiniciar este)
+- "Regular functions are not allowed" -> use `user function`/`static function`

/tlpp-test falha?
+- "connection refused" -> AppServer REST off OU restartando apos compile
|    (volta no proximo ciclo do [ONSTART] RefreshRate; o wrapper aguarda)
+- HTTP 401 -> senha errada em ~/.claude/tlpp-tdd/config.ps1
+- HTTP 404 funcao_nao_existe -> fonte nao compilou no RPO. Rode /tlpp-build antes
+- HTTP 500 error=runtime -> runner imprime message + pilha (fonte e linha) + FAILs
+- HTTP 500 {"code":500,"message":"Internal Server Error"} -> Break() explicito ou
|    erro que derruba a thread (Empty() sobre JsonObject); so aqui ler console.log
+- result=.F. -> asserts falharam. Ler as linhas "FAIL: ..." da saida do runner

Funcao u_tecCtxXxx nao existe?
+- Modulo tem `namespace` no topo -> remove ou aceita o nome qualificado `<ns>.u_<func>`

Integracao test falha TCLink retorna -35?
+- Alias DBAccess nao registrado. Rode /tlpp-tdd-project-init
+- DBAccess nao recarregou ini apos add do alias. Restart dbaccess64.exe

/tlpp-tdd-setup diz "9/9 OK" mas algo nao funciona?
+- Doctor passa todos checks: estado funcional. Issue pode ser logica do teste (asserts), nao do framework.
```

## 9. Onde tudo vive (cheat dirs)

| Recurso | Path |
|---|---|
| Plugin source (dev) | `C:\Users\<user>\tlpp-runner\` |
| Plugin install (via /plugin install) | `~/.claude/plugins/cache/<plugin-id>/` |
| Plugin global enable | `~/.claude/settings.json` `enabledPlugins["tlpp-tdd@tlpp-local"]` |
| Marketplace local (dev) | `~/.claude/marketplaces/tlpp-local/` (junction pro repo) |
| Config global per-machine | `~/.claude/tlpp-tdd/config.ps1` |
| Memoria de sessoes Claude | `~/.claude/projects/<sanitized-cwd>/memory/` |
| `.tlpp-tdd.json` per-project | Raiz do projeto consumidor |
| Banco de teste | SQL `PROTHEUS_TST_<NOME>` |
| Alias DBAccess | `<ProtheusRoot>\TOTVSDBAccess\windows\dbaccess.ini` secao `[MSSQL/PROTHEUS_TST_<NOME>]` |
| AppServer principal .ini | `<ProtheusRoot>\Protheus\bin\appserver_rest\appserver.ini` |
| AppServer dedicado .ini (Modo A) | `<ProtheusRoot>\Protheus\bin\appserver_tdd\appserver.ini` |
| RPO compartilhado | `<ProtheusRoot>\protheus_data\apo\` (ou similar; AppServer .ini define) |
| Instancia isolada - bin (#34) | `<ProtheusRoot>\Protheus\bin\appserver_<nome>\` (+ `console.log` dela) |
| Instancia isolada - RPO (#34) | `<ProtheusRoot>\protheus\apo_<nome>\` (`tttm120.rpo` copiado + `custom.rpo` proprio) |
| Logs de build (transient) | `$env:TEMP\tlpp-tdd\build-<pid>.{ini,log}` (por PID: dois projetos compilando ao mesmo tempo nao se sobrescrevem) |
| Cache de build | `~/.claude/tlpp-tdd/build-cache.json` (global - modela o RPO, que e compartilhado) |
| Backups .ini | `<mesmo dir do .ini>.bak.<timestamp>` |
