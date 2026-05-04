#!/usr/bin/env bash
# test_connections.sh - Validates connectivity, admin login, root login, and disables root SSH at end
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

need_cmd ssh
load_ips

if [[ ! -f "${ADMIN_KEY}" ]]; then
  need_cmd sshpass
  ask_admin_creds
fi

REPORT="${LOG_DIR}/test_$(date +%Y%m%d_%H%M%S).log"

for ip in "${EDGE_IPS[@]}"; do
  {
    echo "===== ${ip} ====="

    echo "-- [1] Ping --"
    ping -c 1 -W 2 "$ip" 2>&1 || echo "WARN: ping failed"

    echo "-- [2] admin: get version --"
    admin_cmd "$ip" 'get version' || echo "FAIL"

    echo "-- [3] admin: get service ssh --"
    admin_cmd "$ip" 'get service ssh' || echo "FAIL"

    echo "-- [4] admin: get managers --"
    admin_cmd "$ip" 'get managers' || echo "FAIL"

    echo "-- [5] enable root SSH --"
    enable_root_ssh "$ip"
    sleep 2

    if [[ ! -f "${ROOT_KEY}" ]]; then
      read -rsp "Root password for ${ip}: " ROOT_PASS; echo
      export ROOT_PASS
    fi

    echo "-- [6] root: uname -a --"
    root_cmd "$ip" 'uname -a' || echo "FAIL"

    echo "-- [7] root: uptime --"
    root_cmd "$ip" 'uptime' || echo "FAIL"

    echo "-- [8] root: df -h /var/log --"
    root_cmd "$ip" 'df -h /var/log' || echo "FAIL"

    echo "-- [9] root: support_bundle log presence --"
    root_cmd "$ip" 'ls -lh /var/log/support_bundle 2>/dev/null || echo FILE_NOT_FOUND' || echo "FAIL"

    echo "-- [10] disable root SSH --"
    disable_root_ssh "$ip"

    unset ROOT_PASS || true
    echo
  } | tee -a "$REPORT"
done

clear_creds
log "Test complete. Report: $REPORT"
