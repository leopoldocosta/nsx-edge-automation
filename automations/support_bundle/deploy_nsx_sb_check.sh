#!/usr/bin/env bash
# =============================================================================
# deploy_nsx_sb_check.sh  v3.0
# Deploy local do kit NSX Edge Automation - Support Bundle
#
# USO:
#   bash deploy_nsx_sb_check.sh [--dir /caminho/destino]
#   curl -fsSL https://raw.githubusercontent.com/leopoldocosta/nsx-edge-automation/main/automations/support_bundle/deploy_nsx_sb_check.sh | bash
#
# O script gera todos os arquivos localmente e solicita os IPs dos Edge Nodes.
# Nenhum repositório Git é necessário.
# Autenticação: sempre por senha via sshpass (sem chaves SSH).
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Diretório de destino
# ---------------------------------------------------------------------------
BASE_DIR="${HOME}/nsx-edge-automation"
if [[ "${1:-}" == "--dir" && -n "${2:-}" ]]; then
  BASE_DIR="$2"
fi

AUTO_DIR="${BASE_DIR}/automations/support_bundle"
LIB_DIR="${BASE_DIR}/lib"
DOCS_DIR="${BASE_DIR}/docs"
EXAMPLES_DIR="${BASE_DIR}/examples"

mkdir -p \
  "${AUTO_DIR}/logs" \
  "${AUTO_DIR}/run" \
  "${LIB_DIR}" \
  "${DOCS_DIR}" \
  "${EXAMPLES_DIR}"

echo ""
echo "================================================================"
echo "  NSX Edge Automation — Support Bundle Kit  v3.0"
echo "  Destino: ${BASE_DIR}"
echo "================================================================"
echo ""

# ---------------------------------------------------------------------------
# Estrutura esperada
# ---------------------------------------------------------------------------
cat <<'TREE'
Estrutura que será criada:
  nsx-edge-automation/
  ├── lib/
  │   └── common.sh          <- biblioteca compartilhada
  ├── automations/
  │   └── support_bundle/
  │       ├── edge_nodes.txt  <- IPs dos Edge Nodes (você preenche)
  │       ├── nsx_sb_main.sh  <- script principal
  │       ├── test_connections.sh
  │       ├── admin_exec.sh
  │       ├── root_exec.sh
  │       ├── nsx_ssh_cli.sh
  │       └── install_dependencies.sh
  └── docs/
      └── MANUAL.md
TREE
echo ""

# ---------------------------------------------------------------------------
# .gitignore
# ---------------------------------------------------------------------------
cat > "${BASE_DIR}/.gitignore" <<'GITIGNORE'
logs/
run/
*.log
*.csv
edge_nodes.txt
.env
session.env
GITIGNORE

# ---------------------------------------------------------------------------
# lib/common.sh  — v3.0
# ---------------------------------------------------------------------------
cat > "${LIB_DIR}/common.sh" <<'COMMON'
#!/usr/bin/env bash
# lib/common.sh  — v3.0
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
# PRE-CHECK bundle detection (v3.0) — 3-stage logic:
#   Stage 1: check_bundle_log_recent — se support_bundle.log indica bundle
#            gerado nos últimos 7 dias, a evidência é confirmada em 2 passos:
#            a) última linha do log é exibida (box azul)
#            b) arquivo support-bundle*.tgz em file-store com mtime ≤ 7 dias
#               é buscado e exibido (box verde)
#            Apenas o nome real do arquivo .tgz é passado ao prompt.
#            Se não houver arquivo físico, avança para Stage 2.
#   Stage 2: check_existing_bundle   — look for .tgz files in file-store or
#            via 'get files' (admin CLI).
#   Stage 3: check_bundle_in_progress — detect an active generation process
#            (napi/python pid running support_bundle collection).
#
# ANSI color output (v3.0):
#   log       — plain white    (general info)
#   log_ok    — bold green     (success)
#   log_warn  — bold yellow    (warnings)
#   log_err   — bold red       (errors)
#   log_cmd   — magenta        (SSH commands sent >> cmd)
#   log_banner— bold cyan      (phase/section headers)
#   log_box   — blue           (box borders ┌ │ └)
#   Prompts   — bold blue
#
# Usage in any automation script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   export AUTO_DIR="${SCRIPT_DIR}"
#   source "${SCRIPT_DIR}/../../lib/common.sh"
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_DIR="${AUTO_DIR:-$(pwd)}"

LOG_DIR="${AUTO_DIR}/logs"
RUN_DIR="${AUTO_DIR}/run"
EDGE_FILE="${AUTO_DIR}/edge_nodes.txt"
EDGE_EXAMPLE="${AUTO_DIR}/edge_nodes.example"

mkdir -p "${LOG_DIR}" "${RUN_DIR}"

# ---------------------------------------------------------------------------
# ANSI color codes
# ---------------------------------------------------------------------------
_C_RESET='\033[0m'
_C_WHITE='\033[0;37m'
_C_GREEN='\033[1;32m'
_C_YELLOW='\033[1;33m'
_C_RED='\033[1;31m'
_C_CYAN='\033[1;36m'
_C_MAGENTA='\033[0;35m'
_C_BLUE='\033[0;34m'
_C_BLUE_BOLD='\033[1;34m'

_CRED_DIR="/tmp"
[[ -d "/dev/shm" ]] && _CRED_DIR="/dev/shm"
_CRED_FILE="${_CRED_DIR}/.nsx_session_${UID}"

_KNOWN_HOSTS="/tmp/.nsx_known_hosts_${UID}"
touch "${_KNOWN_HOSTS}" 2>/dev/null && chmod 600 "${_KNOWN_HOSTS}" 2>/dev/null || true

# Guarda o nome real do arquivo .tgz confirmado no Stage 1
STAGE1_BUNDLE_FILES=""

# ---------------------------------------------------------------------------
# Logging — color-coded
# ---------------------------------------------------------------------------
log(){
  printf "${_C_WHITE}[%s] %s${_C_RESET}\n" "$(date '+%F %T')" "$*"
}
log_ok(){
  printf "${_C_GREEN}[%s] [OK]   %s${_C_RESET}\n" "$(date '+%F %T')" "$*"
}
log_warn(){
  printf "${_C_YELLOW}[%s] [WARN] %s${_C_RESET}\n" "$(date '+%F %T')" "$*"
}
log_err(){
  printf "${_C_RED}[%s] [ERR]  %s${_C_RESET}\n" "$(date '+%F %T')" "$*"
}
log_cmd(){
  printf "${_C_MAGENTA}[%s] >> %s${_C_RESET}\n" "$(date '+%F %T')" "$*"
}
log_banner(){
  printf "${_C_CYAN}[%s] === %s ===${_C_RESET}\n" "$(date '+%F %T')" "$*"
}

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
  printf "${_C_BLUE_BOLD}Paste Edge Node IPs, one per line. Empty line to finish:${_C_RESET}\n"
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
# Session file helpers
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
  printf "${_C_BLUE_BOLD}Usuário admin [admin]: ${_C_RESET}"
  read -r NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  printf "${_C_BLUE_BOLD}Senha admin (todos os caracteres especiais aceitos): ${_C_RESET}"
  IFS= read -rsp "" NSX_PASS; echo
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
  printf "${_C_BLUE_BOLD}Senha root (todos os caracteres especiais aceitos): ${_C_RESET}"
  IFS= read -rsp "" ROOT_PASS; echo
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
  printf "${_C_BLUE_BOLD}Limpar credenciais da memória? [S/n]: ${_C_RESET}"
  read -r _CLR
  if [[ "${_CLR,,}" == "n" ]]; then
    _save_creds
    log "Credenciais mantidas na sessão (${_CRED_FILE})."
  else
    clear_creds
  fi
}

# ---------------------------------------------------------------------------
# SSH Functions
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

admin_cmd(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>/dev/null; }
root_cmd(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>/dev/null; }
admin_cmd_tty(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>&1; }
root_cmd_tty(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>&1; }

# ---------------------------------------------------------------------------
# Root SSH Control
# ---------------------------------------------------------------------------
enable_root_ssh(){
  local ip="$1"
  log "${ip}: enabling root SSH..."
  log_cmd "${ip}: set ssh root-login"
  admin_cmd_tty "$ip" 'set ssh root-login' || true
  log_cmd "${ip}: get service ssh"
  admin_cmd_tty "$ip" 'get service ssh' || true
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: disabling root SSH..."
  log_cmd "${ip}: clear ssh root-login"
  admin_cmd_tty "$ip" 'clear ssh root-login' || true
  log_cmd "${ip}: get service ssh"
  admin_cmd_tty "$ip" 'get service ssh' || true
}

# ---------------------------------------------------------------------------
# check_bundle_log IP
#   Reads /var/log/support_bundle.log on the node (last line only).
#   Returns: 0=ok, 1=errors/warnings found in log, 2=file not found
# ---------------------------------------------------------------------------
check_bundle_log(){
  local ip="$1"
  local log_file="/var/log/support_bundle.log"
  local out

  log "${ip}: lendo ${log_file} (última linha)..."
  out="$(root_cmd "$ip" "test -f ${log_file} && tail -1 ${log_file} || echo '__FILE_NOT_FOUND__'")"

  if grep -q '__FILE_NOT_FOUND__' <<< "$out"; then
    log_warn "${ip}: ${log_file} não encontrado — geração anterior pode não ter ocorrido."
    return 2
  fi

  echo ""
  printf "  ${_C_BLUE}┌─ ${ip}: ${log_file} (última linha) ──────────────────────────────${_C_RESET}\n"
  printf "  ${_C_BLUE}│${_C_RESET}  %s\n" "${out}"
  printf "  ${_C_BLUE}└────────────────────────────────────────────────────────────────${_C_RESET}\n"
  echo ""

  if grep -qiE 'error|fail|exception|abort|fatal' <<< "$out"; then
    log_warn "${ip}: ATENÇÃO — problema detectado na última linha do log (ver acima)."
    return 1
  fi

  log_ok "${ip}: última linha do log sem erros aparentes."
  return 0
}

# ---------------------------------------------------------------------------
# check_bundle_log_recent IP
#   Stage 1 of PRE-CHECK.
#   Evidência válida = arquivo .tgz em file-store com mtime ≤ 7 dias.
#   Exibe:
#     Box azul  — última linha do log (para saber o que foi registrado)
#     Box verde — nome do arquivo .tgz confirmado em file-store
#   STAGE1_BUNDLE_FILES recebe apenas o(s) nome(s) real(is) do(s) arquivo(s).
#   Returns: 0=evidência confirmada, 1=não encontrado, 2=log ausente
# ---------------------------------------------------------------------------
check_bundle_log_recent(){
  local ip="$1"
  local log_file="/var/log/support_bundle.log"

  STAGE1_BUNDLE_FILES=""
  log "${ip}: [PRE-CHECK Stage 1] verificando geração recente em ${log_file}..."

  local out
  out="$(root_cmd "$ip" "test -f ${log_file} && tail -100 ${log_file} || echo '__FILE_NOT_FOUND__'")"

  if grep -q '__FILE_NOT_FOUND__' <<< "$out"; then
    log_warn "${ip}: ${log_file} não encontrado — avançando para Stage 2."
    return 2
  fi

  local last_date
  last_date="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' <<< "$out" | tail -1 || true)"

  if [[ -z "$last_date" ]]; then
    log_warn "${ip}: nenhuma data encontrada no log — avançando para Stage 2."
    return 1
  fi

  local log_epoch now_epoch cutoff_epoch
  log_epoch="$(date -d "${last_date}" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  cutoff_epoch=$(( now_epoch - 7 * 86400 ))

  if [[ "$log_epoch" -lt "$cutoff_epoch" ]]; then
    log_warn "${ip}: último registro no log é de ${last_date} (mais de 7 dias) — avançando para Stage 2."
    return 1
  fi

  # Log recente — captura última linha para exibição
  local last_log_line
  last_log_line="$(tail -1 <<< "$out")"

  log "${ip}: log recente (${last_date}) — confirmando evidência em file-store (arquivo .tgz ≤ 7 dias)..."
  local tgz_out
  tgz_out="$(root_cmd "$ip" "find /var/vmware/nsx/file-store -maxdepth 1 -name 'support-bundle*.tgz' -mtime -7 2>/dev/null | sort || true")"

  if [[ -z "$tgz_out" ]]; then
    log_warn "${ip}: log recente encontrado, mas nenhum arquivo .tgz foi confirmado em /var/vmware/nsx/file-store nos últimos 7 dias — avançando para Stage 2."
    return 1
  fi

  # Exibe box azul — última linha do log (evidência do registro)
  echo ""
  printf "  ${_C_BLUE}┌─ ${ip}: /var/log/support_bundle.log (última linha) ──────────────────────────${_C_RESET}\n"
  printf "  ${_C_BLUE}│${_C_RESET}  %s\n" "${last_log_line}"
  printf "  ${_C_BLUE}└────────────────────────────────────────────────────────────────────────────────${_C_RESET}\n"
  echo ""

  # Exibe box verde — arquivo(s) .tgz confirmado(s) em file-store
  printf "  ${_C_GREEN}┌─ ${ip}: evidência Stage 1 — arquivo(s) confirmados em file-store (≤ 7 dias) ─────${_C_RESET}\n"
  while IFS= read -r tfile; do
    printf "  ${_C_GREEN}│${_C_RESET}  %s\n" "${tfile}"
  done <<< "$tgz_out"
  printf "  ${_C_GREEN}└────────────────────────────────────────────────────────────────────────────────${_C_RESET}\n"
  echo ""

  STAGE1_BUNDLE_FILES="$tgz_out"

  log_ok "${ip}: bundle confirmado por evidência física em file-store — data do log: ${last_date}."
  return 0
}

# ---------------------------------------------------------------------------
# check_existing_bundle IP
#   Stage 2 of PRE-CHECK.
#   Returns 0 with filenames on stdout if found, 1 otherwise.
# ---------------------------------------------------------------------------
check_existing_bundle(){
  local ip="$1"
  local found_files=""

  local admin_out
  admin_out="$(admin_cmd "$ip" 'get files' || true)"
  if [[ -n "$admin_out" ]]; then
    local admin_matches
    admin_matches="$(grep -iE 'support-bundle' <<< "$admin_out" || true)"
    [[ -n "$admin_matches" ]] && found_files="$admin_matches"
  fi

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
#   Returns: 0=in progress, 1=not detected
# ---------------------------------------------------------------------------
check_bundle_in_progress(){
  local ip="$1"
  local found=0

  log "${ip}: [PRE-CHECK Stage 3] verificando geração em andamento..."

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
#   Exibe o(s) nome(s) real(is) do(s) arquivo(s) confirmado(s) e pergunta
#   se o usuário deseja gerar um novo bundle.
# ---------------------------------------------------------------------------
prompt_new_bundle(){
  local ip="$1"
  local files="$2"
  local reply

  echo ""
  printf "${_C_YELLOW}  *** Support bundle já existe em ${ip} ***${_C_RESET}\n"
  printf "${_C_YELLOW}  Arquivos encontrados:${_C_RESET}\n"
  while IFS= read -r f; do
    printf "${_C_YELLOW}    %s${_C_RESET}\n" "${f}"
  done <<< "$files"
  echo ""

  printf "${_C_BLUE_BOLD}  Gerar um NOVO support bundle para ${ip}? [s/N] (skip automático em 10s): ${_C_RESET}"
  if read -r -t 10 reply </dev/tty; then
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
  log_cmd "${ip}: get support-bundle file ${fname} log-age 1"
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
COMMON
chmod +x "${LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# edge_nodes.example
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/edge_nodes.example" <<'EXAMPLE'
# edge_nodes.example
# Copie para edge_nodes.txt e preencha com os IPs reais:
#   cp edge_nodes.example edge_nodes.txt
#
# Um IP por linha. Linhas com # são ignoradas.
192.168.1.10
192.168.1.11
192.168.1.12
EXAMPLE

# ---------------------------------------------------------------------------
# install_dependencies.sh
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/install_dependencies.sh" <<'INST'
#!/usr/bin/env bash
# install_dependencies.sh - Instala sshpass e dependências necessárias.
set -euo pipefail
if command -v sshpass &>/dev/null; then
  echo "[OK] sshpass já instalado: $(command -v sshpass)"
  exit 0
fi
if command -v apt-get &>/dev/null; then
  apt-get update -qq && apt-get install -y sshpass && echo "[OK] sshpass instalado." && exit 0
fi
if command -v yum &>/dev/null; then
  yum install -y sshpass && echo "[OK] sshpass instalado." && exit 0
fi
if command -v dnf &>/dev/null; then
  dnf install -y sshpass && echo "[OK] sshpass instalado." && exit 0
fi
echo "[ERR] Gerenciador de pacotes não reconhecido."
echo "      Em NSX Edge Nodes, copie o binário manualmente:"
echo "        apt-get download sshpass"
echo "        dpkg -x sshpass_*.deb /tmp/sshpass_out"
echo "        scp /tmp/sshpass_out/usr/bin/sshpass root@<IP_EDGE>:/usr/local/bin/"
echo "        chmod +x /usr/local/bin/sshpass"
exit 1
INST
chmod +x "${AUTO_DIR}/install_dependencies.sh"

# ---------------------------------------------------------------------------
# setup_keys.sh (placeholder)
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/setup_keys.sh" <<'SETUP'
#!/usr/bin/env bash
echo "[INFO] Chaves SSH não são usadas nesta versão."
echo "[INFO] Autenticação via sshpass (senha)."
echo "[INFO] Execute ./test_connections.sh para validar."
SETUP
chmod +x "${AUTO_DIR}/setup_keys.sh"

# ---------------------------------------------------------------------------
# test_connections.sh
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/test_connections.sh" <<'TESTC'
#!/usr/bin/env bash
# test_connections.sh - Valida conectividade, acesso admin e root.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
need_cmd sshpass
load_ips
ask_admin_creds
ask_root_creds

REPORT="${LOG_DIR}/test_$(date +%Y%m%d_%H%M%S).log"
log "Relatório: ${REPORT}"

for ip in "${EDGE_IPS[@]}"; do
  {
    echo "======================================"
    echo " Node: ${ip}"
    echo "======================================"

    log_cmd "${ip}: ping"
    ping -c 1 -W 2 "$ip" 2>&1 || echo "WARN: ping falhou (pode estar filtrado)"

    log_cmd "${ip}: get version"
    admin_cmd_tty "$ip" 'get version' || echo "FAIL"

    log_cmd "${ip}: get service ssh"
    admin_cmd_tty "$ip" 'get service ssh' || echo "FAIL"

    log_cmd "${ip}: get managers"
    admin_cmd_tty "$ip" 'get managers' || echo "FAIL"

    enable_root_ssh "$ip"
    sleep 2

    log_cmd "${ip}: uname -a"
    root_cmd_tty "$ip" 'uname -a' || echo "FAIL"

    log_cmd "${ip}: uptime"
    root_cmd_tty "$ip" 'uptime' || echo "FAIL"

    log_cmd "${ip}: df -h /var/log"
    root_cmd_tty "$ip" 'df -h /var/log' || echo "FAIL"

    log_cmd "${ip}: ls support_bundle.log"
    root_cmd_tty "$ip" 'ls -lh /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND'

    disable_root_ssh "$ip"

    echo
  } | tee -a "$REPORT"
done

log_ok "Teste concluído. Relatório: ${REPORT}"
prompt_clear_creds
TESTC
chmod +x "${AUTO_DIR}/test_connections.sh"

# ---------------------------------------------------------------------------
# nsx_sb_main.sh  — v3.0
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/nsx_sb_main.sh" <<'MAIN'
#!/usr/bin/env bash
# nsx_sb_main.sh  — v3.0
# Orchestrator: PRE-CHECK (3-stage) + Phase 1 (request SB)
# Phase 2 (5-min polling) removed — monitoring is done externally.
#
# PRE-CHECK stages:
#   1. check_bundle_log_recent  — evidência válida: arquivo .tgz em file-store criado nos
#                                 últimos 7 dias. Exibe box azul (última linha do log) +
#                                 box verde (nome do arquivo .tgz confirmado).
#   2. check_existing_bundle    — busca .tgz em file-store ou via 'get files'
#   3. check_bundle_in_progress — detecta processo ou arquivo parcial em andamento
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
need_cmd sshpass
load_ips
ask_admin_creds
ask_root_creds

RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"

# ---- PRE-CHECK: 3-stage bundle detection ----
log_banner "PRE-CHECK: Verificando log e bundles existentes"
declare -A SKIP_SB
for ip in "${EDGE_IPS[@]}"; do
  SKIP_SB["$ip"]="false"
done

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando PRE-CHECK..."
  enable_root_ssh "$ip"

  log_rc=0
  check_bundle_log "$ip" || log_rc=$?
  case "$log_rc" in
    0) printf '%s,precheck,bundle_log,ok,%s\n'           "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV" ;;
    1) printf '%s,precheck,bundle_log,warn_errors,%s\n'  "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV" ;;
    2) printf '%s,precheck,bundle_log,not_found,%s\n'    "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV" ;;
  esac

  # Stage 1
  recent_rc=0
  check_bundle_log_recent "$ip" || recent_rc=$?

  if [[ "$recent_rc" -eq 0 ]]; then
    log "${ip}: [Stage 1] evidência física confirmada em file-store — verificando se usuário quer gerar novo."
    printf '%s,precheck,stage1_log_recent,confirmed,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    # STAGE1_BUNDLE_FILES contém o(s) nome(s) real(is) do(s) arquivo(s) .tgz confirmado(s)
    if ! prompt_new_bundle "$ip" "${STAGE1_BUNDLE_FILES}"; then
      SKIP_SB["$ip"]="true"
      printf '%s,precheck,existing_bundle,skipped_stage1_confirmed,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    else
      log "${ip}: usuário solicitou novo bundle — prosseguindo."
      printf '%s,precheck,existing_bundle,new_requested,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
    continue
  fi

  # Stage 2
  existing_files=""
  if existing_files="$(check_existing_bundle "$ip")"; then
    log "${ip}: [Stage 2] bundle(s) existente(s) encontrado(s) em file-store."
    printf '%s,precheck,stage2_filestore,found,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    if ! prompt_new_bundle "$ip" "$existing_files"; then
      SKIP_SB["$ip"]="true"
      printf '%s,precheck,existing_bundle,skipped,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    else
      log "${ip}: usuário solicitou novo bundle — prosseguindo."
      printf '%s,precheck,existing_bundle,new_requested,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
    continue
  fi

  # Stage 3
  if check_bundle_in_progress "$ip"; then
    log_warn "${ip}: [Stage 3] geração de bundle já está em andamento — pulando solicitação."
    printf '%s,precheck,stage3_in_progress,detected,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    SKIP_SB["$ip"]="true"
    continue
  fi

  log "${ip}: nenhum bundle existente ou em andamento — será gerado."
  printf '%s,precheck,existing_bundle,none,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

# ---- PHASE 1: Enable root SSH + Request Support Bundle ----
log_banner "PHASE 1: Support Bundle Request"
for ip in "${EDGE_IPS[@]}"; do
  if [[ "${SKIP_SB[$ip]}" == "true" ]]; then
    log "${ip}: pulando solicitação (bundle existente ou em andamento)."
    continue
  fi
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n'     "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log_ok "Phase 1 done. Bundles requested — monitoring is done externally."

# ---- FINAL: Disable root SSH on all nodes ----
log_banner "FINAL: Disabling root SSH"
for ip in "${EDGE_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

log_ok "Done. Status CSV: ${STATUS_CSV}"
prompt_clear_creds
MAIN
chmod +x "${AUTO_DIR}/nsx_sb_main.sh"

# ---------------------------------------------------------------------------
# admin_exec.sh
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/admin_exec.sh" <<'ADMX'
#!/usr/bin/env bash
# admin_exec.sh - Executa um comando NSX CLI em todos os Edge Nodes como admin.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
need_cmd sshpass
load_ips
ask_admin_creds

printf "${_C_BLUE_BOLD}Comando NSX CLI para executar em todos os nodes: ${_C_RESET}"
read -r NSX_CMD
[[ -z "${NSX_CMD}" ]] && { log_err "Nenhum comando fornecido."; exit 1; }

for ip in "${EDGE_IPS[@]}"; do
  log_cmd "${ip}: ${NSX_CMD}"
  admin_cmd_tty "$ip" "${NSX_CMD}" || log_warn "${ip}: comando retornou erro"
done

prompt_clear_creds
ADMX
chmod +x "${AUTO_DIR}/admin_exec.sh"

# ---------------------------------------------------------------------------
# root_exec.sh
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/root_exec.sh" <<'ROTX'
#!/usr/bin/env bash
# root_exec.sh - Executa um comando shell em todos os Edge Nodes como root.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
need_cmd sshpass
load_ips
ask_admin_creds
ask_root_creds

printf "${_C_BLUE_BOLD}Comando shell para executar em todos os nodes como root: ${_C_RESET}"
read -r SHELL_CMD
[[ -z "${SHELL_CMD}" ]] && { log_err "Nenhum comando fornecido."; exit 1; }

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: habilitando root SSH..."
  enable_root_ssh "$ip"
  sleep 1
  log_cmd "${ip}: ${SHELL_CMD}"
  root_cmd_tty "$ip" "${SHELL_CMD}" || log_warn "${ip}: comando retornou erro"
  log "${ip}: desabilitando root SSH..."
  disable_root_ssh "$ip"
done

prompt_clear_creds
ROTX
chmod +x "${AUTO_DIR}/root_exec.sh"

# ---------------------------------------------------------------------------
# nsx_ssh_cli.sh
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/nsx_ssh_cli.sh" <<'CLISCRIPT'
#!/usr/bin/env bash
# nsx_ssh_cli.sh - Abre sessão SSH interativa em um Edge Node específico.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
need_cmd sshpass
load_ips

echo "Nodes disponíveis:"
for i in "${!EDGE_IPS[@]}"; do
  echo "  [$i] ${EDGE_IPS[$i]}"
done
printf "${_C_BLUE_BOLD}Número do node ou IP direto: ${_C_RESET}"
read -r SEL

if [[ "$SEL" =~ ^[0-9]+$ ]] && [[ -n "${EDGE_IPS[$SEL]:-}" ]]; then
  TARGET_IP="${EDGE_IPS[$SEL]}"
else
  TARGET_IP="$SEL"
fi

printf "${_C_BLUE_BOLD}Usuário [admin]: ${_C_RESET}"
read -r LOGIN_USER
LOGIN_USER="${LOGIN_USER:-admin}"

if [[ "$LOGIN_USER" == "root" ]]; then
  ask_root_creds
  export SSHPASS="${ROOT_PASS}"
else
  ask_admin_creds
  export SSHPASS="${NSX_PASS}"
  LOGIN_USER="${NSX_USER}"
fi

log "Conectando em ${LOGIN_USER}@${TARGET_IP}..."
sshpass -e ssh \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${_KNOWN_HOSTS}" \
  -o ConnectTimeout=15 \
  "${LOGIN_USER}@${TARGET_IP}"
unset SSHPASS
CLISCRIPT
chmod +x "${AUTO_DIR}/nsx_ssh_cli.sh"

# ---------------------------------------------------------------------------
# MANUAL.md
# ---------------------------------------------------------------------------
cat > "${DOCS_DIR}/MANUAL.md" <<'MANUALDOC'
# NSX Edge Automation — Manual de Uso

## Pré-requisitos

- `sshpass` instalado (ver abaixo)
- Arquivo `edge_nodes.txt` com IPs dos Edge Nodes (um por linha)

## Instalação do sshpass

### Em servidores Linux normais (Ubuntu/Debian/RHEL)
```bash
bash install_dependencies.sh
```

### Em NSX Edge Nodes (Debian embarcado, sem acesso a mirrors externos)
```bash
apt-get download sshpass
dpkg -x sshpass_*.deb /tmp/sshpass_out
scp /tmp/sshpass_out/usr/bin/sshpass root@<IP_EDGE>:/usr/local/bin/
chmod +x /usr/local/bin/sshpass
```

## Fluxo de uso

### 1. Deploy
```bash
curl -fsSL https://raw.githubusercontent.com/leopoldocosta/nsx-edge-automation/main/automations/support_bundle/deploy_nsx_sb_check.sh | bash
```

### 2. Testar conectividade
```bash
cd ~/nsx-edge-automation/automations/support_bundle
./test_connections.sh
```

### 3. Coletar Support Bundle
```bash
./nsx_sb_main.sh
```

### 4. Executar comando em todos os nodes
```bash
./admin_exec.sh
./root_exec.sh
```

### 5. Sessão SSH interativa
```bash
./nsx_ssh_cli.sh
```

## Cores no terminal (v3.0)

| Cor | Significado |
|---|---|
| Branco | Informação geral (log) |
| Verde negrito | Sucesso (log_ok) |
| Amarelo negrito | Aviso / atenção (log_warn) |
| Vermelho negrito | Erro crítico (log_err) |
| Magenta | Comando SSH enviado (log_cmd >>cmd) |
| Ciano negrito | Cabeçalho de fase/seção (log_banner) |
| Azul | Bordas do box de log ┌ │ └ |
| Azul negrito | Prompts interativos ao operador |

## Stage 1 — Evidência clara (v3.0)

Quando o script detecta bundle recente via log, dois boxes são exibidos:

```
  ┌─ IP: /var/log/support_bundle.log (última linha) ──────────────────
  │  2026-05-14 18:13:55,833 root INFO Support bundle saved to: /var/.../bundle.tgz
  └────────────────────────────────────────────────────────────────────

  ┌─ IP: evidência Stage 1 — arquivo(s) confirmados em file-store (≤ 7 dias) ──
  │  /var/vmware/nsx/file-store/support-bundle-172-18-214-18-20260514_122125.tgz
  └────────────────────────────────────────────────────────────────────────────
```

O prompt de confirmação exibe apenas o nome real do arquivo .tgz confirmado.

## Autenticação

Todos os scripts pedem usuário e senha interativamente na primeira execução.
Quando o usuário responde "n" ao prompt de limpeza, as credenciais são salvas
em `/dev/shm/.nsx_session_<UID>` (tmpfs, chmod 600) e recarregadas
automaticamente pelo próximo script.
MANUALDOC

# ---------------------------------------------------------------------------
# Exemplo de IPs
# ---------------------------------------------------------------------------
cat > "${EXAMPLES_DIR}/ip_list_example.txt" <<'IPEX'
# Exemplo de lista de IPs
192.168.100.10
192.168.100.11
192.168.100.12
IPEX

# ---------------------------------------------------------------------------
# Verificar sshpass
# ---------------------------------------------------------------------------
echo ""
if ! command -v sshpass &>/dev/null; then
  echo "[WARN] sshpass não encontrado."
  echo "       Em NSX Edge Nodes, copie o binário manualmente."
  echo "       Ou em servidores com acesso a repos:"
  echo "         bash ${AUTO_DIR}/install_dependencies.sh"
else
  echo "[OK] sshpass encontrado: $(command -v sshpass)"
fi

# ---------------------------------------------------------------------------
# Resumo final
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  Deploy concluído! v3.0"
echo "================================================================"
echo ""
echo "  Novidades v3.0:"
echo "    - Stage 1: evidência exibida em 2 boxes separados"
echo "      Box AZUL  — última linha do /var/log/support_bundle.log"
echo "      Box VERDE — nome real do arquivo .tgz confirmado em file-store (≤ 7 dias)"
echo "    - Prompt mostra apenas o nome real do arquivo .tgz (sem '[log recente ≤ 7 dias]')"
echo "    - STAGE1_BUNDLE_FILES contém exclusivamente o caminho físico do arquivo"
echo "    - Se log for recente mas arquivo não existir, fluxo avança para Stage 2"
echo ""
echo "  Novidades v2.9:"
echo "    - ANSI color output em todos os scripts (common.sh)"
echo "      log       branco     informação geral"
echo "      log_ok    verde      sucesso"
echo "      log_warn  amarelo    aviso"
echo "      log_err   vermelho   erro crítico"
echo "      log_cmd   magenta    comando SSH enviado (>> cmd)"
echo "      log_banner ciano     cabeçalho de fase/seção"
echo "      box ┌│└   azul       bordas do box de log"
echo "      prompts   azul bold  prompts interativos"
echo ""
echo "  Novidades v2.8:"
echo "    - check_bundle_log: tail -1 (apenas última linha)"
echo "    - Phase 2 (polling 5 min) removida — monitoramento externo"
echo ""
echo "  Novidades v2.7:"
echo "    - PRE-CHECK 3 estágios: log recente (7d) / file-store / in-progress"
echo ""
echo "Próximos passos:"
echo "  1. Edite o arquivo de IPs:"
echo "       ${AUTO_DIR}/edge_nodes.txt"
echo ""
echo "  2. Teste a conectividade:"
echo "       cd ${AUTO_DIR} && ./test_connections.sh"
echo ""
echo "  3. Execute o script principal:"
echo "       cd ${AUTO_DIR} && ./nsx_sb_main.sh"
echo ""
