#!/usr/bin/env bash
# Resolve os ARNs das roles do EKS no AWS Learner Lab.
#
# O Learner Lab bloqueia iam:ListRoles com deny explicito (policy
# voc-cancel-cred), entao as roles NAO sao descobertas por listagem. O ARN e
# montado a partir do account ID (sts:GetCallerIdentity, sempre permitido).
#
# Entradas (opcionais):
#   EKS_CLUSTER_ROLE_ARN_CONFIGURED  ARN da role do cluster (secret)
#   EKS_NODE_ROLE_ARN_CONFIGURED     ARN da role dos nodes (secret)
#   LAB_CLUSTER_ROLE_NAME            nome padrao da role do cluster (LabRole)
#   LAB_NODE_ROLE_NAME               nome padrao da role dos nodes (LabRole)
#
# Saidas (GITHUB_ENV):
#   TF_VAR_eks_cluster_role_arn
#   TF_VAR_eks_node_role_arn
set -euo pipefail

: "${GITHUB_ENV:=/dev/null}"

CLUSTER_CONFIGURED="${EKS_CLUSTER_ROLE_ARN_CONFIGURED:-}"
NODE_CONFIGURED="${EKS_NODE_ROLE_ARN_CONFIGURED:-}"
CLUSTER_ROLE_NAME="${LAB_CLUSTER_ROLE_NAME:-LabRole}"
NODE_ROLE_NAME="${LAB_NODE_ROLE_NAME:-LabRole}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
if ! [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "::error::Nao foi possivel obter o account ID via sts:GetCallerIdentity."
  exit 1
fi
echo "::add-mask::$ACCOUNT_ID"

ARN_RE="^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$"

# resolve <rotulo> <arn configurado> <nome padrao>  -> imprime o ARN escolhido
resolve() {
  local label="$1" configured="$2" default_name="$3"

  if [[ -n "$configured" ]]; then
    if ! [[ "$configured" =~ $ARN_RE ]]; then
      echo "::warning::Secret da role $label nao e um ARN de role valido. Usando $default_name." >&2
    elif [[ "$configured" != arn:aws:iam::"$ACCOUNT_ID":role/* ]]; then
      echo "::warning::Secret da role $label aponta para outra conta (o lab foi recriado?). Usando $default_name da conta atual." >&2
    else
      printf '%s' "$configured"
      return 0
    fi
  fi

  printf 'arn:aws:iam::%s:role/%s' "$ACCOUNT_ID" "$default_name"
}

CLUSTER_ROLE_ARN="$(resolve cluster "$CLUSTER_CONFIGURED" "$CLUSTER_ROLE_NAME")"
NODE_ROLE_ARN="$(resolve node "$NODE_CONFIGURED" "$NODE_ROLE_NAME")"

# Verificacao opcional. iam:GetRole costuma funcionar no Learner Lab, mas se
# tambem estiver bloqueado nao e motivo para falhar: o EKS valida a role no apply.
verify() {
  local label="$1" arn="$2" name
  name="${arn##*/}"
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    echo "Role $label verificada: $name"
  else
    echo "::warning::Nao foi possivel verificar a role $label ($name) via iam:GetRole. Seguindo com o ARN montado."
  fi
}
verify cluster "$CLUSTER_ROLE_ARN"
verify node "$NODE_ROLE_ARN"

echo "::add-mask::$CLUSTER_ROLE_ARN"
echo "::add-mask::$NODE_ROLE_ARN"

{
  echo "TF_VAR_eks_cluster_role_arn=$CLUSTER_ROLE_ARN"
  echo "TF_VAR_eks_node_role_arn=$NODE_ROLE_ARN"
} >> "$GITHUB_ENV"

echo "Roles EKS resolvidas: cluster=${CLUSTER_ROLE_ARN##*/} node=${NODE_ROLE_ARN##*/}"