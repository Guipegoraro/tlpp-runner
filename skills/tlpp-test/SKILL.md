---
name: tlpp-test
description: 'Use when ADVPL/TLPP tests should actually run on a Protheus AppServer and yield a pass/fail result - "roda o teste", "executa os testes", "testa essa funcao", "roda a suite", "quero o placar verde" - and whenever an ADVPL/TLPP change needs verifying before anything is called done. To write a new battery of tests, the skill is tlpp-tdd; to run a function that is not a test, the command is /tlpp-exec.'
allowed-tools:
  - "Bash(*Invoke-TlppBuild*)"
  - "Bash(*Invoke-TlppRunner*)"
  - "Bash(powershell*)"
---

# Compilar e rodar testes TLPP/AdvPL

## Preflight (todos os modos)

Resolva o caminho do runner (plugin global preferido, fallback in-repo). `.\runner\`
so existe no repo de desenvolvimento do tlpp-runner; em projeto consumidor os
scripts vivem sob a raiz do plugin:

```powershell
$runner = if ($env:CLAUDE_PLUGIN_ROOT) { "$env:CLAUDE_PLUGIN_ROOT\runner" } else { '.\runner' }
```

Daqui em diante todos os comandos usam `$runner` em vez de `.\runner`.

## 3 modos de uso

### Modo 1: Nome de funcao (rota rapida - PREFERIDA para LLM)

Detectar quando o argumento comeca com `u_` ou eh um nome de funcao unica.

Roteamento: chamar `/runner/exec` direto via `-Quiet` (saida em 1 linha, baixo custo de tokens).

```powershell
& "$runner\Invoke-TlppRunner.ps1" -Function "<funcao>" -Quiet
```

Saida esperada:
```
u_test_xxx: result=.T. dur=0.32s asserts=3ok/0fail
```

`.T.` = todos asserts passaram (usando `u_tecAssert*` + `return u_tecAssertsOk()`).
`.F.` = ao menos um falhou. O motivo vem na propria saida (campo `asserts` da
resposta do `/runner/exec`): uma linha `FAIL:` por assert falho, com a descricao
escrita no teste:

```
u_test_xxx: result=.F. dur=0.002s asserts=1ok/2fail
  FAIL: soma errada | expected=3 actual=2
```

Nao precisa abrir o `console.log`; os `[ASSERT_FAIL]` do `ConOut` sao so
complemento (ex. ver a ordem de execucao).

Quando usar: TDD funcao-a-funcao, validacao rapida apos editar fonte, loop iterativo.

### Modo 2: Arquivo .tlpp (compila + roda funcoes do arquivo)

Quando o argumento termina em `.tlpp`:

1. `& "$runner\Invoke-TlppBuild.ps1" -File "<arquivo>"` (compila)
2. Inferir nomes de funcoes do arquivo (procurar `user function test_*`) e rodar cada uma em sequencia via `-Quiet`.

Alternativa simples: `& "$runner\Invoke-TlppRunner.ps1" -Function "tlpp.probat.run" -ArgString '"type:file","<arquivo>"' -Junit`

### Modo 3: Suite completa (`unit`, `integracao`) ou sem argumento

Roda PROBAT completo via `tlpp.probat.run`. Saida verbosa, util para CI/relatorio.

```powershell
# Tudo
& "$runner\Invoke-TlppRunner.ps1" -Function "tlpp.probat.run" -Junit

# Suite especifica
& "$runner\Invoke-TlppRunner.ps1" -Function "tlpp.probat.run" -ArgString '"type:suite","unit"' -Junit
```

## Convencoes

- **Asserts**: testes devem usar `u_tecAssertReset()` + `u_tecAssert*` + `return u_tecAssertsOk()`. So entao `result=.T./.F.` via `/runner/exec` reflete o resultado real dos asserts.
- **PROBAT discovery `type:suite` so funciona com discovery habilitado**: ver `appserver.ini` `[PROBAT] TESTS_DISCOVERY_MODE`. Em duvida, prefira Modo 1.
- **Sempre compile antes**: se editou fonte, compile antes de executar (nao ha hook de build automatico - compilacao e sempre explicita). A skill `tlpp-build` cobre esse passo.

## Reporte honesto do resultado

Nunca declare teste passando sem ter a linha `result=.T.` na saida. Se o runner
nao respondeu, se o AppServer caiu, ou se voce nao executou, diga isso
explicitamente - "NAO-EXECUTADO" e um resultado valido; "passou" sem evidencia nao e.

## Erros comuns

- **Compile falha (FATAL)**: `function` em vez de `user function`, ou tipo incompativel
- **Connection refused**: o HTTPREST cai a cada compilacao - qualquer fonte, nao so `@Get/@Post` - e volta no proximo ciclo do `[ONSTART] RefreshRate` (~5s apos o build com `RefreshRate=2`; ate ~2 min num ini com 120 - a skill `tlpp-tdd-setup` em modo doctor baixa o valor). O wrapper faz backoff assimetrico e aguarda
- **404 funcao_nao_existe**: o fonte nao foi compilado no RPO ainda
- **500 runtime** (`u_x: ERRO <mensagem>`): erro de execucao na funcao chamada (type mismatch, variavel inexistente...). O runner imprime a mensagem, as primeiras linhas da pilha (fonte e linha) e os `FAIL` registrados ate o erro - va direto a linha indicada
- **500 generico** `{"code":500,"message":"Internal Server Error"}`: `Break("...")` explicito no codigo chamado, ou erro que derruba a thread (ex.: `Empty()` sobre JsonObject), escapa do tratamento. So nesse caso leia `console.log`/`error.log`
- **`.T.` sem assertar nada**: a funcao retorna `.T.` mas nao chamou nenhum `u_tecAssert*`. Sem assert, nao ha o que validar - revise o teste
- **HTTP 0 / advpls nao encontrado**: problema de ambiente, nao de teste. Rode a skill `tlpp-tdd-setup` (modo doctor)
- **Teste de integracao sem `.tlpp-tdd.json`**: o projeto nao foi inicializado. Rode a skill `tlpp-tdd-project-init`
