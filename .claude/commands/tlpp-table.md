---
description: 'Adiciona tabela permanente ao schema SQL versionado do projeto (default sql/schema.sql, configuravel via schemaPath no .tlpp-tdd.json) e aplica no banco de teste via db-setup.ps1 do plugin. Para tabelas reutilizadas em varios testes (alternativa: u_tecTstCreateTable para tabela ad-hoc dentro de 1 teste).'
allowed-tools:
  - "Read(*)"
  - "Edit(*)"
  - "Write(*)"
  - "Bash(*db-setup*)"
  - "Bash(powershell*)"
  - "Bash(pwsh*)"
---

# Adicionar tabela permanente ao schema de teste

Argumentos: $ARGUMENTS

## Formato

```
/tlpp-table create <NOME> "<COL_DEFS>"
```

- `<NOME>`: prefixo `Z_TST_` recomendado (ex `Z_TST_FATURA`)
- `<COL_DEFS>`: definicoes separadas por `;`, cada uma `NOME TIPO [MODIFICADORES]`

Exemplo:
```
/tlpp-table create Z_TST_FATURA "NUM CHAR(6) NOT NULL; VALOR NUMERIC(14,2); EMISSAO CHAR(8) NULL"
```

## Passos

### 1. Resolver caminhos (plugin vs projeto)

O runner vive no PLUGIN; o schema vive no PROJETO:

```powershell
$runner = if ($env:CLAUDE_PLUGIN_ROOT) { Join-Path $env:CLAUDE_PLUGIN_ROOT 'runner' } else { '.\runner' }
$psh = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }   # doc promete PS 5.1+
& $psh -NoProfile -Command ". '$runner\runner.config.ps1'; `$TlppRunner.SchemaPath; `$TlppRunner.TestDb"
```

- `SchemaPath` = schema SQL versionado do projeto. Default `<projeto>\sql\schema.sql`;
  no repo dev do tlpp-runner resolve pro `runner\sql\02-create-schema.sql`;
  configuravel com `"schemaPath"` no `.tlpp-tdd.json`.
- `TestDb` = banco de teste alvo (`PROTHEUS_TST` ou `PROTHEUS_TST_<NOME>`).

### 2. Parsear argumentos

- Extrair `<NOME>` e a lista de colunas (split por `;`)
- Validar: nome comeca com `Z_TST_`. Se nao, avisar e seguir mesmo assim (decisao do user).

### 3. Garantir que o arquivo de schema existe

Se `SchemaPath` nao existe ainda (primeiro uso num projeto consumidor), criar o
diretorio e o arquivo com este cabecalho:

```sql
-- =====================================================================
-- Schema de teste do projeto - gerenciado por /tlpp-table (tlpp-tdd)
-- Aplicado no banco de teste ($TlppRunner.TestDb) pelo db-setup.ps1.
-- Idempotente: cada tabela protegida por IF OBJECT_ID(...) IS NULL.
-- =====================================================================
```

### 4. Append idempotente no schema

Adicionar ao final do arquivo:

```sql
-- ---------------------------------------------------------------------
-- <NOME> - adicionada via /tlpp-table em <data atual>
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.<NOME>', 'U') IS NULL
BEGIN
    PRINT 'Criando <NOME>...';
    CREATE TABLE dbo.<NOME> (
        R_E_C_N_O_  INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        <COL1_DEF>,
        <COL2_DEF>,
        ...
        D_E_L_E_T_  CHAR(1)     NOT NULL DEFAULT ''
    );
END
ELSE
    PRINT '<NOME> ja existe';
GO
```

- Adicionar `R_E_C_N_O_` IDENTITY PRIMARY KEY e `D_E_L_E_T_` automaticamente. Nao incluir nas colunas do usuario.
- Se a tabela ja existir no arquivo (procurar por `IF OBJECT_ID('dbo.<NOME>'`), recusar com erro claro: "tabela ja registrada no schema".

### 5. Aplicar no banco

```powershell
& "$runner\db-setup.ps1"
```

O db-setup aplica o schema do framework E o `SchemaPath` do projeto no `TestDb`
do cascade. Verificar saida procurando por `Criando <NOME>...`.

- Se falhar com banco inexistente (`PROTHEUS_TST_<NOME>`), orientar: rodar `/tlpp-tdd-project-init` primeiro.
- Se falhar com config global ausente (SqlInstance vazio/invalido), orientar: rodar `/tlpp-tdd-setup`.

### 6. Confirmar

Mostrar:
- Tabela adicionada com sucesso (arquivo + banco)
- Lista de colunas finais (incluindo R_E_C_N_O_/D_E_L_E_T_)
- Sugestao de uso:

```tlpp
u_tecTstSeed("<NOME>", { ;
    {"<COL1>", "valor"}, ;
    ... ;
})
```

## Quando usar `u_tecTstCreateTable` em vez de `/tlpp-table`

- **`/tlpp-table`**: tabela usada em varios testes, faz parte do schema do projeto (versionada no repo), sobrevive entre runs
- **`u_tecTstCreateTable`**: tabela one-off dentro de 1 teste, dropa no fim do teste (`u_tecTstDropTable`)

## Erros comuns

- **Sintaxe SQL invalida**: revisar `<COL_DEFS>` - tipos validos MSSQL (CHAR, VARCHAR, INT, NUMERIC(p,s), DATE, etc)
- **`db-setup.ps1` falha**: verificar permissao do usuario MSSQL configurado em `~/.claude/tlpp-tdd/config.ps1` (chaves `SqlInstance`, `SqlAuth`, `SqlUser`, `SqlPassword`)
- **Banco do projeto nao existe**: `/tlpp-tdd-project-init` cria `PROTHEUS_TST_<NOME>` + alias DBAccess
- **Tabela ja existe no arquivo**: edite o schema (`SchemaPath`) manualmente, ou drop primeiro
