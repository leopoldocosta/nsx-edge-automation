#!/usr/bin/env bash
# root_exec.sh - Run a shell command on all Edge Nodes as root.
# Usage: ./root_exec.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
need_cmd sshpass
load_ips
ask_admin_creds
ask_root_creds

read -rp "Shell command to run on all nodes as root: " SHELL_CMD
[[ -z "${SHELL_CMD}" ]] && { log_err "No command provided."; exit 1; }

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: enabling root SSH..."
  enable_root_ssh "$ip"
  sleep 1

  log "${ip}: >> ${SHELL_CMD}"
  root_cmd "$ip" "${SHELL_CMD}" || log_warn "${ip}: command returned non-zero"

  log "${ip}: disabling root SSH..."
  disable_root_ssh "$ip"
done

prompt_clear_creds
