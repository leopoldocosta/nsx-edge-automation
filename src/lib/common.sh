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

# check_support_bundle: dupla validação diretamente no edge node
#   1. Lê /var/log/support_bundle e procura pela linha de conclusão real:
#      "Support bundle saved to: /var/vmware/nsx/file-store/..."
#   2. Valida que o arquivo .tgz existe em /var/vmware/nsx/file-store/
#      e retorna nome + tamanho.
#   Retorna:
#     SUCCESS:<caminho_do_bundle>  — bundle concluído e arquivo presente
#     PENDING                     — log não contém linha de conclusão ainda
#     LOG_NOT_FOUND               — /var/log/support_bundle não existe
#     FILE_NOT_FOUND              — log diz concluído mas .tgz ausente (race condition)
check_support_bundle(){
  local ip="$1"

  # Passo 1 — procura linha de conclusão no log do próprio edge
  local log_check
  log_check="$(root_cmd "$ip" "
    if [[ ! -f /var/log/support_bundle ]]; then
      echo LOG_NOT_FOUND
    else
      grep -m1 'Support bundle saved to:' /var/log/support_bundle 2>/dev/null || echo PENDING
    fi
  ")"

  case "$log_check" in
    LOG_NOT_FOUND)
      echo "LOG_NOT_FOUND"
      return
      ;;
    PENDING)
      echo "PENDING"
      return
      ;;
  esac

  # Passo 2 — extrai caminho do bundle e confirma existência do arquivo
  local bundle_path
  bundle_path="$(echo "$log_check" | grep -oP '/var/vmware/nsx/file-store/\S+')"

  if [[ -z "$bundle_path" ]]; then
    # log_check continha a linha mas sem caminho reconhecível — fallback por find
    bundle_path="$(root_cmd "$ip" "
      find /var/vmware/nsx/file-store/ -maxdepth 1 -name 'support-bundle-*.tgz' \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print \$2}'
    ")"
  fi

  if [[ -z "$bundle_path" ]]; then
    echo "FILE_NOT_FOUND"
    return
  fi

  # Passo 3 — confirma que o arquivo existe e pega tamanho
  local file_info
  file_info="$(root_cmd "$ip" "ls -lh \"${bundle_path}\" 2>/dev/null || echo FILE_NOT_FOUND")"

  if grep -q 'FILE_NOT_FOUND' <<< "$file_info"; then
    echo "FILE_NOT_FOUND"
  else
    echo "SUCCESS:${bundle_path}"
  fi
}

# list_old_bundles: lista todos os .tgz em /var/vmware/nsx/file-store/ do edge
# Retorna linhas no formato: <tamanho_humano> <data_modificacao> <caminho>
list_old_bundles(){
  local ip="$1"
  root_cmd "$ip" "
    find /var/vmware/nsx/file-store/ -maxdepth 1 -name 'support-bundle-*.tgz' \
      -printf '%TY-%Tm-%Td %TH:%TM  %s  %p\n' 2>/dev/null \
    | awk '{printf \"%s %s  %6.1f GB  %s\\n\", \$1, \$2, \$3/1073741824, \$4}' \
    | sort
  " 2>/dev/null || echo "NONE"
}

# delete_bundle: remove arquivo específico do edge
delete_bundle(){
  local ip="$1" path="$2"
  root_cmd "$ip" "rm -f \"${path}\" && echo DELETED || echo DELETE_FAILED"
}
