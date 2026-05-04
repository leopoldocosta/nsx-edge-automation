#!/usr/bin/env bash
# lib/common.sh
# Shared library for all NSX Edge automations.
# Provides: SSH access (admin + root), IP loading, credential handling.
#
# Usage in any automation script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../../lib/common.sh"
set -euo pipefail

# Resolve LIB_DIR and derive BASE_DIR (repo root = two levels above lib/)
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${LIB_DIR}/.." && pwd)"

# Caller automation dir (overridden by each script before sourcing if needed)
AUTO_DIR="${AUTO_DIR:-$(pwd)}"

LOG_DIR="${AUTO_DIR}/logs"
RUN_DIR="${AUTO_DIR}/run"
KEY_DIR="${AUTO_DIR}/.ssh_keys"
EDGE_FILE="${AUTO_DIR}/edge_nodes.txt"
EDGE_EXAMPLE="${AUTO_DIR}/edge_nodes.example"
ADMIN_KEY="${KEY_DIR}/nsx_admin_key"
ROOT_KEY="${KEY_DIR}/nsx_root_key"

mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${KEY_DIR}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
log_ok(){   log "[OK]   $*"; }
log_warn(){ log "[WARN] $*"; }
log_err(){  log "[ERR]  $*"; }

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
need_cmd(){
  command -v "$1" >/dev/null 2>&1 || {
    log_err "Missing required command: $1"
    exit 1
  }
}

# ---------------------------------------------------------------------------
# IP Management
# IP file lives in the automation's own directory (edge_nodes.txt).
# Never versioned. Template: edge_nodes.example
# ---------------------------------------------------------------------------
collect_ips(){
  if [[ -f "${EDGE_EXAMPLE}" ]]; then
    echo "Template available: ${EDGE_EXAMPLE}"
    echo "  Copy with: cp edge_nodes.example edge_nodes.txt, then edit."
    echo "  Or paste IPs directly below."
  fi
  echo ""
  echo "Paste Edge Node IPs, one per line. Empty line to finish:"
  : > "${EDGE_FILE}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    [[ "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$line" >> "${EDGE_FILE}"
    else
      log_warn "Skipping invalid entry: ${line}"
    fi
  done
  local count
  count=$(wc -l < "${EDGE_FILE}" | tr -d ' ')
  log "${count} IP(s) saved to ${EDGE_FILE}"
}

load_ips(){
  if [[ ! -s "${EDGE_FILE}" ]]; then
    log_warn "${EDGE_FILE} not found or empty."
    collect_ips
  fi
  mapfile -t EDGE_IPS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${EDGE_FILE}" 2>/dev/null || true)
  if [[ ${#EDGE_IPS[@]} -eq 0 ]]; then
    log_err "No valid IPs found in ${EDGE_FILE}."
    exit 1
  fi
  log "Loaded ${#EDGE_IPS[@]} Edge Node(s): ${EDGE_IPS[*]}"
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
ask_admin_creds(){
  read -rp "Admin username [admin]: " NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  read -rsp "Admin password: " NSX_PASS; echo
  export NSX_USER NSX_PASS
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER 2>/dev/null || true
  log "Credentials cleared from memory."
}

# ---------------------------------------------------------------------------
# SSH Functions
# ---------------------------------------------------------------------------
ssh_admin(){
  local ip="$1"; shift
  if [[ -f "${ADMIN_KEY}" ]]; then
    ssh -i "${ADMIN_KEY}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o BatchMode=yes \
        "admin@${ip}" "$@"
  else
    sshpass -p "${NSX_PASS}" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "${NSX_USER}@${ip}" "$@"
  fi
}

ssh_root(){
  local ip="$1"; shift
  if [[ -f "${ROOT_KEY}" ]]; then
    ssh -i "${ROOT_KEY}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o BatchMode=yes \
        "root@${ip}" "$@"
  else
    sshpass -p "${ROOT_PASS}" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "root@${ip}" "$@"
  fi
}

admin_cmd(){
  local ip="$1" cmd="$2"
  ssh_admin "$ip" "$cmd" 2>&1
}

root_cmd(){
  local ip="$1" cmd="$2"
  ssh_root "$ip" "$cmd" 2>&1
}

# ---------------------------------------------------------------------------
# Root SSH Control
# Adjust these commands to match your NSX version CLI.
# ---------------------------------------------------------------------------
enable_root_ssh(){
  local ip="$1"
  log "${ip}: enabling root SSH..."
  admin_cmd "$ip" 'set service ssh enabled; start service ssh; set service ssh root-login enabled' || true
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: disabling root SSH..."
  admin_cmd "$ip" 'set service ssh root-login disabled' || true
}

# ---------------------------------------------------------------------------
# Support Bundle (specific to support_bundle automation — kept here for reuse)
# Adjust paths and commands as needed for your NSX version.
# ---------------------------------------------------------------------------
request_support_bundle(){
  local ip="$1"
  admin_cmd "$ip" 'get support-bundle status; start support-bundle' \
    || admin_cmd "$ip" 'start support-bundle' || true
}

check_support_bundle(){
  local ip="$1"
  local out_log out_files out_root
  out_log="$(root_cmd "$ip" \
    "test -f /var/log/support_bundle && tail -50 /var/log/support_bundle || echo FILE_NOT_FOUND")"
  out_files="$(root_cmd "$ip" \
    "find /var/log /storage /tmp -maxdepth 3 \( -name '*support*bundle*' -o -name '*.tgz' -o -name '*.tar.gz' \) -type f 2>/dev/null | head -20")"
  out_root="$(root_cmd "$ip" "getent passwd root >/dev/null 2>&1; echo ROOT_OK")"
  printf '%s\n----FILES----\n%s\n----ROOT----\n%s\n' "$out_log" "$out_files" "$out_root"
}
