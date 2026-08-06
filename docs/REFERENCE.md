# Referência do framework — wrappers, mocks, asserts, helpers

Catálogo **canônico** das APIs do framework. Extraído de `src/tecWrap.tlpp`,
`src/tecAssert.tlpp`, `mocks/tecMock.tlpp`, `mocks/tecModelMock.tlpp` e
`test/integracao/tecTstDbHlp.tlpp`. Quando outro documento cita uma assinatura,
ela vale aqui.

Não é um tutorial. Se é seu primeiro contato, comece pelo
[TDD-GUIDE.md](TDD-GUIDE.md); para código pronto por cenário, [RECIPES.md](RECIPES.md).

---

## 1. Ciclo de vida do modo teste

| Função | O que faz |
|---|---|
| `u_tecTstStart()` | Liga o modo teste e **cria** os dicionários de mock (banco, MV, HTTP, SQL) vazios; zera data/hora mockadas |
| `u_tecTstStop()` | Desliga o modo teste e descarta todos os mocks |
| `u_tecTstAtivo()` | `.T.` se o modo teste está ligado (útil para assert de teardown) |
| `u_tecTstWith(bBlock)` | Executa o codeblock entre Start e Stop garantindo o Stop **mesmo com exceção** (`ErrorBlock` + `BEGIN SEQUENCE`). Devolve o retorno do bloco, ou `nil` se houve exceção (loga `[tecTstWith] excecao capturada no bloco`) |

**Ordem obrigatória:** `u_tecTstStart()` **antes** de qualquer `u_tecMk*`. O Start
cria os dicionários; mock registrado antes dele não tem onde ficar (o helper
devolve `.F.`) e o Start em seguida zera o estado. Única exceção:
`u_tecMkModel`, que não usa modo teste.

---

## 2. Wrappers obrigatórios (código de produção) + mock correspondente

Regra do projeto: **código em `src/` nunca chama dependência externa direta**. Se
não passar pelo wrapper, o mock não intercepta e o teste unitário é falso verde.

| Dependência real | Wrapper (usar em produção) | Retorno | Mock (usar no teste) |
|---|---|---|---|
| `DbSelectArea`+`DbSetOrder`+`DbSeek`+`FieldGet` | `u_tecDbSeekFld(cAlias, nOrder, cKey, cFld)` | valor do campo, ou `""` se não achou / campo ausente (**nunca `nil`**) | `u_tecMkBdSeek(cAlias, nOrder, cKey, jRow)` |
| `SA1` por CGC (helper de domínio) | `u_tecBuscaCli(cCgc)` | `A1_NOME`, ou `""` | `u_tecMkBdSeed("SA1", aRows)` com `A1_CGC`+`A1_NOME`; cai para `u_tecMkBdSeek("SA1", 3, ...)` se não achar |
| `SE1` título a receber | `u_tecBuscaTitulo(cPrefixo, cNum, cParcela, cTipo)` | JsonObject `{valor, vencimento, status, baixa, saldo}` ou **`nil`** | `u_tecMkBdSeed("SE1", aRows)` |
| `SC5` cabeçalho de pedido | `u_tecBuscaPedido(cNum)` | JsonObject `{cliente, loja, valor_total, status, nota}` ou **`nil`** | `u_tecMkBdSeed("SC5", aRows)` + `u_tecMkBdSeed("SC6", aRows)` |
| `SC6` itens do pedido | `u_tecBuscaItensPedido(cNum)` | array de JsonObject `{item, produto, qtd, valor}` (vazio se nada) | `u_tecMkBdSeed("SC6", aRows)` |
| `TCQuery`/`DbUseArea TOPCONN` — 1 linha | `u_tecQryFirst(cSql)` | JsonObject da 1ª linha, ou **`nil`** | `u_tecMkSql(cSql, aRows)` |
| `TCQuery`/`DbUseArea TOPCONN` — N linhas | `u_tecQryAll(cSql)` | array de JsonObject (vazio se nada) | `u_tecMkSql(cSql, aRows)` |
| `GetMv`/`GetNewPar` | `u_tecGetMv(cParam, xDefault)` | valor do parâmetro; `xDefault` se não mockado / não existe | `u_tecMkMv(cParam, xValor [, cTipo])` |
| `FWRest():new()` — qualquer verbo | `u_tecHttpReq(cVerb, cUrl, xBody, aHeaders)` | JsonObject `{ok, status, body, error}` | `u_tecMkHttp("VERB URL" \| "URL", nStatus, cBody)` |
| `FWRest():new()` — POST (compat) | `u_tecHttpPost(cUrl, cBody, aHead)` | delega para `u_tecHttpReq("POST", ...)` | idem |
| `Date()` | `u_tecHoje()` | data mockada em modo teste, senão `Date()` | `u_tecMkHoje(dData)` |
| `Time()` | `u_tecHora()` | hora mockada em modo teste, senão `Time()` | `u_tecMkHora(cHora)` |

### Detalhes que mudam o resultado

**`u_tecDbSeekFld` / `u_tecMkBdSeek`** — a chave do mock é composta:
`cAlias + "#" + nOrder + "#" + AllTrim(cKey)`. Ou seja **ordem faz parte da
identidade**: mockar ordem 1 e consultar ordem 2 não casa (é útil — dá para mockar
a mesma chave em ordens diferentes com valores diferentes). O `AllTrim` é aplicado
nos dois lados, então espaço em volta da chave não atrapalha. Campo que não está no
`jRow` devolve `""`, não `nil`.

**`u_tecMkSql`** — o casamento é por **string exata** de SQL
(`hasProperty(cSql)`). Um espaço a mais, quebra de linha diferente ou `SELECT *` vs
`SELECT A,B` já não casa e o wrapper devolve `nil`/array vazio. Na prática: monte o
SQL numa variável e use **a mesma variável** no mock e na chamada.

**`u_tecGetMv`** — em modo teste, parâmetro não mockado devolve `xDefault` (não
estoura). É o que permite o caso "MV inexistente usa default".

**`u_tecMkMv(cParam, xValor, cTipo)`** — `cTipo` é opcional e valida o valor contra
o `X6_TIPO` esperado (`"C"`, `"N"`, `"L"`, `"D"`). Mock com tipo errado é
**rejeitado** (devolve `.F.`, não registra, loga
`[tecMkMv] REJEITADO <param>: esperava tipo N recebeu C`). Serve para não passar
verde com um parâmetro que em produção viria com outro tipo. Sem `cTipo`, aceita
qualquer valor (compatibilidade).

**`u_tecHttpReq` / `u_tecMkHttp`** — a chave do mock pode ser:
- `"GET /api/x"` → casa **só** aquele verbo
- `"/api/x"` → casa **qualquer** verbo

A chave com verbo tem prioridade sobre a sem verbo, o que permite mockar GET e POST
da mesma URL com respostas diferentes. Sem mock configurado, o retorno é
`{ok: .F., status: 0, body: "", error: "mock_nao_configurado: <VERB> <URL>"}`.

> **Pegadinha:** em modo teste, `jResp["ok"]` vem `.T.` **sempre que o mock é
> encontrado**, inclusive quando você mockou status 500. Em produção, `ok` é
> `status >= 200 .and. status < 300`. Portanto, para testar caminho de erro HTTP,
> afirme sobre **`status`** (`u_tecAssertHttpStatus`), nunca sobre `ok`.

**`u_tecHttpReq` em produção** usa `HTTPQuote` (stand-alone), não `FWRest`. É
deliberado: `FWRest` apontando para o **próprio** AppServer causa deadlock/crash
quando o código roda dentro de um endpoint REST. Verbos aceitos: `GET`, `POST`,
`PUT`, `DELETE`, `PATCH`; qualquer outro devolve
`{ok: .F., status: 0, error: "verbo_invalido: <verbo>"}`. Timeout de 30s; header
default `Content-Type: application/json`. `xBody` aceita string ou objeto (usa
`:toJson()`).

**`u_tecHoje` / `u_tecHora`** — só devolvem o valor mockado se o modo teste estiver
ligado **e** o mock tiver sido setado (e `u_tecTstStart` limpa ambos). Sequência
correta: `Start` → `u_tecMkHoje(...)` → act.

### Construtor de linha de mock

```tlpp
u_tecMkRow(aFlds)   // aFlds = {{"CAMPO", valor}, {"CAMPO2", valor2}, ...} -> JsonObject
```

Usado por `u_tecMkBdSeed`, `u_tecMkBdSeek` e `u_tecMkSql` para montar cada linha.

---

## 3. Mock de `FwFormModel` (`u_tecMkModel`)

Dublê do `oModel` que funções de validação e gatilho de `ModelDef` recebem. Permite
testar regra de negócio MVC **sem `Activate` real, sem `FwViewDef`, sem tela e sem
banco**. Não depende de `u_tecTstStart`.

```tlpp
oMdl := u_tecMkModel("MEUMVC")       // cId e informativo; default "MOCK"
```

### API coberta

| Método | Comportamento |
|---|---|
| `:Activate()` / `:DeActivate()` | Liga/desliga a flag interna, devolve `.T.` |
| `:IsActive()` | Estado da flag (nasce `.F.`) |
| `:SetValue(cSub, cCampo, xVal)` | Grava no storage do submodelo (cria o submodelo se não existir), devolve `.T.` |
| `:GetValue(cSub, cCampo)` | Valor gravado, ou **`nil`** se campo/submodelo nunca setado |
| `:GetModel(cSub)` | Submodelo com `:GetValue(cCampo)` / `:SetValue(cCampo, xVal)` — enxerga **o mesmo storage** do pai (escrita no submodelo reflete no pai) |
| `:SetVldBlock(bBlock)` | Registra bloco de validação custom; recebe o próprio mock como argumento |
| `:VldData()` | `.T.` por default; com bloco registrado, devolve `Eval(bBlock, self)` |
| `:FormCommit()` | **NO-OP** — não toca banco. Marca a flag e devolve `.T.` |
| `:WasCommitted()` | `.T.` se `FormCommit` foi chamado (é assim que se afirma sobre commit) |

### Limites conscientes

- **Não simula grid multi-linha** — sem `GetLine`/`SetLine`/`AddLine`/`DeleteLine`
- **Não lê SX3** — campo nunca setado devolve `nil`, **não** o default do dicionário
- **Não dispara `bPre`/`bPost` reais** — a regra sob teste é chamada diretamente
  pela sua função, com o mock no lugar do `oModel`

Se o seu cenário precisa de grid, o mock não serve: promova a regra a uma
`user function` que recebe os dados já extraídos e teste essa função.

---

## 4. Asserts (`src/tecAssert.tlpp`)

Os asserts do PROBAT (`assertEquals` etc.) só registram resultado quando rodam
dentro de `tlpp.probat.run`. Chamado via `/runner/exec` — a rota preferida — o
assert do PROBAT não reprova a função e **todo teste retornaria `.T.`**. Por isso
o framework tem contador próprio: cada assert incrementa ok/fail, loga
`[ASSERT_OK]`/`[ASSERT_FAIL]` no `ConOut`, e `u_tecAssertsOk()` no `return` decide
o `result` da resposta REST.

### Controle

| Função | Comportamento |
|---|---|
| `u_tecAssertReset()` | **Obrigatório na primeira linha.** Zera contadores e lista de falhas (são `static` do módulo — sem reset, vazam do teste anterior) |
| `u_tecAssertsOk()` | **Obrigatório no `return`.** `.T.` só se `falhas == 0` **e** `ok > 0` — teste sem nenhum assert reprova de propósito |
| `u_tecAssertSummary()` | JsonObject `{ok, passed, failed, fails}` (`fails` = array de `"<desc> \| <detalhe>"`). Útil para inspeção via `/tlpp-exec` |

### Asserts de valor

| Assert | Passa quando | Tipos aceitos |
|---|---|---|
| `u_tecAssertEq(cDesc, xEsperado, xAtual)` | `xEsperado == xAtual` | qualquer (comparação `==` do TLPP) |
| `u_tecAssertNeq(cDesc, xNaoEsperado, xAtual)` | `!=` | qualquer |
| `u_tecAssertTrue(cDesc, lCond)` | `lCond` é `.T.` | lógico (`DEFAULT .F.`) |
| `u_tecAssertFalse(cDesc, lCond)` | `lCond` é `.F.` | lógico (`DEFAULT .F.`) |
| `u_tecAssertFail(cDesc, cDetail)` | registra falha explícita, sem comparação — infra de teste sinaliza erro fora do fluxo de assert (ex: `u_tecTstWith` ao capturar exception) | 2 strings |
| `u_tecAssertEmpty(cDesc, xVal)` | valor vazio (tipo-aware) | `nil`, C, N, D, L, array, JsonObject |
| `u_tecAssertNotEmpty(cDesc, xVal)` | valor não vazio (tipo-aware) | idem |
| `u_tecAssertGreater(cDesc, xMin, xAtual)` | `xAtual > xMin` | numérico/data |
| `u_tecAssertLess(cDesc, xMax, xAtual)` | `xAtual < xMax` | numérico/data |

Todos devolvem `.T.`/`.F.` (dá para afirmar sobre o próprio assert, como fazem os
testes negativos do framework) e escrevem no `ConOut` com a descrição em português.

### Asserts HTTP

Consomem o `jResp` de `u_tecHttpReq` (`{ok, status, body, error}`).

| Assert | Passa quando | Falha explicando |
|---|---|---|
| `u_tecAssertHttpStatus(cDesc, nEsperado, jResp)` | `jResp["status"] == nEsperado` | `jResp` nil, sem campo `status`, ou status diferente (mostra o body) |
| `u_tecAssertHttpBodyContains(cDesc, cEsperado, jResp)` | `cEsperado` é substring de `jResp["body"]` | body ausente, não-string, ou sem a substring (mostra 200 primeiros chars) |
| `u_tecAssertHttpJsonField(cDesc, cPath, xEsperado, jResp)` | o campo em `cPath` do body JSON `==` `xEsperado` | body vazio/não-string, body não parseia como JSON, path inexistente, ou valor diferente |

`cPath` usa `.` como separador e aceita índice de array **0-based**:
`"user.name"`, `"itens.0.produto"`, `"a.b.0.c"`.

### Pegadinhas de tipo (custaram sessão de debug)

- **`Empty(JsonObject)` crasha a thread.** Nunca chame. `u_tecAssertEmpty` /
  `u_tecAssertNotEmpty` são tipo-aware: para JsonObject usam
  `Len(xVal:GetNames()) == 0` (seguro) para decidir "vazio".
- **`ValType(JsonObject)` devolve `"J"`** em TLPP, não `"O"`. Código que testa
  `== "O"` para detectar objeto não funciona; use `:hasProperty()` direto.
- **Objeto genérico (`ValType == "O"`) nunca é considerado vazio** — sem
  introspecção segura, não-nil é tratado como não-vazio.
- No detalhe de uma falha, o valor é formatado por tipo: `<nil>`, `'texto'`,
  `123`, `.T.`, `20260729` (data), `<array len=3>`, `<object>`. JsonObject aparece
  como `<J>` — é por isso que uma falha típica se lê
  `[ASSERT_FAIL] programs vazio | expected=<empty> actual=<J>`.
- **Asserts `u_tecAssert*` não contam como testcase no PROBAT** (ele espera
  `assertEquals` da include). O PROBAT reporta `Test without testcase`. É esperado
  — a rota por função via `/runner/exec` é a que dá `result` confiável.

---

## 5. Helpers de banco para integração (`test/integracao/tecTstDbHlp.tlpp`)

Pré-requisito: banco de teste + alias DBAccess configurados
([DATABASE-SETUP.md](DATABASE-SETUP.md), ou `/tlpp-tdd-project-init`).

| Helper | Assinatura / comportamento |
|---|---|
| `u_tecTstConn(@nLinkAnt)` | `TCLink` dinâmico no banco de teste. Guarda a conexão anterior em `nLinkAnt` (**por referência**) e ativa a nova com `TCSetConn`. Devolve o handle (`> 0` = ok). Alias/host/porta vêm do contexto (`u_tecCtxTestDbAlias`/`u_tecCtxDbAccessHost`/`u_tecCtxDbAccessPort`); default `MSSQL/PROTHEUS_TST` em `localhost:7890` |
| `u_tecTstDisconn(nLink, nLinkAnt)` | Restaura a conexão anterior e faz `TCUnlink`. **Sempre** chame no fim |
| `u_tecTstCreateTable(cNome, aColunas)` | `CREATE TABLE` idempotente (`IF OBJECT_ID(...) IS NULL`). Adiciona automaticamente `R_E_C_N_O_ INT IDENTITY(1,1) NOT NULL PRIMARY KEY` e `D_E_L_E_T_ CHAR(1) NOT NULL DEFAULT ''`. `aColunas` = array de `{cNome, cTipoSql, cConstraint}` (3º opcional: `"NOT NULL"`, `"NULL"`, `"DEFAULT 0"`). `.F.` + `ConOut` de erro se o `TCSQLExec` falhar |
| `u_tecTstDropTable(cNome)` | `DROP TABLE` idempotente. Seguro chamar antes de criar |
| `u_tecTstSeed(cTabela, aRow)` | `INSERT` de 1 linha. `aRow` = array de `{campo, valor}`. Escapa por tipo: string com `''` duplicado, número cru, data via `DToS`, lógico como `1`/`0`, `nil` como `NULL` |
| `u_tecTstTruncate(aAliases)` | `DELETE FROM` em várias tabelas (mantém a estrutura) |

Para tabela **permanente** reutilizada por vários testes, prefira
`/tlpp-table create <nome> "<cols>"`, que versiona o DDL no `schemaPath` do
projeto. `u_tecTstCreateTable` é para tabela ad-hoc de um teste só.

---

## 6. Convenções de nomenclatura

| Item | Convenção |
|---|---|
| Fonte de produção | `src/tec<Nome>.tlpp` |
| Teste unitário | `test/unit/tec<Nome>Tst.tlpp` |
| Teste de integração | `test/integracao/tec<Nome>ItgTst.tlpp` |
| Função de produção | `user function tec<Nome>` → chamável como `u_tec<Nome>` |
| Função de teste | `user function test_tec<Nome>_<descricao_snake_case>` (descrição em PT) |
| Tabela de teste | `Z_TST_<NOME>` no banco de teste do projeto |
| Encoding | **CP1252** em `.tlpp`/`.prw`/`.prx` (nunca UTF-8) |

Notação húngara nas variáveis: `cNome`, `nValor`, `lAtivo`, `dData`, `aLista`,
`jObj`, `oObj`, `bBlock`. Tipagem estrita: **não** escreva `as <tipo>` em variável
inicializada com `nil`, e **não existe** `as anytype` (omita o `as` em parâmetro
genérico).

**`namespace` muda o nome registrado.** `user function foo` sem namespace registra
`u_foo` global; com `namespace bar`, registra `bar.u_foo` — e `/runner/exec` não
acha `u_foo`. Módulos cujas funções são chamadas por nome (testes, wrappers,
helpers) **não** devem ter namespace.
