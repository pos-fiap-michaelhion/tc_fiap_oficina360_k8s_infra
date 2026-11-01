#!/usr/bin/env bash
set -Eeuo pipefail

EKS_CLUSTER_ROLE_PATTERN="${EKS_CLUSTER_ROLE_PATTERN:-LabEksClusterRole}"
EKS_NODE_ROLE_PATTERN="${EKS_NODE_ROLE_PATTERN:-LabEksNodeRole}"

fail(){ printf '[ERRO] %s\n' "$*" >&2; exit 1; }
mask(){ [[ -n "${1:-}" ]] && echo "::add-mask::$1"; }

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd nao encontrado"
done

IDENTITY_JSON="$(aws sts get-caller-identity --output json)"
ACCOUNT_ID="$(jq -r '.Account' <<< "$IDENTITY_JSON")"
CALLER_ARN="$(jq -r '.Arn' <<< "$IDENTITY_JSON")"
USER_ID="$(jq -r '.UserId' <<< "$IDENTITY_JSON")"

# Mascare dados somente fora de command substitution.
mask "$ACCOUNT_ID"
mask "$CALLER_ARN"
mask "$USER_ID"
mask "${CALLER_ARN##*/}"

if ! ROLES_JSON="$(aws iam list-roles --output json 2>/tmp/iam-list-roles-error.txt)"; then
  cat /tmp/iam-list-roles-error.txt >&2
  fail "Nao foi possivel descobrir as roles atuais"
fi

resolve_unique_role() {
  local pattern="$1"
  local kind="$2"
  local count arn

  count="$(jq --arg p "$pattern" '[.Roles[] | select(.RoleName | contains($p))] | length' <<< "$ROLES_JSON")"
  [[ "$count" -eq 1 ]] || fail "Era esperada uma unica role para $kind; encontradas: $count"

  # Esta funcao deve escrever somente o ARN no stdout.
  arn="$(jq -r --arg p "$pattern" '.Roles[] | select(.RoleName | contains($p)) | .Arn' <<< "$ROLES_JSON")"
  printf '%s\n' "$arn"
}

CLUSTER_ARN="$(resolve_unique_role "$EKS_CLUSTER_ROLE_PATTERN" "cluster EKS")"
NODE_ARN="$(resolve_unique_role "$EKS_NODE_ROLE_PATTERN" "node group EKS")"

# Agora as mascaras nao contaminam os valores capturados.
mask "$CLUSTER_ARN"
mask "$NODE_ARN"
mask "${CLUSTER_ARN##*/}"
mask "${NODE_ARN##*/}"

[[ "$CLUSTER_ARN" == "arn:aws:iam::${ACCOUNT_ID}:role/"* ]] || fail "Cluster role nao pertence a conta atual"
[[ "$NODE_ARN" == "arn:aws:iam::${ACCOUNT_ID}:role/"* ]] || fail "Node role nao pertence a conta atual"
[[ "$CLUSTER_ARN" != "$NODE_ARN" ]] || fail "Cluster role e node role nao podem ser iguais"

aws iam get-role --role-name "${CLUSTER_ARN##*/}" --query 'Role.Arn' --output text >/dev/null
aws iam get-role --role-name "${NODE_ARN##*/}" --query 'Role.Arn' --output text >/dev/null

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "TF_VAR_eks_cluster_role_arn=$CLUSTER_ARN"
    echo "TF_VAR_eks_node_role_arn=$NODE_ARN"
  } >> "$GITHUB_ENV"
fi

echo "Roles EKS atuais descobertas e validadas com sucesso."
