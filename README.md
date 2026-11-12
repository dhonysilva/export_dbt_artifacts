# export_dbt_artifacts

Script para exportar os artefatos do dbt (`manifest.json`, `run_results.json`, `catalog.json`, logs etc.) gerados por uma task dbt de um Job no Databricks.

Por padrão, o script:

1. Busca a última execução bem-sucedida do Job (ou usa a `RUN_ID` informada).
2. Localiza a task dbt dentro da execução.
3. Baixa o pacote de artefatos e o extrai no diretório de destino.

## Requisitos

- [Databricks CLI](https://docs.databricks.com/aws/en/dev-tools/cli/) v0.200 ou superior
- `jq`
- `curl`
- `tar`

## 1. Instalação do Databricks CLI

### macOS (Homebrew)

```bash
brew tap databricks/tap
brew install databricks
```

### Linux e macOS (script de instalação)

```bash
curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh
```

> Em alguns ambientes é necessário `sudo` para gravar em `/usr/local/bin`.

### Windows (WinGet)

```powershell
winget search databricks
winget install Databricks.DatabricksCLI
```

### Verificando a instalação

```bash
databricks -v
```

A versão exibida deve ser `0.200` ou superior.

### Instalando as demais dependências

No macOS:

```bash
brew install jq
```

No Debian/Ubuntu:

```bash
sudo apt-get install jq curl
```

`curl` e `tar` já vêm instalados na maioria dos sistemas.

## 2. Autenticação com o Databricks

O script usa os perfis do Databricks CLI, armazenados em `~/.databrickscfg`. Nunca coloque tokens diretamente no script nem os envie para o repositório.

### Opção A: login via OAuth (recomendada)

1. Execute o login informando a URL do workspace e um nome para o perfil:

   ```bash
   databricks auth login --host https://<seu-workspace>.cloud.databricks.com --profile prod
   ```

2. O navegador será aberto. Faça login e autorize o acesso.
3. Confirme que o perfil foi criado:

   ```bash
   databricks auth profiles
   ```

### Opção B: Personal Access Token (PAT)

1. No workspace, acesse **Settings > Developer > Access tokens** e gere um novo token.
2. Execute:

   ```bash
   databricks configure --profile prod
   ```

3. Informe a URL do workspace e, quando solicitado, cole o token.

### Testando a autenticação

```bash
databricks current-user me -p prod
```

Se o comando retornar os dados do seu usuário, a autenticação está funcionando.

## 3. Como usar

```bash
./export_dbt_artifacts.sh <job_id> [task_key] [diretorio_destino]
```

| Argumento           | Obrigatório | Descrição                                                                                      |
| ------------------- | ----------- | ---------------------------------------------------------------------------------------------- |
| `job_id`            | Sim         | ID do Job no Databricks.                                                                       |
| `task_key`          | Não         | Nome da task dbt. Se vazio (`""`), usa a primeira task dbt encontrada na execução.             |
| `diretorio_destino` | Não         | Pasta onde os arquivos serão salvos. Padrão: `./dbt_artifacts`.                                |

### Variáveis de ambiente

| Variável             | Descrição                                                                                              |
| -------------------- | ------------------------------------------------------------------------------------------------------ |
| `DATABRICKS_PROFILE` | Perfil do Databricks CLI a ser usado. Padrão: `DEFAULT`.                                               |
| `RUN_ID`             | Exporta uma execução específica, em vez da última bem-sucedida.                                        |
| `ARQUIVO`            | Extrai apenas o arquivo informado (ex.: `manifest.json`). Se vazio, extrai todos os artefatos.         |
| `SEM_SUBPASTA`       | Com `1`, grava direto no diretório de destino, sem criar a subpasta `<data>_run<run_id>`.              |

### Exemplos

```bash
# Todos os artefatos da última execução bem-sucedida
./export_dbt_artifacts.sh 123456789

# Task específica e destino customizado
./export_dbt_artifacts.sh 123456789 dbt_run ./artefatos

# Execução específica
RUN_ID=987654321 ./export_dbt_artifacts.sh 123456789

# Apenas o manifest.json
ARQUIVO=manifest.json ./export_dbt_artifacts.sh 123456789
```

## 4. Exemplo: exportar o `manifest.json` de produção

Para baixar somente o `manifest.json` do Job de produção, usando o perfil `prod` e gravando direto na pasta `target-prd` do projeto dbt (sem subpasta de data/run):

```bash
SEM_SUBPASTA=1 ARQUIVO=manifest.json DATABRICKS_PROFILE=prod \
  ./export_dbt_artifacts.sh 45253452345234523465 "" /pasta-do-projeto-dbt/target-prd
```

O que cada parte faz:

| Parte                                  | Efeito                                                                                   |
| -------------------------------------- | ---------------------------------------------------------------------------------------- |
| `SEM_SUBPASTA=1`                       | Salva o arquivo diretamente em `/pasta-do-projeto-dbt/target-prd`.                       |
| `ARQUIVO=manifest.json`                | Extrai apenas o `manifest.json`, ignorando os demais artefatos.                          |
| `DATABRICKS_PROFILE=prod`              | Autentica com o perfil `prod` do `~/.databrickscfg`.                                     |
| `45253452345234523465`                 | ID do Job no Databricks.                                                                 |
| `""`                                   | `task_key` vazio: usa automaticamente a primeira task dbt da execução.                   |
| `/pasta-do-projeto-dbt/target-prd`     | Diretório de destino.                                                                    |

Substitua o ID do Job e o caminho do projeto pelos valores do seu ambiente. Ao final, o script lista os arquivos exportados:

```
>> Concluído. Arquivos exportados:
   /pasta-do-projeto-dbt/target-prd/manifest.json
```

Esse `manifest.json` pode ser usado como estado de referência do dbt, por exemplo com `dbt build --select state:modified+ --state /pasta-do-projeto-dbt/target-prd`.

E também `dbt build --select nome_do_model+ --defer --state /pasta-do-projeto-dbt/target-prd`.

## Solução de problemas

| Mensagem de erro                                              | Causa provável / solução                                                                                      |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `'<binário>' não encontrado no PATH`                          | Instale a dependência indicada (`databricks`, `jq`, `curl` ou `tar`).                                         |
| `nenhuma execução bem-sucedida encontrada`                    | O Job não tem execuções com sucesso entre as 25 mais recentes. Informe uma `RUN_ID` manualmente.              |
| `task dbt não encontrada na run`                              | O `task_key` está incorreto ou o Job não possui task do tipo dbt.                                             |
| `a task não retornou artifacts_link`                          | A task informada não é do tipo dbt.                                                                           |
| `'<arquivo>' não encontrado no pacote de artefatos`           | O arquivo informado em `ARQUIVO` não existe nos artefatos dessa execução.                                     |
| Erro de autenticação (`401`/`403`) ou perfil não encontrado   | Refaça o login (`databricks auth login`) e confira o nome do perfil em `DATABRICKS_PROFILE`.                  |

## Observações de segurança

- O link de download dos artefatos é temporário e gerado a cada execução do script.
- Não versione o `~/.databrickscfg` nem tokens de acesso.
