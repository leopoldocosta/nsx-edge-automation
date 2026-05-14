#!/usr/bin/env bash
# nsx_sb_main.sh - Orchestrator: Phase 1 (request SB) + Phase 2 (verify every 5 min)
# Recommended: run inside screen or tmux (~35 min total)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
load_ips
[[ -f "${ADMIN_KEY}" ]] || ask_admin_creds
[[ -f "${ROOT_KEY}"  ]] || ask_root_creds

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

# ---- PHASE 1: Enable root SSH + Request Support Bundle ----
log "=== FASE 1: Solicitacao do Support Bundle ==="
for ip in "${EDGE_IPS[@]}"; do
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n'     "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Fase 1 concluida. Aguardando geracao dos bundles (~30 min)..."

# ---- PHASE 2: Verify every 5 min, up to 30 min (6 rounds) ----
log "=== FASE 2: Verificacao ==="
declare -A NODE_DONE
for ip in "${EDGE_IPS[@]}"; do NODE_DONE["$ip"]="false"; done

for ((round=1; round<=6; round++)); do
  log "Verificacao ${round}/6 — aguardando 5 min..."
  sleep 300
  for ip in "${EDGE_IPS[@]}"; do
    [[ "${NODE_DONE[$ip]}" == "true" ]] && continue
    OUT="$(check_support_bundle "$ip" || true)"
    if grep -qiE 'error|fail|unable|denied' <<< "$OUT"; then
      log_err  "${ip}: erro detectado — encerrando verificacoes para este no."
      printf '%s,phase2,error,%q,%s\n'   "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    elif grep -qiE 'complete|generated|success' <<< "$OUT" && ! grep -q 'FILE_NOT_FOUND' <<< "$OUT"; then
      log_ok   "${ip}: bundle confirmado."
      printf '%s,phase2,success,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    else
      log_warn "${ip}: ainda em andamento..."
      printf '%s,phase2,pending,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
  done
  # Sai do loop se todos os nos foram processados
  all_done=true
  for ip in "${EDGE_IPS[@]}"; do
    [[ "${NODE_DONE[$ip]}" == "false" ]] && all_done=false && break
  done
  $all_done && { log "Todos os nos verificados antes do timeout."; break; }
done

# ---- FINAL: Disable root SSH on all nodes ----
log "=== FINAL: Desabilitando root SSH ==="
for ip in "${EDGE_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

clear_creds
rm -f "${RUN_DIR}/session.env" 2>/dev/null || true

# ---- RELATORIO CONSOLIDADO ----
print_final_report "$STATUS_CSV"
log_ok "Concluido. CSV de status: ${STATUS_CSV}"
log_ok "Log de execucao  : ${RUN_LOG}"
