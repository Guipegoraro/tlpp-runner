# LLM Workflow — TDD em TLPP/AdvPL

Guia enxuto pra LLM consumidora (Claude Code, Codex, etc) usar o `tlpp-runner` sem precisar ler tudo.

## TL;DR

Loop: **editar teste → `/tlpp-test <funcao>` → ler `result=.T./.F.` → ajustar fonte → repetir**. Não precisa de TDS-VSCode. O `/tlpp-test` compila o que mudou antes de rodar. Asserts customizados retornam `.T./.F.` confiável via `/runner/exec`.

## Setup mínimo (uma vez)

- Veja `docs/SETUP.md` se for novo no repo
- Compilar tudo de novo: `& .\runner\Invoke-TlppBuild.ps1 -All`
- Sanity: `& .\runner\Invoke-TlppRunner.ps1 -Ping` → HTTP 200

## Smoke test do framework (~30s)

Antes de começar TDD em uma sessão nova, valide que a infra está OK:

```powershell
# 1. REST respondendo
& .\runner\Invoke-TlppRunner.ps1 -Ping   # espera "PING OK"

# 2. Asserts customizados no RPO
& .\runner\Invoke-TlppRunner.ps1 -Function u_tecAssertReset -Quiet
# espera: u_tecAssertReset: result=.T. dur=0.001s

# 3. Skill presente
Test-Path .\.claude\skills\tlpp-tdd\SKILL.md   # espera True

# 4. (Opcional) Se voce instalou os examples, teste um deles:
# & .\runner\Invoke-TlppRunner.ps1 -Function u_test_tecCalcDsc_10pct_faixaAlta -Quiet
```

Se algo falhar: ver `docs/SETUP.md` Troubleshooting.

## Loop TDD (5 passos)

1. **Escrever teste** em `test/unit/tecXxxTst.tlpp` (sem banco) ou `test/integracao/tecXxxItgTst.tlpp` (com banco). Padrão obrigatório:

   ```tlpp
   #include "tlpp-core.th"
   #include "tlpp-probat.th"
   using namespace tlpp.probat

   @TestFixture()
   user function test_minha_feature_caso1()
       u_tecAssertReset()
       // ... arrange + act
       u_tecAssertEq("desc", esperado, atual)
   return u_tecAssertsOk()
   ```

2. **Rodar o teste**: `/tlpp-test u_test_minha_feature_caso1` → espera `.F.` na 1ª (função fonte não existe).

3. **Implementar** o fonte mínimo em `src/<nome>.tlpp` (sempre `user function`, nunca `function` puro). Compilar é explícito: `/tlpp-build <arquivo>` — ou deixe o `/tlpp-test` do passo seguinte compilar antes de rodar.

4. **Re-rodar**: `/tlpp-test u_test_minha_feature_caso1` → `.T.`. Se ainda `.F.`, a própria saída do runner traz o placar e uma linha por assert que falhou (vem do campo `asserts` da resposta do `/runner/exec`):

   ```
   u_test_minha_feature_caso1: result=.F. dur=0.002s asserts=1ok/2fail
     FAIL: soma errada | expected=3 actual=2
   ```

   Erro de execução na função (type mismatch, variável inexistente...) sai como `u_x: ERRO <mensagem>` seguido da pilha com fonte e linha, mais os `FAIL` registrados até o erro.

5. **Refator** com confiança — rerodar o teste após cada mudança. Iterar.

## APIs do framework

**Catálogo canônico**: [REFERENCE.md](REFERENCE.md) — assinaturas completas, semântica de retorno (`""` vs `nil` vs array vazio), pegadinhas de tipo, limites do mock de MVC. Consulte lá antes de assumir comportamento. Resumo mínimo para orientação:

**Asserts** (`src/tecAssert.tlpp`): `u_tecAssertReset()` (obrigatório na 1ª linha) · `u_tecAssertsOk()` (obrigatório no `return`; `.T.` só se 0 falhas **e** ≥1 ok) · `Eq`/`Neq`/`True`/`False` · `Empty`/`NotEmpty` (tipo-aware, enxerga JsonObject) · `Greater`/`Less` · `HttpStatus`/`HttpBodyContains`/`HttpJsonField` (path `a.b.0.c`).

**Wrappers** (`src/tecWrap.tlpp`) — em produção **sempre** o wrapper, nunca a API direta, senão o mock não intercepta:

| Wrapper | Substitui | Mock |
|---|---|---|
| `u_tecDbSeekFld` | `DbSeek` + `ALIAS->CAMPO` | `u_tecMkBdSeek` |
| `u_tecBuscaCli` / `u_tecBuscaTitulo` / `u_tecBuscaPedido` / `u_tecBuscaItensPedido` | `SA1` / `SE1` / `SC5` / `SC6` | `u_tecMkBdSeed` |
| `u_tecQryFirst` / `u_tecQryAll` | `TCQuery` / `TOPCONN` | `u_tecMkSql` (match por SQL **exato**) |
| `u_tecGetMv` | `GetMv` / `GetNewPar` | `u_tecMkMv` (3º arg valida C/N/L/D) |
| `u_tecHttpReq` / `u_tecHttpPost` | `FWRest():new()` | `u_tecMkHttp("VERB URL" ou "URL", nStatus, cBody)` |
| `u_tecHoje` / `u_tecHora` | `Date()` / `Time()` | `u_tecMkHoje` / `u_tecMkHora` |
| `u_tecMkModel` | dublê de `FwFormModel` (MVC sem tela/banco; **não** usa modo teste) | — |

**Ordem load-bearing**: `u_tecAssertReset()` → `u_tecTstStart()` → **mocks** → act → asserts → `u_tecTstStop()`. O `Start` **cria** os dicionários de mock; `u_tecMk*` antes dele é perdido silenciosamente. `u_tecTstWith({|| ... })` garante o teardown mesmo com exceção.

**Helpers de banco** (`test/integracao/tecTstDbHlp.tlpp`), para integração: `u_tecTstConn(@nLinkAnt)` / `u_tecTstDisconn` · `u_tecTstCreateTable` / `DropTable` (idempotentes) · `u_tecTstSeed` (escapa tipos) · `u_tecTstTruncate`. Tabela permanente reutilizável: `/tlpp-table create Z_TST_NOME "COL TIPO; ..."`.

Código pronto por cenário: [RECIPES.md](RECIPES.md). Racional e escolha de casos de teste: [TDD-GUIDE.md](TDD-GUIDE.md). Erro na mão: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Anti-patterns

- ❌ `function nome()` regular — exige token JWT, não compila localmente. Use `user function` ou `static function`.
- ❌ Esquecer `u_tecAssertReset()` no início — contador herda do teste anterior.
- ❌ Esquecer `return u_tecAssertsOk()` no fim — `result` no `/runner/exec` vira `.T.` sem refletir asserts.
- ❌ Rodar `tlpp.probat.run "type:suite","X"` esperando descoberta automática — limitações documentadas em `docs/SETUP.md`. Prefira `/tlpp-test <funcao>`.
- ❌ Usar `Empty()` em JsonObject diretamente — não suportado. Use `u_tecAssertEmpty` (tipo-aware) ou `:hasProperty()`.
- ❌ `FWRest` dentro de endpoint REST chamando outro endpoint do **mesmo** AppServer — pode causar deadlock. Use `u_tecHttpReq` (delega a `HTTPQuote`).
- ❌ Criar SX3/SX6/SIX via fonte — use o Configurador.
- ❌ Tratar `[build] ... pulando` ou `nada a compilar - HTTPREST intacto` como falha — é **sucesso**. O fonte já está no RPO com esse conteúdo, e compilar à toa derrubaria o REST sem ganho nenhum. Não force recompilação por conta própria; o cache invalida sozinho quando o conteúdo muda.
- ❌ Insistir em nova tentativa ao ver `connection refused` logo após compilar — o HTTPREST cai a **cada** compilação (não só de fonte com `@Get/@Post`) e só volta no próximo ciclo do `[ONSTART] RefreshRate` (~5s depois do build com o `RefreshRate=2` que o setup grava; até ~2 min num ini com 120). O wrapper já aguarda: enquanto ele imprime `REST reiniciando`, está tudo normal — a porta 8401 fica fechada a janela inteira, é assim mesmo. Só quando ele diz `AppServer nao responde em <host>:<porta>` é que o processo está realmente parado, e aí retentar não resolve (suba o AppServer).

## Exemplo mínimo end-to-end

**Teste** (`test/unit/tecDobroTst.tlpp`):

```tlpp
#include "tlpp-core.th"
#include "tlpp-probat.th"
using namespace tlpp.probat

@TestFixture()
user function test_dobro_inteiro()
    u_tecAssertReset()
    u_tecAssertEq("dobro de 5", 10, u_tecDobro(5))
    u_tecAssertEq("dobro de 0",  0, u_tecDobro(0))
return u_tecAssertsOk()
```

**Fonte** (`src/tecDobro.tlpp`):

```tlpp
#include "tlpp-core.th"

user function tecDobro(nVal as numeric)
    DEFAULT nVal := 0
return nVal * 2
```

**Run**:

```
/tlpp-test u_test_dobro_inteiro
```

Saída esperada: `u_test_dobro_inteiro: result=.T. dur=0.001s`.
