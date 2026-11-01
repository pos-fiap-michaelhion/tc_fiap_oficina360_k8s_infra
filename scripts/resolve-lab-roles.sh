#!/usr/bin/env bash
set -Eeuo pipefail

EKS_CLUSTER_ROLE_ARN_CONFIGURED="${EKS_CLUSTER_ROLE_ARN_CONFIGURED:-}"
EKS_NODE_ROLE_ARN_CONFIGURED="${EKS_NODE_ROLE_ARN_CONFIGURED:-}"
EKS_CLUSTER_ROLE_PATTERN="${EKS_CLUSTER_ROLE_PATTERN:-LabEksClusterRole}"
EKS_NODE_ROLE_PATTERN="${EKS_NODE_ROLE_PATTERN:-LabEksNodeRole}"

fail() { printf '[ERRO] %s\n' "$*" >&2; exit 1; }
mask() { [[ -n "${1:-}" ]] && echo "::add-mask::$1"; }

command -v aws >/dev/null 2>&1 || fail "AWS CLI nao encontrada"
command -v jq >/dev/null 2>&1 || fail "jq nao encontrado"

IDENTITY_JSON="$(aws sts get-caller-identity --output json)"
ACCOUNT_ID="$(jq -r '.Account' <<< "$IDENTITY_JSON")"
CALLER_ARN="$(jq -r '.Arn' <<< "$IDENTITY_JSON")"
USER_ID="$(jq -r '.UserId' <<< "$IDENTITY_JSON")"
mask "$ACCOUNT_ID"
mask "$CALLER_ARN"
mask "$USER_ID"
mask "${CALLER_ARN##*/}"

# The Learner Lab recreates role names with dynamic prefixes/suffixes.
# Never reconstruct a role ARN only by replacing the account ID.
if ! ROLES_JSON="$(aws iam list-roles --output json 2>/tmp/iam-list-roles.err)"; then
  cat /tmp/iam-list-roles.err >&2
  fail "Nao foi possivel descobrir as roles atuais com iam:ListRoles"
fi

resolve_unique_role() {
  local pattern="$1"
  local configured="$2"
  local kind="$3"
  local configured_name=""
  local candidates count arn role_name

  if [[ "$configured" =~ ^arn:aws:iam::[0-9]{12}:role/(.+)$ ]]; then
    configured_name="${BASH_REMATCH[1]}"
    configured_name="${configured_name##*/}"
  fi

  # Prefer an exact role name only when that role actually exists in the current account.
  if [[ -n "$configured_name" ]]; then
    arn="$(jq -r --arg name "$configured_name" '.Roles[] | select(.RoleName == $name) | .Arn' <<< "$ROLES_JSON" | head -n 1)"
    if [[ -n "$arn" ]]; then
      mask "$configured_name"
      mask "$arn"
      printf '%s\n' "$arn"
      return 0
    fi
  fi

  candidates="$(jq -r --arg pattern "$pattern" '.Roles[] | select(.RoleName | contains($pattern)) | [.RoleName,.Arn] | @tsv' <<< "$ROLES_JSON")"
  count="$(sed '/^$/d' <<< "$candidates" | wc -l | tr -d ' ')"

  if [[ "$count" -eq 0 ]]; then
    fail "Nenhuma role atual encontrada para $kind usando o padrao configurado"
  fi

  if [[ "$count" -gt 1 ]]; then
    while IFS=$'\t' read -r role_name arn; do
      mask "$role_name"
      mask "$arn"
    done <<< "$candidates"
    fail "Mais de uma role candidata encontrada para $kind; ajuste o pattern sem expor ARNs nos logs"
  fi

  IFS=$'\t' read -r role_name arn <<< "$candidates"
  mask "$role_name"
  mask "$arn"
  printf '%s\n' "$arn"
}

CLUSTER_ARN="$(resolve_unique_role "$EKS_CLUSTER_ROLE_PATTERN" "$EKS_CLUSTER_ROLE_ARN_CONFIGURED" "cluster EKS")"
NODE_ARN="$(resolve_unique_role "$EKS_NODE_ROLE_PATTERN" "$EKS_NODE_ROLE_ARN_CONFIGURED" "node group EKS")"

mask "$CLUSTER_ARN"
mask "$NODE_ARN"

[[ "$CLUSTER_ARN" != "$NODE_ARN" ]] || fail "Cluster role e node role nao podem ser iguais"
[[ "$CLUSTER_ARN" == arn:aws:iam::"$ACCOUNT_ID":role/* ]] || fail "Cluster role pertence a outra conta"
[[ "$NODE_ARN" == arn:aws:iam::"$ACCOUNT_ID":role/* ]] || fail "Node role pertence a outra conta"

# Confirm existence immediately before Terraform planning/apply.
CLUSTER_NAME="${CLUSTER_ARN##*/}"
NODE_NAME="${NODE_ARN##*/}"
aws iam get-role --role-name "$CLUSTER_NAME" --query 'Role.Arn' --output text >/dev/null
aws iam get-role --role-name "$NODE_NAME" --query 'Role.Arn' --output text >/dev/null

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "TF_VAR_eks_cluster_role_arn=$CLUSTER_ARN"
    echo "TF_VAR_eks_node_role_arn=$NODE_ARN"
  } >> "$GITHUB_ENV"
fi

echo "Roles EKS atuais descobertas e validadas com sucesso."
