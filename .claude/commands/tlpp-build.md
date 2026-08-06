---
description: Compila fontes TLPP/AdvPL via advpls cli (sem TDS-VSCode aberto). Aceita arquivo, lista ou -All.
allowed-tools:
  - "Bash(*Invoke-TlppBuild*)"
  - "Bash(powershell*)"
---

# Compilar fontes TLPP/AdvPL

Argumentos: $ARGUMENTS

## Formato

- Sem argumento ou `-All` -> recompila todos os fontes em src/, mocks/, test/
- Caminho de arquivo (ex: `src/tecMinhaFunc.tlpp` ou `examples/src/tecCalcDsc.tlpp`) -> compila so esse arquivo
- Multiplos caminhos separados por virgula -> compila a lista

## Passos

1. Determine o argumento.
2. Resolva o caminho do `Invoke-TlppBuild.ps1` (plugin global preferido, fallback in-repo):
   ```powershell
   $runner = if ($env:CLAUDE_PLUGIN_ROOT) { "$env:CLAUDE_PLUGIN_ROOT\runner" } else { '.\runner' }
   ```
3. Execute via PowerShell:
   - `-All`: `& "$runner\Invoke-TlppBuild.ps1" -All`
   - `<arquivo>`: `& "$runner\Invoke-TlppBuild.ps1" -File '<arquivo>'`
4. Apresente resumo: lista de fontes que compilaram OK ou falharam.
5. Se houver erro de compile, mostre as mensagens `[FATAL]` e a linha do fonte.

## Cache de build (importante ao ler a saida)

Compilar derruba o HTTPREST por 37-93s, entao fontes **ja no RPO com o mesmo
conteudo sao pulados**. O guard 0 e o **oraculo RPO** (#33): o build pergunta ao
proprio AppServer o que esta compilado (dataFonte vs mtime do disco, por objeto);
com REST fora do ar cai no cache local:

```
[build] 1 fonte(s) ja no RPO com este conteudo (oraculo RPO) - pulando (use -Force pra ignorar)
[build] OK (nada a compilar - HTTPREST intacto)
```

Isso e **sucesso**, nao falha - nao reporte como erro nem tente recompilar por
conta propria. A invalidacao e automatica: conteudo mudou, RPO alterado por
fora (compile pelo TDS/MCP) ou outro projeto ocupou o slot daquele programa.

Use `-Force` so quando houver motivo concreto pra desconfiar do cache:

```powershell
& "$runner\Invoke-TlppBuild.ps1" -File '<arquivo>' -Force
```

Se aparecer o aviso `'<PROGRAMA>' no RPO veio de outro fonte`, **mostre ao
usuario**: dois projetos disputam o mesmo slot do RPO compartilhado (tipico de
ponto de entrada homonimo) e a compilacao vai sobrescrever a versao do outro.

## Erros comuns

- **"Regular functions are not allowed"** -> trocar `function` por `user function` ou `static function`
- **"Cannot find method"** -> nome de metodo diferente (ex: usar `setKeyHeaderResponse` ao inves de `setContentType`)
- **"Connection refused"** -> appserver_rest nao esta no ar (verifique porta 1268)
- **"Incompatible types"** -> typing estrito do TLPP - remova `as <tipo>` em variaveis inicializadas com nil
