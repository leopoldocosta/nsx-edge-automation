#!/usr/bin/env bash
# =============================================================================
# nsx_ssh_cli.sh
# CLI interativo para envio de comandos SSH aos Edge Nodes NSX.
#
# Modos:
#   1. Comando unico  — digita um comando, executa, encerra
#   2. Sessao        — loop interativo, multiplos comandos, "exit" para sair
#
# Usuarios suportados: admin (NSX-T CLI) e root (Linux shell)
# Historico de comandos salvo em logs/cli_history_<data>.log
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
load_ips

clear
echo "================================================================"
echo " NSX Edge — CLI Interativo via SSH"
echo "================================================================"
echo " Nos disponiveis:"
for i in "${!EDGE_IPS[@]}"; do
  printf '   [%2d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"
done
echo "   [A ] Todos os nos (broadcast)"
echo "================================================================"
echo ""

read -rp "Selecione o no (numero ou A): " SEL
echo ""

if [[ "${SEL^^}" == "A" ]]; then
  TARGET_IPS=("${EDGE_IPS[@]}")
  TARGET_LABEL="TODOS"
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#EDGE_IPS[@]} )); then
  TARGET_IPS=("${EDGE_IPS[$((SEL-1))]}")
  TARGET_LABEL="${TARGET_IPS[0]}"
else
  echo "[ERROR] Selecao invalida."; exit 1
fi

echo "Usuario SSH:"
echo "  [1] admin  (NSX-T CLI)"
echo "  [2] root   (Linux shell)"
echo ""
read -rp "Selecione (1 ou 2): " USR_SEL

USE_ROOT=false
case "${USR_SEL}" in
  1)
    USER_LABEL="admin"
    [[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
    ;;
  2)
    USER_LABEL="root"
    USE_ROOT=true
    [[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
    [[ -f "${ROOT_KEY}" ]]  || ask_root_creds
    ;;
  *) echo "[ERROR] Opcao invalida."; exit 1 ;;
esac

echo ""
echo "Modo:"
echo "  [1] Comando unico  (executa e encerra)"
echo "  [2] Sessao         (multiplos comandos ate digitar 'exit')"
echo ""
read -rp "Selecione (1 ou 2): " MODE_SEL

HISTORY_FILE="${LOG_DIR}/cli_history_$(date +%Y%m%d).log"

log_cmd(){
  local ip="$1" user="$2" cmd="$3" output="$4"
  printf '\n[%s] user=%s ip=%s\nCMD: %s\nOUT:\n%s\n%s\n' \
    "$(date '+%F %T')" "$user" "$ip" "$cmd" "$output" \
    '----------------------------------------------------------------' \
    >> "${HISTORY_FILE}"
}

exec_on_targets(){
  local cmd="$1"
  for ip in "${TARGET_IPS[@]}"; do
    echo ""
    echo "  ===== ${USER_LABEL}@${ip} ====="
    local out
    if [[ "${USE_ROOT}" == "true" ]]; then
      enable_root_ssh "$ip" >/dev/null 2>&1 || true
      sleep 1
      out="$(root_cmd "$ip" "$cmd" 2>&1 || true)"
      disable_root_ssh "$ip" >/dev/null 2>&1 || true
    else
      out="$(admin_cmd "$ip" "$cmd" 2>&1 || true)"
    fi
    echo "${out}"
    log_cmd "$ip" "${USER_LABEL}" "$cmd" "$out"
  done
  echo ""
}

if [[ "${MODE_SEL}" == "1" ]]; then
  echo ""
  echo "--- Comando Unico | ${USER_LABEL} | ${TARGET_LABEL} ---"
  echo ""
  read -rp "Comando: " CMD
  [[ -z "$CMD" ]] && { echo "Nenhum comando informado."; clear_creds; exit 0; }
  exec_on_targets "$CMD"
  echo "  Historico: ${HISTORY_FILE}"
  clear_creds
  exit 0
fi

echo ""
echo "================================================================"
echo " SESSAO INTERATIVA"
echo " Usuario  : ${USER_LABEL}"
echo " Alvo     : ${TARGET_LABEL}"
echo " Historico: ${HISTORY_FILE}"
echo " Comandos internos: exit | nos | historico"
echo "================================================================"
echo ""

while true; do
  printf "[nsx-cli][%s@%s]\$ " "${USER_LABEL}" "${TARGET_LABEL}"
  IFS= read -r CMD || break
  case "${CMD,,}" in
    exit|quit)    echo "Encerrando sessao."; break ;;
    nos|nodes)    echo "  Nos: ${TARGET_IPS[*]}"; continue ;;
    historico|history) tail -n 60 "${HISTORY_FILE}" 2>/dev/null || echo "  Vazio."; continue ;;
    "")           continue ;;
  esac
  exec_on_targets "${CMD}"
done

clear_creds
echo ""
echo "Sessao encerrada. Historico: ${HISTORY_FILE}"
