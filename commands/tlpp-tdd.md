---
description: Workflow TDD autonomo em ADVPL/TLPP - red/green/refactor sem TDS-VSCode. Delega para a skill tlpp-tdd (em .claude/skills/tlpp-tdd/SKILL.md).
allowed-tools:
  - "Skill"
---

# TDD em TLPP — wrapper para a skill `tlpp-tdd`

Argumentos: $ARGUMENTS

Invoque a skill `tlpp-tdd` passando o argumento como descricao da feature. A skill contem o loop autonomo completo (red → green → refactor), padroes obrigatorios e anti-patterns.

Se o usuario nao especificou a feature, peca antes de invocar a skill.
