---
description: Executa uma User Function ou Main Function arbitraria no AppServer dev via endpoint REST. Util para experimentar funcoes sem PROBAT.
allowed-tools:
  - "Bash(*Invoke-TlppRunner*)"
  - "Bash(powershell*)"
---

# Executar funcao TLPP/AdvPL

Argumentos do usuario: $ARGUMENTS

## Formato esperado

`/tlpp-exec <funcao> [args separados por virgula com aspas]`

Exemplos:
- `/tlpp-exec u_tecAssertReset`
- `/tlpp-exec u_tecHoje`
- `/tlpp-exec tec.runner.api.tecRunrPing`
- (Se examples instalados) `/tlpp-exec u_tecCalcDsc 150`

## Passos

1. Primeiro argumento eh o nome da funcao.
2. Os argumentos seguintes formam o `argString` (literal AdvPL).
   - Numeros: passe direto. `150` -> argString="150"
   - Strings: envolva em aspas. `cliente` -> argString=`"cliente"`
   - Multi-arg: separa por virgula. `150,"x"` -> argString="150,\"x\""
3. Resolva o caminho do runner (plugin global preferido, fallback in-repo):
   ```powershell
   $runner = if ($env:CLAUDE_PLUGIN_ROOT) { "$env:CLAUDE_PLUGIN_ROOT\runner" } else { '.\runner' }
   ```
4. Execute via PowerShell:
   ```powershell
   & "$runner\Invoke-TlppRunner.ps1" -Function "<funcao>" -ArgString '<argString>'
   ```
5. Mostre o JSON de resposta resumido (function, duration, result, env).

## Erros comuns

- **HTTP 404 funcao_nao_existe** → fonte ainda nao foi compilado no TDS-VSCode (Ctrl+F9).
- **HTTP 500 runtime** → erro na execucao da funcao. Veja o `message` do JSON.
- **PING FAIL HTTP=0** → AppServer REST nao esta rodando (porta 8401).
