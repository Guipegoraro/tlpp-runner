# Receitas de teste por cenário

Código pronto para os padrões que aparecem de verdade em customização Protheus.
Todos os exemplos são adaptados de testes que rodam neste repositório
(`test/unit/`, `test/integracao/`).

Assinaturas e semântica de cada helper estão no [REFERENCE.md](REFERENCE.md) —
aqui não há tabela de API, só receita. O racional do loop está no
[TDD-GUIDE.md](TDD-GUIDE.md).

Todo arquivo de teste abre **uma vez** com:

```tlpp
#include "tlpp-core.th"
#include "tlpp-probat.th"
using namespace tlpp.probat
```

E toda receita segue a ordem `u_tecAssertReset()` → `u_tecTstStart()` → mocks →
act → asserts → `u_tecTstStop()` → `return u_tecAssertsOk()`.

| Cenário | Seção |
|---|---|
| Consome API REST externa | [1](#1-rotina-que-consome-api-rest-externa) |
| Lê parâmetro (`MV_*`) | [2](#2-rotina-que-lê-parâmetro-mv_) |
| Busca em tabela via DbSeek | [3](#3-busca-em-tabela-via-dbseek) |
| Lógica dependente de data/hora | [4](#4-lógica-dependente-de-datahora) |
| Título (SE1) e pedido (SC5/SC6) | [5](#5-título-se1-e-pedido-sc5sc6) |
| Validação MVC sem tela | [6](#6-validação-mvc-sem-tela) |
| Contra banco real | [7](#7-contra-banco-real-quando-o-mock-não-serve) |

---

## 1. Rotina que consome API REST externa

Produção usa `u_tecHttpReq(cVerb, cUrl, xBody, aHeaders)` — nunca `FWRest`
direto. O mock é `u_tecMkHttp`, e a chave aceita duas formas: `"VERB URL"` (casa
só aquele verbo) ou `"URL"` (casa qualquer verbo).

### Caminho feliz

```tlpp
@TestFixture()
user function test_tecIntegra_get_200()
    local jResp

    u_tecAssertReset()
    u_tecTstStart()

    u_tecMkHttp("/api/cliente/1", 200, '{"id":1,"nome":"ACME"}')
    jResp := u_tecHttpReq("GET", "/api/cliente/1")

    u_tecAssertHttpStatus("status 200", 200, jResp)
    u_tecAssertHttpBodyContains("body traz o nome", "ACME", jResp)
    u_tecAssertHttpJsonField("campo nome", "nome", "ACME", jResp)

    u_tecTstStop()
return u_tecAssertsOk()
```

### Mesma URL, verbos diferentes

Útil quando a rotina faz GET para consultar e POST para gravar no mesmo recurso:

```tlpp
@TestFixture()
user function test_tecIntegra_mock_por_verbo()
    local jGet, jPost

    u_tecAssertReset()
    u_tecTstStart()

    u_tecMkHttp("GET /api/x",  200, '{"verb":"get"}')
    u_tecMkHttp("POST /api/x", 201, '{"verb":"post"}')

    jGet  := u_tecHttpReq("GET",  "/api/x")
    jPost := u_tecHttpReq("POST", "/api/x", '{}')

    u_tecAssertEq("body do get",   '{"verb":"get"}',  jGet["body"])
    u_tecAssertEq("status do get", 200,               jGet["status"])
    u_tecAssertEq("body do post",  '{"verb":"post"}', jPost["body"])
    u_tecAssertEq("status do post", 201,              jPost["status"])

    u_tecTstStop()
return u_tecAssertsOk()
```

### Caminho de erro: 4xx / 5xx

**Afirme sobre `status`, nunca sobre `ok`.** Em modo teste o `ok` vem `.T.` sempre
que o mock existe, inclusive para 500 (em produção `ok` é `2xx`). Assert em `ok`
passaria por motivo errado:

```tlpp
@TestFixture()
user function test_tecIntegra_erro_5xx_nao_derruba()
    local jResp

    u_tecAssertReset()
    u_tecTstStart()

    u_tecMkHttp("POST /api/pedido", 500, '{"erro":"indisponivel"}')
    jResp := u_tecHttpReq("POST", "/api/pedido", '{"num":"000100"}')

    u_tecAssertHttpStatus("status 500", 500, jResp)
    u_tecAssertHttpJsonField("mensagem de erro", "erro", "indisponivel", jResp)

    u_tecTstStop()
return u_tecAssertsOk()
```

### Endpoint que a rotina esqueceu de mockar / URL inexistente

Sem mock configurado, o wrapper devolve `{ok: .F., status: 0, error: "mock_nao_configurado: ..."}`.
Serve para provar que a rotina lida com indisponibilidade sem estourar:

```tlpp
@TestFixture()
user function test_tecIntegra_sem_resposta()
    local jResp

    u_tecAssertReset()
    u_tecTstStart()
    // de proposito: nenhum u_tecMkHttp configurado

    jResp := u_tecHttpReq("GET", "/api/inexistente")

    u_tecAssertFalse("ok deve ser .F.", jResp["ok"])
    u_tecAssertEq("status 0", 0, jResp["status"])
    u_tecAssertNotEmpty("error preenchido", jResp["error"])

    u_tecTstStop()
return u_tecAssertsOk()
```

---

## 2. Rotina que lê parâmetro (`MV_*`)

Produção usa `u_tecGetMv(cParam, xDefault)`. O mock é `u_tecMkMv(cParam, xValor [, cTipo])`.

### Valor explícito e default

```tlpp
@TestFixture()
user function test_tecCalc_le_parametro()
    u_tecAssertReset()
    u_tecTstStart()

    u_tecMkMv("MV_TEC_PCT", 10, "N")

    u_tecAssertEq("le o valor mockado", 10, u_tecGetMv("MV_TEC_PCT", 0))
    u_tecAssertEq("parametro inexistente cai no default", 5, u_tecGetMv("MV_TEC_NAO_EXISTE", 5))

    u_tecTstStop()
return u_tecAssertsOk()
```

### Validação de tipo (evita verde com parâmetro de tipo errado)

O terceiro argumento de `u_tecMkMv` é o `X6_TIPO` esperado. Mock com tipo errado é
**rejeitado** — não registra, e o `u_tecGetMv` volta a devolver o default. Isso
impede o teste de passar assumindo `"1.5"` (string) onde produção entrega `1.5`
(numérico):

```tlpp
@TestFixture()
user function test_tecCalc_parametro_tipo()
    u_tecAssertReset()
    u_tecTstStart()

    u_tecAssertTrue("C aceita string",  u_tecMkMv("MV_TESTC", "abc",             "C"))
    u_tecAssertTrue("N aceita numero",  u_tecMkMv("MV_TESTN", 42,                "N"))
    u_tecAssertTrue("L aceita logico",  u_tecMkMv("MV_TESTL", .T.,               "L"))
    u_tecAssertTrue("D aceita data",    u_tecMkMv("MV_TESTD", CToD("01/07/2026"), "D"))

    u_tecAssertFalse("string onde esperava N e rejeitada", u_tecMkMv("MV_TESTX", "nao-e-numero", "N"))
    u_tecAssertEq("mock rejeitado nao registra (volta o default)", 99, u_tecGetMv("MV_TESTX", 99))

    u_tecTstStop()
return u_tecAssertsOk()
```

> Parâmetro novo é criado **no Configurador**, nunca por fonte (`PutMV`/`PutSX6`
> em rotina de atualização é defeito). Registre a necessidade em
> `.claude/plans/<slug>/pre-producao.md` antes do deploy.

---

## 3. Busca em tabela via DbSeek

Produção usa `u_tecDbSeekFld(cAlias, nOrder, cKey, cFld)`. O mock é
`u_tecMkBdSeek(cAlias, nOrder, cKey, jRow)`, com a chave composta
`alias # ordem # chave`.

### Chave composta e leitura de vários campos

```tlpp
@TestFixture()
user function test_dbSeekFld_match_simples()
    local cRet

    u_tecAssertReset()
    u_tecTstStart()

    u_tecMkBdSeek("SA1", 1, "01000001", ;
        u_tecMkRow({{"A1_NOME", "ACME"}, {"A1_TEL", "1234"}}))

    cRet := u_tecDbSeekFld("SA1", 1, "01000001", "A1_NOME")
    u_tecAssertEq("A1_NOME", "ACME", cRet)

    cRet := u_tecDbSeekFld("SA1", 1, "01000001", "A1_TEL")
    u_tecAssertEq("A1_TEL", "1234", cRet)

    u_tecTstStop()
return u_tecAssertsOk()
```

### Registro não encontrado e campo ausente

Os dois devolvem `""` (nunca `nil`) — assert nisso é o que prova que a rotina não
confunde "não achei" com "achei vazio":

```tlpp
@TestFixture()
user function test_dbSeekFld_nao_encontrado()
    local cRet

    u_tecAssertReset()
    u_tecTstStart()
    // nada mockado

    cRet := u_tecDbSeekFld("SA1", 1, "99999", "A1_NOME")
    u_tecAssertEq("chave inexistente devolve vazio", "", cRet)

    u_tecMkBdSeek("SB1", 2, "00001", u_tecMkRow({{"B1_DESC", "Produto"}}))
    cRet := u_tecDbSeekFld("SB1", 2, "00001", "B1_PRECO")   // mock nao tem B1_PRECO
    u_tecAssertEq("campo nao mockado devolve vazio", "", cRet)

    u_tecTstStop()
return u_tecAssertsOk()
```

### Ordens diferentes são chaves diferentes

```tlpp
@TestFixture()
user function test_dbSeekFld_ordens_distintas()
    local cRetO1, cRetO2

    u_tecAssertReset()
    u_tecTstStart()

    u_tecMkBdSeek("SA2", 1, "001", u_tecMkRow({{"A2_NOME", "POR_ORDEM_1"}}))
    u_tecMkBdSeek("SA2", 2, "001", u_tecMkRow({{"A2_NOME", "POR_ORDEM_2"}}))

    cRetO1 := u_tecDbSeekFld("SA2", 1, "001", "A2_NOME")
    cRetO2 := u_tecDbSeekFld("SA2", 2, "001", "A2_NOME")

    u_tecAssertEq("ordem 1", "POR_ORDEM_1", cRetO1)
    u_tecAssertEq("ordem 2", "POR_ORDEM_2", cRetO2)

    u_tecTstStop()
return u_tecAssertsOk()
```

### Seed por alias (várias linhas do mesmo alias)

Quando a busca é por conteúdo e não por chave de índice — caso do helper de
domínio `u_tecBuscaCli`, que procura `A1_CGC` nas linhas seedadas:

```tlpp
@TestFixture()
user function test_tecBuscaCli_por_cgc()
    u_tecAssertReset()
    u_tecTstStart()

    u_tecMkBdSeed("SA1", { ;
        u_tecMkRow({{"A1_CGC", "11111111000111"}, {"A1_NOME", "CLI A"}}), ;
        u_tecMkRow({{"A1_CGC", "22222222000122"}, {"A1_NOME", "CLI B"}})  ;
    })

    u_tecAssertEq("acha o segundo", "CLI B", u_tecBuscaCli("22222222000122"))
    u_tecAssertEq("cgc inexistente devolve vazio", "", u_tecBuscaCli("99999999000199"))

    u_tecTstStop()
return u_tecAssertsOk()
```

> **Mock parcial é armadilha.** A linha real de `SA1` tem dezenas de colunas. Se a
> sua rotina lê `A1_EST` e você mocou só `A1_CGC`/`A1_NOME`, ela recebe `""` calado.
> Inclua no `u_tecMkRow` todas as colunas que a função **pode** tocar.

---

## 4. Lógica dependente de data/hora

Produção usa `u_tecHoje()` e `u_tecHora()` em vez de `Date()`/`Time()` — assim a
lógica de vencimento, virada de mês e janela de horário fica determinística.

Atenção à ordem: `u_tecTstStart()` **limpa** data e hora mockadas, então o
`u_tecMkHoje`/`u_tecMkHora` vem **depois** do Start.

```tlpp
@TestFixture()
user function test_tecVencido_data_fixa()
    local dVenc := CToD("15/08/2026")

    u_tecAssertReset()
    u_tecTstStart()

    // "hoje" congelado DEPOIS do Start
    u_tecMkHoje(CToD("20/08/2026"))
    u_tecMkHora("23:45:00")

    u_tecAssertEq("hoje mockado",  CToD("20/08/2026"), u_tecHoje())
    u_tecAssertEq("hora mockada",  "23:45:00",         u_tecHora())
    u_tecAssertTrue("titulo vencido", u_tecHoje() > dVenc)

    u_tecTstStop()
return u_tecAssertsOk()
```

Casos que valem a pena para lógica de data (ver checklist do
[TDD-GUIDE.md](TDD-GUIDE.md#4-como-escolher-os-casos-de-teste)): virada de mês
(`31/01` + 1 mês), ano bissexto (`29/02/2028`), data vazia (`CToD("")`), e formato
BR vs ISO quando a data vem de payload externo.

---

## 5. Título (SE1) e pedido (SC5/SC6)

Wrappers de domínio, com chave validada contra o dicionário padrão TOTVS (SIX
ordem 1). Ambos devolvem **`nil`** quando não encontram — assert em `nil` é caso
obrigatório.

### Título a receber (`u_tecBuscaTitulo`)

Chave: `E1_PREFIXO` + `E1_NUM` + `E1_PARCELA` + `E1_TIPO` (a filial é aplicada
internamente). O match no mock ignora espaços em volta, o que reproduz o campo
`PadR`-ado que vem do banco:

```tlpp
@TestFixture()
user function test_tecBuscaTitulo_encontrado()
    local jTit

    u_tecAssertReset()
    u_tecTstStart()

    u_tecMkBdSeed("SE1", { ;
        u_tecMkRow({{"E1_PREFIXO","001"}, {"E1_NUM","000000001"}, {"E1_PARCELA","A"}, {"E1_TIPO","NF "}, ;
                    {"E1_VALOR",1500.50}, {"E1_VENCTO",CToD("15/08/2026")}, {"E1_STATUS","A"}, ;
                    {"E1_BAIXA",CToD("")}, {"E1_SALDO",1500.50}}) ;
    })

    jTit := u_tecBuscaTitulo("001", "000000001", "A", "NF")
    u_tecAssertTrue("titulo encontrado", jTit != nil)
    if jTit != nil
        u_tecAssertEq("valor",      1500.50,            jTit["valor"])
        u_tecAssertEq("vencimento", CToD("15/08/2026"), jTit["vencimento"])
        u_tecAssertEq("status",     "A",                jTit["status"])
        u_tecAssertEq("saldo",      1500.50,            jTit["saldo"])
    endif

    u_tecTstStop()
return u_tecAssertsOk()
```

Não encontrado, e linha mockada só com a chave (campos de valor caem em defaults
neutros — `0` e `""`):

```tlpp
@TestFixture()
user function test_tecBuscaTitulo_nao_encontrado_e_defaults()
    local jTit

    u_tecAssertReset()
    u_tecTstStart()

    u_tecMkBdSeed("SE1", { ;
        u_tecMkRow({{"E1_PREFIXO","001"}, {"E1_NUM","000000003"}, {"E1_PARCELA",""}, {"E1_TIPO","NF"}}) ;
    })

    u_tecAssertTrue("numero inexistente devolve nil", u_tecBuscaTitulo("001", "000000999", "A", "NF") == nil)

    jTit := u_tecBuscaTitulo("001", "000000003", "", "NF")
    u_tecAssertTrue("achou pela chave", jTit != nil)
    if jTit != nil
        u_tecAssertEq("valor default 0",   0,  jTit["valor"])
        u_tecAssertEq("status default ''", "", jTit["status"])
    endif

    u_tecTstStop()
return u_tecAssertsOk()
```

### Pedido de venda (`u_tecBuscaPedido` + `u_tecBuscaItensPedido`)

`valor_total` é a **soma dos itens** (`C6_VALOR`) — o SC5 padrão não tem campo de
total. O `status` segue a convenção padrão do Protheus (não é regra de cliente):
`"faturado"` se `C5_NOTA` preenchida, senão `"liberado"` se `C5_LIBEROK == "S"`,
senão `"aberto"`.

```tlpp
@TestFixture()
user function test_tecBuscaPedido_com_itens()
    local jPed

    u_tecAssertReset()
    u_tecTstStart()

    u_tecMkBdSeed("SC5", { ;
        u_tecMkRow({{"C5_NUM","000100"}, {"C5_CLIENTE","000001"}, {"C5_LOJACLI","01"}, ;
                    {"C5_NOTA",""}, {"C5_LIBEROK",""}}) ;
    })
    u_tecMkBdSeed("SC6", { ;
        u_tecMkRow({{"C6_NUM","000100"}, {"C6_ITEM","01"}, {"C6_PRODUTO","PROD01"}, {"C6_QTDVEN",2}, {"C6_VALOR",100.00}}), ;
        u_tecMkRow({{"C6_NUM","000100"}, {"C6_ITEM","02"}, {"C6_PRODUTO","PROD02"}, {"C6_QTDVEN",1}, {"C6_VALOR",50.25}}),  ;
        u_tecMkRow({{"C6_NUM","000999"}, {"C6_ITEM","01"}, {"C6_PRODUTO","OUTRO"},  {"C6_QTDVEN",9}, {"C6_VALOR",999.99}})  ;
    })

    jPed := u_tecBuscaPedido("000100")
    u_tecAssertTrue("pedido encontrado", jPed != nil)
    if jPed != nil
        u_tecAssertEq("cliente",                      "000001", jPed["cliente"])
        u_tecAssertEq("loja",                         "01",     jPed["loja"])
        u_tecAssertEq("valor_total so deste pedido",  150.25,   jPed["valor_total"])
        u_tecAssertEq("status aberto",                "aberto", jPed["status"])
    endif

    u_tecTstStop()
return u_tecAssertsOk()
```

Itens: o wrapper filtra pelo número do pedido e devolve array vazio quando não há
nada — outro caso obrigatório:

```tlpp
@TestFixture()
user function test_tecBuscaItensPedido_filtra()
    local aItens

    u_tecAssertReset()
    u_tecTstStart()

    u_tecMkBdSeed("SC6", { ;
        u_tecMkRow({{"C6_NUM","000500"}, {"C6_ITEM","01"}, {"C6_PRODUTO","PROD01"}, {"C6_QTDVEN",3}, {"C6_VALOR",30}}),   ;
        u_tecMkRow({{"C6_NUM","000777"}, {"C6_ITEM","01"}, {"C6_PRODUTO","ALHEIO"}, {"C6_QTDVEN",1}, {"C6_VALOR",10}}),   ;
        u_tecMkRow({{"C6_NUM","000500"}, {"C6_ITEM","02"}, {"C6_PRODUTO","PROD02"}, {"C6_QTDVEN",5}, {"C6_VALOR",75.5}})  ;
    })

    aItens := u_tecBuscaItensPedido("000500")
    u_tecAssertEq("dois itens do pedido", 2, Len(aItens))
    if Len(aItens) == 2
        u_tecAssertEq("item 1 produto", "PROD01", aItens[1]["produto"])
        u_tecAssertEq("item 1 qtd",     3,        aItens[1]["qtd"])
        u_tecAssertEq("item 2 item",    "02",     aItens[2]["item"])
    endif

    u_tecAssertEq("pedido sem itens devolve array vazio", 0, Len(u_tecBuscaItensPedido("000000")))

    u_tecTstStop()
return u_tecAssertsOk()
```

---

## 6. Validação MVC sem tela

`u_tecMkModel(cId)` devolve um dublê do `oModel` que validações e gatilhos de
`ModelDef` recebem. **Não** precisa de `u_tecTstStart` — é objeto, não wrapper.

O padrão é: extrair a regra para uma função que recebe `oModel`, e testar essa
função passando o mock.

```tlpp
// A regra como ela vive no ModelDef (bPost / VldData):
// pedido precisa de cliente preenchido E total > 0.
static function vldDemoPedido(oModel)
    local cCliente := oModel:GetValue("SC5MASTER", "C5_CLIENTE")
    local nTotal   := oModel:GetValue("SC5MASTER", "C5_TOTAL")
    if cCliente == nil .or. Empty(cCliente)
        return .F.
    endif
    if nTotal == nil .or. nTotal <= 0
        return .F.
    endif
return .T.

@TestFixture()
user function test_vldPedido_regra_negocio()
    local oMdl

    u_tecAssertReset()

    oMdl := u_tecMkModel("DEMOMVC")
    oMdl:Activate()

    u_tecAssertFalse("rejeita pedido vazio", vldDemoPedido(oMdl))

    oMdl:SetValue("SC5MASTER", "C5_CLIENTE", "000001")
    u_tecAssertFalse("rejeita sem total", vldDemoPedido(oMdl))

    oMdl:SetValue("SC5MASTER", "C5_TOTAL", 0)
    u_tecAssertFalse("rejeita total zero", vldDemoPedido(oMdl))

    oMdl:SetValue("SC5MASTER", "C5_TOTAL", 1500.50)
    u_tecAssertTrue("aceita pedido completo", vldDemoPedido(oMdl))

    oMdl:DeActivate()
return u_tecAssertsOk()
```

### Submodelo e commit

`GetModel(cSub)` devolve um submodelo que enxerga **o mesmo storage** do pai —
escrita por lá reflete no `GetValue` do pai. `FormCommit` é no-op (não toca banco)
e `WasCommitted()` existe justamente para afirmar que foi chamado:

```tlpp
@TestFixture()
user function test_tecMkModel_submodel_e_commit()
    local oMdl, oSub

    u_tecAssertReset()

    oMdl := u_tecMkModel("DEMOMVC")
    oMdl:Activate()
    oMdl:SetValue("SC5MASTER", "C5_CLIENTE", "000001")

    // Estilo oModel:GetModel("ID"):GetValue("CAMPO") - comum em validadores
    oSub := oMdl:GetModel("SC5MASTER")
    u_tecAssertEq("submodel le o mesmo storage", "000001", oSub:GetValue("C5_CLIENTE"))

    oSub:SetValue("C5_TOTAL", 99.5)
    u_tecAssertEq("escrita via submodel reflete no pai", 99.5, oMdl:GetValue("SC5MASTER", "C5_TOTAL"))

    u_tecAssertFalse("nada commitado ainda", oMdl:WasCommitted())
    u_tecAssertTrue("FormCommit no-op retorna .T.", oMdl:FormCommit())
    u_tecAssertTrue("commit registrado pra assert", oMdl:WasCommitted())

    // Validacao custom recebe o proprio mock
    oMdl:SetVldBlock({|oM| oM:GetValue("SC5MASTER", "C5_CLIENTE") != nil})
    u_tecAssertTrue("VldData com cliente", oMdl:VldData())
return u_tecAssertsOk()
```

Limites: campo nunca setado devolve `nil` (o mock **não lê SX3**, então não há
default de dicionário) e **não há grid multi-linha**. Se a regra depende de grid,
extraia-a para uma `user function` que recebe os itens já em array e teste essa.

---

## 7. Contra banco real quando o mock não serve

Vale quando o que você quer provar **é** o SQL, o DDL, o escape ou o comportamento
do banco. Precisa de banco de teste + alias DBAccess
([DATABASE-SETUP.md](DATABASE-SETUP.md) ou `/tlpp-tdd-project-init`).

Arquivo em `test/integracao/tec<Nome>ItgTst.tlpp`. Padrão: conecta, garante limpo,
cria, seed, afirma, dropa, desconecta. Note que **não** há `u_tecTstStart` aqui —
`u_tecQryFirst` sem modo teste vai direto ao banco, que é o que se quer:

```tlpp
@TestFixture()
user function test_meu_caso_no_banco()
    local nLink, nLinkAnt, jRow
    local cTab := "Z_TST_DEMO"

    u_tecAssertReset()

    nLink := u_tecTstConn(@nLinkAnt)          // TCLink no banco de teste do projeto
    if nLink <= 0
        u_tecAssertTrue("conectou no banco de teste", .F.)
        return u_tecAssertsOk()
    endif

    u_tecTstDropTable(cTab)                   // idempotente: garante estado limpo
    u_tecTstCreateTable(cTab, { ;
        {"COD",   "CHAR(6)",       "NOT NULL"}, ;
        {"NOME",  "CHAR(40)",      "NOT NULL"}, ;
        {"VALOR", "NUMERIC(10,2)", "DEFAULT 0"} ;
    })                                        // R_E_C_N_O_ + D_E_L_E_T_ automaticos

    u_tecTstSeed(cTab, { ;
        {"COD",   "000001"},    ;
        {"NOME",  "ACME O'BRIEN"},  ;
        {"VALOR", 1234.56}      ;
    })                                        // escapa string/numero/data/logico/nil

    jRow := u_tecQryFirst("SELECT NOME, VALOR FROM " + cTab + " WHERE COD='000001'")
    u_tecAssertNotEmpty("linha lida", jRow)
    if jRow != nil
        u_tecAssertEq("aspa simples escapada", "ACME O'BRIEN", AllTrim(jRow["NOME"]))
        u_tecAssertEq("valor numerico",        1234.56,        jRow["VALOR"])
    endif

    u_tecTstDropTable(cTab)
    u_tecTstDisconn(nLink, nLinkAnt)          // restaura a conexao anterior
return u_tecAssertsOk()
```

Pontos que evitam teste intermitente:

- **`u_tecTstDropTable` antes de criar.** Run anterior interrompido deixa tabela
  para trás; sem o drop, o `CREATE` idempotente reaproveita a estrutura velha.
- **Cleanup no fim** (`DropTable` + `Disconn`). Sem o `Disconn`, a conexão anterior
  não é restaurada e o teste seguinte pode rodar contra o banco errado.
- **Falha de conexão é assert, não crash.** O `if nLink <= 0` com
  `u_tecAssertTrue(..., .F.)` faz o teste reprovar de forma legível em vez de
  estourar na primeira query.
- **Tabela reutilizada por vários testes** vai para o schema versionado:
  `/tlpp-table create Z_TST_NOME "<cols>"`. `u_tecTstCreateTable` é para ad-hoc.
- **Nunca crie campo/índice via SX3/SIX por fonte.** Tabela de teste é DDL em
  `Z_TST_*`; necessidade de dicionário real vai para
  `.claude/plans/<slug>/pre-producao.md` e para o Configurador.

Múltiplas tabelas no mesmo teste, com reset em vez de drop:

```tlpp
    u_tecTstSeed(cTab1, {{"X", "a"}})
    u_tecTstSeed(cTab2, {{"Y", "c"}})
    // ... asserts ...
    u_tecTstTruncate({cTab1, cTab2})          // DELETE FROM em ambas, mantem estrutura
```
