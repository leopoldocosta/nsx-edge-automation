#!/usr/bin/env bash
# nsx_sb_main.sh — v2.8
# Orchestrator: PRE-CHECK (3-stage) + Phase 1 (request SB)
# Phase 2 (5-min polling) removed — monitoring is done externally.
# Recommended: run inside screen or tmux
#
# PRE-CHECK stages:
#   1. check_bundle_log_recent  — se o log indica bundle gerado nos últimos 7 dias → existe
#   2. check_existing_bundle    — busca .tgz em file-store ou via 'get files'
#   3. check_bundle_in_progress — detecta processo ou arquivo parcial em andamento
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

# ---- PRE-CHECK: 3-stage bundle detection ----
log "=== PRE-CHECK: Verificando log e bundles existentes ==="
declare -A SKIP_SB
for ip in "${EDGE_IPS[@]}"; do
  SKIP_SB["$ip"]="false"
done

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando PRE-CHECK..."
  enable_root_ssh "$ip"

  # Exibe o log (informação ao operador) — retorno usado apenas para CSV
  log_rc=0
  check_bundle_log "$ip" || log_rc=$?
  case "$log_rc" in
    0) printf '%s,precheck,bundle_log,ok,%s\n'           "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV" ;;
    1) printf '%s,precheck,bundle_log,warn_errors,%s\n'  "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV" ;;
    2) printf '%s,precheck,bundle_log,not_found,%s\n'    "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV" ;;
  esac

  # ------------------------------------------------------------------
  # Stage 1: log recente (7 dias) → considera bundle como existente
  # ------------------------------------------------------------------
  recent_rc=0
  check_bundle_log_recent "$ip" || recent_rc=$?

  if [[ "$recent_rc" -eq 0 ]]; then
    log "${ip}: [Stage 1] bundle recente detectado no log — verificando se usuário quer gerar novo."
    printf '%s,precheck,stage1_log_recent,found,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    existing_label="[log recente ≤ 7 dias]"
    if ! prompt_new_bundle "$ip" "${existing_label}"; then
      SKIP_SB["$ip"]="true"
      printf '%s,precheck,existing_bundle,skipped_log_recent,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    else
      log "${ip}: usuário solicitou novo bundle — prosseguindo."
      printf '%s,precheck,existing_bundle,new_requested,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
    continue
  fi

  # ------------------------------------------------------------------
  # Stage 2: buscar arquivo .tgz em file-store / 'get files'
  # ------------------------------------------------------------------
  existing_files=""
  if existing_files="$(check_existing_bundle "$ip")"; then
    log "${ip}: [Stage 2] bundle(s) existente(s) encontrado(s) em file-store."
    printf '%s,precheck,stage2_filestore,found,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    if ! prompt_new_bundle "$ip" "$existing_files"; then
      SKIP_SB["$ip"]="true"
      printf '%s,precheck,existing_bundle,skipped,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    else
      log "${ip}: usuário solicitou novo bundle — prosseguindo."
      printf '%s,precheck,existing_bundle,new_requested,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
    continue
  fi

  # ------------------------------------------------------------------
  # Stage 3: verificar se há geração em andamento
  # ------------------------------------------------------------------
  if check_bundle_in_progress "$ip"; then
    log_warn "${ip}: [Stage 3] geração de bundle já está em andamento — pulando solicitação."
    printf '%s,precheck,stage3_in_progress,detected,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    SKIP_SB["$ip"]="true"
    continue
  fi

  # Nenhum bundle detectado em nenhum dos 3 estágios — gerar novo
  log "${ip}: nenhum bundle existente ou em andamento — será gerado."
  printf '%s,precheck,existing_bundle,none,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

# ---- PHASE 1: Enable root SSH + Request Support Bundle ----
log "=== PHASE 1: Support Bundle Request ==="
for ip in "${EDGE_IPS[@]}"; do
  if [[ "${SKIP_SB[$ip]}" == "true" ]]; then
    log "${ip}: pulando solicitação (bundle existente ou em andamento)."
    continue
  fi
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n'     "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Phase 1 done. Bundles requested — monitoring is done externally."

# ---- FINAL: Disable root SSH on all nodes ----
log "=== FINAL: Disabling root SSH ==="
for ip in "${EDGE_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

log_ok "Done. Status CSV: ${STATUS_CSV}"
prompt_clear_creds
