---
description: Compila fontes e executa testes ADVPL/TLPP. Aceita nome de funcao (rota rapida via /runner/exec) OU suite/arquivo PROBAT. Delega para a skill tlpp-test.
allowed-tools:
  - "Skill"
---

# Compilar e rodar testes — wrapper para a skill `tlpp-test`

Argumentos do usuario: $ARGUMENTS

Invoque a skill `tlpp-test` passando o argumento como alvo. A skill contem os 3
modos de uso (nome de funcao, arquivo `.tlpp`, suite PROBAT), a resolucao do
caminho do runner e os erros comuns.

Se o usuario nao passou argumento, trate como suite completa (Modo 3).
