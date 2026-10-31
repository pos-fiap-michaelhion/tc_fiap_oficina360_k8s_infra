#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
REPORT="${REPORT:-ssm-infra-diagnostico.txt}"

cd "$ROOT"
ROOT="$(pwd)"

{
  echo "===== REPOSITORIO ====="
  echo "$ROOT"

  echo
  echo "===== IMPORT BLOCKS TERRAFORM ====="
  grep -Rni --include='*.tf' -E '^[[:space:]]*import[[:space:]]*\{|aws_ssm_parameter' . \
    --exclude-dir=.terraform --exclude-dir=.git || true

  echo
  echo "===== COMANDOS TERRAFORM IMPORT NOS WORKFLOWS E SCRIPTS ====="
  grep -Rni -E 'terraform[[:space:]]+import|aws_ssm_parameter|/oficina360/' \
    .github scripts terraform 2>/dev/null \
    --exclude-dir=.terraform --exclude-dir=.git || true

  echo
  echo "===== SSM AWS CLI ====="
  grep -Rni -E 'aws[[:space:]]+ssm|ssm:(Get|Put|Delete)|get-parameter|put-parameter|delete-parameter' \
    . 2>/dev/null --exclude-dir=.terraform --exclude-dir=.git || true

  echo
  echo "===== STATE SSM ====="
  if command -v terraform >/dev/null 2>&1 && [[ -d terraform/lab ]]; then
    terraform -chdir=terraform/lab state list 2>/dev/null | grep 'aws_ssm_parameter' || true
  else
    echo "Terraform ou terraform/lab nao encontrado; state nao consultado."
  fi
} | tee "$REPORT"

echo
printf '[OK] Diagnostico salvo em %s\n' "$REPORT"
echo "Nenhum arquivo foi alterado."
