# Instalação do framework tlpp-tdd

Como instalar o `tlpp-runner` (plugin Claude Code) e configurar a máquina pra rodar TDD em projetos ADVPL/TLPP.

## Caminho recomendado: via plugin Claude Code

```
/plugin marketplace add Guipegoraro/tlpp-runner
/plugin install tlpp-tdd@tlpp-runner
/tlpp-tdd-setup            # setup + doctor da máquina (one-shot)
```

> O Claude Code instala plugins a partir de **marketplaces** — o primeiro comando registra este repo como marketplace (o manifest vive em `.claude-plugin/marketplace.json`), o segundo instala o plugin dele.

A skill `/tlpp-tdd-setup` faz:
1. Diagnóstico completo (9 checks: config, paths, AppServer, REST, framework no RPO, DBAccess, SQL)
2. Pergunta AppServer dedicado (recomendado, zero impacto) vs reusar o existente
3. Mostra plano detalhado com razão de cada mudança
4. Aplica passo a passo com backup automático nos `.ini`
5. Compila o framework no RPO compartilhado (UMA VEZ)
6. Smoke test (ping + u_tecAssertReset + u_tecHoje)
7. Reporta o que ficou pronto

**Por projeto** (opcional, só se vai usar testes de integração com banco):

```
/tlpp-tdd-project-init     # cria PROTHEUS_TST_<nome> + alias + .tlpp-tdd.json
```

Tudo idempotente — se algo falhar ou quebrar depois, rode `/tlpp-tdd-setup` de novo. Ele diagnostica o estado atual e só executa o que falta/quebrou.

## Caminho manual (sem o plugin)

Use quando o plugin Claude Code não está disponível, ou quando você prefere ver cada passo.

### Pré-requisitos

- TDS-VSCode instalado (com extensão `totvs.tds-vscode-*`)
- Protheus 24.1+ rodando localmente (AppServer dev + DBAccess + base local)
- SQL Server 2019+ com Windows Auth ou login `sa`
- PowerShell 5.1+
- `sqlcmd.exe` no PATH

### Passo 1: clonar o framework

```powershell
git clone <git-url-interno>/tlpp-runner C:\caminho\tlpp-runner
cd C:\caminho\tlpp-runner
```

### Passo 2: detectar ambiente

```powershell
$envInfo = & .\runner\install\Test-Environment.ps1
$envInfo | ConvertTo-Json -Depth 5
```

Anote: `ProtheusRoot`, `AppServer.Ini`, `AppServer.Port`, `DBAccess.Ini`, `DBAccess.Port`, `Sql.Instances`.

Se `Issues` tiver algum item bloqueante (AppServer não rodando, etc), resolva antes de continuar.

### Passo 3: definir variáveis

```powershell
$projectName    = 'MEUPROJETO'                        # MAIUSCULAS, [A-Z][A-Z0-9_]*
$projectDir     = 'C:\caminho\para\meu-projeto-advpl'
$dbName         = "PROTHEUS_TST_$projectName"
$sqlInstance    = 'localhost\PROTHEUS'                # do Test-Environment
$dbaIni         = 'C:\TOTVS\...\dbaccess.ini'         # do Test-Environment
$appIni         = 'C:\TOTVS\...\appserver.ini'        # do Test-Environment
$protheusRoot   = 'C:\TOTVS\Protheus_241011'
$advplsPath     = "$env:USERPROFILE\.vscode\extensions\totvs.tds-vscode-2.0.16\node_modules\@totvs\tds-ls\bin\windows\advpls.exe"
```

### Passo 4: criar banco isolado

```powershell
.\runner\install\New-TestDatabase.ps1 `
    -SqlInstance $sqlInstance `
    -DbName $dbName `
    -Mode Fresh `
    -SqlAuth Windows
```

Modo `Fresh` cria banco vazio com schema só do framework. Use `-Mode SchemaCopy -SourceDb <NomeBancoCliente>` se precisar dicionário customizado.

### Passo 5: alias DBAccess

```powershell
.\runner\install\Set-DBAccessAlias.ps1 `
    -DbAccessIniPath $dbaIni `
    -DbName $dbName `
    -SqlInstance $sqlInstance `
    -SqlAuth Windows
```

Backup automático em `$dbaIni.bak.<timestamp>`. **Reinicie o `dbaccess64.exe`** após este passo.

### Passo 6: rotas REST no AppServer

```powershell
.\runner\install\Set-AppServerRest.ps1 `
    -AppServerIniPath $appIni `
    -RestPort 8401 `
    -Environment 'DESENVOLVIMENTO'
```

Backup automático em `$appIni.bak.<timestamp>`. **Reinicie o AppServer** após este passo.

### Passo 7: compilar framework no RPO compartilhado (UMA VEZ por máquina)

```powershell
.\runner\install\Install-Framework-Global.ps1 `
    -PluginRoot (Get-Location).Path
```

Compila `src/tecAssert.tlpp`, `tecRunrApi.tlpp`, `tecRunrCtx.tlpp`, `tecWrap.tlpp`, `tecRefl.tlpp`, `mocks/tecMock.tlpp` no RPO do AppServer dev configurado. Após isso, qualquer projeto que use o plugin consome via `/runner/exec`.

### Passo 8: config global (machine-wide)

```powershell
.\runner\install\Write-GlobalConfig.ps1 -Settings @{
    User         = 'admin'
    Password     = '<senha-admin-do-appserver>'
    ProtheusRoot = $protheusRoot
    AdvplsPath   = $advplsPath
    BaseUrl      = 'http://127.0.0.1:8401/rest'   # localhost vira 127.0.0.1 ao carregar (evita ~2s de fallback IPv6 por request)
    SqlInstance  = $sqlInstance
    DbAccessPort = 7890
}
```

Grava em `~/.claude/tlpp-tdd/config.ps1`. Senha mascarada no log. Modo `Merge` (default) preserva chaves existentes.

### Passo 8.5 (opcional, per-project): `.tlpp-tdd.json`

Em cada projeto que vai usar integração com banco:

```powershell
# O runner vive no PLUGIN, nao no projeto - resolva o caminho primeiro
# (o fallback .\runner\ so existe no proprio repo do tlpp-runner):
$runner = if ($env:CLAUDE_PLUGIN_ROOT) { "$env:CLAUDE_PLUGIN_ROOT\runner" } else { '.\runner' }

& "$runner\install\Write-ProjectConfig.ps1" `
    -ProjectRoot $projectDir `
    -Name 'MEUPROJ'
```

Grava `<projectDir>/.tlpp-tdd.json` com `{"name": "MEUPROJ"}`. Deriva banco `PROTHEUS_TST_MEUPROJ`.

### Passo 9: compilar

```powershell
cd $projectDir
$runner = if ($env:CLAUDE_PLUGIN_ROOT) { "$env:CLAUDE_PLUGIN_ROOT\runner" } else { '.\runner' }
& "$runner\Invoke-TlppBuild.ps1" -All
```

### Passo 10: smoke test

```powershell
& "$runner\install\Invoke-Smoke.ps1"
```

Esperado:
```
1) Ping REST ... OK
2) Compilando framework ... OK
3) u_tecAssertReset ... OK
4) u_tecHoje ... OK
Smoke test OK - framework operacional.
```

### Pronto

Próximo passo: `/tlpp-tdd "criar funcao tecMinha que ..."` em uma sessão Claude Code dentro do `$projectDir`.

## Troubleshooting

| Sintoma | Causa | Solucao |
|---|---|---|
| `Test-Environment` reporta `AppServer.Found=false` | Processo não rodando | Suba o AppServer dev e rode de novo |
| `New-TestDatabase` falha "Login failed for user 'NT AUTHORITY\xx'" | Windows auth sem permissão | Use `-SqlAuth SqlServer -SqlUser sa -SqlPassword <senha>` |
| `Set-DBAccessAlias` reporta "Secao existe com config diferente" | Alias já configurado pra outro DB | Remova manualmente do `.ini` ou aceite o existente |
| `Set-AppServerRest` reporta "ja esta configurado" | Idempotente — nada a fazer | Continue |
| Smoke test falha no passo 1 (Ping) | AppServer não reiniciou ou .ini não carregou | Confirme que o AppServer foi reiniciado após passo 6 |
| Smoke test falha no passo 3 (tecAssertReset) | Compile do framework falhou no passo 9 | Rode `.\runner\Invoke-TlppBuild.ps1 -All` manual e veja `[FATAL]` no log |

Se algo der ruim: `ROLLBACK.md` explica como desfazer cada passo.
