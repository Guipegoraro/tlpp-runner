# Guia de TDD em ADVPL/TLPP

Este é o documento de **primeiro contato**. Ao final dele você entende por que
TDD faz sentido num ambiente com ciclo de compilação caro, sabe escrever um teste
que roda, sabe escolher *quais* casos testar, e reconhece a saída de cada etapa do
loop vermelho → verde.

Não é necessário abrir o código do framework para escrever o primeiro teste. Se
depois você quiser a assinatura exata de cada helper, o catálogo canônico é o
[REFERENCE.md](REFERENCE.md); receitas por cenário estão em
[RECIPES.md](RECIPES.md); quando algo quebrar, [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 1. Por que TDD aqui, apesar do ciclo de compilação

A objeção honesta primeiro: **toda compilação derruba o HTTPREST do AppServer**
(issue #29). O AppServer executa "Stopping all HTTP servers"; com `BuildKillUsers=1`
o job `HTTP_START` do `[ONSTART]` morre, e o REST só volta no próximo ciclo do
`[ONSTART] RefreshRate` — o intervalo em que o AppServer confere e relança os jobs.
Com o `RefreshRate=2` que o setup grava, o build leva ~7-8 s e o REST responde ~5 s
depois (janela total ~13 s). Num `appserver.ini` com `RefreshRate=120` a janela
chega a ~2 min; `/tlpp-tdd-setup` (doctor) baixa o valor. Não é por causa de
`@Get`/`@Post` — fonte sem nenhuma annotation derruba igual, porque o gatilho é a
**escrita no RPO**, que é aberto com lock exclusivo. Um compile que **falha** também
derruba os HTTP servers: o custo é da tentativa de lock, não do commit. Passar
`recompile=F` não evita.

Num loop TDD ingênuo — editar, compilar, esperar o REST voltar, rodar — essa espera
se repete a cada iteração. O que mantém o loop curto são três coisas, todas já
implementadas:

| Mitigação | O que faz | Efeito prático |
|---|---|---|
| **Oráculo RPO** (#33) | Antes de compilar, pergunta ao próprio AppServer o `dataFonte` de cada objeto no RPO e compara com o mtime do arquivo em disco | Fonte que já está no RPO com aquele conteúdo **não é recompilado** — janela de restart = zero |
| **Cache de build local** (`runner/BuildCache.ps1`) | Fallback quando o oráculo não responde | Mesma economia, por hash de conteúdo |
| **Isolamento opt-in** (#34) | `isolation` no `.tlpp-tdd.json` dá ao projeto uma instância AppServer + RPO próprios | A janela de restart passa a ser **por instância**: compilar aqui não derruba o REST dos outros projetos |

E o feedback em si é barato: a **rota por função** (`/tlpp-test <funcao>`, que bate
em `POST /runner/exec`) devolve **uma linha** com `result=.T./.F.` e o placar dos
asserts em milissegundos, mais uma linha por assert que falhou. Você não paga
PROBAT, não paga discovery, não abre TDS-VSCode, não aperta Ctrl+F9.

Ou seja: a janela de restart não é paga a cada rodada, só **na primeira** iteração
de cada mudança de fonte; as rodadas de teste custam ~0. Rodar o
mesmo teste 20 vezes enquanto você pensa custa nada.

### E o que se ganha

O ganho é maior aqui do que na média porque customização Protheus roda em produção
com muitos pontos de entrada não óbvios: empresas/filiais diferentes, `MV_*`
inexistente, registro marcado como deletado, parâmetro com tipo errado, URL externa
instável, data em formato BR vs ISO, operador digitando espaço no fim. Um teste só
de caminho feliz cobre ~10% do que aparece no cliente. Os outros 90% são
descobertos em produção — onde descobrir é mais caro (ticket, hotfix, operador
travado, confiança na integração erodida).

Um segundo ganho, específico de quem trabalha com LLM no loop: **o teste é a
especificação objetiva**. Sem ele, "pronto" é o julgamento subjetivo de quem
escreveu o código. Com ele, "pronto" é `result=.T.`.

---

## 2. Antes do primeiro teste

Uma vez por máquina:

```
/tlpp-tdd-setup
```

Faz tudo end-to-end (detecta ambiente, configura `[HTTPREST]` com backup, escreve
a config global, compila o framework no RPO, smoke test) e é idempotente —
re-rodar funciona como **doctor** quando algo quebra. Passo a passo manual em
[SETUP.md](SETUP.md).

Opcional, uma vez por projeto que vai ter teste de integração com banco:

```
/tlpp-tdd-project-init
```

Sanity de 5 segundos antes de começar uma sessão:

```powershell
& "$env:CLAUDE_PLUGIN_ROOT\runner\Invoke-TlppRunner.ps1" -Ping    # espera PING OK
```

---

## 3. Anatomia de um teste

Todo arquivo de teste abre com **estas três linhas, uma única vez**, antes de
qualquer `@TestFixture`. Sem o `#include "tlpp-probat.th"` a annotation não existe
e o arquivo inteiro morre na compilação com `Annotation @TESTFIXTURE not defined`:

```tlpp
#include "tlpp-core.th"
#include "tlpp-probat.th"
using namespace tlpp.probat
```

Depois, **um bloco por caso** (o cabeçalho de 3 linhas não se repete):

```tlpp
@TestFixture()
user function test_tecMinha_caminho_feliz()
    local cRet

    u_tecAssertReset()                       // 1
    u_tecTstStart()                          // 2
    u_tecMkMv("MV_TEC_PCT", 10, "N")         // 3  (arrange: DEPOIS do Start)

    cRet := u_tecMinha("000001")             // 4  act

    u_tecAssertEq("nome do cliente", "ACME", cRet)   // 5  assert

    u_tecTstStop()                           // 6
return u_tecAssertsOk()                      // 7
```

Cada peça é obrigatória por um motivo diferente. Vale entender, porque esquecer
qualquer uma produz **falso verde** — o pior defeito possível num teste.

### 1. `u_tecAssertReset()` — primeira linha, sempre

Os contadores de assert são variáveis `static` no módulo `tecAssert`, ou seja
vivem no **thread**, não no teste. Sem o reset, o contador de "ok" e "fail" que
sobrou do teste anterior vaza para o seu: um teste sem nenhum assert seu pode
retornar `.T.` porque o vizinho deixou 3 ok e 0 fail no contador.

### 2. `u_tecTstStart()` — liga o modo teste

Os wrappers de `src/tecWrap.tlpp` (`u_tecQryFirst`, `u_tecGetMv`, `u_tecHttpReq`,
`u_tecDbSeekFld`, `u_tecHoje`, …) têm dois caminhos: produção (vai no banco / na
rede / no relógio) e teste (lê o mock em memória). O que decide é a flag interna
que o `Start` liga. **Sem `Start`, o wrapper vai no recurso real** — seu "teste
unitário" tenta abrir conexão TOPCONN e falha de um jeito confuso.

### 3. Arrange **depois** do Start (ordem load-bearing)

`u_tecTstStart()` **cria os dicionários de mock vazios**. Chamar
`u_tecMkSql`/`u_tecMkBdSeed`/`u_tecMkMv`/`u_tecMkHoje` *antes* do Start é perda
silenciosa: o mock não tem onde se registrar (os helpers devolvem `.F.`) e o Start
em seguida zera tudo de novo. A ordem correta é sempre:

```
u_tecAssertReset()  ->  u_tecTstStart()  ->  mocks  ->  act  ->  asserts  ->  u_tecTstStop()
```

Exceção: `u_tecMkModel` (mock de `FwFormModel`) **não** depende do modo teste — é
um objeto dublê que você passa para a sua função, e funciona sem `Start`.

### 4-5. Act e assert

Chame a função sob teste e afirme sobre **o que ela retorna ou causa**, nunca
sobre como ela calcula. Vários asserts por caso são bem-vindos; descreva cada um
em português, porque a descrição é o que aparece na linha `FAIL:` quando falha.

Assert sobre o **mock** ("o `u_tecMkSql` foi configurado com este SQL?") testa a
infraestrutura de teste, não a sua função. Não faça.

### 6. `u_tecTstStop()` — desliga e limpa

Zera os mocks e desliga o modo teste. Sem ele o **próximo** teste herda seus mocks
e passa por motivo errado (ou falha por motivo errado, o que é menos ruim mas
igualmente confuso).

### 7. `return u_tecAssertsOk()` — última linha, sempre

É **o que a rota `/runner/exec` reporta**. `u_tecAssertsOk()` devolve `.T.` só se
`falhas == 0 E ok > 0`. Consequências das duas metades:

- Sem esse `return`, a função devolve qualquer outra coisa (ou `.T.` implícito) e
  **todo teste "passa"** sem refletir um único assert.
- Um teste que não executou nenhum assert devolve `.F.` — de propósito. Teste que
  não afirma nada não é teste.

### Alternativa: `u_tecTstWith`

Se o bloco entre Start e Stop pode estourar exceção (acesso a método de `nil`,
índice fora de array), o `Stop` nunca roda e o estado vaza. `u_tecTstWith` resolve:
executa o codeblock entre Start e Stop com `ErrorBlock` + `BEGIN SEQUENCE`, e
**garante o Stop mesmo com exceção** (nesse caso devolve `nil` e loga
`[tecTstWith] excecao capturada no bloco`).

```tlpp
@TestFixture()
user function test_tecMinha_com_teardown_garantido()
    local xRet

    u_tecAssertReset()

    xRet := u_tecTstWith({|| ;
        u_tecMkSql("Q1", { u_tecMkRow({{"N", "OK"}}) }), ;
        u_tecQryFirst("Q1")["N"] ;
    })

    u_tecAssertEq("retorno do bloco", "OK", xRet)
    u_tecAssertFalse("modo teste desligado apos o with", u_tecTstAtivo())
return u_tecAssertsOk()
```

---

## 4. Como escolher os casos de teste

Esta é a parte que mais rende e a que mais se pula. A regra prática: **8 a 15
casos para uma função média**. Menos de 5 é sinal de categoria esquecida; mais de
20 costuma significar que a função faz coisas demais e deveria ser dividida.

Aplique os filtros abaixo **antes de escrever qualquer código**. Para cada
categoria, decida explicitamente se aplica ou não — decidir "não aplica" é uma
resposta válida; não olhar não é.

### 4a. Checklist obrigatório (toda função)

- [ ] **Caminho feliz canônico** — um caso do domínio, o mais comum
- [ ] **Caminho feliz alternativo** — outro caso válido, com variação (outra faixa, outro tipo, outro ramo válido)
- [ ] **Parâmetro nil / não passado** — se existe `DEFAULT`, prove que o default entra; se não, documente o comportamento resultante (erro? retorno vazio?)
- [ ] **Parâmetro vazio** — string `""`, array `{}`, JsonObject sem propriedades
- [ ] **Fronteira numérica** — 0, -1, mínimo do domínio, máximo conhecido
- [ ] **Forma do retorno** — além do valor, afirme o **tipo** (`ValType`, `Len` do array, campos do JsonObject)

### 4b. Heurísticas por dependência (só as que se aplicam)

Liste as dependências externas da função. Cada uma traz casos obrigatórios:

| Dependência | Casos a cobrir |
|---|---|
| `DbSeek` em tabela (via `u_tecDbSeekFld`) | "registro não encontrado" + "registro encontrado com campo vazio" |
| `TCQuery` (via `u_tecQryFirst`/`QryAll`) | "0 linhas" + "múltiplas linhas" + (se relevante) "erro SQL" |
| `GetMv`/`GetNewPar` (via `u_tecGetMv`) | "parâmetro inexistente usa default" + "parâmetro com valor explícito" + (se importa) "parâmetro com tipo errado" |
| `FWRest` (via `u_tecHttpReq`) | HTTP 200 + 4xx + 5xx + (se relevante) timeout / erro de rede |
| `Date()`/`Time()` (via `u_tecHoje`/`u_tecHora`) | data fixa mockada, se a lógica depende da data |
| Outra `user function` do projeto | prefira **não** mockar — exercite indiretamente |

### 4c. Heurísticas específicas de Protheus

- Toca registro? Adicione **"registro deletado (`D_E_L_E_T_ = '*'`)"** e verifique o filtro
- Multi-empresa / multi-filial? **"filial diferente da corrente"** + **"filial em branco"**
- Cálculo monetário? **"arredondamento de centavos"** + **"valor negativo"** + **"valor zero"**
- Manipula data? **"virada de mês"** + **"ano bissexto (29/02)"** + **"data inválida (string vazia, BR vs ISO)"**
- Concatena `ALIAS->CAMPO`? Confirme que o fonte usa `u_tecDbSeekFld` — senão o mock **não intercepta** e o teste é falso verde

### 4d. Error guessing

- O operador consegue digitar algo inválido? (`01/05/2026` vs `2026-05-01`, espaço no fim, caixa alta/baixa)
- Rodar duas vezes seguidas dá o mesmo resultado? (idempotência — crítico em integração)
- Duas threads chamando junto? (raro em customização pontual, mas pense se houver escrita)

### 4e. Saída da fase: lista nomeada

Antes de escrever o primeiro teste, escreva a lista. Ela é o contrato do que você
vai cobrir, e é o artefato que outra pessoa (ou o cliente) pode criticar:

```
Casos planejados para tecCalcCmsn:
 1. test_tecCalcCmsn_tipo_A_faixa_baixa      -- 100, "A" -> 5
 2. test_tecCalcCmsn_tipo_A_faixa_alta       -- 10000, "A" -> 12
 3. test_tecCalcCmsn_tipo_B_aplica_metade    -- 1000, "B" -> 5
 4. test_tecCalcCmsn_tipo_invalido_fallback  -- 1000, "Z" -> usa tipo A
 5. test_tecCalcCmsn_valor_zero              -- 0 -> 0
 6. test_tecCalcCmsn_valor_negativo          -- -100 -> 0 + ConOut de aviso
 7. test_tecCalcCmsn_param_default_tipo      -- nil -> usa "A"
 8. test_tecCalcCmsn_mv_inexistente          -- MV vazio -> default 5%
```

> **Regra de negócio não se inventa.** Se um caso da lista depende de decisão de
> negócio sem fonte do cliente (bloquear? rejeitar? qual faixa?), não decida por
> conta: implemente o comportamento **mais permissivo** com rastro (log/aviso),
> registre a pergunta em `.claude/plans/<slug>/perguntas-cliente.md` e deixe um
> `TODO` inline apontando pra lá.

---

## 5. Unit (mock) ou integração (banco real)?

| Escolha **unit** (`test/unit/tec<Nome>Tst.tlpp`) quando | Escolha **integração** (`test/integracao/tec<Nome>ItgTst.tlpp`) quando |
|---|---|
| A função tem lógica (cálculo, decisão, transformação, montagem de payload) | O que você quer provar É o SQL / o DDL / o comportamento do banco |
| As dependências passam por wrapper e o mock reproduz a forma real do dado | Precisa validar collation, tipo de coluna, escape, `D_E_L_E_T_`, índice |
| Você quer feedback em milissegundos e rodar 20 vezes seguidas | Uma transação envolvendo várias tabelas precisa ser exercida de verdade |
| Não há efeito colateral no banco que outra parte do teste dependa | O mock exigiria reproduzir tanto do banco que já não prova nada |

Sinais de que você escolheu errado:

- **Setup de mock com 20 linhas e um assert.** A função faz coisas demais (divida)
  ou o caso é de integração.
- **Mock parcial.** A linha real de `SA1` tem 30 colunas, você mocou 3, e código
  a jusante lê a quarta e recebe `nil` calado. Espelhe a forma real do dado — inclua
  as colunas que a função *pode* tocar, não só as que o assert de hoje lê.
- **Teste de integração para provar um `if`.** Está pagando banco por nada.

Teste de integração precisa de banco e alias configurados
([DATABASE-SETUP.md](DATABASE-SETUP.md)); o padrão de conexão/criação/seed está em
[RECIPES.md](RECIPES.md#7-contra-banco-real-quando-o-mock-não-serve).

---

## 6. Do vermelho ao verde, com as saídas reais

Alvo: `u_tecMinha(cCod)` devolve o nome do cliente. Vamos ver **exatamente** o que
cada etapa imprime — reconhecer a saída é metade do trabalho.

### 6.1 Red — o teste existe, a função-alvo não

Escreva `test/unit/tecMinhaTst.tlpp` com o bloco da seção 3 e rode:

```
/tlpp-test u_test_tecMinha_caminho_feliz
```

O teste compila e roda, mas dentro dele a chamada `u_tecMinha(...)` não existe no
RPO. Isso é um **erro de execução** dentro da função chamada: o endpoint o captura e
devolve HTTP 500 com `{"error":"runtime", function, argString, message, stack,
duration}` (mais `asserts`, se algum assert rodou antes). O runner imprime a
mensagem e as primeiras linhas da pilha, que apontam o fonte e a linha do teste
onde a chamada falhou:

```
[runner] HTTP 500
u_test_tecMinha_caminho_feliz: ERRO InterFunctionCall: cannot find function U_TECMINHA in AppMap
  ...
  InterFunctionCall: cannot find function U_TECMINHA in AppMap on U_TEST_TECMINHA_CAMINHO_FELIZ(TECMINHATST.TLPP) ... line : 12
```

**Isso é um vermelho saudável** — é a prova de que o teste está de fato exercitando
a função que você ainda não escreveu.

> Não confunda com `HTTP 404 {"error":"funcao_nao_existe"}`: esse é **o próprio
> teste** que não está no RPO (não compilou). Aí não é vermelho de TDD, é build
> quebrado — veja [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

### 6.2 Red — a função existe e o assert falha

O outro vermelho legítimo: a função já está no RPO e devolve a coisa errada. Aí a
resposta é bem-comportada e o `result` reflete os asserts:

```json
{"function":"u_test_x","argString":"","result":".F.","duration":0.002,"env":"DESENVOLVIMENTO",
 "asserts":{"ok":false,"passed":1,"failed":1,"fails":["programs vazio | expected=<empty> actual=<J>"]}}
```

O motivo vem na própria resposta, no campo `asserts.fails`, com a descrição em
português que você escreveu. O runner (`/tlpp-test`) imprime assim:

```
u_test_x: result=.F. dur=0.002s asserts=1ok/1fail
  FAIL: programs vazio | expected=<empty> actual=<J>
```

O `console.log` do AppServer também recebe `[ASSERT_OK]`/`[ASSERT_FAIL]` via
`ConOut` — útil como complemento, por exemplo para ver a ordem em que os asserts
rodaram, mas não é preciso abri-lo para saber o que falhou.

E se a função chamada estourar no meio (type mismatch, variável inexistente...), a
resposta é o 500 `error=runtime` da seção 6.1: mensagem, pilha com fonte e linha, e
os `FAIL` registrados até o erro. A única exceção é `Break("...")` explícito no
código chamado (ou erro que derruba a thread, como `Empty()` sobre JsonObject), que escapa do tratamento e volta como o 500 genérico do tlppCore
(`{"code":500,"message":"Internal Server Error"}`) — só nesse caso o detalhe está no
`console.log`/`error.log`.

### 6.3 Green — implementa e compila

Escreva `src/tecMinha.tlpp` com `user function tecMinha(...)`, sempre acessando
dependências **pelos wrappers**. Compile com `/tlpp-build <arquivo>` (ou deixe o
`/tlpp-test` compilar antes de rodar):

```
[INFO] [SUCCESS] Source C:/.../tecMinha.tlpp compiled successfully.
[build] OK
```

Aqui você paga a janela de restart do HTTPREST (~13 s com `RefreshRate=2`).
Enquanto o wrapper imprime `REST reiniciando`, está tudo normal: a porta REST fica
**fechada a janela inteira** e ele já aguarda com backoff. Só `AppServer nao responde em <host>:<porta>` indica
processo realmente parado.

### 6.4 Skip pelo oráculo — isto é **sucesso**

Rodando de novo sem mudar o fonte:

```
[build] 1 fonte(s) ja no RPO com este conteudo (oraculo RPO) - pulando (use -Force pra ignorar)
[build] OK (nada a compilar - HTTPREST intacto)
```

Não trate como falha e **não force recompilação**. Isso significa que o RPO já tem
exatamente esse conteúdo — compilar à toa derrubaria o REST sem ganho nenhum. O
cache invalida sozinho quando o conteúdo muda.

### 6.5 Green

```
/tlpp-test u_test_tecMinha_caminho_feliz
```

```json
{"function":"u_test_x","argString":"","result":".T.","duration":0.002,"env":"DESENVOLVIMENTO",
 "asserts":{"ok":true,"passed":2,"failed":0,"fails":[]}}
```

### 6.6 Refactor

Com verde na mão, refatore à vontade: extrair `static function`, renomear para
notação húngara, tirar duplicação, trocar literal por constante. Depois de **cada**
passo, rode os casos da função + 3 a 5 testes vizinhos do projeto para pegar
regressão. Se quebrou, desfaça aquele passo.

Uma regra que economiza tempo: **quando o teste falha, o defeito é do fonte, não do
teste**. O teste é a especificação. Ajustar o teste para ele passar é destruir a
única medida objetiva que você tinha. A exceção legítima é quando o brainstorm
assumiu uma regra de negócio que o domínio não quer — e aí a correção vem de
confirmar com o cliente, não de "achar".

---

## 7. Erros que dão falso verde (releia se algo estiver estranho)

| Erro | Sintoma | Correção |
|---|---|---|
| Falta `u_tecAssertReset()` | `.T.` sem motivo; resultado muda de ordem de execução | Primeira linha do teste |
| Falta `return u_tecAssertsOk()` | Sempre `.T.`, nunca reflete assert | Última linha do teste |
| Mock antes de `u_tecTstStart()` | Mock silenciosamente perdido; wrapper devolve vazio/default | Start primeiro, mocks depois |
| Falta `u_tecTstStop()` | Teste vizinho passa/falha por herança de mock | Stop no fim, ou use `u_tecTstWith` |
| Fonte de produção não usa wrapper | Mock não intercepta; verde no teste, quebra no cliente | `u_tecDbSeekFld` / `u_tecQryFirst` / `u_tecGetMv` / `u_tecHttpReq` / `u_tecHoje` |
| `function` puro (sem `user`/`static`) | `Regular functions are not allowed` | `user function` ou `static function` |
| `Empty(jObj)` direto | Thread crasha | `u_tecAssertEmpty`/`NotEmpty` (tipo-aware) |
| `Write` nativo em `.tlpp` | Encoding corrompido, compile quebra | CP1252 (`mcp__file-tools__write_file`) |

---

## 8. Para onde ir agora

| Você quer | Documento |
|---|---|
| Assinatura exata de cada wrapper, mock, assert e helper de banco | [REFERENCE.md](REFERENCE.md) |
| Código pronto para o seu cenário (REST, parâmetro, DbSeek, data, MVC, banco) | [RECIPES.md](RECIPES.md) |
| Uma mensagem de erro para decifrar | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| O loop enxuto, do ponto de vista de uma LLM consumidora | [LLM-WORKFLOW.md](LLM-WORKFLOW.md) |
| Como o plugin está montado, custos, limitações, cheatsheet | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Instalar/configurar na mão | [SETUP.md](SETUP.md), [DATABASE-SETUP.md](DATABASE-SETUP.md) |
| Deixar o loop TDD rodar sozinho | `/tlpp-tdd "<feature>"` (skill `tlpp-tdd`) |
