# Examples

Demonstrações do framework `tlpp-runner`. **Não são parte do framework essencial** — servem só pra mostrar o loop TDD funcionando ponta a ponta.

Apos o redesign global, **os examples NÃO sao copiados pra projetos consumidores** — o framework vive no RPO compartilhado, e exemplos sao referencia pra estudo dentro deste repo. Pra rodar localmente, clone o repo e compile via `/tlpp-build -All -WithExamples` aqui dentro.

## O que tem aqui

| Arquivo | Demonstra |
|---|---|
| `src/helloTst.tlpp` | Função mais simples possivel + 1 teste |
| `src/tecCalcDsc.tlpp` + `test/unit/tecCalcDscTst.tlpp` | Cálculo de desconto progressivo (puro, sem dependencias) |
| `src/tecCalcCmsn.tlpp` + `test/unit/tecCalcCmsnTst.tlpp` + `test/integracao/tecCalcCmsnItgTst.tlpp` | Comissão com lookup em SA1 (DbSeek mockado) + teste de integração com banco real |

## Como rodar

Da raiz do projeto:

```powershell
# Compila tudo (inclui examples)
.\runner\Invoke-TlppBuild.ps1 -All

# Roda um exemplo
.\runner\Invoke-TlppRunner.ps1 -Function u_test_tecCalcDsc_5pct_faixaMedia -Quiet
```

## Quando estudar isso

- Voce e novo no framework e quer entender como a skill `tlpp-tdd` espera que voce estruture testes
- Voce esta com duvida sobre como mockar dependencia X — provavelmente tem um exemplo equivalente aqui
- Voce quer ver o padrão de teste de integração com banco real (`tecCalcCmsnItgTst.tlpp`)

## Quando NÃO usar isso

- Em projeto produtivo: nao deixe os fontes `tecCalcDsc`/`tecCalcCmsn` no RPO do cliente. Mantenha em `examples/` ou apague depois de estudar.
