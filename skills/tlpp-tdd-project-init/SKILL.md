---
name: tlpp-tdd-project-init
description: 'Inicializa um projeto ADVPL/TLPP existente pra usar testes de integracao com banco isolado. Pergunta nome, cria banco PROTHEUS_TST_<projeto> no SQL Server (sem tocar no banco principal), adiciona alias DBAccess com backup do .ini, grava `.tlpp-tdd.json` na raiz do projeto. Oferece tambem o ISOLAMENTO opt-in (#34) - instancia AppServer dedicada com RPO e portas proprias, pra compilar sem derrubar o HTTPREST dos outros projetos. Use quando o usuario disser "init projeto tlpp", "criar projeto tdd", "novo projeto Protheus pra TDD", "tlpp-tdd-project-init", "isolar o projeto", "instancia/AppServer dedicado pro projeto", "RPO proprio", ou quando ele esta tentando rodar teste de integracao em projeto sem `.tlpp-tdd.json`. NAO use pra setup inicial de maquina - isso e `/tlpp-tdd-setup`. NAO use pra projetos que so vao ter testes unitarios sem banco (esses dispensam .tlpp-tdd.json).'
---

You are running **per-project initialization** for an existing ADVPL/TLPP project that will use `tlpp-tdd` with integration tests. The framework is already in the shared RPO (machine setup done via `/tlpp-tdd-setup`). Your job: create an isolated test database, add a DBAccess alias for it, write `.tlpp-tdd.json` in the project root.

**Language rule:** Skill in English, output to user in PT-BR.

## Pre-flight

1. **Verify machine setup done**: `~/.claude/tlpp-tdd/config.ps1` must exist. If not:
   ```
   Antes de inicializar um projeto, voce precisa rodar /tlpp-tdd-setup
   pra configurar o framework na maquina (compila tec* no RPO, cria
   config global). Quer fazer agora?
   ```
   Se sim, delegate pra skill `tlpp-tdd-setup`.

2. **Resolve `$RUNNER_INSTALL`** (path scripts) - mesma logica do tlpp-tdd-setup.

3. **Verify project root**: default `$CLAUDE_PROJECT_DIR` ou cwd. Confirma com user: "Vou inicializar o projeto em <path>. OK?"

4. **Check if already initialized**: `<projectRoot>/.tlpp-tdd.json` existe? Se sim:
   - Le `name` dele
   - Pergunta: "Projeto '<name>' ja inicializado. Quer reconfigurar (cria novo banco) ou nada?"
   - Se nada, exit.

## Phase 1 — Nome do projeto

Pergunta:

```
Qual o nome deste projeto? Sera usado pra:
  - Banco de teste: PROTHEUS_TST_<NOME>
  - Alias DBAccess: MSSQL/PROTHEUS_TST_<NOME>
  - Campo "name" no .tlpp-tdd.json

Default sugerido: <basename do projectRoot em maiuscula, sanitizado>

Formato: [A-Z][A-Z0-9_]{0,19} - max 20 chars, caixa alta, comeca com letra.
```

Valida. Se invalido, pergunta de novo.

## Phase 1.5 — Isolamento (opt-in, #34)

Pergunta SEMPRE (default = nao). O padrao continua sendo o AppServer dev
compartilhado; isolamento e escolha consciente com custo de disco/RAM.

```
Quer uma instancia AppServer DEDICADA pra este projeto?

  [N] Nao (default) - usa o AppServer dev compartilhado (8401).
      Simples, zero disco extra. Contra: cada compilacao sua derruba
      o HTTPREST por 37-93s pra TODOS os projetos da maquina.

  [S] Sim - instancia propria: RPO, portas e appserver.ini exclusivos.
      Compilar aqui NAO afeta os outros (0 downtime medido).
      Custo: ~1,45 GB de disco (485MB da arvore do AppServer + ~960MB
      do RPO padrao, que NAO pode ser compartilhado) e ~500MB de RAM
      enquanto a instancia estiver ligada.
      Portas sao alocadas automaticamente (TCP/HTTPREST/WEBAPP).
      DBAccess, License Server e protheus_data seguem compartilhados.
```

Se `[S]`, pergunta o seed do RPO custom:

```
E o custom.rpo da instancia nova?

  [1] Limpo (default) - nao cria arquivo nenhum. O AppServer cria o
      custom.rpo sozinho na primeira compilacao. Voce compila o
      framework + os seus fontes e pronto.

  [2] Copiar o atual - copia o custom.rpo do ambiente dev compartilhado
      (<ProtheusRoot>\protheus\apo\custom.rpo). Use se o projeto depende
      de objetos customizados que ja estao compilados la e voce nao tem
      os fontes a mao.
```

Guarde a resposta: `$isolar` (bool) e `$seedCustom` (path ou vazio).

## Phase 2 — Plano

Carrega global config pra mostrar onde vai mexer:

```powershell
. (Join-Path $env:USERPROFILE '.claude\tlpp-tdd\config.ps1')
$gcfg = $TlppRunner  # ja inicializado pelo runner.config.ps1 cascade
```

Mostre plano:

```
Plano:

  1. [SQL] CREATE DATABASE PROTHEUS_TST_<NOME>
     Servidor: <gcfg.SqlInstance>
     Auth:     <gcfg.SqlAuth>
     Razao:    banco isolado pros testes de integracao - nao toca em <banco_principal>

  2. [SQL] Aplicar schema base Z_TST_* em PROTHEUS_TST_<NOME>
     Script: <PLUGIN_ROOT>/runner/sql/02-create-schema.sql (do framework)
     Razao:  tabelas base usadas por u_tecTstSeed / u_tecTstCreateTable

  3. [SQL] GRANT db_owner pra sa + sysdba (logins do DBAccess)

  4. [DBAccess] Adicionar secao [MSSQL/PROTHEUS_TST_<NOME>] em <gcfg.DbAccessIniPath>
     Backup:   <ini>.bak.<timestamp>
     Razao:    TCLink dinamico nos testes de integracao usa esse alias

  5. [Filesystem] Gravar <projectRoot>/.tlpp-tdd.json
     Conteudo: {"name": "<NOME>"}
     Razao:    o Invoke-TlppRunner.ps1 le esse arquivo pra saber qual
               banco usar quando chamar /runner/exec

  6. [Restart] Pedir restart do DBAccess (se a porta nao reler ini automatico)
     Razao:    DBAccess precisa recarregar o alias novo

  7. [Smoke] Teste de integracao basico:
     - TCLink no alias
     - INSERT/SELECT numa tabela Z_TST_*
     - TCUnlink

Posso iniciar?
```

Se `$isolar`, acrescente ao plano (rode antes o `New-IsolatedInstance.ps1 -DryRun`
pra ja mostrar as portas escolhidas de verdade, sem copiar nada):

```
  1b. [Isolamento] Instancia dedicada '<NOME>'
      bin:     <ProtheusRoot>\Protheus\bin\appserver_<nome>   (copia de appserver_rest, ~485MB)
      RPO:     <ProtheusRoot>\protheus\apo_<nome>             (+ tttm120.rpo copiado, ~960MB)
      portas:  TCP=<n>  HTTPREST=<n>  WEBAPP=<n>  (livres e nao reservadas por outra instancia)
      custom:  <limpo | copiado de ...>
      json:    isolation:{tcpPort,restPort,webAppPort} no .tlpp-tdd.json
      Razao:   compilar sem derrubar o HTTPREST dos outros projetos (#29/#34)
      NAO toca: protheus_data, DBAccess, License Server, nem as instancias existentes

  1c. [Isolamento] Subir a instancia + compilar o FRAMEWORK nela
      Razao:   o RPO e novo - u_tecAssert*/u_tecMk*/u_tecTstConn nao existem la ainda
```

## Phase 3 — Execucao

```powershell
# 1-3. Banco + schema + grants
& "$RUNNER_INSTALL\New-TestDatabase.ps1" `
    -SqlInstance $gcfg.SqlInstance `
    -DbName "PROTHEUS_TST_$projectName" `
    -Mode 'Fresh' `
    -SqlAuth $gcfg.SqlAuth -SqlUser $gcfg.SqlUser -SqlPassword $gcfg.SqlPassword `
    -SchemaScript (Join-Path $PLUGIN_ROOT 'runner\sql\02-create-schema.sql')

# 4. Alias DBAccess
& "$RUNNER_INSTALL\Set-DBAccessAlias.ps1" `
    -DbAccessIniPath $gcfg.DbAccessIniPath `
    -DbName "PROTHEUS_TST_$projectName" `
    -SqlInstance $gcfg.SqlInstance `
    -SqlAuth $gcfg.SqlAuth -SqlUser $gcfg.SqlUser

# 5. .tlpp-tdd.json
& "$RUNNER_INSTALL\Write-ProjectConfig.ps1" `
    -ProjectRoot $projectRoot `
    -Name $projectName

# 5b. ISOLAMENTO (so se $isolar) - cria a instancia e grava isolation no json.
#     Rode SEMPRE com -DryRun antes e mostre o plano real ao usuario.
if ($isolar) {
    $isoArgs = @{
        ProjectRoot  = $projectRoot
        Name         = $projectName
        ProtheusRoot = $gcfg.ProtheusRoot
    }
    if ($gcfg.DbAccessPort) { $isoArgs.TopPort = [int]$gcfg.DbAccessPort }
    if ($seedCustom)        { $isoArgs.SeedCustomFrom = $seedCustom }

    & "$RUNNER_INSTALL\New-IsolatedInstance.ps1" @isoArgs -DryRun   # mostra portas
    # ... confirma com o usuario ...
    $inst = & "$RUNNER_INSTALL\New-IsolatedInstance.ps1" @isoArgs

    # A instancia sobe SOZINHA no primeiro build (runner/InstanceControl.ps1),
    # mas compilar o framework agora deixa o projeto usavel de imediato.
    # ATENCAO: sao os fontes do PLUGIN compilados com a config do PROJETO
    # (-ProjectRoot $projectRoot) - e o cascade do projeto que resolve
    # environment/porta/RPO da instancia nova.
    $fwSrc = @()
    foreach ($d in @('src', 'mocks')) {          # glob, nao lista fixa: fonte novo entra sozinho
        $p = Join-Path $PLUGIN_ROOT $d
        if (Test-Path $p) {
            $fwSrc += Get-ChildItem -Path $p -Recurse -Include '*.tlpp','*.prw','*.prx','*.prg' -File |
                      Select-Object -ExpandProperty FullName
        }
    }
    & "$PLUGIN_ROOT\runner\Invoke-TlppBuild.ps1" -ProjectRoot $projectRoot -File $fwSrc
    # 1a compilacao cria o custom.rpo em apo_<nome> e derruba/sobe o HTTPREST da
    # instancia NOVA - as outras nao sentem nada.

    # Smoke da instancia: /runner/ping na porta nova
    & "$PLUGIN_ROOT\runner\Invoke-TlppRunner.ps1" -Ping -ProjectRoot $projectRoot
    # Deve responder na porta $inst.RestPort. Se der connection refused mesmo
    # depois do build, olhe $inst.BinDir\console.log.
}

# 6. Pedir restart do DBAccess (se PID achado)
if ($gcfg.DbAccessPid) {
    Write-Host "Reinicie o DBAccess (PID $($gcfg.DbAccessPid)). Quando voltar, me responda 'pronto'."
    # Aguardar resposta do user
}

# 7. Smoke integracao - TCLink + INSERT + SELECT + cleanup
# u_tecSmkProjInit le u_tecCtxTestDbAlias do body (propagado pelo runner via
# .tlpp-tdd.json) e exercita TCLink -> Z_TST_CLIENTE (schema) -> INSERT -> SELECT.
# Retorna .T. se tudo OK, .F. detalhando no Conout do AppServer caso contrario.
$smokeFunc = 'u_tecSmkProjInit'
$runner = if ($env:CLAUDE_PLUGIN_ROOT) { "$env:CLAUDE_PLUGIN_ROOT\runner" } else { "$PLUGIN_ROOT\runner" }
& "$runner\Invoke-TlppRunner.ps1" -Function $smokeFunc -ProjectRoot $projectRoot -Quiet
# Deve mostrar: u_tecSmkProjInit: result=.T. dur=Xs
# Se result=.F., olhar console.log do AppServer (linhas [smk-proj-init])
```

## Phase 4 — Relatorio final

```
=== Projeto <NOME> inicializado ===

Banco:        PROTHEUS_TST_<NOME>
Alias:        MSSQL/PROTHEUS_TST_<NOME>
Config:       <projectRoot>/.tlpp-tdd.json

Isolamento:   <nao (usa AppServer dev 8401) | SIM>
  (se sim)    environment:  <NOME>
              bin:          <ProtheusRoot>\Protheus\bin\appserver_<nome>
              RPO:          <ProtheusRoot>\protheus\apo_<nome>
              portas:       TCP=<n>  HTTPREST=<n>  WEBAPP=<n>
              framework:    compilado no RPO da instancia [OK]
              ciclo:        sobe sozinha no 1o /tlpp-build ou /tlpp-test.
                            Nao para sozinha - pare na mao quando quiser
                            liberar a RAM (feche a janela do console).

Smoke:        u_tecSmkProjInit (TCLink + INSERT + SELECT em Z_TST_CLIENTE) [OK]

Como usar:
  Crie test/integracao/tecXxxItgTst.tlpp normalmente:

    @TestFixture()
    user function test_meu_caso()
        local nLink, nLinkAnt
        u_tecAssertReset()
        nLink := u_tecTstConn(@nLinkAnt)  // conecta no banco do projeto automatic
        // ... seus testes ...
        u_tecTstDisconn(nLink, nLinkAnt)
    return u_tecAssertsOk()

  E rode com:
    /tlpp-test u_test_meu_caso

  O Invoke-TlppRunner.ps1 le .tlpp-tdd.json e propaga o nome pro AppServer.
  u_tecTstConn usa o alias certo automatic.

Reverter:
  - Drop database:       sqlcmd ... -Q "DROP DATABASE PROTHEUS_TST_<NOME>"
  - Remover alias:       editar manualmente dbaccess.ini ou restaurar backup
  - Apagar .tlpp-tdd.json
  - Desfazer isolamento: pare a instancia, apague a chave "isolation" do
                         .tlpp-tdd.json (volta pro AppServer compartilhado) e,
                         se quiser o disco de volta, apague
                         Protheus\bin\appserver_<nome> e protheus\apo_<nome>
```

## Idempotencia

Se rodar de novo:
- Banco ja existe -> skip CREATE, mas garante GRANT
- Alias ja existe e bate -> skip
- .tlpp-tdd.json existe com mesmo Name -> skip (Force-flag pra sobrescrever)
- Instancia isolada ja existe -> `New-IsolatedInstance.ps1` reporta e sai sem
  tocar em nada. Com `-Force` regrava o appserver.ini (com backup) e o json,
  reaproveitando as portas ja registradas e PRESERVANDO o custom.rpo compilado
- Smoke roda sempre

## Anti-patterns

| Erro | Sintoma | Fix |
|---|---|---|
| Criar banco sem mostrar nome ao user | Surpresa: banco "errado" | Mostrar plano + esperar OK |
| Mexer no banco principal por engano | Producao corrompida | Validar regex + NUNCA `DROP <fora-do-test>` |
| Sobrescrever .tlpp-tdd.json com Name diferente | Apaga config previa | Write-ProjectConfig.ps1 valida e pede -Force |
| Pular restart DBAccess | TCLink retorna -35 | Sempre pedir restart explicito |
| Oferecer isolamento como default | 1,45GB de disco que o user nao pediu | Default e NAO; explicar o custo antes |
| Criar instancia sem mostrar as portas reais | User descobre conflito depois | Rodar `-DryRun` primeiro e mostrar |
| Esquecer de compilar o framework na instancia nova | `funcao_nao_existe` em todo teste | Passo 1c e obrigatorio quando `$isolar` |
| Compilar o framework com `-ProjectRoot $PLUGIN_ROOT` | Vai pro RPO compartilhado, nao pro da instancia | `-ProjectRoot $projectRoot -File <fontes do plugin>` |
| Editar a mao o appserver.ini de OUTRA instancia | Derruba o ambiente do vizinho (ex: DENK) | O script so cria `appserver_<nome>`; nunca toque nos outros |

## Referencias

- `$RUNNER_INSTALL\New-TestDatabase.ps1`
- `$RUNNER_INSTALL\Set-DBAccessAlias.ps1`
- `$RUNNER_INSTALL\Write-ProjectConfig.ps1`
- `$RUNNER_INSTALL\New-IsolatedInstance.ps1` - instancia dedicada (#34)
- `$PLUGIN_ROOT\runner\InstanceControl.ps1` - sobe a instancia on-demand no build/test
- `~/.claude/tlpp-tdd/config.ps1` - config global (do `/tlpp-tdd-setup`)
