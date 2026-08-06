# Setup do banco de teste (PROTHEUS_TST)

Guia para configurar o ambiente de **testes de integração** que toca banco real.

> **Caminho recomendado**: rode `/tlpp-tdd-setup` (machine-once) + `/tlpp-tdd-project-init` (per-project). Ambas skills do plugin detectam o ambiente, perguntam o que falta, e configuram com backup automático. Este documento é a referência manual / troubleshooting.

> **Placeholders neste guia**:
> - `<SQL_INSTANCE>` — sua instância SQL Server (ex: `localhost`, `localhost\PROTHEUS`)
> - `<PROTHEUS_ROOT>` — raiz da sua instalação Protheus (ex: `C:\TOTVS\Protheus_241011`)
> - `<DBACCESS_PORT>` — porta do DBAccess (default 7890; init detecta a real)
> - `<TEST_DB>` — nome do banco de teste (default `PROTHEUS_TST`; init usa `PROTHEUS_TST_<nome_projeto>`)

## Arquitetura

```
AppServer REST (1 processo unico, env DESENVOLVIMENTO)
   ├── porta 8401 /rest      → endpoint /runner/* roda no env DESENVOLVIMENTO
   └── conecta no ProtheusTeste via DBAccess (porta <DBACCESS_PORT>)

Banco PROTHEUS_TST (isolado, no MESMO MSSQL)
   ├── tabelas Z_TST_*       → criadas via SQL DDL
   └── acessado via TCLink dinamico nos testes de integracao
```

> **Não há env TST separado no AppServer.** Os testes de integração abrem uma conexão DBAccess **dinâmica** no PROTHEUS_TST usando `TCLink("PROTHEUS_TST", "localhost", <DBACCESS_PORT>)` dentro do próprio teste, e fecham com `TCUnlink` no final. Isso evita ter que mexer no `appserver.ini` do dev e elimina o problema de autenticação Protheus no banco de teste (que não tem tabela de usuários).

## Pre-requisitos

- MSSQL 2019+ rodando (instância default: `<SQL_INSTANCE>`)
- Autenticação Windows habilitada (o `db-setup.ps1` usa `-E`)
- `sqlcmd` no PATH
- DBAccess rodando (porta <DBACCESS_PORT>, configurado no `dbaccess.ini`)
- AppServer REST do dev rodando (porta 8401)

## Setup passo-a-passo

### 1. Criar database e schema

```powershell
.\runner\db-setup.ps1
```

Saída esperada:
```
[db-setup] OK - PROTHEUS_TST configurado
```

Resultado:
- Database `PROTHEUS_TST` com collation `Latin1_General_100_BIN` (mesma do Protheus)
- Tabelas `Z_TST_CLIENTE` e `Z_TST_PEDIDO` com campos no padrão Protheus

### 2. Conceder permissão no PROTHEUS_TST aos logins do DBAccess

O DBAccess se conecta como `sa` (vê `dbaccess.ini`). O Protheus também usa `sysdba` em algumas operações. Ambos precisam ser db_owner no PROTHEUS_TST:

```powershell
# Configure a senha do sa em variavel (NAO commitar)
$saPwd = '<sua_senha_sa>'

# Como sa
& sqlcmd -S "<SQL_INSTANCE>" -U sa -P $saPwd -d PROTHEUS_TST -Q `
  "CREATE USER sa FOR LOGIN sa; ALTER ROLE db_owner ADD MEMBER sa;"

# Como Windows auth (cria sysdba)
& sqlcmd -S "<SQL_INSTANCE>" -E -d PROTHEUS_TST -Q `
  "CREATE USER sysdba FOR LOGIN sysdba; EXEC sp_addrolemember 'db_owner', 'sysdba';"
```

### 3. Adicionar alias `PROTHEUS_TST` no DBAccess

Sem alias configurado, `TCLink` retorna `-35` ("Invalid environment received").

```powershell
# Cria a entrada [MSSQL/PROTHEUS_TST] no dbaccess.ini
# Ajuste o $dbaRoot pro caminho da sua instalacao do TOTVSDBAccess
$dbaRoot = '<PROTHEUS_ROOT>\TOTVSDBAccess\windows'
$dbacfg  = Join-Path $dbaRoot 'tools\dbaccesscfg.exe'
$saPwd   = '<sua_senha_sa>'

Push-Location $dbaRoot
try {
    & $dbacfg -u "sa" -p $saPwd -d "MSSQL" -a "PROTHEUS_TST"
} finally { Pop-Location }
```

**IMPORTANTE**: o `dbaccesscfg` no Windows gera `ConnectionString` em formato Linux (`DRIVER!...@SERVERNAME!...`). Para Windows precisa converter para `DRIVER={...};SERVER=...;DATABASE=...`. Edite `dbaccess.ini` na seção `[MSSQL/PROTHEUS_TST]`:

```ini
[MSSQL/PROTHEUS_TST]
user=sa
password=<encriptada pelo dbaccesscfg>
ConnectionMode=2
ConnectionString=DRIVER={SQL Server Native Client 11.0};SERVER=<SQL_INSTANCE>;DATABASE=PROTHEUS_TST
```

**Reinicie o DBAccess** após mudar o ini (`dbaccess64.exe` precisa fechar e abrir). Se o `appserver_rest` está conectado, reinicie-o também.

### 3. Rodar suite de integração

```powershell
.\runner\Invoke-TlppRunner.ps1 -Function "tlpp.probat.run" -ArgString '"type:suite","integracao"' -Junit
```

> **Importante**: tudo no env DESENVOLVIMENTO. O teste abre a conexão dedicada ao PROTHEUS_TST via `TCLink` no setup.

## Padrão de teste de integração

> **Atenção sintaxe `TCLink`**: formato oficial TOTVS é `<tipo_driver>/<alias>`, não só o alias.
> ✓ `TCLink("MSSQL/PROTHEUS_TST", "localhost", <DBACCESS_PORT>)`
> ✗ `TCLink("PROTHEUS_TST", "localhost", <DBACCESS_PORT>)` → retorna -35

```tlpp
@TestFixture()
user function test_meu_caso()
    local nLink, nLinkAnt
    local cTab := "Z_TST_MEU_CASO"

    u_tecAssertReset()
    nLink := u_tecTstConn(@nLinkAnt)        // TCLink no MSSQL/<TestDb do cascade>
    if nLink <= 0
        u_tecAssertTrue("conectou", .F.)
        return u_tecAssertsOk()
    endif

    u_tecTstDropTable(cTab)                 // idempotente
    u_tecTstCreateTable(cTab, { {"COD", "CHAR(6)", "NOT NULL"} })
    u_tecTstSeed(cTab, {{"COD","000001"}})

    // assert direto no banco (sem mock)
    u_tecAssertEq("linha semeada", "000001", ;
        AllTrim(u_tecQryFirst("SELECT COD FROM " + cTab)["COD"]))

    u_tecTstDropTable(cTab)
    u_tecTstDisconn(nLink, nLinkAnt)        // cleanup obrigatorio
return u_tecAssertsOk()
```

Os helpers globais `u_tecTstConn`/`Disconn`, `u_tecTstCreateTable`/`DropTable`, `u_tecTstSeed`, `u_tecTstTruncate` estão em `test/integracao/tecTstDbHlp.tlpp` (compilados no RPO junto com o framework). Receita completa em [RECIPES.md](RECIPES.md); catálogo em [REFERENCE.md](REFERENCE.md).

## Reset de dados entre runs

```powershell
.\runner\db-setup.ps1 -Reset
```

Trunca todas as tabelas `Z_TST_*` sem dropar a estrutura.

## Adicionar novas tabelas

1. Preferido: `/tlpp-table create <NOME> "<cols>"` - adiciona no schema versionado do
   projeto (`schemaPath` do `.tlpp-tdd.json`, default `sql/schema.sql`; no repo dev do
   tlpp-runner e o `runner/sql/02-create-schema.sql`) e aplica via `db-setup.ps1` (#21).
2. Manual: edite o arquivo do `schemaPath` (DDL idempotente, `IF OBJECT_ID(...) IS NULL`)
   e rode `.\runner\db-setup.ps1` (aplica framework + schema do projeto no banco do cascade).
3. Crie teste em `test/integracao/<nome>Tst.tlpp` que faz CRUD via `TCSQLExec`/`TCQuery`.

## Rollback (desfazer setup)

```powershell
# Dropa database (Windows auth)
& sqlcmd -S "<SQL_INSTANCE>" -E -Q "DROP DATABASE PROTHEUS_TST"
```

> Não é necessário restaurar `appserver.ini` — esta abordagem não toca nele.

## Troubleshooting

| Sintoma | Causa | Solução |
|---|---|---|
| `TCLink retornou -1` | DBAccess não tem login com permissão no PROTHEUS_TST | `GRANT` ao usuário configurado no `dbaccess.ini` |
| `Database PROTHEUS_TST does not exist` | `db-setup.ps1` não foi rodado | Rodar `.\runner\db-setup.ps1` |
| `Tabela Z_TST_CLIENTE inexistente` | Schema não criado | Verificar saída de `02-create-schema.sql` |
| `Login failed for user 'sa'` | Senha sa errada / login desabilitado | Configurar Windows auth no DBAccess ou habilitar sa |
