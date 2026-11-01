#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-.}"
ROLE_SCRIPT="${ROLE_SCRIPT:-scripts/resolve-lab-roles.sh}"
WORKFLOW="${WORKFLOW:-.github/workflows/infrastructure-apply.yml}"
APPLY="${APPLY:-false}"
REPORT="${REPORT:-troubleshoot-eks-roles-definitivo.txt}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/oficina360-roles-backup-$(date +%Y%m%d%H%M%S)}"

OK=0; WARN=0; ERR=0; FIXED=0
section(){ printf '\n===== %s =====\n' "$1"; }
ok(){ OK=$((OK+1)); printf '[OK] %s\n' "$1"; }
warn(){ WARN=$((WARN+1)); printf '[AVISO] %s\n' "$1"; }
err(){ ERR=$((ERR+1)); printf '[ERRO] %s\n' "$1"; }
fixed(){ FIXED=$((FIXED+1)); printf '[CORRIGIDO] %s\n' "$1"; }
fail(){ err "$1"; exit 1; }

for cmd in aws jq bash grep python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ERRO] Dependencia ausente: $cmd"; exit 2; }
done

ROOT="$(cd "$ROOT" && pwd)"
cd "$ROOT"
exec > >(tee "$REPORT") 2>&1

section "CONTEXTO"
echo "Repositorio validado."
echo "Modo: $([[ "$APPLY" == "true" ]] && echo APPLY || echo DRY-RUN)"
[[ -f "$ROLE_SCRIPT" ]] || fail "Script de roles ausente"
[[ -f "$WORKFLOW" ]] || fail "Workflow de apply ausente"

section "IDENTIDADE SANITIZADA"
IDENTITY_JSON="$(aws sts get-caller-identity --output json)"
ACCOUNT_ID="$(jq -r '.Account' <<< "$IDENTITY_JSON")"
CALLER_ARN="$(jq -r '.Arn' <<< "$IDENTITY_JSON")"
USER_ID="$(jq -r '.UserId' <<< "$IDENTITY_JSON")"
echo "::add-mask::$ACCOUNT_ID"
echo "::add-mask::$CALLER_ARN"
echo "::add-mask::$USER_ID"
echo "::add-mask::${CALLER_ARN##*/}"
ok "Identidade AWS validada sem imprimir valores"

section "CAUSA RAIZ DO ERRO ATUAL"
if grep -nE 'mask .*configured_name|mask .*arn|echo.*add-mask.*' "$ROLE_SCRIPT" >/tmp/role-mask-lines.txt 2>/dev/null; then
  if grep -q 'CLUSTER_ARN="$(resolve_unique_role' "$ROLE_SCRIPT" && \
     awk '/resolve_unique_role\(\)/,/^}/' "$ROLE_SCRIPT" | grep -qE 'mask |add-mask'; then
    err "O resolver escreve comandos add-mask dentro de uma funcao capturada por command substitution"
    echo "Isso contamina CLUSTER_ARN/NODE_ARN com linhas extras e causa 'role pertence a outra conta'."
  else
    ok "Nenhum add-mask emitido dentro da funcao capturada"
  fi
else
  warn "Nao foi possivel localizar marcadores de mascara no script atual"
fi

section "DESCOBERTA DAS ROLES REAIS"
if ! ROLES_JSON="$(aws iam list-roles --output json 2>/tmp/iam-list-roles-error.txt)"; then
  cat /tmp/iam-list-roles-error.txt >&2
  fail "iam:ListRoles indisponivel; nao e seguro adivinhar ARNs"
fi

ROLE_TOTAL="$(jq '.Roles | length' <<< "$ROLES_JSON")"
echo "Roles consultadas: $ROLE_TOTAL"

CLUSTER_MATCHES="$(jq '[.Roles[] | select(.RoleName | contains("LabEksClusterRole"))] | length' <<< "$ROLES_JSON")"
NODE_MATCHES="$(jq '[.Roles[] | select(.RoleName | contains("LabEksNodeRole"))] | length' <<< "$ROLES_JSON")"
echo "Candidatas cluster role: $CLUSTER_MATCHES"
echo "Candidatas node role: $NODE_MATCHES"
[[ "$CLUSTER_MATCHES" -eq 1 ]] && ok "Uma cluster role atual encontrada" || err "Quantidade inesperada de cluster roles candidatas"
[[ "$NODE_MATCHES" -eq 1 ]] && ok "Uma node role atual encontrada" || err "Quantidade inesperada de node roles candidatas"

if [[ "$CLUSTER_MATCHES" -eq 1 && "$NODE_MATCHES" -eq 1 ]]; then
  CLUSTER_ARN="$(jq -r '.Roles[] | select(.RoleName | contains("LabEksClusterRole")) | .Arn' <<< "$ROLES_JSON")"
  NODE_ARN="$(jq -r '.Roles[] | select(.RoleName | contains("LabEksNodeRole")) | .Arn' <<< "$ROLES_JSON")"
  CLUSTER_NAME="$(jq -r '.Roles[] | select(.RoleName | contains("LabEksClusterRole")) | .RoleName' <<< "$ROLES_JSON")"
  NODE_NAME="$(jq -r '.Roles[] | select(.RoleName | contains("LabEksNodeRole")) | .RoleName' <<< "$ROLES_JSON")"

  echo "::add-mask::$CLUSTER_ARN"
  echo "::add-mask::$NODE_ARN"
  echo "::add-mask::$CLUSTER_NAME"
  echo "::add-mask::$NODE_NAME"

  [[ "$CLUSTER_ARN" == "arn:aws:iam::${ACCOUNT_ID}:role/"* ]] && ok "Cluster role pertence a conta atual" || err "Cluster role pertence a outra conta"
  [[ "$NODE_ARN" == "arn:aws:iam::${ACCOUNT_ID}:role/"* ]] && ok "Node role pertence a conta atual" || err "Node role pertence a outra conta"
  [[ "$CLUSTER_ARN" != "$NODE_ARN" ]] && ok "Roles de cluster e node sao distintas" || err "Roles nao podem ser iguais"

  aws iam get-role --role-name "$CLUSTER_NAME" --query 'Role.Arn' --output text >/dev/null && ok "Cluster role confirmada" || err "Cluster role nao confirmada"
  aws iam get-role --role-name "$NODE_NAME" --query 'Role.Arn' --output text >/dev/null && ok "Node role confirmada" || err "Node role nao confirmada"
fi

section "CORRECAO DO RESOLVER"
if [[ "$APPLY" == "true" ]]; then
  mkdir -p "$BACKUP_DIR"
  cp "$ROLE_SCRIPT" "$BACKUP_DIR/resolve-lab-roles.sh.before"

  cat > "$ROLE_SCRIPT" <<'SCRIPT'
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
SCRIPT

  chmod 700 "$ROLE_SCRIPT"
  fixed "Resolver de roles substituido por versao sem contaminacao de stdout"
else
  warn "Dry-run: o resolver ainda nao foi alterado"
fi

section "VALIDACAO ESTATICA"
bash -n "$ROLE_SCRIPT" && ok "Sintaxe Bash aprovada" || err "Sintaxe Bash invalida"
if awk '/resolve_unique_role\(\)/,/^}/' "$ROLE_SCRIPT" | grep -qE 'add-mask|mask '; then
  err "A funcao resolve_unique_role ainda emite mascara no stdout"
else
  ok "resolve_unique_role emite apenas o ARN"
fi

grep -q 'bash scripts/resolve-lab-roles.sh' "$WORKFLOW" && ok "Workflow usa o resolver correto" || err "Workflow nao usa o resolver"

section "TESTE ISOLADO DO RESOLVER"
if [[ "$APPLY" == "true" ]]; then
  TEMP_ENV="$(mktemp)"
  if GITHUB_ENV="$TEMP_ENV" bash "$ROLE_SCRIPT" >/tmp/resolve-role-test.log 2>&1; then
    grep -q '^TF_VAR_eks_cluster_role_arn=arn:aws:iam::' "$TEMP_ENV" && ok "Cluster ARN exportado corretamente" || err "Cluster ARN nao exportado"
    grep -q '^TF_VAR_eks_node_role_arn=arn:aws:iam::' "$TEMP_ENV" && ok "Node ARN exportado corretamente" || err "Node ARN nao exportado"
    if grep -Eq '^TF_VAR_eks_(cluster|node)_role_arn=.*add-mask' "$TEMP_ENV"; then
      err "Valor exportado ainda esta contaminado"
    else
      ok "Valores exportados nao contem comandos de workflow"
    fi
  else
    cat /tmp/resolve-role-test.log
    err "Teste isolado do resolver falhou"
  fi
  rm -f "$TEMP_ENV"
else
  warn "Teste funcional sera executado apos APPLY=true"
fi

section "RESUMO"
echo "OK=$OK"
echo "CORRIGIDOS=$FIXED"
echo "AVISOS=$WARN"
echo "ERROS=$ERR"
echo "Relatorio=$REPORT"
[[ "$APPLY" == "true" ]] && echo "Backup=$BACKUP_DIR"
if [[ "$APPLY" != "true" ]]; then
  echo "Para corrigir: APPLY=true bash $0 '$ROOT'"
fi
[[ "$ERR" -eq 0 ]]
