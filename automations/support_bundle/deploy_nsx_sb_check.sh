#!/usr/bin/env bash
# =============================================================================
# deploy_nsx_sb_check.sh  v2.8
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
echo "  NSX Edge Automation — Support Bundle Kit  v2.8"
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
# lib/common.sh  — v2.8
# ---------------------------------------------------------------------------
cat > "${LIB_DIR}/common.sh" <<'COMMON'
#!/usr/bin/env bash
# lib/common.sh  — v2.8
# Biblioteca compartilhada para todos os scripts NSX Edge Automation.
# Autenticação: sempre sshpass (senha). Sem chaves SSH.
#
# PRE-CHECK bundle detection (v2.7+) — lógica 3 estágios:
#   Stage 1: check_bundle_log_recent  — log indica bundle gerado nos últimos 7 dias
#   Stage 2: check_existing_bundle    — busca .tgz em file-store ou via 'get files'
#   Stage 3: check_bundle_in_progress — detecta processo ou arquivo parcial em andamento
#
# FIX v2.8:
#   - nsx_sb_main.sh: Phase 2 (polling 5 min) removida — monitoramento externo
#   - SHA stale fix: SHA sempre buscado de refs/heads/main antes de qualquer update
#   - check_bundle_log: tail -10 → tail -1 (apenas última linha do log)
# FIX v2.7:
#   - PRE-CHECK 3-stage logic (log recent / file-store / in-progress)
# FIX v2.6:
#   - nsx_sb_main.sh: exibe última linha de support_bundle.log no WARN pending
# FIX v2.5:
#   - admin_cmd/root_cmd: stderr suprimido (2>/dev/null)
#   - admin_cmd_tty/root_cmd_tty: stdout+stderr no terminal
# FIX v2.4:
#   - Credenciais persistidas em /dev/shm/.nsx_session_<UID> (tmpfs)
#   - known_hosts persistente em /tmp/.nsx_known_hosts_<UID>
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_DIR="${AUTO_DIR:-$(pwd)}"

LOG_DIR="${AUTO_DIR}/logs"
RUN_DIR="${AUTO_DIR}/run"
EDGE_FILE="${AUTO_DIR}/edge_nodes.txt"
EDGE_EXAMPLE="${AUTO_DIR}/edge_nodes.example"

mkdir -p "${LOG_DIR}" "${RUN_DIR}"

_CRED_DIR="/tmp"
[[ -d "/dev/shm" ]] && _CRED_DIR="/dev/shm"
_CRED_FILE="${_CRED_DIR}/.nsx_session_${UID}"

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
    echo "  Template: ${EDGE_EXAMPLE}"
    echo "  Copie com: cp edge_nodes.example edge_nodes.txt e edite."
    echo "  Ou cole os IPs diretamente abaixo."
  fi
  echo ""
  echo "Cole os IPs dos Edge Nodes, um por linha. Linha vazia para terminar:"
  : > "${EDGE_FILE}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    [[ "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$line" >> "${EDGE_FILE}"
    else
      log_warn "Entrada inválida ignorada: ${line}"
    fi
  done
  local count
  count=$(wc -l < "${EDGE_FILE}" | tr -d ' ')
  log "${count} IP(s) salvos em ${EDGE_FILE}"
}

load_ips(){
  if [[ ! -s "${EDGE_FILE}" ]]; then
    log_warn "${EDGE_FILE} não encontrado ou vazio."
    collect_ips
  fi
  mapfile -t EDGE_IPS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${EDGE_FILE}" 2>/dev/null || true)
  if [[ ${#EDGE_IPS[@]} -eq 0 ]]; then
    log_err "Nenhum IP válido encontrado em ${EDGE_FILE}."
    exit 1
  fi
  log "Carregados ${#EDGE_IPS[@]} Edge Node(s): ${EDGE_IPS[*]}"
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
# Credenciais
# ---------------------------------------------------------------------------
ask_admin_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Credenciais admin já no ambiente (usuário: '${NSX_USER:-admin}'). Pulando prompt."
    return 0
  fi
  if _load_creds 2>/dev/null; then
    if [[ -n "${NSX_PASS:-}" ]]; then
      log "Credenciais admin carregadas do arquivo de sessão (usuário: '${NSX_USER:-admin}'). Pulando prompt."
      return 0
    fi
  fi
  read -rp  "Usuário admin [admin]: " NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  IFS= read -rsp "Senha admin (todos os caracteres especiais aceitos): " NSX_PASS; echo
  export NSX_USER NSX_PASS
  log "Credenciais coletadas para '${NSX_USER}'. Serão reutilizadas em todos os nodes."
}

ask_root_creds(){
  if [[ -n "${ROOT_PASS:-}" ]]; then
    log "Credenciais root já no ambiente. Pulando prompt."
    return 0
  fi
  if _load_creds 2>/dev/null; then
    if [[ -n "${ROOT_PASS:-}" ]]; then
      log "Credenciais root carregadas do arquivo de sessão. Pulando prompt."
      return 0
    fi
  fi
  IFS= read -rsp "Senha root (todos os caracteres especiais aceitos): " ROOT_PASS; echo
  export ROOT_PASS
  log "Credenciais root coletadas. Serão reutilizadas em todos os nodes."
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER 2>/dev/null || true
  _remove_cred_file
  [[ -f "${_KNOWN_HOSTS}" ]] && rm -f "${_KNOWN_HOSTS}" || true
  log "Credenciais removidas da memória, arquivo de sessão e known_hosts apagados."
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
# SSH — sempre sshpass, sem chaves
# admin_cmd / root_cmd: stdout apenas, stderr suprimido (uso programático)
# admin_cmd_tty / root_cmd_tty: stdout+stderr no terminal (uso interativo)
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

admin_cmd(){     local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>/dev/null; }
root_cmd(){      local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>/dev/null; }
admin_cmd_tty(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>&1; }
root_cmd_tty(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>&1; }

# ---------------------------------------------------------------------------
# Root SSH Control
# ---------------------------------------------------------------------------
enable_root_ssh(){
  local ip="$1"
  log "${ip}: habilitando root SSH..."
  log "${ip}: >> set ssh root-login"
  admin_cmd_tty "$ip" 'set ssh root-login' || true
  log "${ip}: >> get service ssh"
  admin_cmd_tty "$ip" 'get service ssh' || true
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: desabilitando root SSH..."
  log "${ip}: >> clear ssh root-login"
  admin_cmd_tty "$ip" 'clear ssh root-login' || true
  log "${ip}: >> get service ssh"
  admin_cmd_tty "$ip" 'get service ssh' || true
}

# ---------------------------------------------------------------------------
# check_bundle_log IP
#   Lê /var/log/support_bundle.log (última linha) e exibe ao operador.
#   Retorna: 0=ok, 1=erros/warnings no log, 2=arquivo não encontrado
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
  echo "  ┌─ ${ip}: ${log_file} (última linha) ──────────────────────────"
  echo "  │  ${out}"
  echo "  └────────────────────────────────────────────────────────────────"
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
#   Stage 1 do PRE-CHECK.
#   Verifica se o log indica bundle gerado nos últimos 7 dias.
#   Retorna: 0=bundle recente encontrado, 1=não encontrado, 2=log ausente
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
#   Stage 2 do PRE-CHECK.
#   Detecta arquivos .tgz de support bundle no file-store ou via 'get files'.
#   Retorna: 0 com nomes de arquivo em stdout se encontrado, 1 caso contrário
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
#   Stage 3 do PRE-CHECK.
#   Detecta geração de bundle em andamento via processo ativo ou arquivo parcial.
#   Retorna: 0=em andamento, 1=nenhuma geração detectada
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
# Support Bundle
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
# NOTA: Em NSX Edge Nodes (Debian embarcado sem acesso a mirrors externos),
#       o sshpass deve ser copiado de uma VM Debian/Ubuntu da mesma arquitetura:
#         apt-get download sshpass
#         dpkg -x sshpass_*.deb /tmp/sshpass_out
#         scp /tmp/sshpass_out/usr/bin/sshpass root@<IP_EDGE>:/usr/local/bin/
#         chmod +x /usr/local/bin/sshpass
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
echo "[ERR] Gerenciador de pacotes não reconhecido ou sshpass não disponível nos repos."
echo "      Em NSX Edge Nodes, copie o binário manualmente de uma VM Debian/Ubuntu amd64:"
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
# setup_keys.sh — placeholder
# Chaves SSH não são usadas nesta versão.
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

    echo "--- [1] Ping ---"
    ping -c 1 -W 2 "$ip" 2>&1 || echo "WARN: ping falhou (pode estar filtrado)"

    echo "--- [2] admin: get version ---"
    admin_cmd_tty "$ip" 'get version' || echo "FAIL"

    echo "--- [3] admin: get service ssh ---"
    admin_cmd_tty "$ip" 'get service ssh' || echo "FAIL"

    echo "--- [4] admin: get managers ---"
    admin_cmd_tty "$ip" 'get managers' || echo "FAIL"

    echo "--- [5] enable root SSH ---"
    enable_root_ssh "$ip"
    sleep 2

    echo "--- [6] root: uname -a ---"
    root_cmd_tty "$ip" 'uname -a' || echo "FAIL"

    echo "--- [7] root: uptime ---"
    root_cmd_tty "$ip" 'uptime' || echo "FAIL"

    echo "--- [8] root: df -h /var/log ---"
    root_cmd_tty "$ip" 'df -h /var/log' || echo "FAIL"

    echo "--- [9] presença do log support_bundle.log ---"
    root_cmd_tty "$ip" 'ls -lh /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND'

    echo "--- [10] disable root SSH ---"
    disable_root_ssh "$ip"

    echo
  } | tee -a "$REPORT"
done

log_ok "Teste concluído. Relatório: ${REPORT}"
prompt_clear_creds
TESTC
chmod +x "${AUTO_DIR}/test_connections.sh"

# ---------------------------------------------------------------------------
# nsx_sb_main.sh  — v2.8
# Phase 2 (polling 5 min) removida — monitoramento externo
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/nsx_sb_main.sh" <<'MAIN'
#!/usr/bin/env bash
# nsx_sb_main.sh  — v2.8
# Orchestrator: PRE-CHECK (3-stage) + Phase 1 (request SB)
# Phase 2 (5-min polling) removed — monitoring is done externally.
#
# PRE-CHECK stages:
#   1. check_bundle_log_recent  — se o log indica bundle gerado nos últimos 7 dias → existe
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
log "=== PRE-CHECK: Verificando log e bundles existentes ==="
declare -A SKIP_SB
for ip in "${EDGE_IPS[@]}"; do
  SKIP_SB["$ip"]="false"
done

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando PRE-CHECK..."
  enable_root_ssh "$ip"

  # Exibe log (informação ao operador)
  log_rc=0
  check_bundle_log "$ip" || log_rc=$?
  case "$log_rc" in
    0) printf '%s,precheck,bundle_log,ok,%s\n'           "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV" ;;
    1) printf '%s,precheck,bundle_log,warn_errors,%s\n'  "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV" ;;
    2) printf '%s,precheck,bundle_log,not_found,%s\n'    "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV" ;;
  esac

  # ------------------------------------------------------------------
  # Stage 1: log recente (7 dias) → considera bundle como existente
  # ------------------------------------------------------------------
  recent_rc=0
  check_bundle_log_recent "$ip" || recent_rc=$?

  if [[ "$recent_rc" -eq 0 ]]; then
    log "${ip}: [Stage 1] bundle recente detectado no log — verificando se usuário quer gerar novo."
    printf '%s,precheck,stage1_log_recent,found,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    existing_label="[log recente ≤ 7 dias]"
    if ! prompt_new_bundle "$ip" "${existing_label}"; then
      SKIP_SB["$ip"]="true"
      printf '%s,precheck,existing_bundle,skipped_log_recent,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    else
      log "${ip}: usuário solicitou novo bundle — prosseguindo."
      printf '%s,precheck,existing_bundle,new_requested,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
    continue
  fi

  # ------------------------------------------------------------------
  # Stage 2: buscar arquivo .tgz em file-store / 'get files'
  # ------------------------------------------------------------------
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

  # ------------------------------------------------------------------
  # Stage 3: verificar se há geração em andamento
  # ------------------------------------------------------------------
  if check_bundle_in_progress "$ip"; then
    log_warn "${ip}: [Stage 3] geração de bundle já está em andamento — pulando solicitação."
    printf '%s,precheck,stage3_in_progress,detected,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    SKIP_SB["$ip"]="true"
    continue
  fi

  # Nenhum bundle detectado — gerar novo
  log "${ip}: nenhum bundle existente ou em andamento — será gerado."
  printf '%s,precheck,existing_bundle,none,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

# ---- PHASE 1: Enable root SSH + Request Support Bundle ----
log "=== PHASE 1: Support Bundle Request ==="
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
log "Phase 1 done. Bundles requested — monitoring is done externally."

# ---- FINAL: Disable root SSH on all nodes ----
log "=== FINAL: Disabling root SSH ==="
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

read -rp "Comando NSX CLI para executar em todos os nodes: " NSX_CMD
[[ -z "${NSX_CMD}" ]] && { log_err "Nenhum comando fornecido."; exit 1; }

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: >> ${NSX_CMD}"
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

read -rp "Comando shell para executar em todos os nodes como root: " SHELL_CMD
[[ -z "${SHELL_CMD}" ]] && { log_err "Nenhum comando fornecido."; exit 1; }

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: habilitando root SSH..."
  enable_root_ssh "$ip"
  sleep 1

  log "${ip}: >> ${SHELL_CMD}"
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
read -rp "Número do node ou IP direto: " SEL

if [[ "$SEL" =~ ^[0-9]+$ ]] && [[ -n "${EDGE_IPS[$SEL]:-}" ]]; then
  TARGET_IP="${EDGE_IPS[$SEL]}"
else
  TARGET_IP="$SEL"
fi

read -rp "Usuário [admin]: " LOGIN_USER
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
Copie o binário de uma VM Debian/Ubuntu amd64 com acesso à internet:
```bash
# Na VM Debian/Ubuntu:
apt-get download sshpass
dpkg -x sshpass_*.deb /tmp/sshpass_out
scp /tmp/sshpass_out/usr/bin/sshpass root@<IP_EDGE>:/usr/local/bin/
chmod +x /usr/local/bin/sshpass
# Validar no Edge:
sshpass -V
```

## Fluxo de uso

### 1. Deploy (primeira vez ou após reinstalação)
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
./admin_exec.sh   # como admin (NSX CLI)
./root_exec.sh    # como root (shell)
```

### 5. Sessão SSH interativa
```bash
./nsx_ssh_cli.sh
```

## Autenticação

Todos os scripts pedem usuário e senha interativamente na primeira execução.
Quando o usuário responde "n" ao prompt de limpeza, as credenciais são salvas
em `/dev/shm/.nsx_session_<UID>` (tmpfs, chmod 600) e recarregadas
automaticamente pelo próximo script — sem novo prompt.

## Known Hosts

Um arquivo `/tmp/.nsx_known_hosts_<UID>` (chmod 600) é mantido entre execuções.
O aviso "Permanently added" aparece apenas na **primeira** conexão a cada IP.
Conexões subsequentes são silenciosas.
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
# Verificar se sshpass está instalado
# ---------------------------------------------------------------------------
echo ""
if ! command -v sshpass &>/dev/null; then
  echo "[WARN] sshpass não encontrado."
  echo "       Em NSX Edge Nodes, copie o binário manualmente:"
  echo "         apt-get download sshpass  (em VM Debian/Ubuntu com internet)"
  echo "         dpkg -x sshpass_*.deb /tmp/sshpass_out"
  echo "         scp /tmp/sshpass_out/usr/bin/sshpass root@<IP_EDGE>:/usr/local/bin/"
  echo "         chmod +x /usr/local/bin/sshpass"
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
echo "  Deploy concluído! v2.8"
echo "================================================================"
echo ""
echo "  Novidades v2.8:"
echo "    - nsx_sb_main.sh: Phase 2 (polling a cada 5 min) removida"
echo "      O monitoramento do bundle deve ser feito externamente."
echo "    - SHA stale fix: SHA sempre buscado de refs/heads/main antes"
echo "      de qualquer update para evitar conflitos de cache."
echo "    - check_bundle_log: tail -10 → tail -1 (apenas última linha)"
echo ""
echo "  Novidades v2.7:"
echo "    - PRE-CHECK 3 estágios: log recente (7d) / file-store / in-progress"
echo "    - Stage 1: detecta bundle recente no log (últimos 7 dias)"
echo "    - Stage 2: detecta .tgz em file-store ou via 'get files'"
echo "    - Stage 3: detecta geração em andamento (processo ou arquivo parcial)"
echo ""
echo "  Novidades v2.6:"
echo "    - FIX: exibe última linha de /var/log/support_bundle.log no WARN pending"
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
