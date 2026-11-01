#!/usr/bin/env bash
set -uo pipefail

ROOT="${1:-.}"
TF_DIR="${TF_DIR:-infra}"
APPLY_WORKFLOW="${APPLY_WORKFLOW:-.github/workflows/infrastructure-apply.yml}"
DESTROY_WORKFLOW="${DESTROY_WORKFLOW:-.github/workflows/infrastructure-destroy.yml}"
GH_REPO="${GH_REPO:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
TF_STATE_KEY="${TF_STATE_KEY:-}"
EXPECTED_WORKSPACE="${EXPECTED_WORKSPACE:-default}"
REPORT="${REPORT:-validacao-state-infra-destroy.txt}"

OK=0
WARN=0
ERR=0

section() { printf '\n===== %s =====\n' "$1"; }
ok() { OK=$((OK + 1)); printf '[OK] %s\n' "$1"; }
warn() { WARN=$((WARN + 1)); printf '[AVISO] %s\n' "$1"; }
err() { ERR=$((ERR + 1)); printf '[ERRO] %s\n' "$1"; }

for cmd in aws jq git gh terraform python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[ERRO] Dependencia ausente: $cmd" >&2
    exit 2
  }
done

ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || {
  echo "[ERRO] Diretorio invalido: $ROOT" >&2
  exit 2
}
cd "$ROOT"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
exec > >(tee "$REPORT") 2>&1

section "CONTEXTO"
echo "Repositorio local: $ROOT"
echo "Terraform dir: $TF_DIR"
echo "Apply workflow: $APPLY_WORKFLOW"
echo "Destroy workflow: $DESTROY_WORKFLOW"
echo "Regiao: $AWS_REGION"
echo "Workspace esperado: $EXPECTED_WORKSPACE"

section "AUTENTICACAO"
if aws sts get-caller-identity --output json > "$WORK_DIR/identity.json" 2> "$WORK_DIR/identity.err"; then
  ACCOUNT_ID="$(jq -r '.Account' "$WORK_DIR/identity.json")"
  CALLER_ARN="$(jq -r '.Arn' "$WORK_DIR/identity.json")"
  echo "AWS account: $ACCOUNT_ID"
  echo "AWS caller: $CALLER_ARN"
  ok "Credenciais AWS validas"
else
  cat "$WORK_DIR/identity.err"
  err "Credenciais AWS invalidas ou expiradas"
  exit 1
fi

if gh auth status >/dev/null 2>&1; then
  ok "GitHub CLI autenticada"
else
  err "GitHub CLI nao autenticada"
  exit 1
fi

if [[ -z "$GH_REPO" ]]; then
  GH_REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
fi
[[ -n "$GH_REPO" ]] && ok "Repositorio GitHub: $GH_REPO" || err "Nao foi possivel identificar GH_REPO"

section "ARQUIVOS"
[[ -f "$APPLY_WORKFLOW" ]] && ok "Workflow apply encontrado" || err "Workflow apply ausente"
[[ -f "$DESTROY_WORKFLOW" ]] && ok "Workflow destroy encontrado" || err "Workflow destroy ausente"
[[ -d "$TF_DIR" ]] && ok "Diretorio Terraform encontrado" || err "Diretorio Terraform ausente"

section "GITHUB VARIABLES"
REPO_VARS='[]'
if [[ -n "$GH_REPO" ]]; then
  REPO_VARS="$(gh variable list --repo "$GH_REPO" --json name,value 2>/dev/null || printf '[]')"
fi

get_repo_var() {
  local name="$1"
  jq -r --arg n "$name" '.[] | select(.name == $n) | .value' <<< "$REPO_VARS" | head -n 1
}

[[ -n "$TF_STATE_BUCKET" ]] || TF_STATE_BUCKET="$(get_repo_var TF_STATE_BUCKET)"
[[ -n "$TF_STATE_KEY" ]] || TF_STATE_KEY="$(get_repo_var TF_STATE_KEY)"
GH_REGION="$(get_repo_var AWS_REGION)"
GH_WORKSPACE="$(get_repo_var TF_WORKSPACE)"

printf 'TF_STATE_BUCKET=%s\n' "${TF_STATE_BUCKET:-<ausente>}"
printf 'TF_STATE_KEY=%s\n' "${TF_STATE_KEY:-<ausente>}"
printf 'AWS_REGION=%s\n' "${GH_REGION:-<ausente>}"
printf 'TF_WORKSPACE=%s\n' "${GH_WORKSPACE:-<ausente>}"

[[ -n "$TF_STATE_BUCKET" ]] && ok "TF_STATE_BUCKET definida" || err "TF_STATE_BUCKET ausente"
[[ -n "$TF_STATE_KEY" ]] && ok "TF_STATE_KEY definida" || err "TF_STATE_KEY ausente"
if [[ -n "$GH_WORKSPACE" && "$GH_WORKSPACE" != "$EXPECTED_WORKSPACE" ]]; then
  warn "TF_WORKSPACE=$GH_WORKSPACE diverge do esperado $EXPECTED_WORKSPACE"
fi

section "COMPARACAO APPLY VERSUS DESTROY"
if [[ -f "$APPLY_WORKFLOW" && -f "$DESTROY_WORKFLOW" ]]; then
  for token in TF_STATE_BUCKET TF_STATE_KEY backend-config workspace terraform init; do
    echo "--- $token / apply ---"
    grep -nF "$token" "$APPLY_WORKFLOW" || true
    echo "--- $token / destroy ---"
    grep -nF "$token" "$DESTROY_WORKFLOW" || true
  done

  python3 - "$APPLY_WORKFLOW" "$DESTROY_WORKFLOW" <<'PY' > "$WORK_DIR/workflow-compare.txt"
from pathlib import Path
import re
import sys

for label, filename in (("apply", sys.argv[1]), ("destroy", sys.argv[2])):
    text = Path(filename).read_text(encoding="utf-8")
    print(f"[{label}]")
    for pattern_name, pattern in (
        ("bucket refs", r"TF_STATE_BUCKET[^\n]*"),
        ("key refs", r"TF_STATE_KEY[^\n]*"),
        ("backend bucket", r"backend-config=[\"']?bucket=[^\s\\]+"),
        ("backend key", r"backend-config=[\"']?key=[^\s\\]+"),
        ("workspace", r"terraform\s+(?:-chdir=\S+\s+)?workspace\s+(?:select|new|show)[^\n]*"),
    ):
        values = sorted(set(re.findall(pattern, text)))
        print(pattern_name + ":")
        for value in values:
            print("  " + value.strip())
PY
  cat "$WORK_DIR/workflow-compare.txt"

  APPLY_HAS_BUCKET="$(grep -c 'TF_STATE_BUCKET' "$APPLY_WORKFLOW" || true)"
  DESTROY_HAS_BUCKET="$(grep -c 'TF_STATE_BUCKET' "$DESTROY_WORKFLOW" || true)"
  APPLY_HAS_KEY="$(grep -c 'TF_STATE_KEY' "$APPLY_WORKFLOW" || true)"
  DESTROY_HAS_KEY="$(grep -c 'TF_STATE_KEY' "$DESTROY_WORKFLOW" || true)"

  [[ "$APPLY_HAS_BUCKET" -gt 0 && "$DESTROY_HAS_BUCKET" -gt 0 ]] \
    && ok "Apply e destroy referenciam TF_STATE_BUCKET" \
    || err "Apply ou destroy nao referencia TF_STATE_BUCKET"
  [[ "$APPLY_HAS_KEY" -gt 0 && "$DESTROY_HAS_KEY" -gt 0 ]] \
    && ok "Apply e destroy referenciam TF_STATE_KEY" \
    || err "Apply ou destroy nao referencia TF_STATE_KEY"
fi

section "OBJETO CONFIGURADO NO S3"
STATE_DOWNLOAD_OK=false
STATE_RESOURCE_COUNT=0
if [[ -n "$TF_STATE_BUCKET" && -n "$TF_STATE_KEY" ]]; then
  if aws s3api head-object \
    --bucket "$TF_STATE_BUCKET" \
    --key "$TF_STATE_KEY" \
    > "$WORK_DIR/head.json" 2> "$WORK_DIR/head.err"; then
    ok "Objeto configurado existe: s3://$TF_STATE_BUCKET/$TF_STATE_KEY"
    jq '{ContentLength,LastModified,VersionId,ETag}' "$WORK_DIR/head.json"

    if aws s3api get-object \
      --bucket "$TF_STATE_BUCKET" \
      --key "$TF_STATE_KEY" \
      "$WORK_DIR/configured.tfstate" \
      > "$WORK_DIR/get.json" 2> "$WORK_DIR/get.err"; then
      STATE_DOWNLOAD_OK=true
      if jq -e '.version and (.resources | type == "array")' "$WORK_DIR/configured.tfstate" >/dev/null 2>&1; then
        STATE_RESOURCE_COUNT="$(jq '[.resources[]? | select(.mode == "managed") | .instances[]?] | length' "$WORK_DIR/configured.tfstate")"
        echo "Instancias gerenciadas no state configurado: $STATE_RESOURCE_COUNT"
        if [[ "$STATE_RESOURCE_COUNT" -gt 0 ]]; then
          ok "State configurado contem recursos"
          jq -r '.resources[]? | select(.mode == "managed") | if .module then "\(.module).\(.type).\(.name)" else "\(.type).\(.name)" end' "$WORK_DIR/configured.tfstate" | sort -u
        else
          err "State configurado esta vazio"
        fi
      else
        err "Objeto configurado nao parece um state Terraform valido"
      fi
    else
      cat "$WORK_DIR/get.err"
      err "Nao foi possivel baixar o state configurado"
    fi
  else
    cat "$WORK_DIR/head.err"
    err "Objeto configurado nao existe ou nao esta acessivel"
  fi
fi

section "BUSCA DE OUTROS STATES NO BUCKET"
CANDIDATE_FOUND=false
if [[ -n "$TF_STATE_BUCKET" ]]; then
  if aws s3api list-objects-v2 \
    --bucket "$TF_STATE_BUCKET" \
    --output json > "$WORK_DIR/objects.json" 2> "$WORK_DIR/list.err"; then

    jq -r '.Contents[]? | select(.Key | endswith(".tfstate")) | [.Key,.Size,.LastModified] | @tsv' "$WORK_DIR/objects.json" > "$WORK_DIR/state-objects.tsv"

    if [[ -s "$WORK_DIR/state-objects.tsv" ]]; then
      printf '%-80s %-12s %s\n' "KEY" "SIZE" "MODIFIED"
      while IFS=$'\t' read -r key size modified; do
        printf '%-80s %-12s %s\n' "$key" "$size" "$modified"
      done < "$WORK_DIR/state-objects.tsv"

      INDEX=0
      while IFS=$'\t' read -r key size modified; do
        INDEX=$((INDEX + 1))
        SAFE_NAME="$(printf '%s' "$key" | tr '/:' '__')"
        FILE="$WORK_DIR/candidate-$INDEX-$SAFE_NAME"
        if aws s3api get-object --bucket "$TF_STATE_BUCKET" --key "$key" "$FILE" >/dev/null 2>&1; then
          if jq -e '.resources | type == "array"' "$FILE" >/dev/null 2>&1; then
            COUNT="$(jq '[.resources[]? | select(.mode == "managed") | .instances[]?] | length' "$FILE")"
            EKS_COUNT="$(jq '[.resources[]? | select(.type == "aws_eks_cluster") | .instances[]?] | length' "$FILE")"
            VPC_COUNT="$(jq '[.resources[]? | select(.type == "aws_vpc") | .instances[]?] | length' "$FILE")"
            printf 'State candidato: %s | recursos=%s | eks=%s | vpc=%s\n' "$key" "$COUNT" "$EKS_COUNT" "$VPC_COUNT"
            if [[ "$COUNT" -gt 0 ]]; then
              CANDIDATE_FOUND=true
            fi
            if [[ "$EKS_COUNT" -gt 0 ]]; then
              warn "State com EKS encontrado em key candidata: $key"
            fi
          fi
        fi
      done < "$WORK_DIR/state-objects.tsv"
    else
      warn "Nenhum objeto .tfstate encontrado no bucket"
    fi
  else
    cat "$WORK_DIR/list.err"
    warn "Listagem do bucket bloqueada; validacao limitada ao key configurado"
  fi
fi

section "VERSIONAMENTO DO STATE CONFIGURADO"
if [[ -n "$TF_STATE_BUCKET" && -n "$TF_STATE_KEY" ]]; then
  VERSIONING="$(aws s3api get-bucket-versioning --bucket "$TF_STATE_BUCKET" 2>/dev/null || printf '{}')"
  echo "$VERSIONING" | jq .
  if [[ "$(jq -r '.Status // "Disabled"' <<< "$VERSIONING")" == "Enabled" ]]; then
    ok "Versionamento S3 habilitado"
    if aws s3api list-object-versions \
      --bucket "$TF_STATE_BUCKET" \
      --prefix "$TF_STATE_KEY" \
      --output json > "$WORK_DIR/versions.json" 2> "$WORK_DIR/versions.err"; then
      jq -r --arg key "$TF_STATE_KEY" '.Versions[]? | select(.Key == $key) | [.IsLatest,.VersionId,.Size,.LastModified] | @tsv' "$WORK_DIR/versions.json"
    else
      warn "Nao foi possivel listar versoes do state"
    fi
  else
    warn "Versionamento S3 nao esta habilitado ou nao pode ser consultado"
  fi
fi

section "BACKEND LOCAL E WORKSPACE"
if [[ -d "$TF_DIR" ]]; then
  BACKEND_BLOCKS="$(grep -Rni --include='*.tf' 'backend[[:space:]]*"s3"' "$TF_DIR" || true)"
  [[ -n "$BACKEND_BLOCKS" ]] && { echo "$BACKEND_BLOCKS"; ok "Backend S3 declarado"; } || warn "Backend S3 nao localizado nos arquivos .tf"

  if [[ -d "$TF_DIR/.terraform" ]]; then
    CURRENT_WORKSPACE="$(terraform -chdir="$TF_DIR" workspace show 2>/dev/null || true)"
    echo "Workspace local atual: ${CURRENT_WORKSPACE:-<indisponivel>}"
    if [[ -n "$CURRENT_WORKSPACE" && "$CURRENT_WORKSPACE" != "$EXPECTED_WORKSPACE" ]]; then
      warn "Workspace local diverge do esperado"
    fi
  else
    warn ".terraform ausente; workspace local nao foi consultado"
  fi
fi

section "RECURSOS AWS AINDA EXISTENTES"
if aws eks describe-cluster --name oficina360 --region "$AWS_REGION" --output json > "$WORK_DIR/eks.json" 2> "$WORK_DIR/eks.err"; then
  EKS_STATUS="$(jq -r '.cluster.status' "$WORK_DIR/eks.json")"
  EKS_ARN="$(jq -r '.cluster.arn' "$WORK_DIR/eks.json")"
  echo "EKS status: $EKS_STATUS"
  echo "EKS ARN: $EKS_ARN"
  warn "Cluster EKS oficina360 ainda existe"
  aws eks list-nodegroups --cluster-name oficina360 --region "$AWS_REGION" --output table || true
else
  ok "Cluster EKS oficina360 nao foi encontrado"
fi

section "DIAGNOSTICO"
if [[ "$STATE_DOWNLOAD_OK" == "true" && "$STATE_RESOURCE_COUNT" -gt 0 ]]; then
  echo "STATE_STATUS=CONFIGURED_STATE_HAS_RESOURCES"
  echo "O key configurado contem recursos. A falha do workflow pode ser workspace ou inicializacao divergente."
elif [[ "$CANDIDATE_FOUND" == "true" ]]; then
  echo "STATE_STATUS=OTHER_STATE_HAS_RESOURCES"
  echo "O key configurado esta vazio, mas existe outro state com recursos no bucket."
  echo "Nao execute destroy ate alinhar TF_STATE_KEY e workspace com o state correto."
else
  echo "STATE_STATUS=NO_MANAGED_STATE_FOUND"
  echo "Nenhum state gerenciado com recursos foi confirmado."
  echo "Se a infraestrutura ainda existe, o state pode ter sido perdido ou substituido."
fi

section "RESUMO"
echo "OK=$OK"
echo "AVISOS=$WARN"
echo "ERROS=$ERR"
echo "Relatorio=$REPORT"

if [[ "$ERR" -gt 0 ]]; then
  exit 1
fi
