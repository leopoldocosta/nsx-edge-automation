#!/usr/bin/env bash
# admin_exec.sh - Run a single NSX CLI command on all Edge Nodes as admin.
# Usage: ./admin_exec.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
need_cmd sshpass
load_ips
ask_admin_creds

read -rp "NSX CLI command to run on all nodes: " NSX_CMD
[[ -z "${NSX_CMD}" ]] && { log_err "No command provided."; exit 1; }

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: >> ${NSX_CMD}"
  admin_cmd "$ip" "${NSX_CMD}" || log_warn "${ip}: command returned non-zero"
done

prompt_clear_creds
