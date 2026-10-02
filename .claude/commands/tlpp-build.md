---
description: Compila fontes TLPP/AdvPL via advpls cli (sem TDS-VSCode aberto). Aceita arquivo, lista ou -All. Delega para a skill tlpp-build.
allowed-tools:
  - "Skill"
---

# Compilar fontes TLPP/AdvPL — wrapper para a skill `tlpp-build`

Argumentos: $ARGUMENTS

Invoque a skill `tlpp-build` passando o argumento como alvo da compilacao
(arquivo, lista separada por virgula, ou `-All`). A skill contem a resolucao do
caminho do runner, a leitura correta do cache de build e os erros comuns.

Se o usuario nao passou argumento, trate como `-All`.
