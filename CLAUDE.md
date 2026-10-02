# CLAUDE.md - tlpp-runner

Instrucoes carregadas automaticamente pelo Claude Code em cada sessao deste projeto.

> **Primeiro contato com o projeto?** Dois pontos de entrada, propositos diferentes:
> - `docs/TDD-GUIDE.md` - **racional completo**: por que TDD apesar do ciclo de compilacao, anatomia de um teste (por que cada peca e obrigatoria), como escolher casos de teste, vermelho -> verde com as saidas reais.
> - `docs/LLM-WORKFLOW.md` - **loop enxuto** pra LLM consumidora: 5 passos, anti-patterns, exemplo end-to-end.
>
> Catalogo canonico de wrappers/mocks/asserts/helpers: `docs/REFERENCE.md`. Receitas por cenario: `docs/RECIPES.md`. Erro na mao: `docs/TROUBLESHOOTING.md`.

## Visao geral

Framework TDD para desenvolvimento ADVPL/TLPP no Protheus.
Compilacao via `advpls cli` (sem TDS-VSCode aberto, sem token JWT).
Execucao de testes via endpoint REST `/runner/exec` (preferido) ou PROBAT (com limitacoes).

## Arquitetura

Tudo roda no AppServer dev existente (env DESENVOLVIMENTO, porta 8401).

- **Suite unit** (`test/unit/`) usa mocks em memoria (`mocks/tecMock.tlpp`). Sem banco.
- **Suite integracao** (`test/integracao/`) usa `u_tecTstConn` (TCLink dinamico no `MSSQL/PROTHEUS_TST`) no setup. AppServer continua em DESENVOLVIMENTO.

## Fluxo TDD recomendado (rota por funcao)

```
1. Red: escreve teste em test/unit/tec<Nome>Tst.tlpp:
     @TestFixture()
     user function test_<o_que_testa>()
         u_tecAssertReset()
         u_tecTstStart()  -- ou usar u_tecTstWith({|| ... })
         // arrange DEPOIS do Start (mocks: u_tecMkSql/MkMv/MkBdSeek/...)
         // act + assert (u_tecAssertEq/True/...)
         u_tecTstStop()
     return u_tecAssertsOk()

2. /tlpp-test u_test_<o_que_testa>  -> ERRO InterFunctionCall: cannot find function
   U_TEC<NOME> (fonte ainda nao existe) ou result=.F. com linhas FAIL:

3. Green: implementa src/tec<Nome>.tlpp com user function. Compile
   explicitamente via /tlpp-build (o /tlpp-test ja compila antes de rodar).

4. /tlpp-test u_test_<o_que_testa>  -> result=.T.

5. Refator com confianca, rerodando testes vizinhos pra checar regressao.
```

A skill `tlpp-tdd` em `.claude/skills/` automatiza esse loop.

## Convencoes do projeto

### Estrutura de pastas

- `src/` - fontes em desenvolvimento
- `test/unit/` - testes com mocks (sem banco)
- `test/integracao/` - testes com banco real + helpers de DB
- `mocks/` - biblioteca de mocks
- `runner/sql/` - DDL e DML do banco de teste
- `runner/*.ps1` - scripts wrappers
- `.claude/commands/` - slash commands
- `.claude/skills/` - skills agenticas (loops, prompts longos)

### Nomenclatura

- Prefixo `tec` (3 chars)
- Fonte: `tec<Nome>.tlpp`
- Teste unit: `tec<Nome>Tst.tlpp` em `test/unit/`
- Teste integracao: `tec<Nome>ItgTst.tlpp` em `test/integracao/`
- User function: `u_tec<Nome>` (chamavel via `/runner/exec`)
- Tabela de teste: `Z_TST_<NOME>` no `PROTHEUS_TST`

### Wrappers OBRIGATORIOS (codigo de PRODUCAO em src/)

Nunca chamar API externa direta. Use os wrappers de `src/tecWrap.tlpp` - assim os mocks interceptam em modo teste. Assinaturas completas, semantica de retorno e pegadinhas: **`docs/REFERENCE.md`** (catalogo canonico). Resumo minimo:

| Wrapper                     | Substitui                    | Mock                |
|-----------------------------|------------------------------|---------------------|
| `u_tecDbSeekFld`            | `DbSeek` + `ALIAS->CAMPO`    | `u_tecMkBdSeek`     |
| `u_tecBuscaCli`             | `SA1` por CGC                | `u_tecMkBdSeed`     |
| `u_tecBuscaTitulo`          | `SE1` titulo a receber       | `u_tecMkBdSeed`     |
| `u_tecBuscaPedido` / `u_tecBuscaItensPedido` | `SC5` / `SC6` | `u_tecMkBdSeed`     |
| `u_tecQryFirst` / `u_tecQryAll` | `TCQuery` / `TOPCONN`    | `u_tecMkSql`        |
| `u_tecGetMv`                | `GetMv` / `GetNewPar`        | `u_tecMkMv`         |
| `u_tecHttpReq` / `u_tecHttpPost` | `FWRest():new()`        | `u_tecMkHttp`       |
| `u_tecHoje` / `u_tecHora`   | `Date()` / `Time()`          | `u_tecMkHoje` / `u_tecMkHora` |
| `u_tecMkModel`              | duble de `FwFormModel` (nao precisa de modo teste) | - |

Ordem load-bearing: `u_tecAssertReset()` -> `u_tecTstStart()` -> **mocks** -> act -> asserts -> `u_tecTstStop()`. O Start CRIA os dicionarios de mock: `u_tecMk*` chamado antes dele e perdido silenciosamente. Use `u_tecTstWith({|| ... })` para garantir Stop mesmo apos exception.

### Asserts (use estes - PROBAT padrao nao bate com fluxo `/runner/exec`)

Tabela completa com tipos aceitos e pegadinhas: **`docs/REFERENCE.md`**. Resumo minimo:

| Assert | Para que |
|---|---|
| `u_tecAssertReset()` | **Obrigatorio** na 1a linha - zera contadores static (senao vazam do teste anterior) |
| `return u_tecAssertsOk()` | **Obrigatorio** no fim - e o que o `/runner/exec` reporta. `.T.` so se 0 falhas E >=1 ok |
| `u_tecAssertEq` / `Neq` / `True` / `False` | Valor e booleano |
| `u_tecAssertEmpty` / `NotEmpty` | Tipo-aware (JsonObject via `GetNames`; `Empty()` cru crasha o thread) |
| `u_tecAssertGreater` / `Less` | Comparacao numerica |
| `u_tecAssertHttpStatus` / `HttpBodyContains` / `HttpJsonField` | `jResp` de `u_tecHttpReq` (path `a.b.0.c`) |

### Teste de integracao (banco real)

Helpers globais em `test/integracao/tecTstDbHlp.tlpp`:

```tlpp
@TestFixture()
user function test_meu_caso()
    local nLink, nLinkAnt
    local cTab := "Z_TST_DEMO"

    u_tecAssertReset()
    nLink := u_tecTstConn(@nLinkAnt)        // TCLink no MSSQL/PROTHEUS_TST
    if nLink <= 0
        u_tecAssertTrue("conectou", .F.)
        return u_tecAssertsOk()
    endif

    u_tecTstDropTable(cTab)                 // idempotente
    u_tecTstCreateTable(cTab, { ;
        {"COD",  "CHAR(6)",  "NOT NULL"}, ;
        {"NOME", "CHAR(40)", "NOT NULL"} ;
    })                                       // R_E_C_N_O_ + D_E_L_E_T_ automaticos
    u_tecTstSeed(cTab, {{"COD","000001"},{"NOME","ACME"}})

    // assert via u_tecQryFirst (sem mock - vai direto pro banco)
    local jRow := u_tecQryFirst("SELECT NOME FROM " + cTab + " WHERE COD='000001'")
    u_tecAssertEq("nome lido", "ACME", AllTrim(jRow["NOME"]))

    u_tecTstDropTable(cTab)
    u_tecTstDisconn(nLink, nLinkAnt)
return u_tecAssertsOk()
```

Helpers DB disponiveis: `u_tecTstConn`/`Disconn`, `u_tecTstCreateTable`/`DropTable`, `u_tecTstSeed` (escapa string/numero/data/logico/nil), `u_tecTstTruncate(aAliases)`.

Para tabela permanente reutilizavel: `/tlpp-table create <nome> "<cols>"`.

### Estilo TLPP

- Notacao hungara: `cNome`, `nValor`, `lAtivo`, `dHoje`, `aLista`, `jObj`
- Tipos: `local cNome := "" as character`
- **Evite `as <tipo>` em vars inicializadas com nil** - typing estrito rejeita
- **Nao existe `as anytype`** - omitir `as` em parametros genericos
- Encoding: CP1252 (`mcp__file-tools__write_file` com `encoding=cp1252`)
- Use `user function` ou `static function` - `function` regular precisa de token JWT
- **`namespace` muda nome registrado**: `user function foo` SEM namespace registra como `u_foo` global. COM `namespace bar`, registra como `bar.u_foo`. Pra modulos cujas funcoes sao chamadas via `tlpp.ffunc()` / `/runner/exec` externo, **NAO usar namespace** (senao precisa qualificar). Para modulos so chamados via `@Get/@Post` annotations (REST routes), namespace e seguro. Ref: [Namespace](https://tdn.totvs.com/display/tec/Namespace).

## Slash commands

| Comando | Uso |
|---|---|
| `/tlpp-build [arquivo\|--all]` | Compila via advpls cli |
| `/tlpp-test <funcao\|arquivo\|suite>` | Compila + executa (recomendado: por funcao) |
| `/tlpp-exec <funcao> [args]` | Executa funcao arbitraria via `/runner/exec` |
| `/tlpp-tdd "<feature>"` | Loop TDD autonomo (delega para skill `tlpp-tdd`) |
| `/tlpp-table create <nome> "<cols>"` | Adiciona tabela permanente em `runner/sql/02-create-schema.sql` |
| `/tlpp-tdd-project-init` | Banco de teste + alias + `.tlpp-tdd.json`; oferece instancia isolada (#34) |

## Compilacao explicita

Nao ha hook de recompilacao automatica ao salvar: toda compilacao derruba o
HTTPREST ate o proximo ciclo do `[ONSTART] RefreshRate` (~13s de janela total com
o `RefreshRate=2` que o setup grava), entao o agente decide QUANDO compilar.
Compile via `/tlpp-build <arquivo>` ou `/tlpp-test` (que compila antes de rodar).

## Regras criticas (de instructions globais do user)

### Dicionario de dados (SX3/SX6/SIX)

**NUNCA** criar campos/parametros/indices via fonte TLPP/AdvPL. Sempre via Configurador.
Registrar em `.claude/plans/<slug>/pre-producao.md` antes do deploy (mesma pasta de
toda a documentacao da customizacao - ver instructions globais do user).

Em testes de integracao, tabelas `Z_TST_*` sao criadas via DDL (`runner/sql/02-create-schema.sql`) ou via `u_tecTstCreateTable` no teste - NAO via SX3.

### Regras de negocio sem fonte do cliente

**NUNCA** decidir regra de bloqueio sem fonte do cliente. Aplicar fallback permissivo + log + TODO em `.claude/plans/<slug>/perguntas-cliente.md`.

## Endpoint REST

| Path           | Verbo | Funcao                                  |
|----------------|-------|-----------------------------------------|
| `/runner/ping` | GET   | Health check                            |
| `/runner/func` | GET   | Verifica se funcao existe no RPO        |
| `/runner/exec` | POST  | Executa funcao - body: `{function,argString}` |

URL base: `http://127.0.0.1:8401/rest/runner/*` (host `localhost` no `BaseUrl` e normalizado para `127.0.0.1` ao carregar a config: o .NET tenta IPv6 primeiro e cada request pagaria ~2s de fallback)
Resposta do `/runner/exec`: `{function, argString, result, duration, env, asserts?}`. `asserts` = `u_tecAssertSummary()` (`ok`, `passed`, `failed`, `fails[]`), presente quando a chamada registrou ao menos um assert - as falhas chegam na resposta, sem ler `console.log`. Erro de execucao na funcao chamada: HTTP 500 `{error:"runtime", function, argString, message, stack, duration, asserts?}`, com a pilha apontando fonte e linha. 400/404 tambem vem com corpo JSON (ex. `{"error":"funcao_nao_existe","function":"u_x"}`).
Auth: Basic admin / senha em `~/.claude/tlpp-tdd/config.ps1` (global, per-machine). No tlpp-runner repo dev, `runner/runner.config.local.ps1` ainda carrega como legacy cascade.

## Limitacoes conhecidas

- **`function` regular nao compila** sem token JWT do portal TOTVS
- **QUALQUER compilacao derruba o HTTPREST** (issue #29). O AppServer executa "Stopping all HTTP servers"; com `BuildKillUsers=1` o job `HTTP_START` do `[ONSTART]` morre e o REST so volta no proximo ciclo do `[ONSTART] RefreshRate` (intervalo em que o AppServer confere e relanca os jobs). O setup grava `RefreshRate=2`: build ~7-8s + REST de volta ~5s depois (janela ~13s). Ini com `RefreshRate=120` deixa o REST fora ate ~2 min - `/tlpp-tdd-setup` (doctor) ou `Set-AppServerRest.ps1` baixa o valor in-place (exige reiniciar o AppServer). Nao e especifico de `@Get/@Post` - o gatilho e a escrita no RPO. `recompile=F` nao evita (o advpls compila do mesmo jeito), e compile que FALHA tambem derruba os HTTP servers. Mitigacoes: `Invoke-TlppBuild.ps1` pula fontes ja no RPO com o mesmo conteudo - guard 0 e o **oraculo RPO** (#33: `u_tecApoStat`/`GetAPOInfo` via `/runner/exec` compara dataFonte com mtime do disco, por objeto), fallback e o cache local (`runner/BuildCache.ps1`); `-Force` ignora ambos. `Invoke-TlppRunner.ps1` faz backoff assimetrico - espera ate 180s se a porta TCP responde (reiniciando; cobre ini com RefreshRate alto), curta se recusa (AppServer desligado). A janela e POR INSTANCIA: projeto com `isolation` no `.tlpp-tdd.json` (#34) so derruba o REST dele mesmo
- **Dois AppServers sobre o mesmo `custom.rpo`** (ex. o de desenvolvimento e o `appserver_rest` abertos juntos): a compilacao falha pelos dois com `COMPILEERROR-300 Failed to open repository ... used by another process`; quando a falha vem pelo AppServer do REST, os HTTP servers dele so voltam reiniciando o AppServer. `Invoke-TlppBuild.ps1` detecta e imprime o diagnostico
- **Mocks so cobrem codigo que passa pelos wrappers** em `tecWrap.tlpp`
- **TCLink no PROTHEUS_TST exige permissao** do login DBAccess no banco de teste
- **`FWRest` apontando pro proprio AppServer** causa deadlock/crash. `u_tecHttpReq` resolve com `HTTPQuote`.
- **`ValType(JsonObject)` retorna `"J"` em TLPP, nao `"O"`**. Use `:hasProperty()` direto.
- **`Empty(JsonObject)` crasha** o thread. Use `u_tecAssertEmpty/NotEmpty` (tipo-aware).
- **PROBAT `type:suite=X` retorna 0/0** com `TESTS_DISCOVERY_MODE=0`. Solucao: chamar `tlpp.probat.discovery()` antes OU usar `/tlpp-test <funcao>` direto (recomendado). Mais detalhes em `docs/SETUP.md`.
- **Asserts custom (`u_tecAssert*`) nao contam como testcase no PROBAT**. Por isso ficamos com `/runner/exec` por nome - retorna `.T./.F.` confiavel.

## Desenvolvimento como Claude Code plugin

Este repo tambem e um Claude Code plugin. Audit + pesquisa de boas praticas estao em memoria - ver `plugin_authoring_practices.md` e `project_distribution.md`. Resumo load-bearing:

- **Layout**: plugin promovido a raiz - `.claude-plugin/plugin.json` + `skills/` + `commands/` ficam na raiz do repo. **NAO** em `.plugin/` (que era o layout antigo). Sem `hooks/` - o plugin nao registra hooks (build e explicito, decidido pelo agente).
- **Mirror `.claude/`**: existe so pra dev in-repo conseguir usar os skills/commands sem `/plugin install file://`. Canonico e a raiz; `scripts/plugin/sync.ps1` empurra raiz -> `.claude/`. Drift validado por `scripts/plugin/validate.ps1` em pre-commit.
- **Skill descriptions** precisam de verbos especificos + trigger phrases concretas + anti-examples; limite de ~1536 chars combinados (description + when_to_use).
- **Manifest** precisa de `name`, `version`, `description` curta + `repository`, `homepage`, `categories`, `keywords`, `license`. README carrega prosa longa.
- **Versao**: bump explicito de `version` em `.claude-plugin/plugin.json` e o trigger pra users baixarem update. Push de commit sem bump nao atualiza ninguem.
- **Politica git**: `git commit` e `git push` estao LIBERADOS; `reset`/`checkout`/`rebase`/`merge`/`clean`/`branch -D` seguem negados pelo deny rule do user. Fluxo: branch -> commit -> push -> PR -> merge via `gh pr merge`. Ver memoria `session_git_commit_denied`.

## Arquitetura global (redesign 0.2.0)

**Apos o redesign**, framework nao e mais copiado per-project. Estado:

- **`~/.claude/tlpp-tdd/config.ps1`** (per-machine): admin/senha, paths Protheus, advpls, AppServer endpoint, DBAccess host/port. Carregado primeiro por `runner.config.ps1`.
- **`<projeto>/.tlpp-tdd.json`** (per-project, opcional): `{"name": "MEUPROJ"}` deriva banco de teste `PROTHEUS_TST_MEUPROJ` e e propagado pro AppServer via `projectName`/`testDbAlias` no body do `/runner/exec`.
- **Framework no RPO compartilhado**: `src/tec*.tlpp` compilados UMA VEZ no AppServer dev. Funcs como `u_tecAssertEq`, `u_tecMkSql`, `u_tecTstConn` ficam disponiveis pra qualquer projeto que use o plugin.
- **Runner scripts** (`Invoke-TlppBuild.ps1`, `Invoke-TlppRunner.ps1`): vivem no plugin (`$env:CLAUDE_PLUGIN_ROOT/runner/`), compilam fontes do **PROJETO ATUAL** (cwd ou `$env:CLAUDE_PROJECT_DIR`).
- **Slash commands** usam cascade `$runner = $env:CLAUDE_PLUGIN_ROOT/runner || .\runner`.
- **`tecRunrCtx.tlpp`** prove context store thread-local (`u_tecCtxSet/Get/Project/TestDbAlias/...`). `tecRunrApi.tlpp` limpa no inicio de cada request e popula do body. `u_tecTstConn` le via accessors.

**Setup nova maquina**: `/tlpp-tdd-setup` faz tudo end-to-end (detecta ambiente, oferece AppServer dedicado vs reusar, escreve config global, compila framework no RPO, smoke). Idempotente - re-roda como doctor quando algo quebra (diagnostica config morto, AppServer off, framework fora do RPO, paths invalidos, instancia isolada quebrada). Pra inicializar projeto especifico com banco, `/tlpp-tdd-project-init` cria `PROTHEUS_TST_<nome>` + alias + `.tlpp-tdd.json` na raiz do projeto.

**Isolamento opt-in por projeto (#34)**: `.tlpp-tdd.json` com `isolation: {tcpPort, restPort, webAppPort}` faz o projeto rodar numa instancia AppServer DEDICADA (`Protheus\bin\appserver_<nome>` + RPO proprio em `protheus\apo_<nome>`) - compilar ali nao derruba o HTTPREST dos outros projetos. Criada por `runner/install/New-IsolatedInstance.ps1` (o `/tlpp-tdd-project-init` oferece), sobe **on-demand** no primeiro build/test via `runner/InstanceControl.ps1` (com `-console`, sem auto-stop). Custo ~1,45GB de disco (o `tttm120.rpo` precisa ser COPIADO - hardlink refutado) + ~500MB de RAM ligada. `protheus_data`, DBAccess e License seguem compartilhados. Sem a chave `isolation`, nada muda. Detalhes em `docs/ARCHITECTURE.md` secao 4.1.

## Recursos relacionados

- `docs/TDD-GUIDE.md` - guia de TDD (racional, anatomia, escolha de casos, red->green com saidas reais)
- `docs/REFERENCE.md` - catalogo canonico de wrappers/mocks/asserts/helpers de banco
- `docs/RECIPES.md` - receitas por cenario (REST, parametro, DbSeek, data, MVC, banco real)
- `docs/TROUBLESHOOTING.md` - sintoma -> causa -> fix das falhas reais
- `docs/LLM-WORKFLOW.md` - guia enxuto pra LLM consumidora
- `docs/ARCHITECTURE.md` - arquitetura, custos, limitacoes, cheatsheet
- `docs/SETUP.md` - instalacao completa para novos devs
- `docs/DATABASE-SETUP.md` - PROTHEUS_TST + DBAccess alias
- GitHub issues - backlog estruturado por phase
