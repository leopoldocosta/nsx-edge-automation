#!/usr/bin/env bash
# lib/common.sh
# Shared library for all NSX Edge automations.
# Provides: SSH access (admin + root), IP loading, credential handling.
#
# Authentication: always sshpass (password-based). No SSH key logic.
#
# Credential persistence: when user chooses NOT to clear credentials,
# they are saved to a tmpfs session file (/dev/shm or /tmp) with mode 600.
#
# Known hosts: persistent per-UID file in /tmp — "Permanently added"
# warning appears only on first connection to each IP.
#
# stderr isolation: admin_cmd/root_cmd suppress stderr so SSH warnings
# ("Warning: Permanently added ...") never contaminate captured stdout.
# This prevents false-positive bundle detection and spurious WARN alerts.
#
# PRE-CHECK bundle detection (v2.7) — 3-stage logic:
#   Stage 1: check_bundle_log_recent — if support_bundle.log shows a bundle
#            generated within the last 7 days, treat as existing (return 0).
#   Stage 2: check_existing_bundle   — look for .tgz files in file-store or
#            via 'get files' (admin CLI).
#   Stage 3: check_bundle_in_progress — detect an active generation process
#            (napi/python pid running support_bundle collection).
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
# ---------------------------------------------------------------------------
ask_admin_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials already in environment (user: '${NSX_USER:-admin}'). Skipping prompt."
    return 0
  fi
  if _load_creds 2>/dev/null; then
    if [[ -n "${NSX_PASS:-}" ]]; then
      log "Admin credentials loaded from session file (user: '${NSX_USER:-admin}'). Skipping prompt."
      return 0
    fi
  fi
  read -rp  "Usuário admin [admin]: " NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  IFS= read -rsp "Senha admin (todos os caracteres especiais aceitos): " NSX_PASS; echo
  export NSX_USER NSX_PASS
  log "Credenciais coletadas para o usuário '${NSX_USER}'. Serão reutilizadas em todos os nós."
}

ask_root_creds(){
  if [[ -n "${ROOT_PASS:-}" ]]; then
    log "Root credentials already in environment. Skipping prompt."
    return 0
  fi
  if _load_creds 2>/dev/null; then
    if [[ -n "${ROOT_PASS:-}" ]]; then
      log "Root credentials loaded from session file. Skipping prompt."
      return 0
    fi
  fi
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
#
# ssh_admin / ssh_root: raw SSH, stderr goes to terminal (interactive use).
# admin_cmd / root_cmd: capture stdout only; stderr suppressed.
#   This prevents SSH warnings ("Warning: Permanently added ...") from
#   contaminating captured output used for bundle detection / log parsing.
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

# admin_cmd / root_cmd: stdout only, stderr suppressed
# Use these for all programmatic output capture.
admin_cmd(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>/dev/null; }
root_cmd(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>/dev/null; }

# admin_cmd_tty / root_cmd_tty: stdout + stderr to terminal
# Use these when showing live output to the user (enable/disable root SSH logs).
admin_cmd_tty(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>&1; }
root_cmd_tty(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>&1; }

# ---------------------------------------------------------------------------
# Root SSH Control
# Uses *_tty variants so the operator sees live SSH output on the terminal.
# ---------------------------------------------------------------------------
enable_root_ssh(){
  local ip="$1"
  log "${ip}: enabling root SSH..."
  log "${ip}: >> set ssh root-login"
  admin_cmd_tty "$ip" 'set ssh root-login' || true
  log "${ip}: >> get service ssh"
  admin_cmd_tty "$ip" 'get service ssh' || true
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: disabling root SSH..."
  log "${ip}: >> clear ssh root-login"
  admin_cmd_tty "$ip" 'clear ssh root-login' || true
  log "${ip}: >> get service ssh"
  admin_cmd_tty "$ip" 'get service ssh' || true
}

# ---------------------------------------------------------------------------
# check_bundle_log IP
#   Reads /var/log/support_bundle.log on the node (last 10 lines).
#   Uses root_cmd (stderr suppressed) so SSH warnings never appear in output.
#   Returns: 0=ok, 1=errors/warnings found in log, 2=file not found
# ---------------------------------------------------------------------------
check_bundle_log(){
  local ip="$1"
  local log_file="/var/log/support_bundle.log"
  local out

  log "${ip}: lendo ${log_file} (últimas 10 linhas)..."
  out="$(root_cmd "$ip" "test -f ${log_file} && tail -10 ${log_file} || echo '__FILE_NOT_FOUND__'")"

  if grep -q '__FILE_NOT_FOUND__' <<< "$out"; then
    log_warn "${ip}: ${log_file} não encontrado — geração anterior pode não ter ocorrido."
    return 2
  fi

  echo ""
  echo "  ┌─ ${ip}: ${log_file} (últimas 10 linhas) ─────────────────────"
  while IFS= read -r line; do
    echo "  │  ${line}"
  done <<< "$out"
  echo "  └────────────────────────────────────────────────────────────────"
  echo ""

  if grep -qiE 'error|fail|exception|abort|fatal' <<< "$out"; then
    log_warn "${ip}: ATENÇÃO — problemas detectados no log da geração anterior (ver acima)."
    return 1
  fi

  log_ok "${ip}: log da geração anterior sem erros aparentes."
  return 0
}

# ---------------------------------------------------------------------------
# check_bundle_log_recent IP
#   Stage 1 of PRE-CHECK.
#   Scans /var/log/support_bundle.log for a timestamp indicating that a
#   support bundle was successfully generated within the last 7 days.
#   Looks for lines containing date patterns (YYYY-MM-DD) in the last 100
#   lines and compares to the current epoch minus 7 days.
#   Returns:
#     0 — recent bundle found in log (within 7 days)  → treat as existing
#     1 — no recent bundle timestamp found in log     → proceed to Stage 2
#     2 — log file not found on node                  → proceed to Stage 2
# ---------------------------------------------------------------------------
check_bundle_log_recent(){
  local ip="$1"
  local log_file="/var/log/support_bundle.log"

  log "${ip}: [PRE-CHECK Stage 1] verificando geração recente em ${log_file}..."

  local out
  out="$(root_cmd "$ip" "test -f ${log_file} && tail -100 ${log_file} || echo '__FILE_NOT_FOUND__'")"

  if grep -q '__FILE_NOT_FOUND__' <<< "$out"; then
    log_warn "${ip}: ${log_file} não encontrado — avançando para Stage 2."
    return 2
  fi

  # Extract the most recent YYYY-MM-DD timestamp present in the log.
  # support_bundle.log uses lines like: "2026-05-14 20:16:01,685 ..."
  local last_date
  last_date="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' <<< "$out" | tail -1 || true)"

  if [[ -z "$last_date" ]]; then
    log_warn "${ip}: nenhuma data encontrada no log — avançando para Stage 2."
    return 1
  fi

  # Compare dates using epoch seconds (portable: date -d on Linux)
  local log_epoch now_epoch cutoff_epoch
  log_epoch="$(date -d "${last_date}" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  cutoff_epoch=$(( now_epoch - 7 * 86400 ))

  if [[ "$log_epoch" -ge "$cutoff_epoch" ]]; then
    log_ok "${ip}: log indica bundle gerado em ${last_date} (dentro dos últimos 7 dias) — considerando como existente."
    return 0
  else
    log_warn "${ip}: último registro no log é de ${last_date} (mais de 7 dias) — avançando para Stage 2."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# check_existing_bundle IP
#   Stage 2 of PRE-CHECK.
#   Detects existing support bundle .tgz files on the node.
#   Uses admin_cmd/root_cmd (stderr suppressed) so SSH warnings never
#   appear in found_files, preventing false-positive bundle detection.
#   Returns 0 with filenames on stdout if found, 1 otherwise.
# ---------------------------------------------------------------------------
check_existing_bundle(){
  local ip="$1"
  local found_files=""

  # Strategy 1: admin 'get files'
  local admin_out
  admin_out="$(admin_cmd "$ip" 'get files' || true)"
  if [[ -n "$admin_out" ]]; then
    local admin_matches
    admin_matches="$(grep -iE 'support-bundle' <<< "$admin_out" || true)"
    [[ -n "$admin_matches" ]] && found_files="$admin_matches"
  fi

  # Strategy 2: root ls on file-store (glob for support-bundle*.tgz)
  if [[ -z "$found_files" ]]; then
    local root_out
    root_out="$(root_cmd "$ip" \
      'ls /var/vmware/nsx/file-store/support-bundle*.tgz 2>/dev/null || true' || true)"
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

# ---------------------------------------------------------------------------
# check_bundle_in_progress IP
#   Stage 3 of PRE-CHECK.
#   Detects whether a support bundle generation is currently in progress by:
#     a) Checking for active napi/python processes related to support_bundles
#     b) Checking for a partial/incomplete .tgz file in file-store
#   Returns:
#     0 — generation in progress detected
#     1 — no active generation detected
# ---------------------------------------------------------------------------
check_bundle_in_progress(){
  local ip="$1"
  local found=0

  log "${ip}: [PRE-CHECK Stage 3] verificando geração em andamento..."

  # Check a) active process
  local proc_out
  proc_out="$(root_cmd "$ip" \
    "ps aux 2>/dev/null | grep -iE 'support_bundle|support-bundle|napi.*bundle' | grep -v grep || true")"
  if [[ -n "$proc_out" ]]; then
    log_warn "${ip}: processo de geração de support bundle detectado em execução:"
    while IFS= read -r pline; do
      log_warn "${ip}:   ${pline}"
    done <<< "$proc_out"
    found=1
  fi

  # Check b) partial file in file-store (any file modified in the last 30 min)
  local partial_out
  partial_out="$(root_cmd "$ip" \
    "find /var/vmware/nsx/file-store -maxdepth 1 -name 'support-bundle*' -newer /proc/1 -mmin -30 2>/dev/null || true")"
  if [[ -n "$partial_out" ]]; then
    log_warn "${ip}: arquivo de support bundle com escrita recente detectado (possível geração em andamento):"
    while IFS= read -r fline; do
      log_warn "${ip}:   ${fline}"
    done <<< "$partial_out"
    found=1
  fi

  if [[ "$found" -eq 1 ]]; then
    return 0
  fi

  log "${ip}: nenhuma geração em andamento detectada."
  return 1
}

# ---------------------------------------------------------------------------
# prompt_new_bundle IP FILES
# ---------------------------------------------------------------------------
prompt_new_bundle(){
  local ip="$1"
  local files="$2"
  local reply

  echo ""
  echo "  *** Support bundle já existe em ${ip} ***"
  echo "  Arquivos encontrados:"
  while IFS= read -r f; do
    echo "    ${f}"
  done <<< "$files"
  echo ""

  if read -r -t 10 -p "  Gerar um NOVO support bundle para ${ip}? [s/N] (skip automático em 10s): " reply </dev/tty; then
    echo ""
    case "${reply,,}" in
      s|y|sim|yes) return 0 ;;
      *) log "${ip}: Geração de novo bundle cancelada pelo usuário."; return 1 ;;
    esac
  else
    echo ""
    log "${ip}: Sem resposta em 10 segundos — pulando geração de bundle."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Support Bundle helpers
# ---------------------------------------------------------------------------
request_support_bundle(){
  local ip="$1"
  local fname="sb_${ip//./_}_$(date +%Y%m%d_%H%M%S).tgz"
  log "${ip}: >> get support-bundle file ${fname} log-age 1"
  admin_cmd_tty "$ip" "get support-bundle file ${fname} log-age 1" || true
}

check_support_bundle(){
  local ip="$1"
  local out_log out_files out_root
  out_log="$(root_cmd "$ip" \
    "test -f /var/log/support_bundle.log && tail -50 /var/log/support_bundle.log || echo FILE_NOT_FOUND")"
  out_files="$(root_cmd "$ip" \
    "find /var/log /storage /tmp -maxdepth 3 \( -name '*support*bundle*' -o -name '*.tgz' -o -name '*.tar.gz' \) -type f 2>/dev/null | head -20")"
  out_root="$(root_cmd "$ip" "getent passwd root >/dev/null 2>&1; echo ROOT_OK")"
  printf '%s\n----FILES----\n%s\n----ROOT----\n%s\n' "$out_log" "$out_files" "$out_root"
}
