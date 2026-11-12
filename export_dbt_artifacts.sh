#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Exporta os artefatos do dbt (manifest.json, run_results.json, catalog.json,
# logs etc.) gerados por uma task dbt de um Job no Databricks.
#
# Uso:
#   ./export_dbt_artifacts.sh <job_id> [task_key] [diretorio_destino]
#
# Exemplos:
#   ./export_dbt_artifacts.sh 123456789
#   ./export_dbt_artifacts.sh 123456789 dbt_run ./artefatos
#   RUN_ID=987654321 ./export_dbt_artifacts.sh 123456789   # execução específica
#   ARQUIVO=manifest.json ./export_dbt_artifacts.sh 123456789   # só o manifest
#   SEM_SUBPASTA=1 ./export_dbt_artifacts.sh 123456789 "" ./destino   # sem subpasta data/run
#
# Autenticação: usa o perfil do Databricks CLI (~/.databrickscfg).
#   Defina DATABRICKS_PROFILE para usar outro perfil (padrão: DEFAULT).
#   Nunca coloque tokens diretamente neste script.
#
# Requisitos: databricks CLI (v0.200+), jq, curl, tar
# -----------------------------------------------------------------------------
set -euo pipefail

JOB_ID="${1:?Uso: $0 <job_id> [task_key] [diretorio_destino]}"
TASK_KEY="${2:-}"
DEST_BASE="${3:-./dbt_artifacts}"
PROFILE="${DATABRICKS_PROFILE:-DEFAULT}"
RUN_ID="${RUN_ID:-}"
ARQUIVO="${ARQUIVO:-}"   # ex.: ARQUIVO=manifest.json extrai só esse arquivo

for bin in databricks jq curl tar; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Erro: '$bin' não encontrado no PATH." >&2; exit 1; }
done

dbx() { databricks "$@" -p "$PROFILE" -o json; }

# 1) Descobre a execução (run) do job --------------------------------------------
if [[ -z "$RUN_ID" ]]; then
  echo ">> Buscando a última execução bem-sucedida do job $JOB_ID..."
  RUN_ID=$(dbx jobs list-runs --job-id "$JOB_ID" --completed-only --limit 25 \
    | jq -r '(.runs? // .) | map(select(.state.result_state == "SUCCESS")) | .[0].run_id // empty')
  [[ -n "$RUN_ID" ]] || { echo "Erro: nenhuma execução bem-sucedida encontrada." >&2; exit 1; }
fi
echo ">> Run selecionada: $RUN_ID"

# 2) Localiza a task dbt dentro da run ------------------------------------------
RUN_JSON=$(dbx jobs get-run "$RUN_ID")

if [[ -n "$TASK_KEY" ]]; then
  TASK_RUN_ID=$(echo "$RUN_JSON" | jq -r --arg k "$TASK_KEY" \
    '.tasks[] | select(.task_key == $k) | .run_id' | head -n1)
else
  TASK_RUN_ID=$(echo "$RUN_JSON" | jq -r \
    '[.tasks[] | select(.dbt_task != null)][0].run_id // empty')
  TASK_KEY=$(echo "$RUN_JSON" | jq -r \
    '[.tasks[] | select(.dbt_task != null)][0].task_key // empty')
fi
[[ -n "${TASK_RUN_ID:-}" ]] || { echo "Erro: task dbt não encontrada na run $RUN_ID." >&2; exit 1; }
echo ">> Task: $TASK_KEY (task run_id: $TASK_RUN_ID)"

# 3) Obtém o link (temporário) dos artefatos ------------------------------------
OUTPUT_JSON=$(dbx jobs get-run-output "$TASK_RUN_ID")
ARTIFACTS_LINK=$(echo "$OUTPUT_JSON" | jq -r '.dbt_output.artifacts_link // empty')
[[ -n "$ARTIFACTS_LINK" ]] || { echo "Erro: a task não retornou artifacts_link (é uma task do tipo dbt?)." >&2; exit 1; }

# Cabeçalhos exigidos pelo link (ex.: criptografia do storage)
CURL_HEADERS=()
while IFS= read -r header; do
  [[ -n "$header" ]] && CURL_HEADERS+=(-H "$header")
done < <(echo "$OUTPUT_JSON" | jq -r '.dbt_output.artifacts_headers // {} | to_entries[] | "\(.key): \(.value)"')

# 4) Baixa e extrai -------------------------------------------------------------
if [[ "${SEM_SUBPASTA:-0}" == "1" ]]; then
  DEST_DIR="$DEST_BASE"
else
  DEST_DIR="${DEST_BASE}/$(date +%Y-%m-%d)_run${RUN_ID}"
fi
mkdir -p "$DEST_DIR"
ARCHIVE="${DEST_DIR}/artifacts.tar.gz"

echo ">> Baixando artefatos..."
curl -sSfL ${CURL_HEADERS[@]+"${CURL_HEADERS[@]}"} -o "$ARCHIVE" "$ARTIFACTS_LINK"

if [[ -n "$ARQUIVO" ]]; then
  # Procura o arquivo dentro de target/ primeiro; se não achar, em qualquer pasta
  MEMBER=$(tar -tzf "$ARCHIVE" | grep -E "(^|/)target/${ARQUIVO}\$" | head -n1 || true)
  if [[ -z "$MEMBER" ]]; then
    MEMBER=$(tar -tzf "$ARCHIVE" | grep -E "(^|/)${ARQUIVO}\$" | head -n1 || true)
  fi
  [[ -n "$MEMBER" ]] || { echo "Erro: '$ARQUIVO' não encontrado no pacote de artefatos." >&2; rm -f "$ARCHIVE"; exit 1; }

  echo ">> Extraindo apenas $MEMBER em $DEST_DIR..."
  TMP_DIR=$(mktemp -d)
  tar -xzf "$ARCHIVE" -C "$TMP_DIR" "$MEMBER"
  mv "$TMP_DIR/$MEMBER" "$DEST_DIR/$(basename "$MEMBER")"
  rm -rf "$TMP_DIR"
else
  echo ">> Extraindo em $DEST_DIR..."
  tar -xzf "$ARCHIVE" -C "$DEST_DIR"
fi
rm -f "$ARCHIVE"

echo ">> Concluído. Arquivos exportados:"
find "$DEST_DIR" -maxdepth 3 -type f | sed 's/^/   /'
