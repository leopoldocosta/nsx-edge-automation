#!/usr/bin/env bash
# lib/common.sh
# Shared library for all NSX Edge automations.
# Provides: SSH access (admin + root), IP loading, credential handling.
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
KEY_DIR="${AUTO_DIR}/.ssh_keys"
EDGE_FILE="${AUTO_DIR}/edge_nodes.txt"
EDGE_EXAMPLE="${AUTO_DIR}/edge_nodes.example"
ADMIN_KEY="${KEY_DIR}/nsx_admin_key"
ROOT_KEY="${KEY_DIR}/nsx_root_key"

mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${KEY_DIR}"

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
# IPs live in edge_nodes.txt inside each automation's own folder.
# Never committed. Template: edge_nodes.example
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
# Credentials
# Collected ONCE and reused for all nodes.
# ask_admin_creds / ask_root_creds sao no-op se variaveis ja existirem.
# ---------------------------------------------------------------------------
ask_admin_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials already loaded, skipping prompt."
    return 0
  fi
  read -rp  "Admin username [admin]: " NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  IFS= read -rsp "Admin password (all special characters accepted): " NSX_PASS; echo
  export NSX_USER NSX_PASS
  log "Credentials collected for user '${NSX_USER}'. Will be reused for all nodes."
}

ask_root_creds(){
  if [[ -n "${ROOT_PASS:-}" ]]; then
    log "Root credentials already loaded, skipping prompt."
    return 0
  fi
  IFS= read -rsp "Root password (all special characters accepted): " ROOT_PASS; echo
  export ROOT_PASS
  log "Root credentials collected. Will be reused for all nodes."
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER 2>/dev/null || true
  log "Credentials cleared from memory."
}

# ---------------------------------------------------------------------------
# ask_clear_creds
#
# Pergunta ao final de cada script se o usuario deseja limpar as credenciais
# da memoria (NSX_PASS, ROOT_PASS, NSX_USER).
#
# Padrao YES: pressionar Enter limpa e encerra.
# Digitar N/no mantem as credenciais para o proximo script na mesma sessao.
# Qualquer entrada nao reconhecida aplica padrao YES por seguranca.
#
# Uso: adicione ao final de cada script de automacao:
#   ask_clear_creds
# ---------------------------------------------------------------------------
ask_clear_creds(){
  echo ""
  echo "============================================================"
  printf "  Clear credentials from memory? [Y/n] (default: Yes): "
  local _answer
  IFS= read -r _answer
  case "${_answer,,}" in
    ""|y|ye|yes|sim|s)
      clear_creds
      log "Session ended. Credentials removed from memory."
      ;;
    n|no|nao)
      log "Credentials kept in memory for this shell session."
      echo ""
      echo "  You can now run any other script without re-entering credentials:"
      echo "    cd ~/nsx-edge-automation/automations/support_bundle && ./nsx_sb_main.sh"
      echo "    cd ~/nsx-edge-automation/automations/ssh_cli        && ./nsx_ssh_cli.sh"
      echo ""
      ;;
    *)
      log_warn "Unrecognized input '${_answer}' -- defaulting to YES, clearing credentials."
      clear_creds
      ;;
  esac
  echo "============================================================"
  echo ""
}

# ---------------------------------------------------------------------------
# SSH helper: escreve senha em arquivo temporario privado.
# Evita exposicao em argumentos de processo. Funciona com qualquer char especial.
# ---------------------------------------------------------------------------
_sshpass_safe(){
  local _passvar="$1"; shift
  local _pass="${!_passvar}"
  local _tmpfile
  _tmpfile="$(mktemp -t sshpass_XXXXXX)"
  chmod 600 "${_tmpfile}"
  printf '%s' "${_pass}" > "${_tmpfile}"
  SSHPASS="$(cat "${_tmpfile}")" sshpass -e "$@"
  local _rc=$?
  rm -f "${_tmpfile}"
  return $_rc
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
    _sshpass_safe NSX_PASS ssh \
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
    _sshpass_safe ROOT_PASS ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "root@${ip}" "$@"
  fi
}

# Exibe o comando no terminal antes de executar (stderr para nao poluir stdout)
admin_cmd(){
  local ip="$1" cmd="$2"
  printf '[CMD] admin@%s >>> %s\n' "$ip" "$cmd" >&2
  ssh_admin "$ip" "$cmd" 2>&1
}

root_cmd(){
  local ip="$1" cmd="$2"
  printf '[CMD] root@%s >>> %s\n' "$ip" "$cmd" >&2
  ssh_root "$ip" "$cmd" 2>&1
}

# ---------------------------------------------------------------------------
# Root SSH Control -- comandos corretos NSX-T Edge
#
# HABILITAR root login : set ssh root-login
# DESABILITAR root login: clear ssh root-login
# VERIFICAR estado      : get service ssh
#
# IMPORTANTE: NAO usar 'start service ssh' nem 'set service ssh enabled'
# O servico SSH ja esta ativo no Edge Node. Apenas o root-login precisa ser
# habilitado/desabilitado conforme necessidade.
# ---------------------------------------------------------------------------
enable_root_ssh(){
  local ip="$1"
  log "${ip}: enabling root SSH login..."
  admin_cmd "$ip" 'set ssh root-login' || true
  admin_cmd "$ip" 'get service ssh'    || true
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: disabling root SSH login..."
  admin_cmd "$ip" 'clear ssh root-login' || true
  admin_cmd "$ip" 'get service ssh'       || true
}

# ---------------------------------------------------------------------------
# Support Bundle helpers
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
