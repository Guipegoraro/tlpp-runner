# Troubleshooting — sintoma, causa, correção

Falhas que **realmente aconteceram** neste ambiente, com o diagnóstico que resolveu.
Formato: sintoma exato (o que você lê na tela ou no log) → causa raiz → correção.

Complemento: a [árvore de decisão da seção 8 do ARCHITECTURE.md](ARCHITECTURE.md#8-troubleshooting-decision-tree)
resume o mesmo material em formato de fluxograma — útil quando você ainda não sabe
em que categoria cair. Aqui há o porquê e o detalhe.

> Antes de investigar qualquer coisa: `/tlpp-tdd-setup` roda como **doctor**
> (idempotente). Ele diagnostica config morta, AppServer fora do ar, framework fora
> do RPO, path inválido e instância isolada quebrada — e oferece o fix. Comece por
> ele se o sintoma é vago.

---

## 1. Compilação e a janela de restart do HTTPREST

### `connection refused` (ou porta 8401 fechada) logo depois de compilar

**Causa.** O HTTPREST está fora pela compilação (issue #29) — e isso vale para
**qualquer** fonte, não só os que têm `@Get`/`@Post`. O gatilho é a escrita no RPO,
que é aberto com **lock exclusivo**: para compilar, o AppServer executa "Stopping
all HTTP servers". Com `BuildKillUsers=1` o job `HTTP_START` do `[ONSTART]` morre
junto, e o REST só volta no **próximo ciclo do `[ONSTART] RefreshRate`** — o
intervalo em que o AppServer confere e relança os jobs. `recompile=F` não evita.

Quanto dura depende desse valor no `appserver.ini`:

| `[ONSTART] RefreshRate` | REST de volta após o fim do build |
|---|---|
| `2` (o que o setup grava: template de `IniIO.ps1`, `Set-AppServerRest.ps1`, `New-IsolatedInstance.ps1`) | ~5 s (build ~7-8 s, janela total ~13 s) |
| `120` (valor comum em ini antigo) | até ~2 min (~92 s medido) |

Dois corolários que costumam surpreender:

- **Compile que FALHA também derruba os HTTP servers.** O custo é da tentativa de
  lock, não do commit. Não existe "testar sintaxe de graça" compilando com erro.
- **Não existe AppServer "só de compilação" ao lado** do que serve: o segundo
  recebe `Failed to open repository ... used by another process`. Isolar compilação
  de atendimento exige **RPOs separados**, não instâncias apontando pro mesmo RPO
  (veja "RPO aberto por outro AppServer" abaixo).

**Correção.** Nenhuma — é esperado. **Não retente na mão.** O
`Invoke-TlppRunner.ps1` já aguarda com backoff assimétrico: espera de até 180 s
quando a porta TCP do AppServer aceita conexão (servidor reiniciando — cobre ini
com `RefreshRate` alto), curta quando recusa (processo morto). Enquanto ele imprime
`REST reiniciando`, está tudo normal: a porta REST fica fechada a janela inteira, é
assim mesmo.

Se cada compilação deixa o REST fora por ~1-2 min, o `appserver.ini` está com
`RefreshRate` alto: rode `/tlpp-tdd-setup` (doctor) ou `Set-AppServerRest.ps1`
(aceita `-DryRun`), que baixa o valor in-place, e reinicie o AppServer.

**Como reduzir a exposição.** Com `isolation` no `.tlpp-tdd.json` (#34) a janela
passa a ser **por instância** — compilar no seu projeto não derruba o REST dos
outros. Veja a seção 4.1 do [ARCHITECTURE.md](ARCHITECTURE.md).

### `AppServer nao responde em <host>:<porta> ha <N>s - parece desligado`

**Causa.** Diferente do anterior: aqui a porta TCP **recusa** conexão, ou seja o
processo não está no ar.

**Correção.** Suba o AppServer. Retentar não resolve. Se ele não sobe, veja as
seções 2 e 6 abaixo.

### `[build] ... ja no RPO com este conteudo (oraculo RPO) - pulando` / `[build] OK (nada a compilar - HTTPREST intacto)`

**Isto é sucesso, não falha.** O oráculo RPO (#33) perguntou ao AppServer o
`dataFonte` de cada objeto e concluiu que o RPO já tem exatamente esse conteúdo.
Compilar à toa deixaria o REST fora do ar por uma janela de restart sem ganho nenhum.

**Não force recompilação por conta própria.** O cache invalida sozinho quando o
conteúdo muda. `-Force` existe, mas usar sem motivo é autossabotagem.

### `COMPILEERROR-300 Failed to open repository`

**Causa.** O RPO está com lock exclusivo de outro processo. Os dois casos reais:

- **Debugger do TDS-VSCode segurando o RPO**, mesmo sem janela aberta — a extensão
  TOTVS mantém o language server vivo (e faz respawn automático de `advpls.exe`;
  matar os processos não resolve, voltam em segundos).
- **Segunda instância de AppServer apontando pro MESMO RPO.**

**Correção.** Feche o VSCode ou reinicie o AppServer. `BuildKillUsers=1` na seção
`[General]` do `appserver.ini` ajuda com sessões que podem ser mortas, mas **não**
mata sessão de debugger. Instância isolada (#34) tem RPO próprio — é a solução
estrutural quando duas frentes compilam na mesma máquina.

### RPO aberto por outro AppServer: `COMPILEERROR-300` e o REST não volta

**Sintoma.** O build falha com `COMPILEERROR-300 Failed to open repository ... used
by another process`, o `Invoke-TlppBuild.ps1` imprime `[build] o RPO esta aberto
por OUTRO AppServer (mesmo custom.rpo)`, e depois disso o `/runner/*` fica em
`connection refused` indefinidamente.

**Causa.** Dois AppServers abertos sobre o mesmo `custom.rpo` (ex.: um de
desenvolvimento e o `appserver_rest` juntos). Só um processo por vez escreve no
RPO, então a compilação falha pelos dois. Quando a falha vem pelo AppServer do
REST, ele já executou "Stopping all HTTP servers" no início do build e não os
religa.

**Correção.** Feche o outro AppServer e **reinicie** o do REST — sem o restart os
HTTP servers não voltam. Para manter duas instâncias vivas na mesma máquina, cada
uma precisa de RPO próprio (instância isolada, #34).

### `Regular functions are not allowed`

**Causa.** O fonte tem `function nome()` puro. Função regular exige token JWT do
portal TOTVS (chave Harpia).

**Correção.** `user function` (visível como `u_nome`) ou `static function` (privada
do módulo). Sempre.

### `[FATAL] Annotation @TESTFIXTURE not defined`

**Causa.** Falta `#include "tlpp-probat.th"` no topo do arquivo de teste.

**Correção.** As três linhas de cabeçalho, uma única vez, antes de qualquer
`@TestFixture`:

```tlpp
#include "tlpp-core.th"
#include "tlpp-probat.th"
using namespace tlpp.probat
```

### `Incompatible types between D and U` (ou similar)

**Causa.** Tipagem estrita do TLPP rejeitando `local x := nil as <tipo>`.

**Correção.** Remova o `as <tipo>` quando inicializar com `nil`, ou inicialize com
valor neutro. E lembre: **não existe `as anytype`** — em parâmetro genérico, omita
o `as`.

### `advpls.exe nao encontrado` / `Includes nao encontrado`

**Causa.** `AdvplsPath` ou `ProtheusRoot` errados em `~/.claude/tlpp-tdd/config.ps1`
(o `ProtheusRoot` precisa conter `Protheus\include`).

**Correção.** Rode `/tlpp-tdd-setup` — o doctor re-detecta os paths e faz merge na
config global preservando as outras chaves.

---

## 2. AppServer que não sobe

### AppServer travado em `Loading Ctree Local [ctreestd.dll]`

**Causa.** Não é o ctree. É **License Server zumbi**. O serviço `licenseVirtual`
roda um `appserver.exe` próprio; se ele virar zumbi (aconteceu: processo vivo por
duas semanas sem responder), mantém os locks dos arquivos c-tree locais — que são
single-process — e qualquer outro AppServer trava exatamente nessa linha do log.

**Diagnóstico rápido.** `Get-Service licenseVirtual` diz `Stopped` mas
`Get-Process appserver` mostra o PID vivo; porta 5555 aberta mas sem resposta útil.

**Correção.** Matar o zumbi **com elevação** (sem elevação dá "Acesso negado") e
subir o serviço:

```powershell
Start-Process taskkill -Verb RunAs -ArgumentList '/F','/PID','<pid_do_zumbi>'
Start-Service licenseVirtual
```

Subida saudável passa por essa linha do log em menos de 1s.

### `appserver.exe` sai em silêncio, sem erro no console.log nem no Event Log

**Causa.** Iniciado **sem `-console`**. Sem o argumento ele tenta modo serviço, loga
até `Starting (TOTVS)... Please wait...` e morre calado.

**Correção.** Sempre com `-console`:

```powershell
Start-Process <exe> -ArgumentList '-console' -WorkingDirectory '<...>\bin\appserver_rest'
```

Instâncias isoladas (#34) já sobem assim por desenho (janela minimizada, sem
auto-stop).

### Instância isolada (#34) não sobe

**Causa provável.** Erro de ambiente/porta na instância, ou árvore incompleta
(cópia interrompida).

**Correção.** Leia o `console.log` **da instância**
(`<ProtheusRoot>\Protheus\bin\appserver_<nome>\console.log`, que o cascade expõe em
`$TlppRunner.ConsoleLogPath` quando o projeto é isolado). Se a árvore estiver
incompleta, recrie com `New-IsolatedInstance.ps1` (aceita `-Force`; use `-DryRun`
primeiro para ver as portas que ele alocaria sem copiar nada).

---

## 3. Endpoint REST do runner

### HTTP 428 no `/runner/ping`

**Causa.** **License Server fora do ar.** Não é erro de autenticação nem de rota. O
sintoma colateral no log é `REST could not be initialized!`.

**Correção.** Suba o License Server (veja o caso do zumbi na seção 2) e reinicie o
AppServer REST.

### HTTP 401 Unauthorized

**Causa.** Usuário/senha errados.

**Correção.** Confira `User` e `Password` em `~/.claude/tlpp-tdd/config.ps1`.
`/tlpp-tdd-setup` re-pergunta a senha quando detecta 401.

> **Não fique retentando com senha errada.** Já aconteceu de o login `sa` do SQL
> Server ficar **bloqueado por política de brute force** depois de uma rajada de
> tentativas do REST. Destravar exige Windows Auth:
> `ALTER LOGIN sa WITH PASSWORD='<senha>' UNLOCK`.

### HTTP 404 `{"error":"funcao_nao_existe","function":"..."}`

**Causa.** A função pedida não está no RPO. Duas origens:

1. **O fonte não compilou.** Rode `/tlpp-build` e confira
   `[SUCCESS] ... compiled successfully`.
2. **O módulo tem `namespace` no topo.** `user function foo` sem namespace registra
   `u_foo` global; **com** `namespace bar`, registra `bar.u_foo` — e o `/runner/exec`
   não acha `u_foo`. Vale para qualquer função chamada por nome (`tlpp.ffunc`,
   `/runner/exec`, teste). Em módulo só de rotas `@Get`/`@Post`, namespace é seguro.

**Correção.** Compile, ou remova o `namespace` do módulo (ou aceite e chame pelo
nome qualificado).

### HTTP 400 `{"error":"body_vazio"}` / `json_invalido` / `function_obrigatoria`

**Causa.** Requisição malformada para o `/runner/exec` (ou `name_obrigatorio` no
`/runner/func`): corpo vazio, JSON que não faz parse, ou sem a chave `function`. O
código vem no corpo JSON da resposta, que o runner imprime depois de `[runner] HTTP 400`.

**Correção.** Confira o `-Function`/`-ArgString` passado, ou o body se estiver
chamando o endpoint direto.

### HTTP 500 `{"error":"runtime",...}` — `u_x: ERRO <mensagem>`

**Causa.** Erro de execução dentro da função chamada (type mismatch, variável
inexistente, chamada a função que não está no RPO...). O endpoint captura o erro e
devolve HTTP 500 com
`{"error":"runtime","function","argString","message","stack","duration","asserts"?}`.
A pilha aponta o fonte e a linha da função chamada. O runner imprime a mensagem, as
primeiras linhas da pilha e os `FAIL` registrados até o erro:

```
[runner] HTTP 500
u_tecPrbCrash: ERRO type mismatch on +
  type mismatch on +  on U_TECPRBCRASH(TECPRBEXEC.TLPP) ... line : 23
  ...
```

Durante TDD, a função-alvo que ainda não existe no RPO, chamada de dentro do teste,
cai aqui: é o **vermelho esperado**.

**Correção.** Vá ao fonte e à linha que a pilha indica. Não é preciso abrir o
`console.log`.

### HTTP 500 `{"code":500,"message":"Internal Server Error"}` (genérico)

**Causa.** `Break("...")` explícito no código chamado, ou erro que derruba a thread
inteira antes do `catch` (ex.: `Empty()` sobre JsonObject, seção 5). Os dois escapam
do tratamento do endpoint e voltam como o 500 genérico do tlppCore, sem mensagem
nem pilha.

**Correção.** Aqui, e só aqui, o detalhe está no log do AppServer:

```powershell
. "$env:CLAUDE_PLUGIN_ROOT\runner\runner.config.ps1"
Get-Content $TlppRunner.ConsoleLogPath -Tail 40
```

(o `error.log` do AppServer também registra a ocorrência).

> **`FWRest` apontando para o próprio AppServer** não produz nenhum dos dois: é
> deadlock/crash. Use `u_tecHttpReq`, que usa `HTTPQuote` stand-alone.

### `result=.F.` e você não sabe qual assert falhou

**Causa.** Nenhuma — é o fluxo normal. A resposta do `/runner/exec` traz o campo
`asserts` (`u_tecAssertSummary()`: `ok`, `passed`, `failed`, `fails[]`), e o runner
imprime o placar e uma linha por falha.

**Correção.** Leia a saída do `/tlpp-test`:

```
u_test_x: result=.F. dur=0.002s asserts=1ok/2fail
  FAIL: soma errada | expected=3 actual=2
  FAIL: programs vazio | expected=<empty> actual=<J>
```

Cada `FAIL` tem a descrição que você escreveu mais o detalhe por tipo. O
`console.log` recebe as mesmas linhas como `[ASSERT_OK]`/`[ASSERT_FAIL]` via
`ConOut` — complemento para ver a ordem de execução, não o caminho principal.

### `result=.F.` sem placar `asserts=` nem linha `FAIL`

**Causa.** O teste não executou nenhum assert — o campo `asserts` só vem na resposta
quando a chamada registrou ao menos um. `u_tecAssertsOk()` devolve `.T.` só se
`falhas == 0` **e** `ok > 0`: teste que não afirma nada reprova de propósito.
Costuma ser `return` antecipado antes do primeiro assert.

**Correção.** Confira o fluxo do teste. Se houve erro de execução, a resposta é o
500 `error=runtime` acima, com a pilha.

### `result=.T.` suspeito (teste que passou de primeira)

**Causa.** Falso verde. As três origens reais:

- **Falta `u_tecAssertReset()`** — contador vazado do teste anterior.
- **Falta `return u_tecAssertsOk()`** — o `result` não reflete assert nenhum.
- **O fonte de produção não passa pelos wrappers** — o mock não intercepta, o teste
  exercita outra coisa.

**Correção.** Veja a anatomia do teste no
[TDD-GUIDE.md](TDD-GUIDE.md#3-anatomia-de-um-teste).

---

## 4. Banco e DBAccess

### `TOPCONN - No connection: -2`

**Causa.** Não há conexão DBAccess ativa no ponto em que a query rodou. Na prática:
o contexto do projeto (`projectName`/`testDbAlias`/`dbAccessHost`/`dbAccessPort`)
não foi propagado para o AppServer, ou a config global aponta para host/porta
errados de DBAccess.

**Correção.** Confira `~/.claude/tlpp-tdd/config.ps1` (host e porta do DBAccess) e
o `.tlpp-tdd.json` do projeto. Em teste de integração, o `u_tecTstConn` é quem abre
a conexão — se você chamou query antes dele, é isso. Rode
`/tlpp-tdd-project-init` se o projeto nunca foi inicializado.

### `TCLink` devolve `-35`

**Causa.** Uma de duas:

1. **Alias não registrado no DBAccess.** Sem a seção
   `[MSSQL/PROTHEUS_TST_<NOME>]` no `dbaccess.ini`, o TCLink devolve -35
   ("Invalid environment received").
2. **DBAccess não releu o ini** depois de você adicionar o alias.

**Correção.** `/tlpp-tdd-project-init` cria o alias (com backup do ini). Depois
**reinicie o serviço DBACCESS** (`dbaccess64.exe` precisa fechar e abrir) — e, se o
`appserver_rest` estava conectado, reinicie-o também.

> **Sintaxe do TCLink:** o formato oficial é `<driver>/<alias>`.
> `TCLink("MSSQL/PROTHEUS_TST", "localhost", 7890)` funciona;
> `TCLink("PROTHEUS_TST", ...)` devolve -35.

### `TCLink` devolve `-1`

**Causa.** O login que o DBAccess usa não tem permissão no banco de teste.

**Correção.** Conceda `db_owner` no banco de teste aos logins usados
(`sa` e `sysdba` no caso desta máquina). `New-TestDatabase.ps1 -Mode Fresh` já cria
os grants. Detalhes em [DATABASE-SETUP.md](DATABASE-SETUP.md).

### `Falha de logon do usuario ''`

**Causa.** Duas causas distintas, ambas já vividas:

1. **`ConnectionMode=2` ignora `user=`/`password=` da seção.** Quem autentica são
   `UID=`/`PWD=` **dentro da `ConnectionString`**. Alias escrito só com `user=`
   sobe, mas não autentica.
2. **`dbaccess.ini` corrompido por leitura ASCII.** As chaves `password=` guardam
   senha **cifrada** pelo `dbaccesscfg`, com bytes `>0x7F`. Ler com
   `Get-Content -Encoding ASCII` e regravar transforma cada um em `?` — e derruba a
   autenticação de **todos** os aliases já existentes no arquivo.

**Correção.** Para (1), inclua `UID`/`PWD` na `ConnectionString` (o
`Set-DBAccessAlias.ps1` herda as credenciais de um alias `[MSSQL/*]` que já
funciona no mesmo ini; `-ConnectionUser`/`-ConnectionPassword` sobrescrevem). Para
(2), **nunca** manipule o ini com ASCII/UTF-8: use `runner/install/IniIO.ps1`
(`Read-IniLines`/`Write-IniLines`, Latin1/28591, que mapeia 1:1 byte↔char). Se já
corrompeu, restaure o `.bak.<timestamp>` que os scripts geram.

### `Database ... does not exist` / `Tabela Z_TST_* inexistente`

**Causa.** Banco ou schema não criados.

**Correção.** `/tlpp-tdd-project-init` (cria banco + alias + `.tlpp-tdd.json`); para
schema, `db-setup.ps1` aplica o schema do framework e o do projeto (`schemaPath`).
Tabela nova reutilizável: `/tlpp-table create <nome> "<cols>"`.

---

## 5. Pegadinhas de tipo do TLPP

### `Empty(JsonObject)` crasha a thread

**Causa.** `Empty()` não suporta JsonObject em TLPP e derruba a thread inteira:
o `catch` do `/runner/exec` não chega a rodar e a resposta é o 500 genérico do
tlppCore (`{"code":500,"message":"Internal Server Error"}`), sem mensagem nem
pilha. O detalhe fica só no `console.log` (veja a seção 3).

**Correção.** Use `u_tecAssertEmpty` / `u_tecAssertNotEmpty`, que são tipo-aware —
para JsonObject decidem por `Len(xVal:GetNames()) == 0`. Em código de produção, use
`:hasProperty()` ou `Len(:GetNames())` direto.

### `ValType(JsonObject)` devolve `"J"`, não `"O"`

**Causa.** É assim em TLPP. Código que testa `ValType(x) == "O"` para detectar
objeto não reconhece JsonObject.

**Correção.** Use `:hasProperty()` direto. É também por isso que uma falha de
assert mostra `actual=<J>` em vez de `<object>`.

---

## 6. PROBAT

### `tlpp.probat.run "type:suite","X"` devolve 0/0

**Causa.** `[PROBAT] TESTS_DISCOVERY_MODE=0` no `appserver.ini`: fonte recém
compilado não é descoberto automaticamente. Há um segundo motivo somado: os asserts
próprios do framework (`u_tecAssert*`) **não contam como testcase** para o PROBAT,
que espera `assertEquals` da include — ele reporta `Test without testcase`.

**Correção.** Use a **rota por função**, que é a recomendação do projeto:
`/tlpp-test <funcao>` (via `/runner/exec`, devolve `result=.T./.F.` confiável em
milissegundos). Se precisar do PROBAT (CI, JUnit XML), chame
`tlpp.probat.discovery()` antes de `tlpp.probat.run`, ou configure
`TESTS_DISCOVERY_MODE=1`. Detalhes em [SETUP.md](SETUP.md).

---

## 7. Não achou aqui?

| Situação | Onde olhar |
|---|---|
| Fluxograma rápido por sintoma | [ARCHITECTURE.md § 8](ARCHITECTURE.md#8-troubleshooting-decision-tree) |
| Assinatura/semântica de um helper que está se comportando diferente do esperado | [REFERENCE.md](REFERENCE.md) |
| "Como eu testo *isto*?" | [RECIPES.md](RECIPES.md) |
| Limitações conhecidas, custos, portas, paths | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Instalação manual, PROBAT, pré-requisitos | [SETUP.md](SETUP.md) |
| Banco de teste, alias, grants | [DATABASE-SETUP.md](DATABASE-SETUP.md) |
| Desfazer uma etapa do install | [ROLLBACK.md](../ROLLBACK.md) |
| Diagnóstico automático | `/tlpp-tdd-setup` (doctor mode) |
