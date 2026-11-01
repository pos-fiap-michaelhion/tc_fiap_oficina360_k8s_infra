#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER_ROLE_ARN_CONFIGURED="${EKS_CLUSTER_ROLE_ARN_CONFIGURED:-}"
EKS_NODE_ROLE_ARN_CONFIGURED="${EKS_NODE_ROLE_ARN_CONFIGURED:-}"
EKS_CLUSTER_ROLE_NAME="${EKS_CLUSTER_ROLE_NAME:-LabEksClusterRole}"
EKS_NODE_ROLE_NAME="${EKS_NODE_ROLE_NAME:-LabEksNodeRole}"

fail() { printf '[ERRO] %s\n' "$*" >&2; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

normalize_role_arn() {
  local configured="$1"
  local fallback_name="$2"
  local suffix

  if [[ "$configured" =~ ^arn:aws:iam::[0-9]{12}:role/(.+)$ ]]; then
    suffix="${BASH_REMATCH[1]}"
    printf 'arn:aws:iam::%s:role/%s\n' "$ACCOUNT_ID" "$suffix"
  else
    printf 'arn:aws:iam::%s:role/%s\n' "$ACCOUNT_ID" "$fallback_name"
  fi
}

CLUSTER_ARN="$(normalize_role_arn "$EKS_CLUSTER_ROLE_ARN_CONFIGURED" "$EKS_CLUSTER_ROLE_NAME")"
NODE_ARN="$(normalize_role_arn "$EKS_NODE_ROLE_ARN_CONFIGURED" "$EKS_NODE_ROLE_NAME")"

[[ "$CLUSTER_ARN" != "$NODE_ARN" ]] || fail "Cluster role e node role nao podem ser iguais"

# Validate when Learner Lab permits iam:GetRole; otherwise Terraform/EKS performs final validation.
for arn in "$CLUSTER_ARN" "$NODE_ARN"; do
  role_path_name="${arn#*:role/}"
  role_name="${role_path_name##*/}"
  if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    echo "[OK] Role encontrada: $role_name"
  else
    echo "[AVISO] iam:GetRole indisponivel ou role nao consultavel: $role_name" >&2
  fi
done

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "TF_VAR_eks_cluster_role_arn=$CLUSTER_ARN"
    echo "TF_VAR_eks_node_role_arn=$NODE_ARN"
  } >> "$GITHUB_ENV"
fi

echo "Cluster role: ${CLUSTER_ARN##*/}"
echo "Node role: ${NODE_ARN##*/}"
