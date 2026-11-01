#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-oficina360}"
DEPLOYMENT="${DEPLOYMENT:-oficina360-api}"
K8S_SECRET="${K8S_SECRET:-oficina360-secret}"
RDS_IDENTIFIER="${RDS_IDENTIFIER:-oficina360-lab-postgres}"
RDS_SECRET_ARN="${RDS_SECRET_ARN:-}"
GH_REPO="${GH_REPO:-}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
APPLY="${APPLY:-false}"
UPDATE_GITHUB="${UPDATE_GITHUB:-true}"
REPORT="${REPORT:-sincronizacao-rds-aplicacao.txt}"

log() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[AVISO] %s\n' "$*" >&2; }
fail() { printf '[ERRO] %s\n' "$*" >&2; exit 1; }

for cmd in aws kubectl jq gh; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd nao encontrado"
done

exec > >(tee "$REPORT") 2>&1

aws sts get-caller-identity >/dev/null 2>&1 || fail "AWS CLI nao autenticada ou credenciais expiradas"
kubectl version --client >/dev/null 2>&1 || fail "kubectl indisponivel"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"

printf '%s\n' "===== CONTEXTO ====="
echo "AWS account: $ACCOUNT_ID"
echo "AWS caller: $CALLER_ARN"
echo "AWS region: $AWS_REGION"
echo "Namespace: $NAMESPACE"
echo "Deployment: $DEPLOYMENT"
echo "Kubernetes Secret: $K8S_SECRET"
echo "RDS: $RDS_IDENTIFIER"

printf '\n%s\n' "===== VALIDANDO RECURSOS ====="
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || fail "Namespace $NAMESPACE nao existe"
kubectl get deployment "$DEPLOYMENT" --namespace "$NAMESPACE" >/dev/null 2>&1 || fail "Deployment $DEPLOYMENT nao existe"
ok "Namespace e deployment encontrados"

RDS_JSON="$(
  aws rds describe-db-instances \
    --db-instance-identifier "$RDS_IDENTIFIER" \
    --region "$AWS_REGION" \
    --query 'DBInstances[0]' \
    --output json
)"

RDS_STATUS="$(jq -r '.DBInstanceStatus' <<< "$RDS_JSON")"
RDS_ENDPOINT="$(jq -r '.Endpoint.Address' <<< "$RDS_JSON")"
RDS_PORT="$(jq -r '.Endpoint.Port' <<< "$RDS_JSON")"
RDS_DATABASE="$(jq -r '.DBName // "oficina360"' <<< "$RDS_JSON")"

[[ "$RDS_STATUS" == "available" ]] || fail "RDS nao esta available: $RDS_STATUS"
ok "RDS disponivel em $RDS_ENDPOINT:$RDS_PORT/$RDS_DATABASE"

if [[ -z "$RDS_SECRET_ARN" ]]; then
  RDS_SECRET_ARN="$(
    jq -r '.MasterUserSecret.SecretArn // empty' <<< "$RDS_JSON"
  )"
fi

[[ -n "$RDS_SECRET_ARN" ]] || fail "RDS_SECRET_ARN nao informado e nao encontrado no RDS"

printf '\n%s\n' "===== VALIDANDO SEGREDO RDS ====="
SECRET_JSON="$(
  aws secretsmanager get-secret-value \
    --secret-id "$RDS_SECRET_ARN" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text
)"

DB_USERNAME="$(jq -r '.username // empty' <<< "$SECRET_JSON")"
DB_PASSWORD="$(jq -r '.password // empty' <<< "$SECRET_JSON")"

[[ -n "$DB_USERNAME" ]] || fail "Campo username ausente no segredo RDS"
[[ -n "$DB_PASSWORD" ]] || fail "Campo password ausente no segredo RDS"

printf '::add-mask::%s\n' "$DB_USERNAME"
printf '::add-mask::%s\n' "$DB_PASSWORD"
echo "Usuario resolvido: $DB_USERNAME"
echo "Senha resolvida: presente, ${#DB_PASSWORD} caracteres"
ok "Segredo RDS lido com sucesso"

printf '\n%s\n' "===== PRESERVANDO JWT_SECRET ====="
JWT_SECRET=""
if kubectl get secret "$K8S_SECRET" --namespace "$NAMESPACE" >/dev/null 2>&1; then
  JWT_SECRET="$(
    kubectl get secret "$K8S_SECRET" \
      --namespace "$NAMESPACE" \
      --output jsonpath='{.data.JWT_SECRET}' 2>/dev/null \
      | base64 --decode 2>/dev/null || true
  )"
fi

if [[ -z "$JWT_SECRET" ]]; then
  if [[ "$UPDATE_GITHUB" == "true" ]]; then
    gh auth status >/dev/null 2>&1 || fail "GitHub CLI nao autenticada"
    if [[ -z "$GH_REPO" ]]; then
      GH_REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
    fi
    warn "JWT_SECRET nao estava no Kubernetes. O valor nao pode ser recuperado do GitHub Secrets."
    fail "Execute o deployment existente com JWT_SECRET ou informe JWT_SECRET no ambiente antes deste script"
  else
    fail "JWT_SECRET nao encontrado no Kubernetes Secret $K8S_SECRET"
  fi
fi

printf '::add-mask::%s\n' "$JWT_SECRET"
ok "JWT_SECRET atual preservado"

printf '\n%s\n' "===== PLANO ====="
echo "1. Atualizar DB_USERNAME e DB_PASSWORD no Kubernetes Secret $K8S_SECRET"
echo "2. Preservar JWT_SECRET atual"
echo "3. Atualizar DB_USERNAME e DB_PASSWORD no GitHub, se habilitado"
echo "4. Reiniciar o deployment $DEPLOYMENT"
echo "5. Aguardar rollout e validar logs do Flyway"

if [[ "$APPLY" != "true" ]]; then
  warn "Dry-run. Nenhuma alteracao foi feita."
  echo "Para aplicar: APPLY=true bash $0"
  unset SECRET_JSON DB_PASSWORD JWT_SECRET
  exit 0
fi

printf '\n%s\n' "===== ATUALIZANDO KUBERNETES SECRET ====="
kubectl create secret generic "$K8S_SECRET" \
  --namespace "$NAMESPACE" \
  --from-literal=DB_USERNAME="$DB_USERNAME" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --dry-run=client \
  --output yaml \
  | kubectl apply -f -

K8S_USERNAME="$(
  kubectl get secret "$K8S_SECRET" \
    --namespace "$NAMESPACE" \
    --output jsonpath='{.data.DB_USERNAME}' \
    | base64 --decode
)"

[[ "$K8S_USERNAME" == "$DB_USERNAME" ]] || fail "Usuario aplicado no Kubernetes nao coincide com o segredo RDS"
ok "Kubernetes Secret atualizado"

if [[ "$UPDATE_GITHUB" == "true" ]]; then
  printf '\n%s\n' "===== ATUALIZANDO GITHUB SECRETS ====="
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI nao autenticada"
  if [[ -z "$GH_REPO" ]]; then
    GH_REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
  fi

  printf '%s' "$DB_USERNAME" | gh secret set DB_USERNAME --repo "$GH_REPO"
  printf '%s' "$DB_PASSWORD" | gh secret set DB_PASSWORD --repo "$GH_REPO"
  ok "DB_USERNAME e DB_PASSWORD atualizados em $GH_REPO"
fi

printf '\n%s\n' "===== REINICIANDO APLICACAO ====="
kubectl rollout restart deployment/"$DEPLOYMENT" --namespace "$NAMESPACE"

if ! kubectl rollout status deployment/"$DEPLOYMENT" \
  --namespace "$NAMESPACE" \
  --timeout="$ROLLOUT_TIMEOUT"; then
  warn "Rollout nao concluiu. Coletando diagnostico."
  kubectl get pods --namespace "$NAMESPACE" --output wide || true
  kubectl describe deployment "$DEPLOYMENT" --namespace "$NAMESPACE" || true
  kubectl logs deployment/"$DEPLOYMENT" --namespace "$NAMESPACE" --tail=200 || true
  fail "Rollout falhou"
fi
ok "Rollout concluido"

printf '\n%s\n' "===== VALIDANDO PODS ====="
kubectl get pods --namespace "$NAMESPACE" --selector app=oficina360-api --output wide

READY_REPLICAS="$(
  kubectl get deployment "$DEPLOYMENT" \
    --namespace "$NAMESPACE" \
    --output jsonpath='{.status.readyReplicas}'
)"
[[ "${READY_REPLICAS:-0}" -ge 1 ]] || fail "Deployment sem replicas prontas"
ok "Deployment possui ${READY_REPLICAS} replica(s) pronta(s)"

printf '\n%s\n' "===== LOGS DA APLICACAO ====="
LOGS="$(
  kubectl logs deployment/"$DEPLOYMENT" \
    --namespace "$NAMESPACE" \
    --tail=300 2>&1
)"
printf '%s\n' "$LOGS"

if grep -qi 'password authentication failed' <<< "$LOGS"; then
  fail "Senha ainda rejeitada pelo PostgreSQL"
fi
if grep -qi 'Connect timed out' <<< "$LOGS"; then
  fail "Conectividade com o RDS ainda apresenta timeout"
fi
if grep -qiE 'Flyway.*failed|Unable to obtain connection from database' <<< "$LOGS"; then
  fail "Flyway ainda nao conseguiu conectar ao banco"
fi

if grep -qiE 'Successfully applied|Successfully validated|Schema .* is up to date|Started Oficina360Application' <<< "$LOGS"; then
  ok "Aplicacao iniciou e Flyway nao apresenta erro de conexao"
else
  warn "Nao foi encontrada mensagem conclusiva do Flyway; confira os logs acima"
fi

printf '\n%s\n' "===== VALIDACAO FINAL ====="
kubectl get deployment,pod,service --namespace "$NAMESPACE" --output wide

unset SECRET_JSON DB_PASSWORD JWT_SECRET

ok "Sincronizacao concluida"
echo "Relatorio: $REPORT"
echo "Proximo passo: testar novamente o endpoint da Lambda."
