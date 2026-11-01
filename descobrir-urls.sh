#!/usr/bin/env bash
set -Eeuo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-oficina360}"
KONG_NAMESPACE="${KONG_NAMESPACE:-kong}"
GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-observability}"
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

fail() {
  printf '[ERRO] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[INFO] %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 nao encontrado."
}

require_command aws
require_command kubectl
require_command jq

configure_kubeconfig() {
  local context=""
  local clusters_text=""
  local cluster_name=""
  local cluster_count=0

  if [[ -s "$KUBECONFIG" ]]; then
    context="$(kubectl config current-context 2>/dev/null || true)"
  fi

  if [[ -n "$context" ]] && kubectl --request-timeout=10s auth can-i get services --all-namespaces >/dev/null 2>&1; then
    info "Acesso Kubernetes ja configurado."
    return 0
  fi

  info "Kubeconfig ausente ou invalido. Descobrindo o cluster EKS atual..."

  clusters_text="$(
    aws eks list-clusters \
      --region "$AWS_REGION" \
      --query 'clusters[]' \
      --output text 2>/dev/null || true
  )"

  mapfile -t clusters < <(
    tr '\t' '\n' <<< "$clusters_text" |
      sed '/^[[:space:]]*$/d'
  )

  cluster_count="${#clusters[@]}"
  (( cluster_count > 0 )) || fail "Nenhum cluster EKS encontrado em $AWS_REGION."

  for candidate in "${clusters[@]}"; do
    if [[ "$candidate" == "$PROJECT_NAME" ]]; then
      cluster_name="$candidate"
      break
    fi
  done

  if [[ -z "$cluster_name" && "$cluster_count" -eq 1 ]]; then
    cluster_name="${clusters[0]}"
  fi

  [[ -n "$cluster_name" ]] || fail "Mais de um cluster encontrado e nenhum corresponde a $PROJECT_NAME."

  status="$(
    aws eks describe-cluster \
      --name "$cluster_name" \
      --region "$AWS_REGION" \
      --query 'cluster.status' \
      --output text
  )"

  [[ "$status" == "ACTIVE" ]] || fail "O cluster EKS selecionado nao esta ACTIVE."

  mkdir -p "$(dirname "$KUBECONFIG")"
  rm -f "$KUBECONFIG"
  export KUBECONFIG

  aws eks update-kubeconfig \
    --name "$cluster_name" \
    --region "$AWS_REGION" \
    --alias oficina360 \
    --kubeconfig "$KUBECONFIG" \
    >/dev/null

  [[ -s "$KUBECONFIG" ]] || fail "O kubeconfig nao foi criado."

  kubectl --request-timeout=20s auth can-i get services --all-namespaces >/dev/null 2>&1 ||
    fail "O kubeconfig foi criado, mas nao foi possivel acessar o cluster."

  info "Acesso Kubernetes configurado."
}

find_load_balancer_service() {
  local namespace="$1"
  local preferred_name="$2"
  local service_name=""

  if kubectl get service "$preferred_name" --namespace "$namespace" >/dev/null 2>&1; then
    printf '%s\n' "$preferred_name"
    return 0
  fi

  service_name="$(
    kubectl get services \
      --namespace "$namespace" \
      --output json |
      jq -r '[.items[] | select(.spec.type == "LoadBalancer") | .metadata.name][0] // empty'
  )"

  [[ -n "$service_name" ]] || return 1
  printf '%s\n' "$service_name"
}

resolve_service_url() {
  local namespace="$1"
  local preferred_name="$2"
  local preferred_protocol="$3"
  local service_name=""
  local service_json=""
  local address=""
  local port=""
  local protocol="$preferred_protocol"

  service_name="$(find_load_balancer_service "$namespace" "$preferred_name")" ||
    fail "Nenhum Service LoadBalancer encontrado no namespace $namespace."

  for attempt in $(seq 1 30); do
    service_json="$(kubectl get service "$service_name" --namespace "$namespace" --output json)"

    address="$(
      jq -r '.status.loadBalancer.ingress[0].hostname // .status.loadBalancer.ingress[0].ip // empty' \
        <<< "$service_json"
    )"

    [[ -n "$address" ]] && break

    if [[ "$attempt" -lt 30 ]]; then
      info "Aguardando o endereco externo de $service_name ($attempt/30)..."
      sleep 10
    fi
  done

  [[ -n "$address" ]] || fail "O LoadBalancer de $service_name ainda nao recebeu endereco externo."

  port="$(
    jq -r '[
      .spec.ports[]
      | select(
          (.name // "" | test("proxy|http|service"; "i")) or
          .port == 80 or
          .port == 443
        )
      | .port
    ][0] // .spec.ports[0].port' <<< "$service_json"
  )"

  if [[ "$port" == "443" ]]; then
    protocol="https"
  fi

  if [[ "$protocol" == "https" && "$port" == "443" ]]; then
    printf 'https://%s\n' "$address"
  elif [[ "$protocol" == "http" && "$port" == "80" ]]; then
    printf 'http://%s\n' "$address"
  else
    printf '%s://%s:%s\n' "$protocol" "$address" "$port"
  fi
}

configure_kubeconfig

KONG_URL="$(resolve_service_url "$KONG_NAMESPACE" "kong-kong-proxy" "http")"
GRAFANA_URL="$(resolve_service_url "$GRAFANA_NAMESPACE" "grafana" "http")"

echo
echo "===== URLS ATUAIS ====="
echo "Kong:    $KONG_URL"
echo "Grafana: $GRAFANA_URL"
