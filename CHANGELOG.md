# Changelog

Todos os releases do `tlpp-tdd` (plugin Claude Code) seguem [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [0.4.1] - 2026-10-02

Correcoes medidas contra o AppServer real ao avaliar o `tds_run` do tds-mcp como transporte alternativo ao REST. A avaliacao concluiu pelo REST: com as correcoes abaixo ele roda um teste em ~10 ms e volta ~5 s depois de cada compilacao, contra 5,5-8 s por chamada do `tds_run` (sem valor de retorno).

### Corrigido
- **Janela do REST apos compilar: de ~92 s para ~5 s.** A janela nao e a compilacao (~7,5 s): o build derruba os HTTP servers e o job `HTTP_START` so e relancado no proximo ciclo do `[ONSTART] RefreshRate`. O template gravava `RefreshRate=120`; passa a gravar `2` (`IniIO.ps1`, usado por `Set-AppServerRest` e `New-IsolatedInstance`). `Set-AppServerRest` baixa in-place um `RefreshRate` acima de 2 em ini existente, e o doctor do `/tlpp-tdd-setup` aponta o caso. Explica a variacao de 37-93 s medida na #29 (fase do ciclo de 120 s em que a compilacao caia).
- **~2 s por request ao REST**: `BaseUrl` com `localhost` resolve IPv6 primeiro e o AppServer escuta so IPv4. Padrao vira `http://127.0.0.1:8401/rest`, e `runner.config.ps1` normaliza `localhost` de config global e `.tlpp-tdd.json` ja gravados. `/runner/exec` cai de ~2 s para ~10 ms.
- **Erro de execucao na funcao testada voltava como sucesso com retorno vazio**: o `BEGIN SEQUENCE` do `tecRunrExec` nao tinha `ErrorBlock`, e mesmo com ele o `Break` disparado dentro da chamada por `tlpp.call`/macro nao chega ao `RECOVER` do chamador (medido). Agora `try/catch` + macro: HTTP 500 com `message` e `stack` apontando a linha do fonte chamado (`tlpp.call` so para nome com namespace, que a macro nao resolve). `Break("...")` explicito e `Empty()` sobre JsonObject ainda derrubam a thread (500 generico do tlppCore).
- **Respostas de erro do endpoint (400/404/500) chegavam como 500 generico**: os handlers faziam `return .F.`, e o tlppCore descarta o corpo montado nesse caso. Handlers retornam `.T.` com o status em `setStatusCode`.
- **`Show-Error` do `Invoke-TlppRunner` nao mostrava nada no PowerShell 7** (`GetResponseStream` nao existe em `HttpResponseMessage`): le `ErrorDetails` e formata erro de execucao como mensagem + pilha.

### Adicionado
- **Falhas de assert na resposta do `/runner/exec`**: campo `asserts` (`u_tecAssertSummary()`: ok, passed, failed, fails[]) quando a chamada registra assert. `-Quiet` imprime `asserts=NokMfail` e uma linha `FAIL:` por falha - nao e mais preciso ler o `console.log`.
- **`tecRunrToStr` serializa JsonObject** (`toJson()`) em vez de `<J>`.
- **Diagnostico de `COMPILEERROR-300`** no `Invoke-TlppBuild`: dois AppServers sobre o mesmo `custom.rpo` impedem a compilacao pelos dois, e o AppServer do REST fica sem HTTP ate reiniciar.

### Mudado
- `.gitignore` cobre `runner/runner.config.local.ps1.bak*`.

## [0.4.0] - 2026-08-15

Correcao de descoberta: o plugin se chama `tlpp-tdd`, o usuario chama de "tlpp runner", e a string "tlpp runner" nao existia em NENHUM `name`/`description` de skill ou command. Resultado em campo: sessao nova num projeto consumidor recebeu "pode usar o tlpp runner para esse projeto" e nao reconheceu nada.

### Adicionado
- **Skills `tlpp-build` e `tlpp-test`**: antes existiam so como slash command. Command o agente nunca invoca sozinho - depende do usuario digitar a barra - entao "roda o teste" / "compila esse fonte" nao disparavam nada proativamente. O conteudo real migrou dos commands pros `SKILL.md`; os commands viraram delegadores finos (mesmo padrao que `tlpp-tdd.md` ja usava), mantendo fonte unica.
- **Tabela de roteamento no `tlpp-tdd` SKILL**: quando o usuario libera o toolchain pelo nome em vez de pedir uma acao, a skill le o repo e encaminha - sem `.tlpp-tdd.json` e precisa de banco -> `tlpp-tdd-project-init`; runner respondendo HTTP 0 -> `tlpp-tdd-setup`; so compilar -> `tlpp-build`; rodar teste -> `tlpp-test`; funcao nova -> segue o ciclo local.
- **Secao "Where you are running" no `tlpp-tdd` SKILL**: a primeira linha do arquivo afirmava "You are inside the `tlpp-runner` project", falso em todo projeto consumidor. Agora distingue os dois contextos e avisa que o prefixo `tec` e o layout `src/`+`test/unit/` sao convencao DESTE repo, usados nos exemplos - projeto consumidor substitui pelos seus.
- **Passo 8 do `tlpp-tdd-project-init`**: anexar a secao "Testes (tlpp-tdd / tlpp-runner)" no `CLAUDE.md` do projeto. O `.tlpp-tdd.json` configura o runner mas nao ensina nada ao agente; sem essa linha o projeto fica inicializado e ainda assim sem sinal passivo de que o toolchain existe. Anexa, nunca sobrescreve; secao ja existente e atualizada, nao duplicada.

### Mudado
- **Descriptions reescritas** (`tlpp-tdd`, `tlpp-build`, `tlpp-test`) por tres regras: um trigger por branch (a versao intermediaria empilhava 6-9 sinonimos da mesma coisa), description descreve QUANDO usar e nao o que a skill faz (resumo de workflow vira atalho que o agente segue em vez de ler o corpo), e redirecionamento positivo no lugar de `NAO use pra X`. O nome do toolchain vive em UMA skill so - `tlpp-tdd`, o guarda-chuva: quatro descriptions disputando "tlpp runner" seria a mesma falha em escala de corpus.

### Nota de verificacao
A correcao de gatilho **nao foi verificada em ambiente controlado**. O RED (baseline com as descriptions 0.3.0) nao e rodavel por subagent a partir da sessao que escreveu a skill: o subagent herda o snapshot da lista de skills da sessao pai, entao tanto o inventario falso via prompt quanto a reversao dos arquivos no disco saem contaminados com as descriptions novas. A evidencia disponivel e o relato de campo (0.3.0, sessao real, nao reconheceu) mais 10/10 subagents desta sessao escolhendo `tlpp-tdd` com a description nova presente - sem controle valido, portanto sugestivo e nao conclusivo. Teste real: sessao nova num projeto com a versao anterior instalada, dizer a frase, depois atualizar e repetir.

## [0.3.0] - 2026-08-06

Release do gate de revisao geral pre-lancamento: 20 achados confirmados, 10 corrigidos aqui (os demais viraram issues #49-#58). Primeira versao considerada pronta pra outros usuarios.

### Adicionado
- **`.claude-plugin/marketplace.json`**: o repo agora e um marketplace Claude Code - instalacao passa a ser `/plugin marketplace add Guipegoraro/tlpp-runner` + `/plugin install tlpp-tdd@tlpp-runner` (o fluxo antigo `/plugin install <git url>` documentado nao funcionava: o CLI instala a partir de marketplaces). README/INSTALL/PLUGIN atualizados.
- **`u_tecAssertFail(cDesc, cDetail)`** em `tecAssert.tlpp`: registra falha explicita fora do fluxo normal de assert - usado pelo `u_tecTstWith` pra converter exception em falha. Documentado no REFERENCE.

### Corrigido
- **Onda 1 - instalacao em maquina virgem (#60)**: `Set-AppServerRest.ps1` ganhou update in-place real de Port/Environment/Enable e criacao do bloco REST completo ([HTTPJOB]/[ONSTART]/[HTTPV11]/[HTTPREST]/[HTTPURI]) via template unico compartilhado com `New-IsolatedInstance` - antes anunciava ajuste sem mudar byte e criava secao que nao servia /rest; snippets do `tlpp-tdd-setup` corrigidos contra o objeto REAL do `Test-Environment` (+ `AppServer.Dir` novo); `Write-GlobalConfig` falha listando chave obrigatoria nula em vez de gravar config incompleto - e corrigido bug do `-f` em argumento de metodo que explodia TODA gravacao real (a fase de gravacao do setup nunca tinha funcionado); cascade `$env:CLAUDE_PLUGIN_ROOT` no `tlpp-tdd` SKILL (o `.\runner\` so existia no repo dev); backoff do `Invoke-TlppRunner` classificado por TIPO de exception em `runner/HttpRetry.ps1` (WebException.Status/HttpRequestException/SocketException; HttpResponseException excluida por FullName - 404 nao vira retry) - o regex por mensagem estava MORTO em PS 5.1 pt-BR. Test-AppServerRest 6->26 checks, Test-RunnerConfig 35->51.
- **Onda 2 - vazamento de credenciais (#59)**: `build-<PID>.ini` com `psw=` em claro agora e apagado no finally (sucesso, falha e excecao) e orfaos de execucoes mortas sao varridos na entrada (`runner/BuildTemp.ps1`; PID morto ou >1h sai, build concorrente vivo fica); `Set-DBAccessAlias` mascara `PWD=` na exibicao (`Get-MaskedConnString` em IniIO.ps1) mantendo a string real no arquivo; SETUP.md documenta a senha em claro no config global + ACL recomendada. Test-BuildCache +C19-C24, Test-DBAccessAlias +A8-A11.
- **Onda 3 - falso-verdes no framework TLPP (#61)**: exception dentro do bloco de `u_tecTstWith` REGISTRA FALHA (RECOVER chama `u_tecAssertFail` com a Description do erro) em vez de deixar o teste terminar verde; e `tecRunrExec` desliga o modo teste (`u_tecTstStop`) no inicio de cada request e no RECOVER - teste que estourava antes do Stop deixava mocks/`lModoTst` (statics por thread) vazando pro request seguinte, medido 30/30 requests contaminados antes do fix e 0/30 depois. Suite 60->61.

### Removido
- **Hook PostToolUse `build-on-save`**: o plugin nao registra mais hook de recompilacao automatica ao salvar (`hooks/hooks.json` + `hooks/build-on-save.ps1` + `Test-BuildOnSaveHook.ps1` removidos, junto com o hook espelhado no `.claude/settings.json` do repo). Motivo: toda compilacao reinicia o HTTPREST por 37-93s (#29), entao recompilar a cada Edit/Write penaliza o loop inteiro - e em maquina sem execution policy liberada o hook falhava em TODA edicao. Compilacao passa a ser 100% explicita, decidida pelo agente: `/tlpp-build <arquivo>` ou `/tlpp-test` (que compila antes de rodar, com guard do oraculo RPO/cache pulando fontes inalterados).

### Corrigido
- **`u_tecMkHttp`: `ok` do mock espelha a semantica de prod (#46)**: em modo teste, `jResp["ok"]` vinha `.T.` fixo sempre que o mock existia - inclusive com status 500 mockado, enquanto em producao `ok = (2xx)`. Teste de cenario de erro que afirmasse sobre `ok` passava verde a toa. Agora o mock calcula `ok` a partir do status (e preenche `error` como em prod). Achado pelo agente da #27 ao documentar o REFERENCE. Suite 59 -> 60.

### Mudado
- **README enxuto (#25)**: de 194 pra 49 linhas - pitch, instalacao, tabela de comandos e indice de docs. Conteudo movido sem perda: quick start dev in-repo foi pro cheatsheet do `docs/ARCHITECTURE.md` (filosofia, workflow, convencoes e limitacoes ja viviam la); estrutura do repo e guia de contribuidor ja viviam no `PLUGIN.md`. De quebra, atualizados pontos que envelheceram nos dois: `/tlpp-table` global (#21), oraculo RPO (#33) na mitigacao do restart, `Copy-AppServerDev` absorvido pela #34 e descricao do CI com schema check (#37).

### Adicionado
- **Isolamento opt-in por projeto (#34)**: um projeto pode ganhar a sua **instancia AppServer dedicada** - RPO, portas e `appserver.ini` proprios - pra compilar sem derrubar o HTTPREST dos outros (o restart de 37-93s da #29 vale por instancia). Gatilho e a chave nova `isolation: {tcpPort, restPort, webAppPort}` no `.tlpp-tdd.json`; projeto sem ela segue exatamente como antes, no AppServer dev compartilhado.
  - **`runner/install/New-IsolatedInstance.ps1`**: aloca as tres portas (sondagem por bind + parse dos `appserver.ini` de TODAS as instancias por glob - porta de instancia DESLIGADA tambem e respeitada), copia a arvore do `appserver_rest` (excluindo o ini original e os logs), cria `apo_<nome>` copiando o RPO base, gera o ini novo em Latin1 e grava o `isolation` no json preservando chaves desconhecidas. `-DryRun` mostra as portas reais sem tocar em nada; idempotente (instancia existente nao e destruida; `-Force` regrava ini com backup e preserva o `custom.rpo` compilado).
  - **`runner/InstanceControl.ps1`**: `Start-IsolatedInstanceIfNeeded` sobe a instancia **on-demand** no primeiro build/test (porta TCP fechada = subir), com `-console` obrigatorio e espera da porta REST. Sem auto-stop, sem excecao (falhar aqui nunca reprova um build) e no-op silencioso pra projeto nao isolado. Chamado por `Invoke-TlppBuild.ps1` e `Invoke-TlppRunner.ps1` antes de qualquer uso de advpls/REST.
  - **Cascade** (`runner.config.ps1`): com `isolation`, deriva `BaseUrl`/`Port`/`Environment`/`RpoCustom`/`ConsoleLogPath` + expoe `IsolationBinDir`/`ApoDir`. Um `baseUrl` explicito no mesmo json ainda vence; `isolation` sem `name` e ignorado com warning (o nome e o que deriva environment/bin/RPO).
  - **Fatos do spike (29/07/2026)** que moldaram o desenho: o `tttm120.rpo` (~957MB) **nao pode ser compartilhado** entre instancias que compilam - hardlink refutado (servir funciona, build falha com lock `cannot access the file ... DEFAULT`), por isso a copia; o `custom.rpo` e criado pelo proprio AppServer na 1a compilacao (seed e opcional); compilar na instancia isolada deu **0 downtime** na 8401; e sem `-console` o processo sai em silencio. Custo medido por instancia: ~1,45GB de disco e ~500MB de RAM enquanto ligada. `protheus_data`, DBAccess (7892) e License (5555) seguem compartilhados.
  - **Skills**: `/tlpp-tdd-project-init` pergunta o opt-in (default NAO, com o custo explicito) e o seed do custom.rpo (limpo vs copiar o atual), cria a instancia, sobe e compila os fontes do PLUGIN com a config do PROJETO (`-ProjectRoot <projeto> -File <src\tec*.tlpp + mocks\*.tlpp>`, enumerados por glob), smoke com `/runner/ping` na porta nova. `/tlpp-tdd-setup` ganhou o check 10: arvore/ini/RPO ausentes, conflito de porta entre instancias, framework desatualizado no RPO da instancia (via oraculo RPO da #33, comparando `dataFonte` com o mtime dos fontes do plugin) e - explicitamente **nao** um defeito - instancia parada, que sobe on-demand.
  - **`scripts/test/Test-IsolatedInstance.ps1`** (62 checks, CI sem AppServer): ProtheusRoot FALSO em `$env:TEMP`, sem copiar 485MB e sem subir processo nenhum - o unico recurso real e um `TcpListener` local pra provar que a sondagem enxerga porta ocupada. Cobre alocacao (pulando reservada em ini de instancia vizinha E porta em uso), conteudo do ini (environment, as tres portas, SourcePath/RpoCustom/TOPALias, RootPath compartilhado), ausencia de BOM, copia da arvore (subdiretorio vem, `console.log` e ini da fonte nao vem), copia byte a byte do RPO base, `custom.rpo` nao criado, gravacao do `isolation` preservando chaves desconhecidas, `-DryRun` inerte, idempotencia, `-Force` com backup, seed que nao sobrescreve custom.rpo existente, nome invalido rejeitado e os tres caminhos do `InstanceControl` que **nao** sobem processo (sem isolamento, instancia de pe, arvore incompleta - este ultimo provando que nao lanca excecao).
  - **`Test-RunnerConfig.ps1`** vai de 12 pra 35 checks: R9-R13 cobrem a derivacao do isolamento, o caso SEM isolamento (nada muda), `isolation` sem `name`, precedencia do `baseUrl` explicito e isolamento sem `ProtheusRoot`.
  - **Fix de revisao (banco de SISTEMA)**: o default do `TOPALias` apontava o environment da instancia pro banco de TESTE (`PROTHEUS_TST_<NAME>`, que so tem `Z_TST_*`) - com `StartSysInDB=1` a instancia nao acharia os dicionarios no boot. Agora `TOPALias`/`TOPServer`/`TOPDataBase`/`TOPPort` sao **herdados do appserver.ini de origem** (o banco de teste continua via TCLink, como no dev compartilhado); origem sem `TOPALias` e erro explicito, nao chute. Coberto por S16 (67 checks no total) e validado em E2E real: instancia criada em 3,1s + 912MB de RPO, boot on-demand em 22s, framework compilado com `custom.rpo` auto-criado e `{"env":"ISODEMO"}` respondendo na porta propria - com o 8401 intocado.
  - **Achado durante os testes** (defeito real, corrigido antes do commit): a exclusao do proprio `appserver.ini` da lista de portas reservadas comparava CAMINHO - e o `FullName` do `Get-ChildItem` vem sempre em forma longa enquanto um caminho montado com `Join-Path` preserva a forma curta 8.3 (`C:\Users\GUILHE~1\...`). As strings nunca batiam, a instancia entrava na propria lista de reservados e um reparo sem portas no json fugia das SUAS proprias portas, realocando tudo e deixando o ini divergente do que o projeto usava. Agora compara o NOME do diretorio; coberto por S14.
- **Mock de FwFormModel (#15)**: `u_tecMkModel(cId)` devolve duble do `oModel` que funcoes de validacao/gatilho de ModelDef recebem - testa regra de negocio MVC sem Activate real, sem tela e sem banco. API coberta: `Activate/DeActivate/IsActive`, `SetValue/GetValue(cSub, cCampo)`, `GetModel(cSub)` (submodel que enxerga o mesmo storage), `VldData` (custom via `SetVldBlock`), `FormCommit` no-op com `WasCommitted()` pra assert. Limites documentados no fonte: sem grid multi-linha, sem defaults de SX3. +5 testes (incluindo demo de regra de negocio); suite 54 -> 59.
- **Wrappers de dominio SE1/SC5/SC6 (#14)**: `u_tecBuscaTitulo(cPrefixo, cNum, cParcela, cTipo)` -> `{valor, vencimento, status, baixa, saldo}`; `u_tecBuscaPedido(cNum)` -> `{cliente, loja, valor_total, status, nota}` (total = soma dos itens - o SC5 padrao nao tem campo de total; status pela convencao padrao faturado > liberado > aberto); `u_tecBuscaItensPedido(cNum)` -> array de `{item, produto, qtd, valor}`. Campos e chaves de DbSeek validados contra o dicionario padrao TOTVS (MCP de referencia). Em modo teste, seeds via `u_tecMkBdSeed("SE1"/"SC5"/"SC6", aRows)`. E `u_tecMkMv` ganhou 3o parametro opcional `cTipo` (C/N/L/D): mock com tipo errado e rejeitado (.F., nao registra), evitando teste verde com parametro que em prod viria com outro tipo. Suite unit: 44 -> 54 testes.
- **`/tlpp-table` no modelo global (#21)**: o schema de tabelas permanentes agora vive no PROJETO, nao no plugin. Novo campo `schemaPath` no `.tlpp-tdd.json` (default `sql/schema.sql`; o repo dev do tlpp-runner segue usando `runner/sql/02-create-schema.sql` por fallback de layout). `db-setup.ps1` passou a: respeitar o banco do cascade (`TestDb` - `PROTHEUS_TST_<NOME>` em consumidor), aplicar o schema do projeto apos o do framework (com dedup quando sao o mesmo arquivo), aceitar `-ProjectRoot` (override ANTES do dot-source, mesma pegadinha do PR #31) e dar hint de `/tlpp-tdd-project-init` quando o banco do projeto nao existe. `Write-ProjectConfig.ps1` aceita `-SchemaPath`. Validado e2e: projeto consumidor sem `runner/` aplicou schema proprio no banco, idempotente, e o fluxo dev-repo nao duplica.
- **`scripts/test/Test-RunnerConfig.ps1`** (12 checks, CI sem AppServer): primeira suite do cascade de config - que nunca teve teste e ja teve bug grave silencioso (`-ProjectRoot` ignorado, PR #31). Cobre override de ProjectRoot, derivacao de TestDb, precedencia de `testDb` explicito, resolucao de `schemaPath` (relativo/absoluto/default/dev-repo) e JSON invalido sem excecao.
- **Oraculo RPO (#33)**: em vez de so modelar o RPO com cache local, o build agora **pergunta ao proprio AppServer** o que esta compilado. `u_tecApoStat` (novo `src/tecRunrRpo.tlpp`) expoe `GetAPOInfo` via `/runner/exec`: para cada programa, se existe no RPO e com qual mtime de arquivo-fonte (`dataFonte`). `Invoke-TlppBuild.ps1` ganhou o guard 0: `dataFonte == mtime do disco (+-2s)` pula a compilacao por objeto - sem invalidar o environment inteiro quando o RPO muda por fora (compile via TDS/MCP), que era o ponto fraco do guard de stamp. REST indisponivel (janela de restart, AppServer off, framework antigo sem `u_tecApoStat`) cai **silenciosamente** nos guards locais de sempre - o oraculo e upgrade, nunca dependencia. Novos checks C12-C18 no `Test-BuildCache.ps1` (parse do dataFonte nos dois formatos documentados, tolerancia de frescor, fallback rapido com REST fora), todos sem AppServer, no CI.
- Origem da #33: investigacao do `syntaxOnly` (refutado - advpls 2.1.2 ignora o flag e compila; 2.2.0 vira no-op falso-verde com AppServer 7.00.240223P). Bonus medido: **compile que falha tambem reinicia o HTTPREST** (~30s) - nao existe "validar de graca" compilando com erro.

### Corrigido
- **`u_tecAssertEmpty`/`NotEmpty` agora enxergam JsonObject vazio.** `tstIsEmpty` tratava qualquer JsonObject como nao-vazio (alem de casar o tipo errado: `ValType` retorna `"J"`, e o case checava `"O"`). Agora usa `GetNames()` - `{}` e vazio, `{"k":1}` nao e. Coberto por assert novo na suite TLPP (44 testes).

## [0.2.5] - 2026-07-28

Validacao do `/tlpp-tdd-setup` (#19). Mesmo padrao da #17: rodar o fluxo revelou
defeitos que nenhuma suite pegava.

### Corrigido
- **`Set-AppServerRest.ps1` corrompia comentarios acentuados do `appserver.ini`** - mesmo defeito de encoding do `Set-DBAccessAlias.ps1` (#17): lia com `-Encoding ASCII` e regravava, trocando byte >0x7F por `?`. O `appserver.ini` de referencia tem 16 desses bytes em 4 comentarios. Dano menor que o do dbaccess.ini (sao comentarios, nao credenciais), mas ainda e corrupcao silenciosa do arquivo do usuario.
- **Deteccao de ambiente falhava no caso comum.** `Test-Environment.ps1` so achava AppServer/DBAccess se conseguisse ler `Process.Path` - impossivel quando o processo roda elevado ou como servico, que e a situacao normal. O fallback oferecido era "rode esta skill como Admin", travando quem nao pode elevar. Agora tenta, em ordem: layout conhecido sob `ProtheusRoot` (deterministico) e depois `Win32_Service.PathName` (nao exige elevacao). Nesta maquina saiu de `Found=False` + 2 issues para deteccao completa com 0 issues.
- **A deteccao por servico confundia o License Server com o AppServer REST.** O `TOTVSLicenseVirtual` tambem roda um `appserver.exe` e, sendo servico, aparecia primeiro - apontando um `appserver.ini` sem `[HTTPREST]` (porta vinha vazia). Agora o layout do ProtheusRoot tem prioridade e a busca por servico exclui explicitamente o License Server.
- **Falso-verde nos proprios testes**: `Test-BuildCache`/`Test-DBAccessAlias` tinham `try/finally` sem `catch`. Uma excecao terminante do script sob teste pulava todos os asserts e o resumo saia "tudo OK" com `$fail=0`. Encontrado quando um bug real (abaixo) fez o `Set-AppServerRest` lancar e o teste reportou sucesso mesmo assim.
- **`Write-IniLines` rejeitava linha em branco.** O binder de `[string[]]` recusa elemento vazio por padrao, e `.ini` tem linhas em branco entre secoes. Faltavam `[AllowEmptyString()]`/`[AllowEmptyCollection()]`.

### Adicionado
- **`runner/install/IniIO.ps1`** - `Read-IniLines`/`Write-IniLines` com Latin1 (28591), que mapeia 1:1 byte<->char e preserva o arquivo qualquer que seja o encoding real. Extraido porque o mesmo defeito ja tinha aparecido em **dois** scripts independentes; `Set-DBAccessAlias.ps1` e `Set-AppServerRest.ps1` agora compartilham a implementacao.
- `scripts/test/Test-AppServerRest.ps1` (6 checks, sem AppServer, no CI): encoding preservado, comentario acentuado intacto, `[HTTPREST]` adicionada, idempotencia, `-DryRun` inerte e backup.

## [0.2.4] - 2026-07-28

Validacao end-to-end do `/tlpp-tdd-project-init` contra banco real (#17). O fluxo
**nunca tinha sido executado inteiro** - os tres defeitos abaixo estavam em todas
as versoes anteriores. Um deles causava perda de dados.

### Corrigido
- **[PERDA DE DADOS] `Set-DBAccessAlias.ps1` destruia as senhas cifradas do `dbaccess.ini`.** Lia com `Get-Content -Encoding ASCII` e regravava com `ASCIIEncoding`: todo byte >0x7F virava `?`. As chaves `password=` guardam senha cifrada pelo `dbaccesscfg` e tem exatamente esses bytes - o ini real desta maquina tinha 18 deles em 2 secoes. Rodar o script derrubaria a autenticacao de **todos** os aliases ja existentes (`Falha de logon do usuario ''`), quebrando o ambiente de teste inteiro. Agora usa Latin1 (28591), que mapeia 1:1 byte<->char. Era o mesmo desastre ja documentado em `docs/SESSION-NOTES.md`, cometido pelo proprio script que deveria evita-lo.
- **`Set-DBAccessAlias.ps1` gerava alias que nao autentica.** Com `ConnectionMode=2` o DBAccess **ignora** as chaves `user=`/`password=` da secao - quem autentica e o `UID=`/`PWD=` dentro da `ConnectionString`, que o script nao escrevia. Agora herda as credenciais de um alias `[MSSQL/*]` que ja funciona no mesmo ini (o padrao que a maquina provou valido), com `-ConnectionUser`/`-ConnectionPassword` para sobrescrever e aviso explicito quando nao ha o que herdar.
- **`-ProjectRoot` nunca funcionou em `Invoke-TlppRunner.ps1` nem em `Invoke-TlppBuild.ps1`.** `runner.config.ps1` e dot-sourced e le o `.tlpp-tdd.json` durante o load, a partir do cwd/`CLAUDE_PROJECT_DIR`; os scripts ajustavam `$cfg.ProjectRoot` **depois**, tarde demais. Resultado: `ProjectName`/`TestDb` vinham do diretorio errado e o teste rodava contra `PROTHEUS_TST` em vez do banco do projeto - **em silencio, com resultado verde**. Era exatamente a isolacao per-project que o `/tlpp-tdd-project-init` existe pra entregar. Agora o override vai via `$TlppProjectRootOverride` antes do dot-source.

### Adicionado
- `scripts/test/Test-DBAccessAlias.ps1` (8 checks, sem DBAccess/SQL, no CI): preservacao byte a byte do encoding, senha cifrada intacta, heranca de credencial, prioridade dos parametros explicitos, aviso quando nao ha o que herdar, idempotencia e backup.

### Notas de campo (#17)
- O grant de `db_owner` para `sa` falha com `Msg 15405` ("nao e possivel usar a entidade de seguranca 'sa'") porque `sa` ja e dono do banco recem-criado. E inofensivo, mas o `New-TestDatabase.ps1` reporta como falha - ruido a limpar.
- O DBAccess **nao rele o ini sozinho**: sem restart, `TCLink` no alias novo retorna `-35`. Confirmado em execucao real.

## [0.2.3] - 2026-07-28

Correcoes de defeitos encontrados em revisao adversarial do 0.2.2 **antes do release**.
Tres deles quebravam a promessa central da versao anterior.

### Corrigido
- **O retry assimetrico do 0.2.2 nunca funcionou - era PIOR que o codigo que substituiu.** Duas causas somadas:
  1. `Test-PortOpen` usava `BeginConnect` + `AsyncWaitHandle`, que **nao sinaliza** neste ambiente: retornava `$false` para porta aberta E fechada. Trocado por `Connect()` sincrono em IPv4 explicito (`localhost` paga ~2s tentando IPv6 antes do fallback; com `127.0.0.1` a resposta e de 1-70ms).
  2. Sondava a porta do **REST**, que fica fechada durante toda a janela de restart (`deleting server, HTTPREST` no console.log). Agora sonda a porta **TCP do AppServer** (`$cfg.Port`), que permanece aceitando - medido: REST fora por 36,6s enquanto a 1268 aceitou o tempo todo.

  O efeito combinado travava o budget em 12s (contra 18s do codigo original) e reportava `AppServer parece desligado` com o servidor vivo. A flag `sawPortOpen` tambem deixou de ser sticky: se o AppServer morrer durante a espera, o budget encolhe.
- **O guard de `rpoStamp` re-abencoava entradas velhas.** `Update-BuildCache` gravava o stamp novo preservando os programas ja cadastrados: bastava um build apos alteracao externa do RPO para as outras entradas voltarem a dar HIT apontando para um RPO que nao era mais aquele. Agora `Invoke-TlppBuild` chama `Clear-BuildCacheEnvironment` ao detectar alteracao externa, descartando o environment inteiro. Coberto por C9/C10.
- **`runner/db-setup.ps1` criava as `Z_TST_*` no banco default do login (tipicamente `master`).** Regressao introduzida no 0.2.1 ao remover o `USE PROTHEUS_TST` do `02-create-schema.sql`: cada `sqlcmd -i` e conexao nova, e o script nao passava `-d`. Afetava `/tlpp-table` e o setup de maquina nova. `99-reset.sql` teve o `USE` removido pelo mesmo motivo (agora recebe `-d`).
- **Mutex do cache: `WaitOne` com timeout tinha o retorno ignorado** e a escrita prosseguia sem lock - o lost-update que o mutex existia para impedir. Agora aborta a gravacao (recompilar depois e seguro; cache corrompido nao). Coberto por C11.
- **Build simultaneo de dois projetos colidia em `$env:TEMP\tlpp-tdd\last-build.{ini,log}`**: um sobrescrevia o INI do outro (compilando a lista de fontes errada) e o `Remove-Item` do log estourava com "file in use", abortando o build sob `ErrorActionPreference='Stop'`. Arquivos agora sao `build-<pid>.{ini,log}`, com limpeza de restos com mais de 1 dia.
- **Dois fontes de mesmo basename no MESMO build** (`-All` com `src/X.tlpp` e `test/X.tlpp`) faziam o cache alternar o dono do slot a cada execucao - recompilando um dos dois para sempre e alternando o conteudo do RPO. Agora ambos sao compilados e um aviso aponta a colisao.
- **`sync.ps1` reportava sucesso com orfao presente**: contava orfaos em `$changed` e no modo normal imprimia "N arquivo(s) atualizados" saindo 0 sem fazer nada, enquanto o `validate` continuava falhando - laco sem saida. Orfaos agora sao contados a parte e forcam exit 1.
- **`Get-RpoStamp` ignorava o environment.** Uma maquina pode ter mais de um RPO (ex. `apo\` para DESENVOLVIMENTO e `apo_denk\` para DENK) e o fallback so achava o `apo\` padrao - carimbando o RPO errado, o que desliga o guard de alteracao externa sem avisar. Nova chave opcional `RpoCustom` no config global (escrita por `Write-GlobalConfig.ps1`); quando configurada e invalida, o guard e desligado em vez de mentir com outro RPO.
- `docs/LLM-WORKFLOW.md` ensinava a LLM a **desistir exatamente quando deveria esperar** (dizia que `porta fechada` significava AppServer parado). Corrigido.

### Adicionado
- `Test-BuildCache.ps1` vai de 14 para 22 checks: C9 (stamp externo nao re-abencoa), C10 (limpeza de um environment nao afeta outro) e C11 (lock de outro processo impede gravacao). C11 usa um job separado de proposito - Mutex e reentrante na mesma thread, entao segurar o lock no proprio teste nao exercitaria nada.

## [0.2.2] - 2026-07-28

### Corrigido
- **Toda compilacao reinicia o HTTPREST por 68-93s** - nao so as de fonte com `@Get/@Post`, como estava documentado. Fontes sem nenhuma annotation derrubam igual: o gatilho e a escrita no RPO. `recompile=F` tambem nao evita (o advpls compila do mesmo jeito). O retry do `Invoke-TlppRunner.ps1` era `6 x 3s = 18s`, **menor que a janela real** - desistia antes de o servidor voltar e reportava `connection refused` como falha definitiva. (#29)
- **`validate.ps1` tinha lista fixa de scripts**: o `BuildCache.ps1` novo nao entrava, e `db-setup.ps1` / `runner.config.local.ps1` ja existiam sem nunca passar por parse check. Virou glob sobre `runner/`, `scripts/` e `hooks/` - mesmo falso-verde que o `sync.ps1` tinha.

### Adicionado
- **Cache de build** (`runner/BuildCache.ps1`): pula fontes ja no RPO com o mesmo conteudo. No caso comum (hook ja compilou ao salvar, `/tlpp-test` manda compilar de novo) o efeito medido foi **9000ms -> 134ms, sem derrubar o HTTPREST**. Escape hatch: `Invoke-TlppBuild.ps1 -Force`.
  - A chave e o **nome do programa**, nao o caminho do fonte. O RPO e compartilhado: dois projetos podem ter cada um o seu `MT410ROT.tlpp` (ponto de entrada) ocupando o **mesmo slot** - o ultimo a compilar vence. Um cache por caminho mentiria. Indexando por programa, o cache detecta a troca de dono, recompila e **avisa** - tornando visivel uma colisao ate entao silenciosa.
  - Invalidacao em camadas: `rpoStamp` (mtime+tamanho do `custom.rpo`, pega compile feito pelo TDS por fora) -> hash SHA256 do conteudo -> dono do slot. Escrita serializada por Mutex nomeado (projetos simultaneos), troca atomica via `.tmp`, JSON corrompido tratado como cache vazio.
- **Retry assimetrico** no `Invoke-TlppRunner.ps1`: porta aceita conexao (servidor reiniciando) espera ate 120s; porta recusa desde a 1a tentativa (AppServer desligado) desiste em 12s. A mensagem diz qual dos dois foi.
- `scripts/test/Test-BuildCache.ps1`: 14 checks de logica pura (sem AppServer), rodando no CI. Cobre a colisao entre projetos.

### Investigado e descartado
- **REST via `VdrCtrl`** (TDN 553334696, subir servico REST em runtime via JSON em vez de `appserver.ini`). A classe existe e instancia no 12.1.2510, mas nenhum beneficio sobreviveu a medicao: nao reduz edicao de ini (exige `[OnStart]`+`[JOBx]` contra a unica `[HTTPREST]` de hoje, mais ~150 linhas de config JSON case-sensitive), e `LoadURNs` nao evita o restart porque o restart nao vem das annotations. (#26)

## [0.2.1] - 2026-07-28

### Corrigido
- **`Invoke-TlppRunner.ps1` so propagava `dbAccessHost`/`dbAccessPort`/`testDbAlias` quando `ProjectName` estava setado** via `.tlpp-tdd.json`. Host e porta do DBAccess sao config de **maquina**, nao de projeto: sem o arquivo, o body ia sem porta e o servidor caia no default `7890` de `tecRunrCtx.tlpp`, quebrando `u_tecTstConn` com `TOPCONN - No connection: -2 - NO_CONNECTION`. Atingia qualquer projeto que instalasse o plugin sem rodar `/tlpp-tdd-project-init`. Suite de integracao: 8/11 -> 11/11. (#17, #28)
- **`sync.ps1` tinha lista fixa de 6 pares** raiz->espelho: skill/command novo na raiz ficava invisivel para o sync **e para o drift check** do `validate.ps1` - CI verde sobre buraco. Virou glob (`skills/*/SKILL.md` + `commands/*.md`) com `$excluded` explicito, mais deteccao de orfao (espelho sem canonico).
- `-SchemaSqlPath` -> `-SchemaScript` na skill `tlpp-tdd-project-init`: o nome nao batia com a assinatura real de `New-TestDatabase.ps1`.
- `USE PROTHEUS_TST` removido de `runner/sql/02-create-schema.sql` - o banco-destino vem do `-d` do sqlcmd, senao todo projeto caia no mesmo banco.

### Adicionado
- `src/tecSmkProjInit.tlpp`: smoke end-to-end do `/tlpp-tdd-project-init` (TCLink -> valida schema -> INSERT -> SELECT -> cleanup).
- `DbAccessIniPath` no config global, escrito por `Write-GlobalConfig.ps1`.

## [0.2.0] - 2026-05-20

### Mudado (BREAKING - redesign global)
- **Arquitetura repensada**: framework compilado **uma vez no RPO compartilhado** do AppServer dev em vez de copiado em cada projeto. Projetos consumidores agora so precisam de (opcional) `.tlpp-tdd.json` na raiz pra integracao com banco - nenhum diretorio framework duplicado.
- **Config global**: `~/.claude/tlpp-tdd/config.ps1` carrega credenciais, paths Protheus, advpls, AppServer endpoint. `runner.config.ps1` virou loader em cascata (defaults -> global -> projeto -> legacy local).
- **Per-project**: `.tlpp-tdd.json` na raiz do projeto com `{"name": "MEUPROJ"}` deriva o banco de teste `PROTHEUS_TST_MEUPROJ` e e propagado pra `/runner/exec` via `projectName`/`testDbAlias`.
- **Runner scripts** (`Invoke-TlppBuild.ps1`, `Invoke-TlppRunner.ps1`): vivem no plugin, compilam fontes do PROJETO ATUAL (cwd ou `$env:CLAUDE_PROJECT_DIR`), nao mais do plugin root.
- **Slash commands** (`/tlpp-build`, `/tlpp-test`, `/tlpp-exec`): resolvem `$runner` via cascade `$env:CLAUDE_PLUGIN_ROOT/runner` -> `.\runner` fallback. Funciona em qualquer projeto.
- **Hook PostToolUse** (`hooks/build-on-save.ps1`): cascade `$env:CLAUDE_PLUGIN_ROOT` -> `$env:CLAUDE_PROJECT_DIR` -> script's parent. No-op silencioso se nada achado.
- **API `/runner/exec`**: aceita `projectName`, `testDbAlias`, `dbAccessHost`, `dbAccessPort` no body; populados pelo runner PS1; consumidos por helpers via `tecRunrCtx.tlpp` (`u_tecCtxProject`, `u_tecCtxTestDbAlias`, etc).
- **`u_tecTstConn`**: nao tem mais alias hardcoded - usa `u_tecCtxTestDbAlias()`/`u_tecCtxDbAccessHost/Port()` com defaults razoaveis pra back-compat.

### Adicionado
- `src/tecRunrCtx.tlpp`: helpers de contexto per-request thread-aware (clear no inicio de cada handler, set/get key-value, accessors de conveniencia).
- `hooks/build-on-save.ps1`: hook PostToolUse extraido como script (em vez de inline JSON).
- Cascade de config em 4 niveis no `runner.config.ps1` (defaults > global > projeto > legacy local).

### Migracao desde o modelo per-project
- Projetos que tinham `runner/`, `src/`, `mocks/`, `test/` copiados podem deletar tudo exceto `test/` (seus testes proprios). Compilacao agora referencia framework do RPO compartilhado.
- `runner/runner.config.local.ps1` legado continua funcionando (carregado em cascade), mas mova as credenciais pra `~/.claude/tlpp-tdd/config.ps1` quando puder.
- Pra integracao com banco, crie `.tlpp-tdd.json` na raiz com `{"name": "..."}`.

### Adicionado (skills + scripts do redesign)
- **Skill `tlpp-tdd-setup`** (setup + doctor): faz checklist de 9 itens (config, paths, AppServer, REST, framework no RPO, DBAccess, SQL), classifica OK/FALTA/BROKEN, faz fix targeted ou setup completo conforme estado. Idempotente - re-rodar so executa o que falta. Oferece AppServer dedicado (recomendado, ~80MB copia, zero impacto no env principal) vs reusar o existente.
- **Skill `tlpp-tdd-project-init`** (per-project): cria `PROTHEUS_TST_<NOME>` + alias DBAccess + `.tlpp-tdd.json` na raiz do projeto. Zero arquivos do framework copiados.
- **Slash commands**: `/tlpp-tdd-setup` (com doctor mode) e `/tlpp-tdd-project-init`.
- **`runner/install/Write-GlobalConfig.ps1`** (novo): grava `~/.claude/tlpp-tdd/config.ps1` com merge preservando chaves existentes; mascara senhas.
- **`runner/install/Write-ProjectConfig.ps1`** (novo): grava `<projeto>/.tlpp-tdd.json` com validacao de nome.
- **`runner/install/Install-Framework-Global.ps1`** (novo): compila framework do plugin source no RPO via `Invoke-TlppBuild.ps1 -All`.

### Removido (sem usuarios legados a preservar)
- **Skill `skills/tlpp-tdd-init/`** + **comando `commands/tlpp-tdd-init.md`**: substituidos por `/tlpp-tdd-setup` (machine) + `/tlpp-tdd-project-init` (per-project).
- **`runner/install/Install-FrameworkFiles.ps1`**: substituido por `Install-Framework-Global.ps1`.
- **`runner/install/Write-LocalConfig.ps1`**: substituido por `Write-GlobalConfig.ps1` + `Write-ProjectConfig.ps1`.

### Corrigido (smoke test descobriu)
- `src/tecRunrCtx.tlpp` tinha `namespace tec.runner.ctx` que suprime registro de `u_<nome>` global - funcoes `u_tecCtx*` nao apareciam em `tlpp.ffunc("u_tecCtxProject")`. Namespace removido (ficou so com comentario explicando porque NAO ter namespace). Tests externos via `/runner/exec` agora encontram a funcao.
- Convencao documentada em `CLAUDE.md > Estilo TLPP`: modulos chamados externamente via `/runner/exec` NAO devem ter `namespace` (registro vira `<ns>.u_<nome>` em vez de `u_<nome>` global). Modulos com so REST routes (`@Get/@Post`) podem ter namespace.

### Smoke test end-to-end (validado em `C:\temp\tlpp-smoke`)
- Cascade config (defaults > global > .tlpp-tdd.json > legacy local) carrega correto em pasta arbitraria.
- `ProjectRoot` resolve cwd, `Invoke-TlppBuild.ps1 -All` compila fontes do projeto consumidor (nao do plugin root).
- `Invoke-TlppRunner.ps1` envia `projectName/testDbAlias/dbAccessHost/Port` no body, `tecRunrExec` propaga via `u_tecCtxSet`, accessors (`u_tecCtxProject`, `u_tecCtxTestDbAlias`, etc) retornam valores corretos.
- Doctor mode detectou cenarios reais: AppServer off (HTTP 0), debugger lock no RPO bloqueando build apesar de `BuildKillUsers=1`.

### Qualidade, testes e CI
- **Skill `tlpp-tdd`**: nova secao "Test file template (load-bearing)" separando o header de arquivo (`#include tlpp-core.th` + `tlpp-probat.th` + `using namespace`, uma vez no topo) do bloco por caso, com o erro de compile citado. Evita `@TestFixture not defined` no primeiro pass de um teste gerado. (#22)
- **`scripts/test/Test-BuildOnSaveHook.ps1`** (novo): teste de regressao do hook PostToolUse `build-on-save` - valida disparo em `.tlpp`, no-trigger em `.md`, no-op silencioso sem framework acessivel e escrita de `last-build.log`, simulando as env vars do harness contra um projeto externo. Modo `-SkipBuild` p/ CI headless. (#18)
- **`scripts/plugin/install-git-hooks.ps1`** (novo): instala um git pre-commit que roda `validate.ps1` e bloqueia o commit se falhar. Idempotente, suporta worktree, escape hatch `git commit --no-verify`. (#23)
- **`.github/workflows/validate.yml`** (novo): CI em push/PR pra `main` (windows-latest) roda `validate.ps1` (parse + JSON + frontmatter + drift) e o teste de logica do hook. (#23)

### Pendente
- `/tlpp-table` ainda assume `runner/sql/02-create-schema.sql` no projeto. Pode precisar de redesign pra path configurabel via `.tlpp-tdd.json`.
- Modo dedicado da skill `tlpp-tdd-setup` orienta o copy do dir AppServer manualmente. Automacao via `Copy-AppServerDev.ps1` (novo script) ficou pra release seguinte - varia muito por layout de instalacao Protheus.
- Smoke test instalou `.tlpp-tdd.json` so como name. Testar com integracao real (TCLink → PROTHEUS_TST_SMOKE) requer criar o banco + alias (passo do `/tlpp-tdd-project-init`) - ainda nao validado end-to-end.

### Anterior nesta release (Unreleased)
- **Layout do plugin**: promovido para a raiz do repo (`.claude-plugin/`, `skills/`, `commands/`, `hooks/`). Antes ficava em `.plugin/`, exigia `git subtree split` ou `/plugin install file://`.
- **Manifest**: adicionados `repository`, `homepage`, `categories`. Descricao reduzida a uma linha (prosa longa migrou pro README).
- **Scripts dev-only** movidos pra `scripts/plugin/`: `sync.ps1`, `validate.ps1`, `find-errors.ps1`. Nao shipam mais no install do plugin.

### Adicionado anteriormente
- `LICENSE` (MIT) e `CHANGELOG.md` na raiz.
- `PLUGIN.md` (ex-`.plugin/README.md`) com guia de install do plugin.

## [0.1.0] - 2026-04-XX (interno)

Primeira versao funcional com framework TDD completo:
- Endpoint REST `/runner/{ping,func,exec}` no AppServer dev
- Wrappers de DB/SQL/HTTP/GetMv/Date em `src/tecWrap.tlpp`
- Asserts customizados + HTTP em `src/tecAssert.tlpp`
- Mocks em `mocks/tecMock.tlpp`
- Helpers de DB para testes de integracao (`u_tecTstConn`/`CreateTable`/`Seed`)
- Skill `tlpp-tdd` (loop autonomo red->green->refactor)
- Skill `tlpp-tdd-init` (scaffold em projeto existente)
- Slash commands `/tlpp-build`, `/tlpp-test`, `/tlpp-exec`, `/tlpp-table`, `/tlpp-tdd`, `/tlpp-tdd-init`
- Hook PostToolUse recompila fontes `.tlpp/.prw` ao salvar
