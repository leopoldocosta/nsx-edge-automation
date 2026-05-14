#!/usr/bin/env bash
# nsx_sb_main.sh - Orchestrator: Phase 1 (request SB) + Phase 2 (verify every 5 min)
# Recommended: run inside screen or tmux (~35 min total)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
need_cmd sshpass
load_ips
ask_admin_creds
ask_root_creds

RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"

# ---- PHASE 1: Enable root SSH + Request Support Bundle ----
log "=== PHASE 1: Support Bundle Request ==="
for ip in "${EDGE_IPS[@]}"; do
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n'     "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Phase 1 done. Waiting for bundles to generate..."

# ---- PHASE 2: Verify every 5 min, up to 30 min (6 rounds) ----
log "=== PHASE 2: Verification ==="
declare -A NODE_DONE
for ip in "${EDGE_IPS[@]}"; do NODE_DONE["$ip"]="false"; done

for ((round=1; round<=6; round++)); do
  log "Check ${round}/6 — sleeping 5 min..."
  sleep 300
  for ip in "${EDGE_IPS[@]}"; do
    [[ "${NODE_DONE[$ip]}" == "true" ]] && continue
    OUT="$(check_support_bundle "$ip" || true)"
    if grep -qiE 'error|fail|unable|denied' <<< "$OUT"; then
      log_err  "${ip}: error detected — stopping checks for this node."
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
for ip in "${EDGE_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

log_ok "Done. Status CSV: ${STATUS_CSV}"
prompt_clear_creds
