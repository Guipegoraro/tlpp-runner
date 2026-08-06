# tlpp-tdd

**Claude Code plugin para TDD em ADVPL/TLPP no Protheus** — loop autonomo red->green->refactor, compile via `advpls cli` (sem TDS-VSCode aberto), execucao de teste por nome via endpoint REST, compilacao explicita controlada pelo agente.

Para devs ADVPL/TLPP com TDS-VSCode + Protheus 24.1+ + DBAccess + SQL Server locais.

## Instalacao

```
/plugin marketplace add Guipegoraro/tlpp-runner
/plugin install tlpp-tdd@tlpp-runner
/tlpp-tdd-setup           # one-shot por MAQUINA (config global + framework no RPO). Re-rodar = doctor.
```

Opcional, por projeto que quer testes de integracao com banco:

```
/tlpp-tdd-project-init    # cria PROTHEUS_TST_<nome> + alias DBAccess + .tlpp-tdd.json
```

## Comandos

| Comando | Funcao |
|---|---|
| `/tlpp-tdd "<feature>"` | Loop TDD autonomo (red -> green -> refactor) |
| `/tlpp-build [arquivo\|--all]` | Compila via `advpls cli` |
| `/tlpp-test <funcao\|arquivo\|suite>` | Compila + roda teste (rota rapida por nome) |
| `/tlpp-exec <funcao> [args]` | Executa user function arbitraria |
| `/tlpp-table create <nome> "<cols>"` | Tabela permanente no schema versionado do projeto |
| `/tlpp-tdd-setup` | Setup + doctor da maquina |
| `/tlpp-tdd-project-init` | Banco + config per-project |

Compilacao e explicita (`/tlpp-build` ou `/tlpp-test`) - nao ha hook de build ao salvar, ja que toda compilacao reinicia o HTTPREST do AppServer.

## Documentacao

**Comece aqui:** [docs/TDD-GUIDE.md](docs/TDD-GUIDE.md) - por que TDD apesar do ciclo de compilacao, anatomia de um teste, como escolher casos, vermelho -> verde com as saidas reais.

| Doc | Conteudo |
|---|---|
| [docs/TDD-GUIDE.md](docs/TDD-GUIDE.md) | **Guia de TDD - leitura de primeiro contato** |
| [docs/REFERENCE.md](docs/REFERENCE.md) | Catalogo canonico: wrappers, mocks, asserts, helpers de banco |
| [docs/RECIPES.md](docs/RECIPES.md) | Receitas por cenario (REST, parametro, DbSeek, data, MVC, banco real) |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Sintoma -> causa -> fix das falhas reais |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Arquitetura, fluxo TDD, cascade de config, possibilidades, limitacoes, cheatsheet |
| [docs/LLM-WORKFLOW.md](docs/LLM-WORKFLOW.md) | Guia enxuto do loop TDD para LLM consumidora |
| [INSTALL.md](INSTALL.md) | Instalacao passo a passo + troubleshooting de install |
| [docs/SETUP.md](docs/SETUP.md) | Instalacao manual completa (fallback humano) |
| [docs/DATABASE-SETUP.md](docs/DATABASE-SETUP.md) | Banco de teste + alias DBAccess |
| [ROLLBACK.md](ROLLBACK.md) | Reversao manual de cada etapa do install |
| [PLUGIN.md](PLUGIN.md) | Estrutura e manutencao do plugin (devs do framework) |
| [CHANGELOG.md](CHANGELOG.md) | Historico de versoes |

## Licenca

[MIT](LICENSE)
