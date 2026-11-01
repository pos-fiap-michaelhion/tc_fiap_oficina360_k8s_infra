#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-oficina360}"
ENVIRONMENT="${ENVIRONMENT:-lab}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${RUNNER_TEMP:-/tmp}/oficina360-kubeconfig}"
WAIT_SECONDS="${WAIT_SECONDS:-900}"

fail() { printf '[ERRO] %s\n' "$*" >&2; exit 1; }
log() { printf '[INFO] %s\n' "$*"; }

for cmd in aws jq kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd nao encontrado"
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
log "Conta AWS atual: $ACCOUNT_ID"
log "Regiao: $AWS_REGION"

mapfile -t CLUSTERS < <(
  aws eks list-clusters \
    --region "$AWS_REGION" \
    --query 'clusters[]' \
    --output text |
  tr '\t' '\n' |
  sed '/^$/d'
)

[[ "${#CLUSTERS[@]}" -gt 0 ]] || fail "Nenhum cluster EKS encontrado em $AWS_REGION"

CANDIDATES=()
for cluster in "${CLUSTERS[@]}"; do
  CLUSTER_JSON="$(aws eks describe-cluster --name "$cluster" --region "$AWS_REGION" --output json)"
  STATUS="$(jq -r '.cluster.status' <<< "$CLUSTER_JSON")"
  TAG_PROJECT="$(jq -r '.cluster.tags.Project // empty' <<< "$CLUSTER_JSON")"
  TAG_ENV="$(jq -r '.cluster.tags.Environment // empty' <<< "$CLUSTER_JSON")"

  if [[ "$cluster" == "$PROJECT_NAME" ]] ||
     [[ "$TAG_PROJECT" == "$PROJECT_NAME" && "$TAG_ENV" == "$ENVIRONMENT" ]]; then
    CANDIDATES+=("$cluster")
    log "Candidato: $cluster status=$STATUS Project=$TAG_PROJECT Environment=$TAG_ENV"
  fi
done

if [[ "${#CANDIDATES[@]}" -eq 0 && "${#CLUSTERS[@]}" -eq 1 ]]; then
  CANDIDATES=("${CLUSTERS[0]}")
  log "Fallback: usando o unico cluster da conta/regiao"
fi

[[ "${#CANDIDATES[@]}" -eq 1 ]] || {
  printf '[ERRO] Nao foi possivel selecionar um unico cluster. Encontrados: %s; candidatos: %s\n' \
    "${CLUSTERS[*]}" "${CANDIDATES[*]:-nenhum}" >&2
  exit 1
}

EKS_CLUSTER_NAME="${CANDIDATES[0]}"
log "Cluster selecionado: $EKS_CLUSTER_NAME"

DEADLINE=$((SECONDS + WAIT_SECONDS))
while true; do
  STATUS="$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text)"
  [[ "$STATUS" == "ACTIVE" ]] && break
  (( SECONDS < DEADLINE )) || fail "Cluster nao ficou ACTIVE em ${WAIT_SECONDS}s; status=$STATUS"
  log "Aguardando cluster ACTIVE; status=$STATUS"
  sleep 15
done

rm -f "$KUBECONFIG_PATH"
aws eks update-kubeconfig \
  --name "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --alias "$PROJECT_NAME" \
  --kubeconfig "$KUBECONFIG_PATH"

export KUBECONFIG="$KUBECONFIG_PATH"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "EKS_CLUSTER_NAME=$EKS_CLUSTER_NAME"
    echo "KUBECONFIG=$KUBECONFIG_PATH"
  } >> "$GITHUB_ENV"
fi

kubectl cluster-info
kubectl get nodes --output wide
