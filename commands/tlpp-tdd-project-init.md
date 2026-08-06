---
description: Inicializa projeto ADVPL/TLPP pra usar testes de integracao com banco isolado. Cria PROTHEUS_TST_<projeto> + alias DBAccess + .tlpp-tdd.json. Assume que /tlpp-tdd-setup ja rodou.
allowed-tools:
  - "Skill"
---

# /tlpp-tdd-project-init - inicializar projeto atual

Argumentos opcionais: $ARGUMENTS

Invoque a skill `tlpp-tdd-project-init`. **Roda uma vez por projeto** (pra cada projeto que vai ter testes de integracao).

## O que essa skill faz

1. **Pergunta nome** do projeto (valida `[A-Z][A-Z0-9_]{0,19}`)
2. **Cria banco** `PROTHEUS_TST_<NOME>` no SQL (isolado do banco principal, com schema base do framework)
3. **Adiciona alias DBAccess** `MSSQL/PROTHEUS_TST_<NOME>` no `dbaccess.ini` (com backup)
4. **Grava `.tlpp-tdd.json`** na raiz do projeto: `{"name": "<NOME>"}`
5. **Smoke test**: ping + assert que `u_tecCtxTestDbAlias()` retorna o alias certo

## Pre-requisitos

- `/tlpp-tdd-setup` ja rodou (existe `~/.claude/tlpp-tdd/config.ps1`)
- Voce esta no diretorio do projeto que quer inicializar (a skill confirma)
- SQL Server + DBAccess do `tlpp-tdd-setup` ainda rodando

## Quando NAO usar

- Projeto so vai ter testes UNIT (sem banco). Esses dispensam `.tlpp-tdd.json` - basta os fontes `src/` + `test/unit/`.
- Setup de maquina ainda nao feito - rode `/tlpp-tdd-setup` antes.
- Banco do projeto ja foi criado manualmente - skill detecta e oferece reconfig vs skip.

## O que vai mudar no seu ambiente

| Recurso | Mudanca | Backup |
|---|---|---|
| SQL Server | CREATE DATABASE `PROTHEUS_TST_<NOME>` | n/a (banco novo) |
| `dbaccess.ini` | Adiciona secao `[MSSQL/PROTHEUS_TST_<NOME>]` | `.bak.<timestamp>` |
| `<projeto>/.tlpp-tdd.json` | Cria arquivo | n/a (novo) |

**ZERO mudancas** no banco principal, no AppServer, ou em fontes do projeto.

## Flags

- `--name <NOME>` - pula o prompt, usa esse nome
- `--dry-run` - so mostra plano

## Reverter

```sql
DROP DATABASE PROTHEUS_TST_<NOME>
```
+ remover secao do `dbaccess.ini` (ou restaurar backup)
+ deletar `.tlpp-tdd.json`
