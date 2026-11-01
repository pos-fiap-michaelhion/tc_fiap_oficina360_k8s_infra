#!/usr/bin/env bash
set -uo pipefail

TF_DIR="${TF_DIR:-terraform/lab}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-oficina360-tfstate-337958928021-us-east-1}"
TF_STATE_KEY="${TF_STATE_KEY:-oficina360/lab.tfstate}"
CLUSTER_NAME="${CLUSTER_NAME:-oficina360}"
REPORT="${REPORT:-validacao-state-infra-destroy-v2.txt}"

OK=0
WARN=0
ERR=0
section(){ printf '\n===== %s =====\n' "$1"; }
ok(){ OK=$((OK+1)); printf '[OK] %s\n' "$1"; }
warn(){ WARN=$((WARN+1)); printf '[AVISO] %s\n' "$1"; }
err(){ ERR=$((ERR+1)); printf '[ERRO] %s\n' "$1"; }

for cmd in aws jq terraform; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ERRO] $cmd nao encontrado"; exit 2; }
done

exec > >(tee "$REPORT") 2>&1

section "IDENTIDADE"
IDENTITY="$(aws sts get-caller-identity --output json 2>&1)"
if jq -e '.Account and .Arn' >/dev/null 2>&1 <<< "$IDENTITY"; then
  echo "Account: $(jq -r '.Account' <<< "$IDENTITY")"
  echo "Caller: $(jq -r '.Arn' <<< "$IDENTITY")"
  ok "Credenciais AWS validas"
else
  echo "$IDENTITY"
  err "Credenciais AWS invalidas"
  exit 1
fi

section "BACKEND ESPERADO"
echo "Terraform dir: $TF_DIR"
echo "Bucket: $TF_STATE_BUCKET"
echo "Key: $TF_STATE_KEY"
echo "Region: $AWS_REGION"
[[ -d "$TF_DIR" ]] && ok "Diretorio Terraform existe" || err "Diretorio Terraform nao existe"

section "OBJETO S3"
HEAD_JSON="$(aws s3api head-object --bucket "$TF_STATE_BUCKET" --key "$TF_STATE_KEY" 2>&1)"
if jq -e '.ContentLength != null' >/dev/null 2>&1 <<< "$HEAD_JSON"; then
  echo "$HEAD_JSON" | jq '{ContentLength,LastModified,VersionId,ETag}'
  ok "Objeto do state existe"
else
  echo "$HEAD_JSON"
  err "Objeto do state ausente ou inacessivel"
fi

STATE_JSON="$(aws s3api get-object --bucket "$TF_STATE_BUCKET" --key "$TF_STATE_KEY" /dev/stdout 2>/dev/null || true)"
if jq -e '.version and (.resources | type == "array")' >/dev/null 2>&1 <<< "$STATE_JSON"; then
  RESOURCE_COUNT="$(jq '[.resources[]? | select(.mode == "managed") | .instances[]?] | length' <<< "$STATE_JSON")"
  echo "Instancias gerenciadas: $RESOURCE_COUNT"
  if [[ "$RESOURCE_COUNT" -gt 0 ]]; then
    ok "State contem recursos"
    jq -r '.resources[]? | select(.mode == "managed") | if .module then "\(.module).\(.type).\(.name)" else "\(.type).\(.name)" end' <<< "$STATE_JSON" | sort -u
  else
    err "State valido, mas sem recursos gerenciados"
  fi
else
  RESOURCE_COUNT=0
  err "Conteudo S3 nao e um state Terraform valido"
fi

section "VERSOES DO STATE"
VERSIONING="$(aws s3api get-bucket-versioning --bucket "$TF_STATE_BUCKET" 2>&1 || true)"
echo "$VERSIONING" | jq . 2>/dev/null || echo "$VERSIONING"
if jq -e '.Status == "Enabled"' >/dev/null 2>&1 <<< "$VERSIONING"; then
  ok "Versionamento habilitado"
  VERSIONS="$(aws s3api list-object-versions --bucket "$TF_STATE_BUCKET" --prefix "$TF_STATE_KEY" --output json 2>&1 || true)"
  jq -r --arg key "$TF_STATE_KEY" '.Versions[]? | select(.Key == $key) | [.IsLatest,.VersionId,.Size,.LastModified] | @tsv' <<< "$VERSIONS"
else
  warn "Versionamento nao habilitado ou consulta bloqueada"
fi

section "TERRAFORM INIT E STATE LIST"
if [[ -d "$TF_DIR" ]]; then
  rm -rf "$TF_DIR/.terraform"
  INIT_OUTPUT="$(terraform -chdir="$TF_DIR" init -reconfigure \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="key=$TF_STATE_KEY" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="use_lockfile=true" -no-color 2>&1)"
  INIT_STATUS=$?
  echo "$INIT_OUTPUT"
  if [[ "$INIT_STATUS" -eq 0 ]]; then
    ok "Terraform init concluido"
    WORKSPACE="$(terraform -chdir="$TF_DIR" workspace show 2>&1 || true)"
    echo "Workspace: $WORKSPACE"
    STATE_LIST="$(terraform -chdir="$TF_DIR" state list 2>&1 || true)"
    echo "$STATE_LIST"
    if grep -q '^aws_eks_cluster\.main$' <<< "$STATE_LIST"; then ok "aws_eks_cluster.main presente"; else err "aws_eks_cluster.main ausente"; fi
    if grep -q '^aws_eks_node_group\.main$' <<< "$STATE_LIST"; then ok "aws_eks_node_group.main presente"; else err "aws_eks_node_group.main ausente"; fi
    if grep -q '^module\.vpc\.' <<< "$STATE_LIST"; then ok "Recursos module.vpc presentes"; else err "Recursos module.vpc ausentes"; fi
  else
    err "Terraform init falhou"
  fi
fi

section "RECURSOS AWS"
EKS_JSON="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --output json 2>&1 || true)"
if jq -e '.cluster.name' >/dev/null 2>&1 <<< "$EKS_JSON"; then
  echo "EKS: $(jq -r '.cluster.name + " / " + .cluster.status' <<< "$EKS_JSON")"
  warn "Cluster EKS ainda existe"
  aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --output table || true
else
  ok "Cluster EKS nao existe"
fi

section "RESULTADO"
if [[ "${RESOURCE_COUNT:-0}" -gt 0 ]]; then
  echo "STATE_STATUS=STATE_OK"
  echo "O state remoto contem recursos. O destroy pode prosseguir apos confirmar o plano."
else
  echo "STATE_STATUS=STATE_EMPTY_OR_INVALID"
  echo "Nao execute destroy. Investigue versoes anteriores ou outro key."
fi

echo "OK=$OK"
echo "AVISOS=$WARN"
echo "ERROS=$ERR"
echo "Relatorio=$REPORT"
[[ "$ERR" -eq 0 ]]
