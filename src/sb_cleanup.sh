#!/usr/bin/env bash
# sb_cleanup.sh - Remove support bundles antigos do file-store dos edge nodes
# Pode ser chamado pelo nsx_sb_main.sh ou executado manualmente.
# Uso: bash src/sb_cleanup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

need_cmd ssh
load_ips

[[ -f "${ADMIN_KEY}" ]] || ask_admin_creds

RUN_LOG="${LOG_DIR}/sb_cleanup_$(date +%Y%m%d_%H%M%S).log"
log "=== Módulo de Limpeza de Support Bundles ==="
log "Log: ${RUN_LOG}"

for ip in "${EDGE_IPS[@]}"; do
  log "--- ${ip} ---"

  # Reabilita root SSH para poder listar e deletar
  enable_root_ssh "$ip" 2>/dev/null || true

  # Lista bundles presentes
  BUNDLES="$(list_old_bundles "$ip" || echo 'NONE')"

  if [[ "$BUNDLES" == "NONE" ]] || [[ -z "$(echo "$BUNDLES" | grep -v '^$' || true)" ]]; then
    log "${ip}: nenhum bundle encontrado. Nada a fazer."
    disable_root_ssh "$ip" 2>/dev/null || true
    continue
  fi

  echo ""
  echo "  Bundles encontrados em ${ip}:"
  echo "  --------------------------------------------------"
  mapfile -t BUNDLE_LINES < <(echo "$BUNDLES" | grep -v '^$')
  for idx in "${!BUNDLE_LINES[@]}"; do
    echo "  [$(( idx+1 ))] ${BUNDLE_LINES[$idx]}"
  done
  echo "  --------------------------------------------------"
  echo "  Opções:"
  echo "    a  — remover TODOS os bundles listados"
  echo "    n  — não remover nenhum (pular este node)"
  echo "    ou informe os números separados por espaço (ex: 1 3)"
  echo ""
  read -rp "  Sua escolha para ${ip}: " CHOICE

  if [[ "${CHOICE,,}" == "n" ]]; then
    log "${ip}: limpeza ignorada pelo operador."
    disable_root_ssh "$ip" 2>/dev/null || true
    continue
  fi

  # Monta lista de índices a remover
  declare -a TO_DELETE=()
  if [[ "${CHOICE,,}" == "a" ]]; then
    for idx in "${!BUNDLE_LINES[@]}"; do
      TO_DELETE+=("$idx")
    done
  else
    for num in $CHOICE; do
      if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#BUNDLE_LINES[@]} )); then
        TO_DELETE+=("$(( num-1 ))")
      else
        log "[WARN] ${ip}: índice inválido ignorado: '${num}'"
      fi
    done
  fi

  # Executa as remoções
  for idx in "${TO_DELETE[@]}"; do
    # Extrai caminho (último campo da linha de listagem)
    BPATH="$(echo "${BUNDLE_LINES[$idx]}" | awk '{print $NF}')"
    if [[ -z "$BPATH" ]]; then
      log "[WARN] ${ip}: não foi possível extrair caminho do bundle na linha ${idx}. Pulando."
      continue
    fi
    log "${ip}: removendo ${BPATH}..."
    RESULT="$(delete_bundle "$ip" "$BPATH" || echo DELETE_FAILED)"
    if [[ "$RESULT" == "DELETED" ]]; then
      log "${ip}: [OK] ${BPATH} removido."
      printf '%s,cleanup,deleted,%s,%s\n' "$ip" "$BPATH" "$(date +%F_%T)" >> "$RUN_LOG"
    else
      log "${ip}: [ERROR] falha ao remover ${BPATH} — ${RESULT}"
      printf '%s,cleanup,error,%s,%s\n' "$ip" "$BPATH" "$(date +%F_%T)" >> "$RUN_LOG"
    fi
  done

  disable_root_ssh "$ip" 2>/dev/null || true
done

log "=== Limpeza concluída. Log: ${RUN_LOG} ==="
