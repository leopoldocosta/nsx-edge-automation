#!/usr/bin/env bash
# root_exec.sh - Run any Linux root command on selected or all Edge Nodes
#                Enables root SSH before execution, disables after.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_ips
[[ -f "${ADMIN_KEY}" ]] || [[ -f "${ROOT_KEY}" ]] || ask_admin_creds

echo ""
echo "Edge Nodes:"
for i in "${!EDGE_IPS[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"; done
echo "  [A] All nodes"
echo ""
read -rp 'Select node (number or A): ' SEL
read -rp 'Linux root command: '         CMD
read -rp '[WARNING] Confirm root execution in production? [y/N]: ' CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Cancelled."; exit 0; }

run(){
  local ip="$1"
  echo "===== root@${ip} ====="
  enable_root_ssh "$ip"; sleep 2
  if [[ -f "${ROOT_KEY}" ]]; then
    root_cmd "$ip" "$CMD" || true
  else
    read -rsp "Root password for ${ip}: " ROOT_PASS; echo; export ROOT_PASS
    root_cmd "$ip" "$CMD" || true
    unset ROOT_PASS 2>/dev/null || true
  fi
  disable_root_ssh "$ip"
  echo
}

if   [[ "${SEL^^}" == "A" ]]; then for ip in "${EDGE_IPS[@]}"; do run "$ip"; done
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#EDGE_IPS[@]} )); then run "${EDGE_IPS[$((SEL-1))]}"
else echo "[ERROR] Invalid selection."; exit 1; fi

clear_creds
