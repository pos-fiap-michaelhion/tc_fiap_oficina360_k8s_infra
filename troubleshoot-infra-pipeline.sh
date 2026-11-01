#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-.}"
TF_DIR="${TF_DIR:-terraform/lab}"
APPLY_WORKFLOW="${APPLY_WORKFLOW:-.github/workflows/infrastructure-apply.yml}"
DESTROY_WORKFLOW="${DESTROY_WORKFLOW:-.github/workflows/infrastructure-destroy.yml}"
APPLY="${APPLY:-false}"
REPORT="${REPORT:-troubleshoot-infra-pipeline-v2.txt}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/oficina360-pipeline-backup-$(date +%Y%m%d%H%M%S)}"

OK=0; WARN=0; ERR=0; FIXED=0
section(){ printf '\n===== %s =====\n' "$1"; }
ok(){ OK=$((OK+1)); printf '[OK] %s\n' "$1"; }
warn(){ WARN=$((WARN+1)); printf '[AVISO] %s\n' "$1"; }
err(){ ERR=$((ERR+1)); printf '[ERRO] %s\n' "$1"; }
fixed(){ FIXED=$((FIXED+1)); printf '[CORRIGIDO] %s\n' "$1"; }

for cmd in terraform python3 bash grep find tar; do
  command -v "$cmd" >/dev/null || { echo "[ERRO] $cmd ausente"; exit 2; }
done

ROOT="$(cd "$ROOT" && pwd)"; cd "$ROOT"
exec > >(tee "$REPORT") 2>&1
[[ -d "$TF_DIR" ]] || { err "Diretorio ausente: $TF_DIR"; exit 1; }
[[ -f "$APPLY_WORKFLOW" ]] || { err "Workflow ausente: $APPLY_WORKFLOW"; exit 1; }

section "BACKUP"
if [[ "$APPLY" == "true" ]]; then
  mkdir -p "$BACKUP_DIR"
  tar --exclude='.terraform' --exclude='.git' -czf "$BACKUP_DIR/before-fix.tar.gz" \
    "$TF_DIR" .github scripts 2>/dev/null || true
  ok "Backup: $BACKUP_DIR/before-fix.tar.gz"
else
  warn "Dry-run: nenhuma alteracao sera feita"
fi

section "LIMPEZA DE CACHE"
if [[ -d "$TF_DIR/.terraform" ]]; then
  if [[ "$APPLY" == "true" ]]; then
    rm -rf "$TF_DIR/.terraform"
    fixed "Cache .terraform removido"
  else
    warn "Aplicacao removera $TF_DIR/.terraform antes da auditoria"
  fi
fi

scan_duplicates() {
  python3 - "$TF_DIR" <<'PY2'
from pathlib import Path
from collections import defaultdict
import re,sys
root=Path(sys.argv[1]); found=defaultdict(list)
pat=re.compile(r'^\s*(resource|data)\s+"([^"]+)"\s+"([^"]+)"\s*\{')
for p in sorted(root.glob('*.tf')):  # somente modulo raiz; nunca .terraform/modules
    for n,line in enumerate(p.read_text(encoding='utf-8').splitlines(),1):
        m=pat.match(line)
        if m: found['.'.join(m.groups())].append(f'{p}:{n}')
dups={k:v for k,v in found.items() if len(v)>1}
for k,v in dups.items():
    print(k)
    for x in v: print('  '+x)
raise SystemExit(1 if dups else 0)
PY2
}

section "DUPLICIDADES DO MODULO RAIZ"
set +e
DUP_OUTPUT="$(scan_duplicates 2>&1)"; DUP_STATUS=$?
set -e
if [[ "$DUP_STATUS" -eq 0 ]]; then
  ok "Nenhum resource/data duplicado no modulo raiz"
else
  echo "$DUP_OUTPUT"
  if grep -q '^resource.aws_security_group.database_access$' <<< "$DUP_OUTPUT" && \
     [[ -f "$TF_DIR/security-group.tf" && -f "$TF_DIR/security-groups.tf" ]] && \
     grep -q 'aws_vpc_security_group_ingress_rule' "$TF_DIR/security-group.tf"; then
    if [[ "$APPLY" == "true" ]]; then
      cp "$TF_DIR/security-groups.tf" "$BACKUP_DIR/security-groups.tf.legacy"
      rm -f "$TF_DIR/security-groups.tf"
      fixed "security-groups.tf legado removido"
    else
      warn "Aplicacao removera security-groups.tf legado"
    fi
  else
    err "Duplicidade ambigua; correcao automatica bloqueada"
  fi
fi

section "ARQUIVOS LEGADOS"
if [[ -f "$TF_DIR/variabels.tf" ]]; then
  if [[ -f "$TF_DIR/variables.tf" ]]; then
    err "variabels.tf e variables.tf coexistem"
  elif [[ "$APPLY" == "true" ]]; then
    mv "$TF_DIR/variabels.tf" "$TF_DIR/variables.tf"; fixed "variabels.tf renomeado"
  else
    warn "Aplicacao renomeara variabels.tf"
  fi
else
  ok "variables.tf consistente"
fi

section "PRIVACIDADE"
# add-mask e atribuicoes capturadas sao seguras; somente impressao direta e marcada.
LEAKS="$(grep -RniE --include='*.yml' --include='*.yaml' --include='*.sh' \
  '^[[:space:]]*aws sts get-caller-identity[[:space:]]*$|echo[[:space:]]+.*(CALLER_ARN|USER_ID|Account:|Caller:|UserId:)|echo[[:space:]]+"?(Cluster role:|Node role:|Backend bucket:)' \
  .github scripts 2>/dev/null | grep -v 'add-mask' || true)"
if [[ -n "$LEAKS" ]]; then
  echo "$LEAKS"; err "Possiveis vazamentos de dados nos logs"
else
  ok "Nenhuma impressao direta de identidade detectada"
fi

if grep -q '::add-mask::\$ACCOUNT_ID' "$APPLY_WORKFLOW" && \
   grep -q 'Identidade AWS validada com sucesso' "$APPLY_WORKFLOW"; then
  ok "Apply mascara identidade AWS"
else
  err "Apply nao possui mascaramento de identidade"
fi

if [[ -f "$DESTROY_WORKFLOW" ]]; then
  if grep -Eq '^[[:space:]]*aws sts get-caller-identity[[:space:]]*$' "$DESTROY_WORKFLOW"; then
    err "Destroy ainda imprime identidade AWS completa"
  else
    ok "Destroy nao imprime identidade completa"
  fi
fi

section "RESILIENCIA"
for f in scripts/resolve-lab-roles.sh scripts/resolve-eks-runtime.sh; do
  if [[ -f "$f" ]] && bash -n "$f"; then ok "$f valido"; else err "$f ausente ou invalido"; fi
done
grep -q 'resolve-lab-roles.sh' "$APPLY_WORKFLOW" && ok "Roles dinamicas habilitadas" || err "Resolver de roles ausente"
grep -q 'resolve-eks-runtime.sh' "$APPLY_WORKFLOW" && ok "EKS dinamico habilitado" || err "Resolver EKS ausente"
! grep -Eq 'EKS_CLUSTER_ENDPOINT|EKS_CLUSTER_CA' "$APPLY_WORKFLOW" && ok "Sem endpoint/CA persistidos" || err "Endpoint/CA persistidos encontrados"
grep -q 'create-bucket' "$APPLY_WORKFLOW" && grep -q 'put-bucket-versioning' "$APPLY_WORKFLOW" && ok "Bootstrap S3 presente" || err "Bootstrap S3 incompleto"

section "TERRAFORM"
if [[ "$APPLY" == "true" ]]; then terraform -chdir="$TF_DIR" fmt -recursive; fixed "terraform fmt aplicado"; fi
terraform -chdir="$TF_DIR" fmt -check -recursive && ok "fmt aprovado" || err "fmt falhou"
rm -rf "$TF_DIR/.terraform"
if terraform -chdir="$TF_DIR" init -backend=false -no-color >/tmp/tf-init.log 2>&1; then ok "init aprovado"; else cat /tmp/tf-init.log; err "init falhou"; fi
if TF_VAR_eks_cluster_role_arn='arn:aws:iam::000000000000:role/LabEksClusterRole' \
   TF_VAR_eks_node_role_arn='arn:aws:iam::000000000000:role/LabEksNodeRole' \
   terraform -chdir="$TF_DIR" validate -no-color >/tmp/tf-validate.log 2>&1; then
  ok "validate aprovado"
else cat /tmp/tf-validate.log; err "validate falhou"; fi

section "YAML"
for wf in "$APPLY_WORKFLOW" "$DESTROY_WORKFLOW"; do
  [[ -f "$wf" ]] || continue
  if python3 - "$wf" <<'PY3'
import sys,yaml
with open(sys.argv[1],encoding='utf-8') as f: d=yaml.safe_load(f)
assert isinstance(d,dict) and 'jobs' in d
PY3
  then ok "$wf valido"; else err "$wf invalido"; fi
done

section "CONSISTENCIA FINAL"
rm -rf "$TF_DIR/.terraform"
set +e
FINAL_DUP="$(scan_duplicates 2>&1)"; FINAL_STATUS=$?
set -e
if [[ "$FINAL_STATUS" -eq 0 ]]; then ok "Sem duplicidades no modulo raiz"; else echo "$FINAL_DUP"; err "Duplicidades restantes"; fi

section "RESUMO"
echo "OK=$OK"; echo "CORRIGIDOS=$FIXED"; echo "AVISOS=$WARN"; echo "ERROS=$ERR"; echo "Relatorio=$REPORT"
[[ "$APPLY" == "true" ]] && echo "Backup=$BACKUP_DIR"
if [[ "$APPLY" != "true" ]]; then echo "Para aplicar: APPLY=true bash $0 '$ROOT'"; fi
[[ "$ERR" -eq 0 ]]
