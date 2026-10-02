# tlpp-tdd plugin

Plugin Claude Code que entrega o framework **tlpp-runner** (TDD autonomo para customizacoes ADVPL/TLPP no Protheus).

## O que vem no plugin

- **Skill `tlpp-tdd`** - loop autonomo red->green->refactor com brainstorming sistematico de edge cases antes de codar
- **Skill `tlpp-tdd-setup`** - setup + doctor (machine-once): detecta ambiente, oferece AppServer dedicado vs reusar, compila framework UMA VEZ no RPO compartilhado, cria config global em `~/.claude/tlpp-tdd/config.ps1`. Diagnostico + reparo idempotente.
- **Skill `tlpp-tdd-project-init`** - inicializacao per-project: cria `PROTHEUS_TST_<nome>` + alias DBAccess + `.tlpp-tdd.json` no projeto atual. Zero arquivos do framework copiados.
- **Slash commands**:
  - `/tlpp-tdd-setup` - setup + doctor da maquina
  - `/tlpp-tdd-project-init` - inicializa o projeto atual
  - `/tlpp-tdd "<feature>"` - dispara o loop TDD pra uma funcao
  - `/tlpp-build [arquivo|--all]` - compila via `advpls cli` (sem TDS-VSCode aberto)
  - `/tlpp-test <funcao|arquivo|suite>` - roda testes
  - `/tlpp-exec <funcao> [args]` - executa user function arbitraria
  - `/tlpp-table create <nome> "<cols>"` - adiciona tabela permanente ao schema de teste
- **Compilacao explicita** - nenhum hook de build ao salvar. O agente decide quando compilar (`/tlpp-build` / `/tlpp-test`), porque toda escrita no RPO derruba o HTTPREST ate o proximo ciclo do `[ONSTART] RefreshRate` (~13s de janela com o `RefreshRate=2` que o setup grava; ate ~2 min com 120).

## Audiencia

Devs ADVPL/TLPP que:
- Ja tem TDS-VSCode instalado (vem com `advpls.exe`)
- Tem Protheus 24.1+ rodando localmente (AppServer dev + DBAccess + base local)
- Querem desenvolver via TDD sem precisar abrir o TDS-VSCode pra cada compile

**Importante**: o plugin nao instala/distribui binarios TOTVS (AppServer, advpls, DBAccess) - esses sao proprietarios e voce precisa ter licenca e instalador deles independentemente.

## Arquitetura global

Apos o redesign de 2026-05-13, o framework NAO e mais copiado per-project. Estrutura:

| Escopo | Onde | Conteudo |
|---|---|---|
| Per-machine | `~/.claude/tlpp-tdd/config.ps1` | admin/senha, paths Protheus, advpls, AppServer endpoint, DBAccess, SQL |
| Per-machine | AppServer dev RPO | Framework compilado (`tecAssert`, `tecWrap`, `tecMock`, `tecRunrApi`, `tecRunrCtx`, `tecRefl`) |
| Per-project (opcional) | `<projeto>/.tlpp-tdd.json` | `{"name": "MEUPROJ"}` deriva banco `PROTHEUS_TST_MEUPROJ` |
| Per-project (opcional) | Banco SQL + DBAccess alias | Isolado por projeto |

Projetos consumidores so escrevem **seus** fontes `src/...tlpp` + `test/...tlpp`. Compilam contra o RPO compartilhado.

## Instalacao

### Via marketplace do GitHub (recomendado)

```
/plugin marketplace add Guipegoraro/tlpp-runner
/plugin install tlpp-tdd@tlpp-runner
```

O Claude Code instala plugins a partir de **marketplaces**: o repo carrega `.claude-plugin/marketplace.json` (manifest do marketplace, plugin com `source: "./"`) alem do `.claude-plugin/plugin.json` (manifest do plugin, na raiz). O clone inteiro vai pro cache (`~/.claude/plugins/cache/...`), o que torna os scripts em `runner/install/` disponiveis via `$env:CLAUDE_PLUGIN_ROOT/runner/install/` para as skills `tlpp-tdd-setup` e `tlpp-tdd-project-init`.

### Via marketplace de diretorio local (dev)

Clone o repo e registre um marketplace apontando pro diretorio:

```powershell
git clone https://github.com/Guipegoraro/tlpp-runner C:\caminho\tlpp-runner
# No Claude Code:
/plugin marketplace add C:\caminho\tlpp-runner
/plugin install tlpp-tdd@tlpp-runner
```

## Primeiro uso

**1. Setup da maquina (one-shot):**

```
/tlpp-tdd-setup
```

A skill conduz: detecta ambiente, pergunta isolamento (AppServer dedicado vs reusar), compila framework no RPO, cria config global, smoke test. Idempotente. Re-roda quando algo quebra - ela diagnostica e conserta.

**2. Inicializar projeto (opcional, so se vai usar integracao com banco):**

```
/tlpp-tdd-project-init
```

Cria `PROTHEUS_TST_<nome>` + alias DBAccess + `.tlpp-tdd.json` na raiz do projeto. ZERO arquivos do framework copiados.

**3. Workflow TDD:**

```
/tlpp-tdd "criar funcao tecCalcDescPrazo que ..."
```

Voce so cria `src/tecMinha.tlpp` + `test/tecMinhaTst.tlpp` no projeto. Slash commands compilam contra RPO compartilhado.

## Rollback

Se algo der ruim, ver `ROLLBACK.md` na raiz do framework instalado - explica passo a passo como desfazer cada etapa (restaurar `appserver.ini`, drop banco, deletar config global). Os scripts fazem backup automatico antes de qualquer mudanca em `.ini`.

## Estrutura do plugin (na raiz do repo)

```
tlpp-runner/                              # raiz do repo = raiz do plugin
├── .claude-plugin/plugin.json            # manifest (REQUERIDO)
├── skills/
│   ├── tlpp-tdd/SKILL.md                 # loop TDD autonomo
│   ├── tlpp-tdd-setup/SKILL.md           # setup + doctor (machine-once)
│   └── tlpp-tdd-project-init/SKILL.md    # init per-project
├── commands/
│   ├── tlpp-build.md                     # /tlpp-build
│   ├── tlpp-exec.md                      # /tlpp-exec
│   ├── tlpp-table.md                     # /tlpp-table
│   ├── tlpp-tdd.md                       # /tlpp-tdd
│   ├── tlpp-test.md                      # /tlpp-test
│   ├── tlpp-tdd-setup.md                 # /tlpp-tdd-setup
│   └── tlpp-tdd-project-init.md          # /tlpp-tdd-project-init
├── runner/install/                       # scripts idempotentes (setup + project-init)
├── runner/Invoke-*.ps1                   # scripts do framework (rodam do plugin root)
├── runner/BuildCache.ps1                 # cache de build (evita o restart do HTTPREST)
├── src/, mocks/, test/, docs/            # framework essencial (compilado uma vez no RPO)
├── examples/                             # demos opcionais (--with-examples)
│
├── scripts/plugin/                       # dev-only - sync, validate, find-errors
├── scripts/test/                         # dev-only - testes PS1 que rodam sem AppServer
└── .claude/                              # MIRROR de skills/commands pra dev in-repo
```

## Manutencao do plugin (so para devs do framework)

- **Editou skill ou command?** Edite o canonico em `skills/` ou `commands/` (raiz), depois rode `.\scripts\plugin\sync.ps1` para empurrar a copia pra `.claude/` (mirror in-repo).
- **Antes de commit/push:** `.\scripts\plugin\validate.ps1` - faz parse PowerShell, JSON validation, frontmatter check em SKILL.md e drift check via `sync.ps1 -DryRun`. Os `.ps1` conferidos sao **enumerados por glob** em `runner/`, `scripts/` e `hooks/` (nao ha lista fixa a manter: script novo entra sozinho).
- **Pre-commit automatico (recomendado):** `pwsh .\scripts\plugin\install-git-hooks.ps1` instala um git pre-commit que roda `validate.ps1` a cada commit e bloqueia se falhar. Escape hatch: `git commit --no-verify` pula o hook. Idempotente; faz backup de um pre-commit pre-existente de terceiros.
- **CI:** `.github/workflows/validate.yml` roda `validate.ps1` (incluindo o schema check via `claude plugin validate`, com o CLI instalado no runner) + todas as suites `scripts/test/Test-*.ps1` que nao precisam de AppServer, em todo push/PR pra `main`. Garante que ninguem mergeie com drift, parse error, JSON invalido ou manifest fora do schema mesmo pulando o hook local.
- **Release**: bumpar `version` em `.claude-plugin/plugin.json`, atualizar `CHANGELOG.md`, tag git. Sem bump, users que ja instalaram nao recebem update.
- **Skills `tlpp-tdd-setup` e `tlpp-tdd-project-init` nao tem mirror em `.claude/`** - so existem na raiz canonica. Faz sentido: in-repo voce nao quer rodar setup nem init dentro do proprio repo do framework.
