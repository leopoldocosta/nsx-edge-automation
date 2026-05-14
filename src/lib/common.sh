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

# --------------------------------------------------------------------
# check_existing_bundle IP
#   Returns 0 (bundle found) or 1 (no bundle found).
#   Strategy 1: admin user — 'get files' and look for support-bundle*
#   Strategy 2: root user  — ls /var/vmware/nsx/file-store/support-bundle*
# On success prints the found filenames to stdout.
# --------------------------------------------------------------------
check_existing_bundle(){
  local ip="$1"
  local found_files=""

  # Strategy 1: admin 'get files'
  local admin_out
  admin_out="$(admin_cmd "$ip" 'get files' 2>/dev/null || true)"
  if [[ -n "$admin_out" ]]; then
    local admin_matches
    admin_matches="$(grep -iE 'support-bundle' <<< "$admin_out" || true)"
    [[ -n "$admin_matches" ]] && found_files="$admin_matches"
  fi

  # Strategy 2: root ls on file-store (more reliable when root SSH is already on)
  if [[ -z "$found_files" ]]; then
    local root_out
    root_out="$(root_cmd "$ip" \
      'ls /var/vmware/nsx/file-store/support-bundle* 2>/dev/null || true' 2>/dev/null || true)"
    if [[ -n "$root_out" ]] && ! grep -qiE 'no such file|cannot access' <<< "$root_out"; then
      found_files="$root_out"
    fi
  fi

  if [[ -n "$found_files" ]]; then
    echo "$found_files"
    return 0
  fi
  return 1
}

# --------------------------------------------------------------------
# prompt_new_bundle IP
#   Called when an existing bundle was detected.
#   Asks the user whether to generate a NEW bundle.
#   If no answer within 10 seconds, assumes "no" and skips.
#   Returns 0 to generate, 1 to skip.
# --------------------------------------------------------------------
prompt_new_bundle(){
  local ip="$1"
  local reply
  echo ""
  echo "  *** Support bundle already exists on ${ip} ***"
  echo "  Files found:"
  while IFS= read -r f; do
    echo "    ${f}"
  done <<< "$2"
  echo ""
  # read with 10-second timeout; default = skip (n)
  if read -r -t 10 -p "  Generate a NEW support bundle for ${ip}? [y/N] (auto-skip in 10s): " reply </dev/tty; then
    echo ""
    case "${reply,,}" in
      y|yes) return 0 ;;
      *)     log "${ip}: Skipping bundle generation (user chose no)."; return 1 ;;
    esac
  else
    echo ""
    log "${ip}: No response in 10 seconds — skipping bundle generation."
    return 1
  fi
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
