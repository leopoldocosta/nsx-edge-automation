#!/usr/bin/env bash
# root_exec.sh - Run any Linux command as root on selected or all Edge Nodes
#                Enables root SSH before, disables after each node.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

load_ips
if [[ ! -f "${ADMIN_KEY}" && ! -f "${ROOT_KEY}" ]]; then
  ask_admin_creds
fi

echo ""
echo "Available Edge Nodes:"
for i in "${!EDGE_IPS[@]}"; do
  printf '  [%d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"
done
echo "  [A] All nodes"
echo ""
read -rp 'Select node (number or A): ' SEL
read -rp 'Linux root command to execute: ' CMD
echo ""
read -rp '[WARNING] Root command will run in production. Confirm? [y/N]: ' CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Cancelled."; exit 0; }

run(){
  local ip="$1"
  echo "===== root@${ip} ====="
  enable_root_ssh "$ip"
  sleep 2
  if [[ -f "${ROOT_KEY}" ]]; then
    root_cmd "$ip" "$CMD" || true
  else
    read -rsp "Root password for ${ip}: " ROOT_PASS; echo
    export ROOT_PASS
    root_cmd "$ip" "$CMD" || true
    unset ROOT_PASS || true
  fi
  disable_root_ssh "$ip"
  echo
}

if [[ "${SEL^^}" == "A" ]]; then
  for ip in "${EDGE_IPS[@]}"; do run "$ip"; done
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#EDGE_IPS[@]} )); then
  run "${EDGE_IPS[$((SEL-1))]}"
else
  echo "[ERROR] Invalid selection."; exit 1
fi

clear_creds
