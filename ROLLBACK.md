# Rollback do framework tlpp-tdd

Como desfazer manualmente cada passo do install se algo der ruim.

> Todos os passos do install fazem backup automático onde mexem em arquivo crítico. Os backups têm nome `<arquivo>.bak.<yyyyMMdd-HHmmss>` no mesmo diretório do original.

## Cenário 1: rollback completo (desinstalar tudo)

Reverta na ordem inversa do install — passos 6 → 4 → 1.

### Passo A: restaurar appserver.ini

```powershell
$appIni = 'C:\TOTVS\...\bin\appserver_rest\appserver.ini'
# Liste backups
Get-ChildItem (Split-Path $appIni) -Filter "$(Split-Path $appIni -Leaf).bak.*" | Sort-Object LastWriteTime -Descending

# Restaure o backup mais recente (anterior à mudança)
Copy-Item "$appIni.bak.<timestamp>" $appIni -Force

# Reinicie o AppServer
```

### Passo B: restaurar dbaccess.ini

```powershell
$dbaIni = 'C:\TOTVS\...\TOTVSDBAccess\windows\dbaccess.ini'
Get-ChildItem (Split-Path $dbaIni) -Filter "$(Split-Path $dbaIni -Leaf).bak.*" | Sort-Object LastWriteTime -Descending
Copy-Item "$dbaIni.bak.<timestamp>" $dbaIni -Force
# Reinicie o dbaccess64.exe
```

### Passo C: dropar banco de teste

```powershell
$sqlInstance = 'localhost\PROTHEUS'
$dbName      = 'PROTHEUS_TST_MEUPROJETO'

# Windows auth
sqlcmd -S $sqlInstance -E -Q "DROP DATABASE [$dbName]"

# SQL Server auth
# sqlcmd -S $sqlInstance -U sa -P '<senha>' -Q "DROP DATABASE [$dbName]"
```

> **Importante**: confirme o nome do banco antes do `DROP`. Se você por engano tentar dropar o banco principal do cliente, o SQL Server vai recusar (em uso) — mas confirme de qualquer jeito.

### Passo D: limpar artefatos per-project

Após o redesign global, projetos consumidores **NÃO recebem cópia do framework** — só os arquivos que o usuário cria + (opcionalmente) `.tlpp-tdd.json`. Coisas a verificar:

- `<projeto>/.tlpp-tdd.json` — config per-project (delete se quer "esquecer" o nome do projeto)
- `<projeto>/src/tec*.tlpp` — **SEUS fontes** (preservar)
- `<projeto>/test/...` — **SEUS testes** (preservar)
- Banco SQL `PROTHEUS_TST_<NOME>` + alias DBAccess — ver Passo A/B/C acima

Pra remover completamente o framework do uso por **uma máquina**:

```powershell
# Config global per-machine
Remove-Item "$env:USERPROFILE\.claude\tlpp-tdd\config.ps1" -Force

# Plugin install (se quiser remover o plugin do Claude Code)
# /plugin uninstall tlpp-tdd@tlpp-local  (no Claude Code)
# Ou editar ~/.claude/settings.json e remover entradas extraKnownMarketplaces.tlpp-local + enabledPlugins
```

### Passo E: remover do RPO os fontes compilados

Os fontes `tecAssert`, `tecRunrApi`, `tecRunrCtx`, `tecWrap`, `tecRefl`, `tecMock` foram compilados no RPO do AppServer compartilhado (one-shot). Pra removê-los:

- **Mais simples (recomendado)**: deixar lá. São user functions com prefixo `tec*` — não conflitam com nada do Protheus padrão. Não consomem memória se não chamadas.
- **Se você precisa de remoção total**: use o TDS-VSCode (menu Project → Delete Source) ou compile um fonte vazio com o mesmo nome.

## Cenário 2: rollback parcial — manter banco, restaurar só o AppServer

Se você quer manter o banco de teste mas desabilitar a rota REST do framework:

```powershell
Copy-Item "$appIni.bak.<timestamp>" $appIni -Force
# Reinicie o AppServer
```

Os fontes ficam no RPO mas as rotas `/rest/runner/*` deixam de responder.

## Cenário 3: rollback parcial — manter framework, dropar só o banco e recriar

Útil quando os dados de teste ficaram inconsistentes:

```powershell
# Drop completo (perde tudo) e recria
$sql = "DROP DATABASE PROTHEUS_TST_<NOME>"
sqlcmd -S $sqlInstance -E -Q $sql
# Depois recria via /tlpp-tdd-project-init OU manualmente:
& "$env:CLAUDE_PLUGIN_ROOT\runner\install\New-TestDatabase.ps1" `
    -SqlInstance $sqlInstance `
    -DbName 'PROTHEUS_TST_<NOME>' `
    -Mode Fresh

# Ou só TRUNCATE das tabelas Z_TST_* (preserva schema)
# Conecte via TCLink no teste, use u_tecTstTruncate({"Z_TST_FOO", "Z_TST_BAR"})
```

## Cenário 4: re-rodar o setup após erro parcial

Não é rollback, é retomada — `/tlpp-tdd-setup` é idempotente e tem **doctor mode**. Se está num estado inconsistente:

```
/tlpp-tdd-setup
```

Ele roda diagnóstico (9 checks), classifica cada item OK/FALTA/BROKEN, e aplica só o fix que falta. Use `/tlpp-tdd-setup --dry-run` antes pra ver o plano sem aplicar.

Pra problemas específicos de projeto (banco PROTHEUS_TST_<nome> sumiu / alias morto), rode `/tlpp-tdd-project-init` de novo no mesmo projeto - ele detecta o que existe.

## Confirmando reversão

Apos rollback, valide:

```powershell
# AppServer voltou a usar a rota original
Get-Content $appIni | Select-String '\[HTTPREST\]' -Context 0,5

# DBAccess sem o alias
Get-Content $dbaIni | Select-String 'PROTHEUS_TST_'   # esperado: nenhum match

# Banco dropado
sqlcmd -S $sqlInstance -E -Q "SELECT name FROM sys.databases WHERE name LIKE 'PROTHEUS_TST_%'"
```

## Quando NÃO usar este rollback

- **Se o framework está em produção** (não deveria estar — é dev tool — mas se está): não dropar banco enquanto tem teste rodando. Encerre processos primeiro.
- **Se você não tem certeza qual era o `.ini` original**: prefira `git diff` ou comparar com o `.bak.<timestamp>` mais antigo, em vez de chutar.

## Onde os backups vivem

| Arquivo | Localização do .bak |
|---|---|
| `appserver.ini` | mesmo diretório do `appserver.ini` |
| `dbaccess.ini` | mesmo diretório do `dbaccess.ini` |
| `~/.claude/tlpp-tdd/config.ps1` | não tem backup auto - `Write-GlobalConfig.ps1 -Mode Merge` preserva campos não fornecidos |
| `<projeto>/.tlpp-tdd.json` | não tem backup auto - arquivo pequeno, edite manualmente |

Não há cleanup automático dos `.bak.*` — se acumular, apague os antigos manualmente quando confirmar que está tudo OK.
