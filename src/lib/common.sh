#!/usr/bin/env bash
# common.sh - Shared functions for NSX Edge Support Bundle Automation
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src"
LOG_DIR="${BASE_DIR}/logs"
RUN_DIR="${BASE_DIR}/run"
KEY_DIR="${BASE_DIR}/.ssh_keys"
EDGE_FILE="${BASE_DIR}/edge_nodes.txt"
ADMIN_KEY="${KEY_DIR}/nsx_admin_key"
ROOT_KEY="${KEY_DIR}/nsx_root_key"
mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${KEY_DIR}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }

collect_ips(){
  : > "${EDGE_FILE}"
  echo "Paste Edge Node IPs below, one per line. Press ENTER on empty line to finish:"
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    [[ "$line" =~ ^# ]] && continue
    [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$line" >> "${EDGE_FILE}"
  done
}

load_ips(){
  [[ -s "${EDGE_FILE}" ]] || collect_ips
  mapfile -t EDGE_IPS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${EDGE_FILE}")
  [[ ${#EDGE_IPS[@]} -gt 0 ]] || { echo "No valid IPs found." >&2; exit 1; }
}

ask_admin_creds(){
  read -rp "Admin username [admin]: " NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  read -rsp "Admin password: " NSX_PASS; echo
  export NSX_USER NSX_PASS
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER || true
}

ssh_admin(){
  local ip="$1"; shift
  if [[ -f "${ADMIN_KEY}" ]]; then
    ssh -i "${ADMIN_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -o BatchMode=yes "admin@${ip}" "$@"
  else
    sshpass -p "${NSX_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 "${NSX_USER}@${ip}" "$@"
  fi
}

ssh_root(){
  local ip="$1"; shift
  if [[ -f "${ROOT_KEY}" ]]; then
    ssh -i "${ROOT_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -o BatchMode=yes "root@${ip}" "$@"
  else
    sshpass -p "${ROOT_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 "root@${ip}" "$@"
  fi
}

admin_cmd(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>&1; }
root_cmd(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>&1; }

# === Adjust the NSX CLI commands below to match your NSX version ===

enable_root_ssh(){
  local ip="$1"
  admin_cmd "$ip" 'set service ssh enabled; start service ssh; set service ssh root-login enabled' || true
}

disable_root_ssh(){
  local ip="$1"
  admin_cmd "$ip" 'set service ssh root-login disabled' || true
}

request_support_bundle(){
  local ip="$1"
  admin_cmd "$ip" 'get support-bundle status; start support-bundle' \
    || admin_cmd "$ip" 'start support-bundle' || true
}

check_support_bundle(){
  local ip="$1"
  local out1 out2 out3
  out1="$(root_cmd "$ip" "test -f /var/log/support_bundle && tail -50 /var/log/support_bundle || echo FILE_NOT_FOUND")"
  out2="$(root_cmd "$ip" "find /var/log /storage /tmp -maxdepth 3 \( -name '*support*bundle*' -o -name '*.tgz' -o -name '*.tar.gz' \) -type f 2>/dev/null | head -20")"
  out3="$(root_cmd "$ip" "getent passwd root >/dev/null 2>&1; echo ROOT_OK")"
  printf '%s\n----FILES----\n%s\n----ROOT----\n%s\n' "$out1" "$out2" "$out3"
}
