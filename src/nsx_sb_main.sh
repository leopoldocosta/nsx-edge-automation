#!/usr/bin/env bash
# nsx_sb_main.sh - Main orchestrator: Phase 1 (request SB) + Phase 2 (verify SB)
# Recommended: run inside screen or tmux (takes ~35 minutes)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

need_cmd ssh
need_cmd date
load_ips

[[ -f "${ADMIN_KEY}" ]] || ask_admin_creds

RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"

EXPIRY_EPOCH="$(( $(date +%s) + 1800 ))"

# Background job: clears session credential file after 30 min
auto_clear_creds_bg(){
  ( while [[ "$(date +%s)" -lt "$1" ]]; do sleep 5; done
    rm -f "${RUN_DIR}/session.env" 2>/dev/null || true
  ) >/dev/null 2>&1 &
}

if [[ -n "${NSX_PASS:-}" ]]; then
  umask 077
  printf 'export NSX_USER=%q\nexport NSX_PASS=%q\n' "${NSX_USER}" "${NSX_PASS}" > "${RUN_DIR}/session.env"
  auto_clear_creds_bg "$EXPIRY_EPOCH"
fi

# ---- PRE-CHECK: Detect existing support bundles before Phase 1 ----
log "=== PRE-CHECK: Searching for existing support bundles ==="
declare -A SKIP_SB
for ip in "${EDGE_IPS[@]}"; do
  SKIP_SB["$ip"]="false"
done

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: checking for existing support bundle..."
  # enable_root_ssh is needed so Strategy 2 (root ls) is available
  enable_root_ssh "$ip"
  existing_files=""
  if existing_files="$(check_existing_bundle "$ip")"; then
    log "${ip}: existing bundle(s) found."
    if ! prompt_new_bundle "$ip" "$existing_files"; then
      SKIP_SB["$ip"]="true"
      printf '%s,precheck,skipped,existing_bundle_kept,%s\n' "$ip" "$(date +%F_%T)" \
        | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    else
      log "${ip}: user requested a new bundle — will proceed."
      printf '%s,precheck,new_requested,ok,%s\n' "$ip" "$(date +%F_%T)" \
        | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
  else
    log "${ip}: no existing bundle found — will generate."
    printf '%s,precheck,no_existing_bundle,ok,%s\n' "$ip" "$(date +%F_%T)" \
      | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  fi
done

# ---- PHASE 1: Enable root SSH + Request Support Bundle ----
log "=== PHASE 1: Support Bundle Request ==="
for ip in "${EDGE_IPS[@]}"; do
  if [[ "${SKIP_SB[$ip]}" == "true" ]]; then
    log "${ip}: skipping bundle request (existing bundle kept)."
    continue
  fi
  log "Processing ${ip}..."
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Phase 1 complete. Waiting for bundles to generate..."

# ---- PHASE 2: Verify every 5 min for up to 30 min ----
log "=== PHASE 2: Support Bundle Verification ==="
declare -A NODE_DONE
for ip in "${EDGE_IPS[@]}"; do
  # Nodes that were skipped are already done
  if [[ "${SKIP_SB[$ip]}" == "true" ]]; then
    NODE_DONE["$ip"]="true"
  else
    NODE_DONE["$ip"]="false"
  fi
done

for ((i=1;i<=6;i++)); do
  log "Check round ${i}/6 — waiting 5 min..."
  sleep 300
  for ip in "${EDGE_IPS[@]}"; do
    [[ "${NODE_DONE[$ip]}" == "true" ]] && continue
    OUT="$(check_support_bundle "$ip" || true)"
    if grep -qiE 'error|fail|unable|denied' <<< "$OUT"; then
      log "${ip}: ERROR detected."
      printf '%s,phase2,error,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    elif grep -qiE 'complete|generated|success' <<< "$OUT" && ! grep -q 'FILE_NOT_FOUND' <<< "$OUT"; then
      log "${ip}: SUCCESS — bundle confirmed."
      printf '%s,phase2,success,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    else
      log "${ip}: still pending..."
      printf '%s,phase2,pending,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
  done
done

# ---- FINAL: Disable root SSH on all nodes ----
log "=== FINAL: Disabling root SSH on all nodes ==="
for ip in "${EDGE_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

clear_creds
rm -f "${RUN_DIR}/session.env" 2>/dev/null || true
log "Execution complete. Status CSV: $STATUS_CSV"
