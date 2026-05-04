#!/usr/bin/env bash
# setup_keys.sh - Generate Ed25519 SSH keys and distribute to each Edge Node
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh-keygen
need_cmd sshpass
load_ips
ask_admin_creds

[[ -f "${ADMIN_KEY}" ]] || ssh-keygen -t ed25519 -f "${ADMIN_KEY}" -N '' -C 'nsx-admin-key' -q
[[ -f "${ROOT_KEY}" ]]  || ssh-keygen -t ed25519 -f "${ROOT_KEY}"  -N '' -C 'nsx-root-key'  -q

ADMIN_PUB="$(cat "${ADMIN_KEY}.pub")"
ROOT_PUB="$(cat "${ROOT_KEY}.pub")"

for ip in "${EDGE_IPS[@]}"; do
  log "Distributing keys to ${ip}..."
  admin_cmd "$ip" "set user admin ssh-key \"${ADMIN_PUB}\"" || true
  enable_root_ssh "$ip"
  admin_cmd "$ip" "set user root ssh-key \"${ROOT_PUB}\""  || true
  disable_root_ssh "$ip"
  log_ok "${ip}: keys distributed."
done

clear_creds
log_ok "SSH key setup complete."
