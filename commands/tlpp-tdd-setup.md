---
description: Setup + diagnostico + reparo do framework tlpp-tdd na maquina. Faz checklist completo (config global, paths, AppServer rodando, REST, framework no RPO) e classifica OK/FALTA/BROKEN com fix concreto. Use pra instalar inicial OU pra consertar quando algo nao funciona.
allowed-tools:
  - "Skill"
---

# /tlpp-tdd-setup - configurar / diagnosticar / consertar o framework

Argumentos opcionais: $ARGUMENTS

Invoque a skill `tlpp-tdd-setup`. **Idempotente** — pode rodar quantas vezes precisar.

## O que essa skill faz

**Phase 1: Diagnose** (sempre roda)
9 checks - cada um OK/FALTA/BROKEN com motivo:
1. Config global existe
2. Config global parses + tem chaves essenciais
3. ProtheusRoot valido
4. advpls.exe acessivel
5. Includes valido
6. AppServer REST responde `/runner/ping`
7. Framework no RPO (`u_tecAssertReset` retorna `.T.`)
8. DBAccess rodando (warning - so importa pra integracao)
9. SQL Server acessivel (warning - so importa pra integracao)

**Phase 2: Triage**
- 9/9 OK -> "tudo funcionando, nao precisa fazer nada"
- Check 1 FALTA -> setup completo (Phase 3)
- Checks 2-7 BROKEN isolados -> fix pontual (Phase 4)
- Multiplos BROKEN -> oferece redo do zero

**Phase 3: Setup completo** (user novo)
- Detecta ambiente (Test-Environment.ps1)
- Pergunta isolamento: AppServer dedicado (recomendado) vs reusar
- Aplica config + compila framework no RPO + smoke test

**Phase 4: Fix targeted** (doctor mode)
- Check 3-5 BROKEN -> re-detecta e regrava paths (`Write-GlobalConfig.ps1 -Merge`)
- Check 6 BROKEN -> diferencia HTTP 0 (AppServer off) / 401 (senha) / 404 (.ini sem HTTPREST), aplica fix correspondente
- Check 7 BROKEN -> recompila framework no RPO
- Apos cada fix, re-roda diagnose

## Quando usar

- **Maquina nova**: setup inicial.
- **Algo nao funciona**: `/tlpp-build` retorna "advpls nao encontrado", `/tlpp-test` retorna `HTTP 0 connection refused`, `/runner/exec` retorna `funcao_nao_existe`. Skill diagnostica e conserta.
- **Apos atualizar TDS-VSCode**: caminho do advpls.exe mudou. Skill detecta e regrava.
- **Apos mudar Protheus**: paths derivados invalidos. Skill detecta e regrava.

## Quando NAO usar

- Inicializar um projeto especifico (criar banco PROTHEUS_TST_<projeto>): use `/tlpp-tdd-project-init`.

## Pre-requisitos

A skill detecta tudo, mas voce precisa ter:
- TDS-VSCode instalado (vem com `advpls.exe`)
- Protheus 24.1+ instalado localmente
- SQL Server 2019+ acessivel (opcional pra unit tests)
- PowerShell 5.1+

## Flags

- `--dry-run` - so mostra diagnostico, nao aplica fix
- `--reuse-appserver` - no Phase 3, pula pergunta indo pro modo "reusar"
- `--dedicated` - no Phase 3, pula pergunta indo pro modo "dedicado"

## Rollback

Se algo der ruim:
- `.ini` revertem via `<ini>.bak.<timestamp>` (mesma pasta)
- AppServer dedicado: deletar `<ProtheusRoot>/bin/appserver_tdd/`
- Config global: deletar `~/.claude/tlpp-tdd/config.ps1`
- Framework no RPO: nao precisa "remover" (so sobrescreve no proximo build)
