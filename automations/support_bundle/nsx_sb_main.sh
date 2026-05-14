#!/usr/bin/env bash
# nsx_sb_main.sh - Orchestrator: Phase 0 (pre-check) + Phase 1 (request SB) + Phase 2 (verify every 5 min)
# Recommended: run inside screen or tmux (~35 min total)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
load_ips
[[ -f "${ADMIN_KEY}" ]] || ask_admin_creds

RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"

EXPIRY_EPOCH="$(( $(date +%s) + 1800 ))"

# Auto-clear session credential file after 30 min
auto_clear_bg(){
  ( while [[ "$(date +%s)" -lt "$1" ]]; do sleep 5; done
    rm -f "${RUN_DIR}/session.env" 2>/dev/null || true
  ) >/dev/null 2>&1 &
}
if [[ -n "${NSX_PASS:-}" ]]; then
  umask 077
  printf 'export NSX_USER=%q\nexport NSX_PASS=%q\n' "${NSX_USER}" "${NSX_PASS}" > "${RUN_DIR}/session.env"
  auto_clear_bg "$EXPIRY_EPOCH"
fi

# ---------------------------------------------------------------------------
# PHASE 0: Pre-check — detecta bundle em andamento ou tentativa recente
# ---------------------------------------------------------------------------
log "=== PHASE 0: Pre-check de Support Bundle ==="

declare -A PRECHECK_STATUS   # por IP: none | running | recent | error | partial
declare -A PRECHECK_DETAIL   # resumo legivel por IP

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: verificando estado do support bundle..."
  precheck_status="none"
  precheck_detail="Nenhuma geracao detectada."

  # --- 1. Verifica via admin CLI se ha processo em andamento ---
  admin_out="$(admin_cmd "$ip" 'get support-bundle status' 2>/dev/null || echo 'CMD_FAILED')"
  if echo "$admin_out" | grep -qiE 'in.progress|running|generating|started'; then
    precheck_status="running"
    precheck_detail="Admin CLI indica geracao EM ANDAMENTO."
  fi

  # --- 2. Verifica via root /var/log/support_bundle ---
  enable_root_ssh "$ip"
  sleep 2
  root_out="$(root_cmd "$ip" \
    "test -f /var/log/support_bundle && tail -30 /var/log/support_bundle || echo FILE_NOT_FOUND" \
    2>/dev/null || echo 'CMD_FAILED')"
  disable_root_ssh "$ip" || true

  if echo "$root_out" | grep -q 'FILE_NOT_FOUND'; then
    root_summary="Log /var/log/support_bundle nao encontrado."
  elif echo "$root_out" | grep -q 'CMD_FAILED'; then
    root_summary="Nao foi possivel acessar root SSH."
  else
    last_line="$(echo "$root_out" | grep -v '^[[:space:]]*$' | tail -1)"
    root_summary="Ultima entrada no log: ${last_line}"

    if echo "$root_out" | grep -qiE 'complete|generated|success|bundle saved'; then
      if [[ "$precheck_status" != "running" ]]; then
        precheck_status="recent"
        precheck_detail="Bundle gerado recentemente detectado no log. ${root_summary}"
      fi
    fi

    if echo "$root_out" | grep -qiE 'error|fail|unable|denied'; then
      if [[ "$precheck_status" == "none" ]]; then
        precheck_status="error"
        precheck_detail="Erro detectado no log de bundle anterior. ${root_summary}"
      fi
    fi

    if [[ "$precheck_status" == "none" ]]; then
      precheck_status="partial"
      precheck_detail="Log existente mas sem status conclusivo. ${root_summary}"
    fi
  fi

  PRECHECK_STATUS["$ip"]="$precheck_status"
  PRECHECK_DETAIL["$ip"]="$precheck_detail"
  printf '%s,phase0,%s,%q,%s\n' "$ip" "$precheck_status" "$precheck_detail" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

# --- Exibe resumo do pre-check ---
echo ""
echo "========================================="
echo " RESUMO DO PRE-CHECK"
echo "========================================="
for ip in "${EDGE_IPS[@]}"; do
  status="${PRECHECK_STATUS[$ip]}"
  detail="${PRECHECK_DETAIL[$ip]}"
  case "$status" in
    running)  label="[EM ANDAMENTO] " ;;
    recent)   label="[RECENTE/OK]   " ;;
    error)    label="[ERRO ANTERIOR]" ;;
    partial)  label="[INDETERMINADO]" ;;
    none)     label="[LIMPO]        " ;;
    *)        label="[DESCONHECIDO] " ;;
  esac
  printf '  %s  %s  --  %s\n' "$label" "$ip" "$detail"
done
echo "========================================="
echo ""
echo "Como deseja prosseguir?"
echo "  [S] Skip nos ja concluidos ou em andamento, solicitar apenas nos LIMPO/ERRO/INDETERMINADO"
echo "  [F] Forcar novo bundle em TODOS os nos (ignora pre-check)"
echo "  [A] Abortar"
echo ""
read -rp 'Escolha [S/F/A]: ' CHOICE
echo ""

case "${CHOICE^^}" in
  S)
    NODES_TO_REQUEST=()
    for ip in "${EDGE_IPS[@]}"; do
      case "${PRECHECK_STATUS[$ip]}" in
        running|recent)
          log_warn "${ip}: pulando (${PRECHECK_STATUS[$ip]})."
          printf '%s,phase0,skipped,pre-check skip,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
          ;;
        *)
          NODES_TO_REQUEST+=("$ip")
          ;;
      esac
    done
    ;;
  F)
    log_warn "Forcando novo bundle em todos os nos."
    NODES_TO_REQUEST=("${EDGE_IPS[@]}")
    ;;
  A)
    log "Abortado pelo usuario."
    exit 0
    ;;
  *)
    log_err "Opcao invalida. Abortando."
    exit 1
    ;;
esac

if [[ ${#NODES_TO_REQUEST[@]} -eq 0 ]]; then
  log_ok "Nenhum no necessita de novo bundle. Encerrando."
  exit 0
fi

log "Nos selecionados para solicitacao: ${NODES_TO_REQUEST[*]}"

# ---- PHASE 1: Enable root SSH + Request Support Bundle ----
log "=== PHASE 1: Support Bundle Request ==="
for ip in "${NODES_TO_REQUEST[@]}"; do
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n'     "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Phase 1 done. Waiting for bundles to generate..."

# ---- PHASE 2: Verify every 5 min, up to 30 min (6 rounds) ----
log "=== PHASE 2: Verification ==="
declare -A NODE_DONE
for ip in "${NODES_TO_REQUEST[@]}"; do NODE_DONE["$ip"]="false"; done

for ((round=1; round<=6; round++)); do
  log "Check ${round}/6 -- sleeping 5 min..."
  sleep 300
  for ip in "${NODES_TO_REQUEST[@]}"; do
    [[ "${NODE_DONE[$ip]}" == "true" ]] && continue
    OUT="$(check_support_bundle "$ip" || true)"
    if grep -qiE 'error|fail|unable|denied' <<< "$OUT"; then
      log_err  "${ip}: error detected -- stopping checks for this node."
      printf '%s,phase2,error,%q,%s\n'   "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    elif grep -qiE 'complete|generated|success' <<< "$OUT" && ! grep -q 'FILE_NOT_FOUND' <<< "$OUT"; then
      log_ok   "${ip}: bundle confirmed."
      printf '%s,phase2,success,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    else
      log_warn "${ip}: still pending..."
      printf '%s,phase2,pending,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
  done
done

# ---- FINAL: Disable root SSH on all nodes ----
log "=== FINAL: Disabling root SSH ==="
for ip in "${NODES_TO_REQUEST[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

clear_creds
rm -f "${RUN_DIR}/session.env" 2>/dev/null || true
log_ok "Done. Status CSV: ${STATUS_CSV}"
