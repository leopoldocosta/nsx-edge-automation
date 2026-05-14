#!/usr/bin/env bash
# lib/common.sh
# Shared library for all NSX Edge automations.
# Provides: SSH access (admin + root), IP loading, credential handling.
#
# Authentication: always sshpass (password-based). No SSH key logic.
#
# Credential persistence: when user chooses NOT to clear credentials,
# they are saved to a tmpfs session file (/dev/shm or /tmp) with mode 600.
# The file is removed by clear_creds or when the session is explicitly cleared.
#
# Known hosts: uses a persistent per-UID file in /tmp so the
# "Permanently added ... to known hosts" warning is suppressed on
# subsequent connections to the same IPs.
#
# Usage in any automation script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   export AUTO_DIR="${SCRIPT_DIR}"
#   source "${SCRIPT_DIR}/../../lib/common.sh"
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${LIB_DIR}/.." && pwd)"

AUTO_DIR="${AUTO_DIR:-$(pwd)}"

LOG_DIR="${AUTO_DIR}/logs"
RUN_DIR="${AUTO_DIR}/run"
EDGE_FILE="${AUTO_DIR}/edge_nodes.txt"
EDGE_EXAMPLE="${AUTO_DIR}/edge_nodes.example"

mkdir -p "${LOG_DIR}" "${RUN_DIR}"

# ---------------------------------------------------------------------------
# Session credential file — stored in tmpfs (memory only, never on disk)
# ---------------------------------------------------------------------------
_CRED_DIR="/tmp"
[[ -d "/dev/shm" ]] && _CRED_DIR="/dev/shm"
_CRED_FILE="${_CRED_DIR}/.nsx_session_${UID}"

# ---------------------------------------------------------------------------
# Persistent known_hosts file — suppresses repeated "Permanently added" warnings
# ---------------------------------------------------------------------------
_KNOWN_HOSTS="/tmp/.nsx_known_hosts_${UID}"
touch "${_KNOWN_HOSTS}" 2>/dev/null && chmod 600 "${_KNOWN_HOSTS}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log(){      printf '[%s] %s\n'        "$(date '+%F %T')" "$*"; }
log_ok(){   printf '[%s] [OK]   %s\n' "$(date '+%F %T')" "$*"; }
log_warn(){ printf '[%s] [WARN] %s\n' "$(date '+%F %T')" "$*"; }
log_err(){  printf '[%s] [ERR]  %s\n' "$(date '+%F %T')" "$*"; }

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
# ---------------------------------------------------------------------------
collect_ips(){
  if [[ -f "${EDGE_EXAMPLE}" ]]; then
    echo "  Template available: ${EDGE_EXAMPLE}"
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
# Session file helpers — tmpfs only (memory, never disk)
# ---------------------------------------------------------------------------
_save_creds(){
  (
    umask 177
    printf 'NSX_USER=%s\n'  "${NSX_USER:-}"  > "${_CRED_FILE}"
    printf 'NSX_PASS=%s\n'  "${NSX_PASS:-}"  >> "${_CRED_FILE}"
    printf 'ROOT_PASS=%s\n' "${ROOT_PASS:-}" >> "${_CRED_FILE}"
  )
  chmod 600 "${_CRED_FILE}"
}

_load_creds(){
  [[ -f "${_CRED_FILE}" ]] || return 1
  local file_uid
  file_uid="$(stat -c '%u' "${_CRED_FILE}" 2>/dev/null \
           || stat -f '%u' "${_CRED_FILE}" 2>/dev/null \
           || echo -1)"
  [[ "${file_uid}" == "${UID}" ]] || return 1
  local key val
  while IFS= read -r _line; do
    [[ -z "${_line}" || "${_line}" =~ ^# ]] && continue
    key="${_line%%=*}"
    val="${_line#*=}"
    case "${key}" in
      NSX_USER)  export NSX_USER="${val}"  ;;
      NSX_PASS)  export NSX_PASS="${val}"  ;;
      ROOT_PASS) export ROOT_PASS="${val}" ;;
    esac
  done < "${_CRED_FILE}"
  return 0
}

_remove_cred_file(){
  [[ -f "${_CRED_FILE}" ]] && rm -f "${_CRED_FILE}" || true
}

# ---------------------------------------------------------------------------
# Credentials
# Collected interactively ONCE per session and reused for all nodes.
# Passwords stored in memory only (session file in /dev/shm, never on disk).
# ---------------------------------------------------------------------------
ask_admin_creds(){
  # 1. Already in environment (same process tree)
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials already in environment (user: '${NSX_USER:-admin}'). Skipping prompt."
    return 0
  fi
  # 2. Try session file (set by a previous script run)
  if _load_creds 2>/dev/null; then
    if [[ -n "${NSX_PASS:-}" ]]; then
      log "Admin credentials loaded from session file (user: '${NSX_USER:-admin}'). Skipping prompt."
      return 0
    fi
  fi
  # 3. Interactive prompt
  read -rp  "Usuário admin [admin]: " NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  IFS= read -rsp "Senha admin (todos os caracteres especiais aceitos): " NSX_PASS; echo
  export NSX_USER NSX_PASS
  log "Credenciais coletadas para o usuário '${NSX_USER}'. Serão reutilizadas em todos os nós."
}

ask_root_creds(){
  # 1. Already in environment
  if [[ -n "${ROOT_PASS:-}" ]]; then
    log "Root credentials already in environment. Skipping prompt."
    return 0
  fi
  # 2. Try session file
  if _load_creds 2>/dev/null; then
    if [[ -n "${ROOT_PASS:-}" ]]; then
      log "Root credentials loaded from session file. Skipping prompt."
      return 0
    fi
  fi
  # 3. Interactive prompt
  IFS= read -rsp "Senha root (todos os caracteres especiais aceitos): " ROOT_PASS; echo
  export ROOT_PASS
  log "Root credentials collected. Will be reused for all nodes."
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER 2>/dev/null || true
  _remove_cred_file
  [[ -f "${_KNOWN_HOSTS}" ]] && rm -f "${_KNOWN_HOSTS}" || true
  log "Credentials cleared from memory, session file and known_hosts removed."
}

prompt_clear_creds(){
  echo ""
  read -rp "Limpar credenciais da memória? [S/n]: " _CLR
  if [[ "${_CLR,,}" == "n" ]]; then
    _save_creds
    log "Credenciais mantidas na sessão (${_CRED_FILE})."
  else
    clear_creds
  fi
}

# ---------------------------------------------------------------------------
# SSH Functions — always password-based via sshpass
# _KNOWN_HOSTS is a persistent per-UID file so "Permanently added" warnings
# only appear the very first time each IP is seen. Subsequent calls are silent.
# StrictHostKeyChecking=accept-new: auto-accept unknown hosts, never re-prompt.
# ---------------------------------------------------------------------------
ssh_admin(){
  local ip="$1"; shift
  export SSHPASS="${NSX_PASS}"
  sshpass -e ssh \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="${_KNOWN_HOSTS}" \
      -o ConnectTimeout=15 \
      "${NSX_USER}@${ip}" "$@"
  local _rc=$?
  unset SSHPASS
  return $_rc
}

ssh_root(){
  local ip="$1"; shift
  export SSHPASS="${ROOT_PASS}"
  sshpass -e ssh \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="${_KNOWN_HOSTS}" \
      -o ConnectTimeout=15 \
      "root@${ip}" "$@"
  local _rc=$?
  unset SSHPASS
  return $_rc
}

admin_cmd(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>&1; }
root_cmd(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>&1; }

# ---------------------------------------------------------------------------
# Root SSH Control
# ---------------------------------------------------------------------------
enable_root_ssh(){
  local ip="$1"
  log "${ip}: enabling root SSH..."
  log "${ip}: >> set ssh root-login"
  admin_cmd "$ip" 'set ssh root-login' || true
  log "${ip}: >> get service ssh"
  admin_cmd "$ip" 'get service ssh' || true
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: disabling root SSH..."
  log "${ip}: >> clear ssh root-login"
  admin_cmd "$ip" 'clear ssh root-login' || true
  log "${ip}: >> get service ssh"
  admin_cmd "$ip" 'get service ssh' || true
}

# ---------------------------------------------------------------------------
# Support Bundle helpers
# ---------------------------------------------------------------------------
request_support_bundle(){
  local ip="$1"
  local fname="sb_${ip//./_}_$(date +%Y%m%d_%H%M%S).tgz"
  log "${ip}: >> get support-bundle file ${fname} log-age 1"
  admin_cmd "$ip" "get support-bundle file ${fname} log-age 1" || true
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
