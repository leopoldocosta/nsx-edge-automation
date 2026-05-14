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
# Passwords are stored internally as raw strings (read -r).
# When passed to sshpass, they are written to a temp file (fd) to avoid
# shell word-splitting and to handle any special characters safely.
# Collected ONCE and reused for all nodes.
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
# SSH helper: write password to a private temp file, pass via SSHPASS env var.
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

admin_cmd(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>&1; }
root_cmd(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>&1; }

# ---------------------------------------------------------------------------
# Root SSH Control
# Comandos corretos NSX Edge CLI:
#   Habilitar : set ssh root-login   + get service ssh  (validacao)
#   Desabilitar: clear ssh root-login + get service ssh  (validacao)
# ---------------------------------------------------------------------------
enable_root_ssh(){
  local ip="$1"
  log "${ip}: enabling root SSH..."
  admin_cmd "$ip" 'set ssh root-login' || true
  admin_cmd "$ip" 'get service ssh'    || true
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: disabling root SSH..."
  admin_cmd "$ip" 'clear ssh root-login' || true
  admin_cmd "$ip" 'get service ssh'      || true
}

# ---------------------------------------------------------------------------
# Support Bundle helpers
#
# request_support_bundle:
#   Comando correto NSX Edge CLI (admin):
#     get support-bundle file <filename> log-age 1 all
#   Usa log-age 1 (1 dia) conforme padrao do ambiente.
#   Nome do arquivo inclui IP e timestamp para identificacao.
#
# check_support_bundle:
#   Via admin : get files  -- lista arquivos gerados no node
#   Via root  : tail -30 /var/log/support_bundle  -- status de geracao
#   Retorna bloco formatado para consolidacao no relatorio final.
# ---------------------------------------------------------------------------
request_support_bundle(){
  local ip="$1"
  local fname
  fname="support-bundle-${ip//\./-}-$(date +%Y%m%d_%H%M%S).tgz"
  log "${ip}: requesting support bundle (log-age 1 day) -> ${fname}"
  admin_cmd "$ip" "get support-bundle file ${fname} log-age 1 all" || true
}

check_support_bundle(){
  local ip="$1"
  local out_files out_log

  # Via admin: lista arquivos presentes no node
  out_files="$(admin_cmd "$ip" 'get files' || echo 'ADMIN_CMD_FAILED')"

  # Via root: verifica log de geracao do support bundle
  out_log="$(root_cmd "$ip" \
    'if [ -f /var/log/support_bundle ]; then
       echo "=== /var/log/support_bundle (ultimas 30 linhas) ===";
       tail -30 /var/log/support_bundle;
     else
       echo "FILE_NOT_FOUND: /var/log/support_bundle nao existe";
     fi' \
    || echo 'ROOT_CMD_FAILED')"

  printf '=== %s: get files ===\n%s\n\n=== %s: /var/log/support_bundle ===\n%s\n' \
    "$ip" "$out_files" "$ip" "$out_log"
}

# ---------------------------------------------------------------------------
# print_final_report  <status_csv>
# Le o CSV gerado pelo nsx_sb_main.sh e imprime visao consolidada por no.
# Exibe: tabela completa de eventos + resumo final de cada bundle.
# ---------------------------------------------------------------------------
print_final_report(){
  local csv="$1"
  local sep
  sep=$(printf '%0.s-' {1..72})

  echo ""
  echo "${sep}"
  echo "  RELATORIO CONSOLIDADO - NSX EDGE SUPPORT BUNDLES"
  echo "${sep}"
  printf '%-18s %-14s %-12s %-22s %s\n' "NODE IP" "FASE" "STATUS" "TIMESTAMP" "DETALHES"
  echo "${sep}"

  tail -n +2 "$csv" | awk -F',' '{
    printf "%-18s %-14s %-12s %-22s %s\n", $1, $2, $3, $5, $4
  }'

  echo "${sep}"
  echo ""
  echo "=== RESULTADO FINAL DOS BUNDLES POR NO ==="
  echo "${sep}"
  printf '%-18s %-12s %s\n' "NODE IP" "RESULTADO" "DETALHES"
  echo "${sep}"

  # Ultima entrada phase2 de cada no = resultado definitivo
  tail -n +2 "$csv" | awk -F',' '
    $2=="phase2" { last[$1]=$3" | "$4" | "$5 }
    END {
      for (ip in last)
        printf "%-18s %-12s %s\n", ip, (last[ip] ~ /success/ ? "SUCCESS" : (last[ip] ~ /error/ ? "ERROR" : "PENDING")), last[ip]
    }
  ' | sort

  echo "${sep}"
  echo ""
}
