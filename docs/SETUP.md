# Setup do tlpp-runner

Guia passo-a-passo para outros desenvolvedores configurarem o tlpp-runner do zero.

## Pre-requisitos

| Componente | Versao minima | Como verificar |
|---|---|---|
| AppServer Protheus | build 24.x | Properties do `appserver.exe` -> ProductVersion |
| tlppCore | 01.05.x (PANTHERA ONCA) | Apos rodar PROBAT, ver `<TLPPVersion>` no `resultsprobat.xml` |
| TDS-VSCode | 2.0.x | Marketplace ou pasta `~/.vscode/extensions/totvs.tds-vscode-*` |
| advpls (LS) | 2.1.x | `advpls.exe --version` no `node_modules/@totvs/tds-ls/bin/windows/` |
| PowerShell | 5.1 ou 7+ | `$PSVersionTable.PSVersion` |
| MSSQL local | 2019+ | Para suite `integracao` (opcional) |

## Passo 1: clonar o repositorio

```powershell
git clone <url-do-projeto> C:\dev\tlpp-runner
cd C:\dev\tlpp-runner
```

## Passo 2: criar config global em `~/.claude/tlpp-tdd/config.ps1`

Após o redesign global, o framework usa **uma config por máquina** em `~/.claude/tlpp-tdd/config.ps1` (não mais per-project). Esse arquivo vive fora do repo e contém credenciais + paths.

```powershell
# Cria o diretorio + arquivo
$cfgPath = "$env:USERPROFILE\.claude\tlpp-tdd\config.ps1"
New-Item -ItemType Directory -Path (Split-Path $cfgPath -Parent) -Force | Out-Null

# Template minimo
@'
$TlppRunner.User         = 'seu_usuario_protheus'
$TlppRunner.Password     = 'sua_senha_protheus'
$TlppRunner.ProtheusRoot = 'C:\TOTVS\Protheus_241011'
$TlppRunner.AdvplsPath   = "$env:USERPROFILE\.vscode\extensions\totvs.tds-vscode-2.0.16\node_modules\@totvs\tds-ls\bin\windows\advpls.exe"

# Opcionais (derivados de ProtheusRoot se nao setados):
# $TlppRunner.Includes = 'D:\Protheus\include'
# $TlppRunner.BaseUrl  = 'http://localhost:8401/rest'
# $TlppRunner.Server   = 'localhost'
# $TlppRunner.Port     = 1268
# $TlppRunner.SqlInstance = 'localhost\PROTHEUS'
# $TlppRunner.DbAccessPort = 7890
'@ | Out-File $cfgPath -Encoding utf8
```

> **Seguranca**: `$TlppRunner.Password` fica em **texto plano** nesse arquivo - e o formato que o `advpls cli` e o endpoint REST exigem, nao ha suporte a senha cifrada. Trate `~/.claude/tlpp-tdd/config.ps1` como credencial: deixe a ACL restrita so ao seu usuario (`icacls "$env:USERPROFILE\.claude\tlpp-tdd\config.ps1" /inheritance:r /grant:r "$env:USERNAME:(R,W)"`), nao versione o arquivo e nao cole o conteudo em ticket/chat. O INI temporario que o build gera com essa senha (`%TEMP%\tlpp-tdd\build-<PID>.ini`) e apagado ao fim de cada compilacao, inclusive quando ela falha.

**Atalho automático**: rode `/tlpp-tdd-setup` (skill do plugin) - ela detecta TDS-VSCode/Protheus/SQL/DBAccess, pergunta o que faltar, e gera esse arquivo via `Write-GlobalConfig.ps1` com senha mascarada no terminal.

## Passo 3: verificar que o AppServer REST esta no ar

```powershell
# Conferir que ouvinte da porta 8401 (ou a sua)
Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -eq 8401 }
```

Se nao estiver, suba seu AppServer REST como sempre faz (geralmente como Administrador).

> **Atalho recomendado**: rode `/tlpp-tdd-setup` (skill do plugin) — ela detecta tudo, pergunta o que falta, e configura com backup automático. Tem doctor mode embutido: re-rodar quando algo quebrar diagnostica e conserta. Este SETUP.md é a referência manual passo a passo. Ver também `INSTALL.md` na raiz e `ROLLBACK.md`.

## Passo 4: habilitar log do REST (opcional mas recomendado)

Adicione no `appserver.ini` do **AppServer REST** (NAO no principal):

```ini
[GENERAL]
ConsoleLog=1
ConsoleFile=C:\TOTVS\...\appserver_rest\console.log
```

Reinicie o AppServer REST. Permite diagnosticar erros 500 olhando o log.

## Passo 5: configurar `[PROBAT]` no AppServer REST (opcional)

Para ter JUnit XML exportado automaticamente:

```ini
[PROBAT]
EXPORT_AFTER_RUN=1
EXPORT_FILE_NAME=resultsprobat
EXPORT_FORMAT=JUnit
```

O arquivo sai em `<RootPath>\system\resultsprobat.xml` por default.

## Passo 6: compilar o endpoint do runner

```powershell
& .\runner\Invoke-TlppBuild.ps1 -File src\tecRunrApi.tlpp
```

Esperado: `[INFO] [SUCCESS] Source ... compiled successfully` e exit 0.

> Observacao: toda compilacao reinicia o HTTP REST do AppServer (37-93s medidos) - nao so as de fonte com `@Get/@Post`. O wrapper aguarda automaticamente, e o build evita compilar fonte que ja esta no RPO com o mesmo conteudo (oraculo RPO #33, fallback cache local).

## Passo 7: validar com PING

```powershell
& .\runner\Invoke-TlppRunner.ps1 -Ping
```

Esperado:
```json
{
  "status": "ok",
  "env": "DESENVOLVIMENTO",
  "company": "99",
  "branch": "01",
  "timestamp": "..."
}
```

## Passo 8: compilar todos os fontes e rodar PROBAT

```powershell
& .\runner\Invoke-TlppBuild.ps1 -All
& .\runner\Invoke-TlppRunner.ps1 -Function "tlpp.probat.run" -Junit
```

Esperado:
```
=== PROBAT JUnit: 12/12 OK | failures=0 skipped=0 ===
```

## Passo 9 (Claude Code): instalar slash commands

Os comandos ja estao em `.claude/commands/`. Eles ficam disponiveis automaticamente quando voce abre o Claude Code dentro da pasta do projeto.

| Comando | Uso |
|---|---|
| `/tlpp-build [arquivo\|--all]` | Compila fontes via advpls cli |
| `/tlpp-test <funcao\|arquivo\|suite>` | Compila + executa (preferencia: por funcao) |
| `/tlpp-exec <funcao> [args]` | Executa funcao arbitraria via `/runner/exec` |
| `/tlpp-tdd "feature"` | Loop TDD autonomo (delega para skill) |
| `/tlpp-table create <nome> "<cols>"` | Adiciona tabela permanente em `runner/sql/` |

Compilacao e sempre explicita: `/tlpp-build <arquivo>` ou `/tlpp-test` (que compila antes de rodar). Nao ha hook de build ao salvar - toda compilacao reinicia o HTTPREST, entao o agente decide o momento.

## Troubleshooting

| Sintoma | Causa | Solucao |
|---|---|---|
| `Regular functions are not allowed` | Codigo usa `function` sem token de compile | Trocar por `user function` ou `static function` |
| `Cannot find method TLPP.REST.REST:SetContentType` | Nome de metodo errado | Usar `setKeyHeaderResponse("Content-Type", "...")` |
| `Incompatible types between D and U` | Tipo estrito do TLPP rejeita `nil as <tipo>` | Remover `as <tipo>` na declaracao |
| `Connection refused` na primeira chamada apos build | HTTP REST reiniciou | Aguardar 2-3s (wrapper ja tem retry) |
| `PING FAIL 401 Unauthorized` | Credenciais erradas | Conferir `~/.claude/tlpp-tdd/config.ps1` (chaves User+Password) |
| `PING FAIL 500 Internal Server Error` | Erro de runtime no endpoint | Ler `console.log` do appserver REST |
| `funcao_nao_existe` no /exec | Fonte nao foi compilado no RPO | Rodar `/tlpp-build` antes |

## Limitacoes conhecidas

- **Compile via advpls cli usa o RPO token automaticamente** detectado pelo TDS-VSCode previamente conectado. Se voce nunca conectou pelo TDS-VSCode, pode precisar de uma primeira conexao manual.
- **Apenas `user function` e `static function`** sao compilaveis sem token JWT do portal TOTVS. `Function` regular (publica) exige token Harpia.
- **Toda compilacao** reinicia o HTTPREST do AppServer (37-93s medidos, issue #29) - nao so fonte com `@Get/@Post`. Wrapper aguarda; oraculo RPO (#33) + cache local evitam recompilar fonte inalterado.
- **Mocks (`tec_mk*`)** so interceptam codigo que passa pelos wrappers de `src/tecWrap.tlpp`. Codigo legado que chama `DbSelectArea` direto nao eh mockavel sem refactor.

## PROBAT vs `/runner/exec` por nome

**Recomendacao do projeto**: rodar testes via `/tlpp-test <funcao>` (rota direta por nome). Mais barato em tokens e nao depende da descoberta PROBAT.

### Por que evitar PROBAT suite mode aqui

1. **Discovery sob solicitacao**: `[PROBAT] TESTS_DISCOVERY_MODE=0` no `appserver.ini` significa que fontes recem-compilados nao sao descobertos automaticamente. Antes de `tlpp.probat.run "type:suite","X"` precisa chamar `tlpp.probat.discovery()` explicitamente. Alternativa: setar `TESTS_DISCOVERY_MODE=1` (rediscover a cada run) com cache via `TESTS_DISCOVERY_TIME_INTERVAL=N` segundos.

2. **Asserts custom nao contam como testcase no PROBAT**: o PROBAT espera `assertEquals`/`assertTrue`/etc. da include `tlpp-probat.th`. Os asserts deste projeto (`u_tecAssert*`) registram contador proprio e fazem `return u_tecAssertsOk()` - perfeito para `/runner/exec` (result=.T./.F. confiavel), mas o PROBAT reporta `Test without testcase` porque nao detectou nenhum assertEquals interno.

3. **Suite=all (default)**: `@TestFixture()` sem propriedade atribui suite "all". Para filtrar por suite, precisa `@TestFixture(suite="integracao")` ou `@TestFixture("integracao")` em cada teste.

### Quando ainda vale rodar PROBAT

Em CI, ou quando quiser JUnit XML completo. Nesse caso:

```powershell
# Forca discovery dos fontes recem-compilados
.\runner\Invoke-TlppRunner.ps1 -Function "tlpp.probat.discovery"

# Roda tudo
.\runner\Invoke-TlppRunner.ps1 -Function "tlpp.probat.run" -Junit
```

Para `type:suite` funcionar, marcar cada teste com `@TestFixture(suite="X")` E usar `assertEquals`/`assertTrue` do PROBAT (em vez de `u_tecAssert*`).

## Fluxo TDD recomendado (rota por funcao - barato em tokens)

1. **Red**: escreve teste em `test/unit/tecXxxTst.tlpp` com `u_tecAssertReset()` + `u_tecAssert*` + `return u_tecAssertsOk()`
2. `/tlpp-test u_test_xxx_caso1` -> deve retornar `result=.F.` (funcao nao existe ainda)
3. **Green**: implementa `src/tecXxx.tlpp` com `user function tecXxx(...)` - sempre pelos wrappers de `tecWrap.tlpp`
4. `/tlpp-test u_test_xxx_caso1` -> compila o que mudou e roda -> `result=.T.` (1 linha, ~0.001s)
5. **Refactor**: rerodar testes vizinhos via nome pra checar regressao

Skill `tlpp-tdd` em `.claude/skills/` automatiza esse loop. Triggers: "criar feature", "TDD para X", "nova funcao TLPP".

Para detalhes pra LLM consumidora: [LLM-WORKFLOW.md](LLM-WORKFLOW.md).
