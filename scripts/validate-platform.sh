#!/usr/bin/env bash
set -u

OUT="platform-validation.txt"
: > "$OUT"
ERRORS=0

check_file() {
  if [[ -s "$1" ]]; then
    echo "[OK] $1" | tee -a "$OUT"
  else
    echo "[ERRO] ausente ou vazio: $1" | tee -a "$OUT"
    ERRORS=$((ERRORS + 1))
  fi
}

check_text() {
  if [[ -f "$1" ]] && grep -q "$2" "$1"; then
    echo "[OK] $3" | tee -a "$OUT"
  else
    echo "[ERRO] $3" | tee -a "$OUT"
    ERRORS=$((ERRORS + 1))
  fi
}

FILES=(
  terraform/lab/network.tf
  terraform/lab/eks.tf
  terraform/lab/parameters.tf
  terraform/lab/security-groups.tf
  .github/workflows/infrastructure-apply.yml
  .github/workflows/infrastructure-destroy.yml
  .github/workflows/deploy-aplicacao.yml
  .github/workflows/deploy-kong.yml
  .github/workflows/deploy-observabilidade.yml
  k8s/aws/api-deployment.yaml
  k8s/aws/api-service.yaml
  k8s/kong/values.yaml
  k8s/kong/api-ingress.yaml
  k8s/observabilidade/loki-values.yaml
  k8s/observabilidade/alloy-values.yaml
  k8s/observabilidade/grafana-values.yaml
  docs/external-integrations.md
)

for file in "${FILES[@]}"; do
  check_file "$file"
done

if [[ -e .github/workflows/deploy-lambda.yml ]]; then
  echo "[ERRO] deploy-lambda.yml deve ficar no repositorio da Lambda" \
    | tee -a "$OUT"
  ERRORS=$((ERRORS + 1))
else
  echo "[OK] Workflow Lambda nao existe neste repositorio" | tee -a "$OUT"
fi

check_text .github/workflows/deploy-kong.yml \
  'helm upgrade --install' 'Kong possui deploy Helm'
check_text .github/workflows/deploy-observabilidade.yml \
  'helm upgrade --install loki' 'Observabilidade instala Loki'
check_text .github/workflows/deploy-observabilidade.yml \
  'helm upgrade --install alloy' 'Observabilidade instala Alloy'
check_text .github/workflows/deploy-observabilidade.yml \
  'helm upgrade --install grafana' 'Observabilidade instala Grafana'
check_text k8s/kong/api-ingress.yaml \
  'ingressClassName: kong' 'Ingress usa Kong'
check_text k8s/aws/api-service.yaml \
  'type: ClusterIP' 'API permanece interna'
check_text terraform/lab/security-groups.tf \
  'resource "aws_security_group" "database_access"' \
  'Security Group compartilhado presente'

TRACKED_SECRETS="$(
  git ls-files |
    grep -E '(^|/)(secret\.yaml|.*-secret\.yaml)$' ||
    true
)"

if [[ -n "$TRACKED_SECRETS" ]]; then
  echo "[ERRO] Secrets rastreados pelo Git:" | tee -a "$OUT"
  echo "$TRACKED_SECRETS" | tee -a "$OUT"
  ERRORS=$((ERRORS + 1))
else
  echo "[OK] Nenhum Secret real rastreado" | tee -a "$OUT"
fi

if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=terraform/lab fmt -check -recursive \
    >> "$OUT" 2>&1 || ERRORS=$((ERRORS + 1))
  terraform -chdir=terraform/lab init -backend=false \
    >> "$OUT" 2>&1 || ERRORS=$((ERRORS + 1))
  terraform -chdir=terraform/lab validate \
    >> "$OUT" 2>&1 || ERRORS=$((ERRORS + 1))
else
  echo "[WARN] Terraform ausente; validacao executavel ignorada" | tee -a "$OUT"
fi

if [[ "$ERRORS" -eq 0 ]]; then
  echo "RESULTADO: PLATAFORMA CONSISTENTE" | tee -a "$OUT"
  exit 0
fi

echo "RESULTADO: $ERRORS PENDENCIA(S)" | tee -a "$OUT"
exit 1
