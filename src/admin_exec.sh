#!/usr/bin/env bash
# admin_exec.sh - Run any NSX-T CLI command as admin on selected or all Edge Nodes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

load_ips
[[ -f "${ADMIN_KEY}" ]] || ask_admin_creds

echo ""
echo "Available Edge Nodes:"
for i in "${!EDGE_IPS[@]}"; do
  printf '  [%d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"
done
echo "  [A] All nodes"
echo ""
read -rp 'Select node (number or A): ' SEL
read -rp 'NSX-T admin CLI command: ' CMD
echo ""

run(){
  local ip="$1"
  echo "===== admin@${ip} ====="
  admin_cmd "$ip" "$CMD" || true
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
