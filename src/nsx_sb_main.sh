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

# ---- PHASE 1: Enable root SSH + Request Support Bundle ----
log "=== PHASE 1: Support Bundle Request ==="
for ip in "${EDGE_IPS[@]}"; do
  log "Processing ${ip}..."
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Phase 1 complete. Waiting for bundles to generate..."

# ---- PHASE 2: Verify every 5 min for up to 30 min ----
# Detecção dupla:
#   1. grep por 'Support bundle saved to:' em /var/log/support_bundle (sinal real)
#   2. confirmação de existência do .tgz em /var/vmware/nsx/file-store/
log "=== PHASE 2: Support Bundle Verification ==="
declare -A NODE_DONE
declare -A NODE_BUNDLE_PATH
for ip in "${EDGE_IPS[@]}"; do
  NODE_DONE["$ip"]="false"
  NODE_BUNDLE_PATH["$ip"]=""
done

for ((i=1;i<=6;i++)); do
  log "Verificação ${i}/6 — aguardando 5 min..."
  sleep 300
  for ip in "${EDGE_IPS[@]}"; do
    [[ "${NODE_DONE[$ip]}" == "true" ]] && continue

    OUT="$(check_support_bundle "$ip" || echo 'CHECK_ERROR')"

    case "$OUT" in
      SUCCESS:*)
        BPATH="${OUT#SUCCESS:}"
        NODE_BUNDLE_PATH["$ip"]="$BPATH"
        log "[OK] ${ip}: bundle confirmado em ${BPATH}"
        printf '%s,phase2,success,%q,%s\n' "$ip" "$BPATH" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
        NODE_DONE["$ip"]="true"
        ;;
      PENDING)
        log "[WARN] ${ip}: ainda pendente..."
        printf '%s,phase2,pending,log_sem_conclusao,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
        ;;
      LOG_NOT_FOUND)
        log "[WARN] ${ip}: /var/log/support_bundle não encontrado — bundle ainda não iniciou ou caminho diferente."
        printf '%s,phase2,pending,log_not_found,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
        ;;
      FILE_NOT_FOUND)
        log "[WARN] ${ip}: log indica conclusão mas .tgz ausente no file-store — possível race condition, re-verificando na próxima rodada."
        printf '%s,phase2,pending,file_not_found_yet,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
        ;;
      CHECK_ERROR)
        log "[ERROR] ${ip}: falha ao conectar via SSH durante verificação."
        printf '%s,phase2,error,ssh_check_failed,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
        NODE_DONE["$ip"]="true"
        ;;
      *)
        log "[ERROR] ${ip}: resposta inesperada — ${OUT}"
        printf '%s,phase2,error,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
        NODE_DONE["$ip"]="true"
        ;;
    esac
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
log "Execução concluída. Status CSV: $STATUS_CSV"

# ---- PÓS-EXECUÇÃO: verificar se há bundles antigos e oferecer limpeza ----
log "=== Verificando bundles no file-store de cada node ==="
HAS_OLD_BUNDLES="false"
for ip in "${EDGE_IPS[@]}"; do
  # Reabilita root SSH temporariamente só para listar
  enable_root_ssh "$ip" 2>/dev/null || true
  BUNDLES="$(list_old_bundles "$ip" || echo 'NONE')"
  disable_root_ssh "$ip" 2>/dev/null || true

  COUNT="$(echo "$BUNDLES" | grep -vc '^$\|^NONE' || true)"
  if [[ "$COUNT" -gt 0 ]]; then
    HAS_OLD_BUNDLES="true"
    log "${ip}: ${COUNT} bundle(s) encontrado(s):"
    echo "$BUNDLES" | while IFS= read -r line; do
      [[ -n "$line" ]] && echo "    ${line}"
    done
  fi
done

if [[ "$HAS_OLD_BUNDLES" == "true" ]]; then
  echo ""
  echo "================================================================"
  echo "  Foram encontrados support bundles no file-store dos edge nodes."
  echo "  Bundles antigos consomem espaço em disco (cada um ~1-3 GB)."
  echo "================================================================"
  read -rp "  Deseja executar o módulo de limpeza agora? [s/N]: " RUN_CLEANUP
  if [[ "${RUN_CLEANUP,,}" == "s" ]]; then
    bash "${SCRIPT_DIR}/sb_cleanup.sh"
  else
    log "Limpeza ignorada. Execute manualmente: bash src/sb_cleanup.sh"
  fi
fi
