#!/usr/bin/env bash
# =============================================================================
# deploy_nsx_sb_check.sh  v3.1
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

BASE_DIR="${HOME}/nsx-edge-automation"
if [[ "${1:-}" == "--dir" && -n "${2:-}" ]]; then
  BASE_DIR="$2"
fi

AUTO_DIR="${BASE_DIR}/automations/support_bundle"
LIB_DIR="${BASE_DIR}/lib"
DOCS_DIR="${BASE_DIR}/docs"
EXAMPLES_DIR="${BASE_DIR}/examples"

mkdir -p "${AUTO_DIR}/logs" "${AUTO_DIR}/run" "${LIB_DIR}" "${DOCS_DIR}" "${EXAMPLES_DIR}"

echo ""
echo "================================================================"
echo "  NSX Edge Automation — Support Bundle Kit  v3.1"
echo "  Destino: ${BASE_DIR}"
echo "================================================================"
echo ""

cat <<'TREE'
Estrutura que será criada:
  nsx-edge-automation/
  ├── lib/
  │   └── common.sh
  ├── automations/
  │   └── support_bundle/
  │       ├── edge_nodes.txt
  │       ├── nsx_sb_main.sh
  │       ├── test_connections.sh
  │       ├── admin_exec.sh
  │       ├── root_exec.sh
  │       ├── nsx_ssh_cli.sh
  │       └── install_dependencies.sh
  └── docs/
      └── MANUAL.md
TREE
echo ""

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
# lib/common.sh  — v3.1
# ---------------------------------------------------------------------------
cat > "${LIB_DIR}/common.sh" <<'COMMON'
#!/usr/bin/env bash
# lib/common.sh  — v3.1
#
# Lógica PRE-CHECK (v3.1) — totalmente automática, sem prompt interativo:
#
#   check_bundle_status IP
#     Retorna via variável global BUNDLE_STATUS:
#       "recent"  — arquivo .tgz em file-store com mtime ≤ 7 dias  → PULAR geração
#       "old"     — arquivo .tgz em file-store com mtime > 7 dias   → DELETAR + GERAR
#       "none"    — nenhum arquivo encontrado                        → GERAR
#       "inprogress" — geração já em andamento                      → PULAR
#
#   delete_old_bundles IP
#     Apaga arquivos support-bundle*.tgz com mtime > 7 dias em file-store.
#     Registra cada arquivo deletado via log_warn.
#
#   Ao final de nsx_sb_main.sh é exibido um relatório compacto (box ciano)
#   com 1 linha por IP: IP | status | ação | arquivo confirmado.
#
# ANSI color output:
#   log        — branco     informação geral
#   log_ok     — verde      sucesso
#   log_warn   — amarelo    aviso
#   log_err    — vermelho   erro crítico
#   log_cmd    — magenta    comando SSH enviado
#   log_banner — ciano      cabeçalho de fase/seção
#   Prompts    — azul bold
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_DIR="${AUTO_DIR:-$(pwd)}"
LOG_DIR="${AUTO_DIR}/logs"
RUN_DIR="${AUTO_DIR}/run"
EDGE_FILE="${AUTO_DIR}/edge_nodes.txt"
EDGE_EXAMPLE="${AUTO_DIR}/edge_nodes.example"

mkdir -p "${LOG_DIR}" "${RUN_DIR}"

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

# Variáveis globais preenchidas por check_bundle_status
BUNDLE_STATUS=""      # recent | old | none | inprogress
BUNDLE_FILES_RECENT=""  # arquivos ≤ 7 dias
BUNDLE_FILES_OLD=""     # arquivos > 7 dias

log(){        printf "${_C_WHITE}[%s] %s${_C_RESET}\n"         "$(date '+%F %T')" "$*"; }
log_ok(){     printf "${_C_GREEN}[%s] [OK]   %s${_C_RESET}\n"  "$(date '+%F %T')" "$*"; }
log_warn(){   printf "${_C_YELLOW}[%s] [WARN] %s${_C_RESET}\n" "$(date '+%F %T')" "$*"; }
log_err(){    printf "${_C_RED}[%s] [ERR]  %s${_C_RESET}\n"    "$(date '+%F %T')" "$*"; }
log_cmd(){    printf "${_C_MAGENTA}[%s] >> %s${_C_RESET}\n"    "$(date '+%F %T')" "$*"; }
log_banner(){ printf "${_C_CYAN}[%s] === %s ===${_C_RESET}\n"  "$(date '+%F %T')" "$*"; }

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || { log_err "Missing required command: $1"; exit 1; }
}

collect_ips(){
  if [[ -f "${EDGE_EXAMPLE}" ]]; then
    echo "  Template: ${EDGE_EXAMPLE}  |  cp edge_nodes.example edge_nodes.txt"
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
  log "$(wc -l < "${EDGE_FILE}" | tr -d ' ') IP(s) saved to ${EDGE_FILE}"
}

load_ips(){
  [[ ! -s "${EDGE_FILE}" ]] && { log_warn "${EDGE_FILE} not found or empty."; collect_ips; }
  mapfile -t EDGE_IPS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${EDGE_FILE}" 2>/dev/null || true)
  [[ ${#EDGE_IPS[@]} -eq 0 ]] && { log_err "No valid IPs found in ${EDGE_FILE}."; exit 1; }
  log "Loaded ${#EDGE_IPS[@]} Edge Node(s): ${EDGE_IPS[*]}"
}

_save_creds(){
  ( umask 177
    printf 'NSX_USER=%s\nNSX_PASS=%s\nROOT_PASS=%s\n' \
      "${NSX_USER:-}" "${NSX_PASS:-}" "${ROOT_PASS:-}" > "${_CRED_FILE}" )
  chmod 600 "${_CRED_FILE}"
}

_load_creds(){
  [[ -f "${_CRED_FILE}" ]] || return 1
  local fuid
  fuid="$(stat -c '%u' "${_CRED_FILE}" 2>/dev/null || stat -f '%u' "${_CRED_FILE}" 2>/dev/null || echo -1)"
  [[ "${fuid}" == "${UID}" ]] || return 1
  local key val
  while IFS= read -r _line; do
    [[ -z "${_line}" || "${_line}" =~ ^# ]] && continue
    key="${_line%%=*}"; val="${_line#*=}"
    case "${key}" in
      NSX_USER)  export NSX_USER="${val}"  ;;
      NSX_PASS)  export NSX_PASS="${val}"  ;;
      ROOT_PASS) export ROOT_PASS="${val}" ;;
    esac
  done < "${_CRED_FILE}"
  return 0
}

_remove_cred_file(){ [[ -f "${_CRED_FILE}" ]] && rm -f "${_CRED_FILE}" || true; }

ask_admin_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials already in environment (user: '${NSX_USER:-admin}')."; return 0
  fi
  if _load_creds 2>/dev/null && [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials loaded from session file."; return 0
  fi
  printf "${_C_BLUE_BOLD}Usuário admin [admin]: ${_C_RESET}"; read -r NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  printf "${_C_BLUE_BOLD}Senha admin: ${_C_RESET}"; IFS= read -rsp "" NSX_PASS; echo
  export NSX_USER NSX_PASS
  log "Credenciais coletadas para '${NSX_USER}'."
}

ask_root_creds(){
  if [[ -n "${ROOT_PASS:-}" ]]; then
    log "Root credentials already in environment."; return 0
  fi
  if _load_creds 2>/dev/null && [[ -n "${ROOT_PASS:-}" ]]; then
    log "Root credentials loaded from session file."; return 0
  fi
  printf "${_C_BLUE_BOLD}Senha root: ${_C_RESET}"; IFS= read -rsp "" ROOT_PASS; echo
  export ROOT_PASS
  log "Root credentials collected."
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER 2>/dev/null || true
  _remove_cred_file
  [[ -f "${_KNOWN_HOSTS}" ]] && rm -f "${_KNOWN_HOSTS}" || true
  log "Credentials cleared."
}

prompt_clear_creds(){
  echo ""
  printf "${_C_BLUE_BOLD}Limpar credenciais da memória? [S/n]: ${_C_RESET}"
  read -r _CLR
  if [[ "${_CLR,,}" == "n" ]]; then _save_creds; log "Credenciais mantidas (${_CRED_FILE})."
  else clear_creds; fi
}

ssh_admin(){
  local ip="$1"; shift
  export SSHPASS="${NSX_PASS}"
  sshpass -e ssh -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${_KNOWN_HOSTS}" -o ConnectTimeout=15 \
    "${NSX_USER}@${ip}" "$@"
  local _rc=$?; unset SSHPASS; return $_rc
}

ssh_root(){
  local ip="$1"; shift
  export SSHPASS="${ROOT_PASS}"
  sshpass -e ssh -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${_KNOWN_HOSTS}" -o ConnectTimeout=15 \
    "root@${ip}" "$@"
  local _rc=$?; unset SSHPASS; return $_rc
}

admin_cmd(){     local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>/dev/null; }
root_cmd(){      local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>/dev/null; }
admin_cmd_tty(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>&1; }
root_cmd_tty(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>&1; }

enable_root_ssh(){
  local ip="$1"
  log "${ip}: enabling root SSH..."
  log_cmd "${ip}: set ssh root-login"
  admin_cmd_tty "$ip" 'set ssh root-login' || true
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: disabling root SSH..."
  log_cmd "${ip}: clear ssh root-login"
  admin_cmd_tty "$ip" 'clear ssh root-login' || true
}

# ---------------------------------------------------------------------------
# check_bundle_log IP
#   Exibe última linha do support_bundle.log (box azul). Sempre 1 linha.
#   Returns: 0=ok, 1=erro no log, 2=arquivo não encontrado
# ---------------------------------------------------------------------------
check_bundle_log(){
  local ip="$1"
  local log_file="/var/log/support_bundle.log"
  local out
  out="$(root_cmd "$ip" "test -f ${log_file} && tail -1 ${log_file} || echo '__FILE_NOT_FOUND__'")"
  if grep -q '__FILE_NOT_FOUND__' <<< "$out"; then
    log_warn "${ip}: ${log_file} não encontrado."
    return 2
  fi
  echo ""
  printf "  ${_C_BLUE}┌─ ${ip}: ${log_file} (última linha) ──────────────────────────────${_C_RESET}\n"
  printf "  ${_C_BLUE}│${_C_RESET}  %s\n" "${out}"
  printf "  ${_C_BLUE}└────────────────────────────────────────────────────────────────${_C_RESET}\n"
  echo ""
  if grep -qiE 'error|fail|exception|abort|fatal' <<< "$out"; then
    log_warn "${ip}: problema detectado na última linha do log."; return 1
  fi
  log_ok "${ip}: última linha do log sem erros aparentes."
  return 0
}

# ---------------------------------------------------------------------------
# check_bundle_status IP
#   Preenche as variáveis globais:
#     BUNDLE_STATUS        : recent | old | none | inprogress
#     BUNDLE_FILES_RECENT  : lista de arquivos ≤ 7 dias
#     BUNDLE_FILES_OLD     : lista de arquivos > 7 dias
#
#   Lógica:
#     1. Verifica processos em andamento → inprogress
#     2. Busca .tgz em file-store:
#        - algum com mtime ≤ 7d  → recent  (exibe box verde)
#        - apenas com mtime > 7d → old     (exibe box amarelo)
#        - nenhum                → none
# ---------------------------------------------------------------------------
check_bundle_status(){
  local ip="$1"
  BUNDLE_STATUS="none"
  BUNDLE_FILES_RECENT=""
  BUNDLE_FILES_OLD=""

  log "${ip}: [PRE-CHECK] verificando status do support bundle..."

  # Stage 1: em andamento?
  local proc_out
  proc_out="$(root_cmd "$ip" \
    "ps aux 2>/dev/null | grep -iE 'support_bundle|support-bundle|napi.*bundle' | grep -v grep || true")"
  local partial_out
  partial_out="$(root_cmd "$ip" \
    "find /var/vmware/nsx/file-store -maxdepth 1 -name 'support-bundle*' -newer /proc/1 -mmin -30 2>/dev/null || true")"
  if [[ -n "$proc_out" || -n "$partial_out" ]]; then
    log_warn "${ip}: geração de bundle em andamento detectada."
    BUNDLE_STATUS="inprogress"
    return 0
  fi

  # Stage 2: arquivos recentes (≤ 7 dias)
  BUNDLE_FILES_RECENT="$(root_cmd "$ip" \
    "find /var/vmware/nsx/file-store -maxdepth 1 -name 'support-bundle*.tgz' -mtime -7 2>/dev/null | sort || true")"

  # Stage 3: arquivos antigos (> 7 dias)
  BUNDLE_FILES_OLD="$(root_cmd "$ip" \
    "find /var/vmware/nsx/file-store -maxdepth 1 -name 'support-bundle*.tgz' -mtime +7 2>/dev/null | sort || true")"

  if [[ -n "$BUNDLE_FILES_RECENT" ]]; then
    BUNDLE_STATUS="recent"
    echo ""
    printf "  ${_C_GREEN}┌─ ${ip}: bundle recente confirmado em file-store (≤ 7 dias) ──────────────────${_C_RESET}\n"
    while IFS= read -r f; do
      printf "  ${_C_GREEN}│${_C_RESET}  %s\n" "$f"
    done <<< "$BUNDLE_FILES_RECENT"
    printf "  ${_C_GREEN}└────────────────────────────────────────────────────────────────────────────────${_C_RESET}\n"
    echo ""
    log_ok "${ip}: bundle recente — geração será pulada."
    return 0
  fi

  if [[ -n "$BUNDLE_FILES_OLD" ]]; then
    BUNDLE_STATUS="old"
    echo ""
    printf "  ${_C_YELLOW}┌─ ${ip}: bundle(s) ANTIGO(S) encontrado(s) em file-store (> 7 dias) ────────────${_C_RESET}\n"
    while IFS= read -r f; do
      printf "  ${_C_YELLOW}│${_C_RESET}  %s\n" "$f"
    done <<< "$BUNDLE_FILES_OLD"
    printf "  ${_C_YELLOW}└────────────────────────────────────────────────────────────────────────────────${_C_RESET}\n"
    echo ""
    log_warn "${ip}: bundle(s) antigo(s) detectado(s) — será(ão) deletado(s) e novo será gerado."
    return 0
  fi

  log "${ip}: nenhum bundle encontrado em file-store — será gerado."
  return 0
}

# ---------------------------------------------------------------------------
# delete_old_bundles IP
#   Apaga arquivos support-bundle*.tgz com mtime > 7 dias.
#   Registra cada deleção via log_warn.
# ---------------------------------------------------------------------------
delete_old_bundles(){
  local ip="$1"
  if [[ -z "$BUNDLE_FILES_OLD" ]]; then return 0; fi
  log "${ip}: deletando bundle(s) antigo(s)..."
  while IFS= read -r fpath; do
    [[ -z "$fpath" ]] && continue
    log_cmd "${ip}: rm -f ${fpath}"
    if root_cmd "$ip" "rm -f '${fpath}' 2>/dev/null"; then
      log_warn "${ip}: deletado — ${fpath}"
    else
      log_err "${ip}: falha ao deletar — ${fpath}"
    fi
  done <<< "$BUNDLE_FILES_OLD"
}

request_support_bundle(){
  local ip="$1"
  local fname="sb_${ip//./_}_$(date +%Y%m%d_%H%M%S).tgz"
  log_cmd "${ip}: get support-bundle file ${fname} log-age 1"
  admin_cmd_tty "$ip" "get support-bundle file ${fname} log-age 1" || true
}
COMMON
chmod +x "${LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# edge_nodes.example
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/edge_nodes.example" <<'EXAMPLE'
# edge_nodes.example — copie para edge_nodes.txt e edite
192.168.1.10
192.168.1.11
192.168.1.12
EXAMPLE

# ---------------------------------------------------------------------------
# install_dependencies.sh
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/install_dependencies.sh" <<'INST'
#!/usr/bin/env bash
set -euo pipefail
if command -v sshpass &>/dev/null; then
  echo "[OK] sshpass já instalado: $(command -v sshpass)"; exit 0
fi
for pm in apt-get yum dnf; do
  if command -v $pm &>/dev/null; then
    $pm install -y sshpass && echo "[OK] sshpass instalado." && exit 0
  fi
done
echo "[ERR] Instale sshpass manualmente."; exit 1
INST
chmod +x "${AUTO_DIR}/install_dependencies.sh"

# ---------------------------------------------------------------------------
# setup_keys.sh (placeholder)
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/setup_keys.sh" <<'SETUP'
#!/usr/bin/env bash
echo "[INFO] Autenticação via sshpass (senha). Execute ./test_connections.sh para validar."
SETUP
chmod +x "${AUTO_DIR}/setup_keys.sh"

# ---------------------------------------------------------------------------
# test_connections.sh
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/test_connections.sh" <<'TESTC'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds; ask_root_creds
REPORT="${LOG_DIR}/test_$(date +%Y%m%d_%H%M%S).log"
log "Relatório: ${REPORT}"
for ip in "${EDGE_IPS[@]}"; do
  {
    echo "====================================== Node: ${ip}"
    ping -c 1 -W 2 "$ip" 2>&1 || echo "WARN: ping filtrado"
    admin_cmd_tty "$ip" 'get version'     || echo "FAIL"
    admin_cmd_tty "$ip" 'get service ssh' || echo "FAIL"
    admin_cmd_tty "$ip" 'get managers'   || echo "FAIL"
    enable_root_ssh "$ip"; sleep 2
    root_cmd_tty "$ip" 'uname -a'  || echo "FAIL"
    root_cmd_tty "$ip" 'uptime'    || echo "FAIL"
    root_cmd_tty "$ip" 'df -h /var/log' || echo "FAIL"
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
# nsx_sb_main.sh  — v3.1
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/nsx_sb_main.sh" <<'MAIN'
#!/usr/bin/env bash
# nsx_sb_main.sh  — v3.1
#
# Fluxo automático por node:
#   bundle recente (≤ 7d)  → pular geração
#   bundle antigo  (> 7d)  → deletar antigos + gerar novo
#   nenhum bundle          → gerar novo
#   geração em andamento   → pular
#
# Exibe relatório compacto ao final com 1 linha por node.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds; ask_root_creds

RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"

# Array para relatório final: cada entrada = "IP|STATUS|AÇÃO|ARQUIVO"
declare -a REPORT_LINES=()

# ---- PRE-CHECK ----
log_banner "PRE-CHECK: Verificando bundles existentes"

for ip in "${EDGE_IPS[@]}"; do
  log "${ip}: iniciando PRE-CHECK..."
  enable_root_ssh "$ip"

  # Lê última linha do log
  check_bundle_log "$ip" || true

  # Determina status do bundle
  check_bundle_status "$ip"

  printf '%s,precheck,bundle_status,%s,%s\n' "$ip" "$BUNDLE_STATUS" "$(date +%F_%T)" \
    | tee -a "$RUN_LOG" >> "$STATUS_CSV"

  case "$BUNDLE_STATUS" in

    recent)
      REPORT_LINES+=("${ip}|RECENTE (≤7d)|PULADO|${BUNDLE_FILES_RECENT}")
      ;;

    old)
      delete_old_bundles "$ip"
      printf '%s,precheck,deleted_old_bundles,ok,%s\n' "$ip" "$(date +%F_%T)" \
        | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      REPORT_LINES+=("${ip}|ANTIGO (>7d)|DELETADO + GERANDO|${BUNDLE_FILES_OLD}")
      ;;

    none)
      REPORT_LINES+=("${ip}|NENHUM|GERANDO|—")
      ;;

    inprogress)
      REPORT_LINES+=("${ip}|EM ANDAMENTO|PULADO|—")
      ;;
  esac
done

# ---- PHASE 1: Request Support Bundle ----
log_banner "PHASE 1: Support Bundle Request"

for ip in "${EDGE_IPS[@]}"; do
  # Recupera decisão do precheck
  local_status=""
  for entry in "${REPORT_LINES[@]}"; do
    if [[ "${entry%%|*}" == "$ip" ]]; then
      local_status="$(echo "$entry" | cut -d'|' -f3)"
      break
    fi
  done

  if [[ "$local_status" == "PULADO" ]]; then
    log "${ip}: pulando solicitação de bundle."
    continue
  fi

  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n' "$ip" "$(date +%F_%T)" \
    | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

log_ok "Phase 1 done."

# ---- FINAL: Disable root SSH ----
log_banner "FINAL: Disabling root SSH"
for ip in "${EDGE_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" \
    | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

# ---- RELATÓRIO COMPACTO FINAL ----
echo ""
printf "${_C_CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${_C_RESET}\n"
printf "${_C_CYAN}║  RELATÓRIO FINAL — Support Bundle Check  %-35s║${_C_RESET}\n" "$(date '+%F %T')"
printf "${_C_CYAN}╠═══════════════════╦══════════════════╦══════════════════╦════════════════════╣${_C_RESET}\n"
printf "${_C_CYAN}║ %-17s ║ %-16s ║ %-16s ║ %-18s ║${_C_RESET}\n" "NODE" "STATUS" "AÇÃO" "ARQUIVO"
printf "${_C_CYAN}╠═══════════════════╬══════════════════╬══════════════════╬════════════════════╣${_C_RESET}\n"
for entry in "${REPORT_LINES[@]}"; do
  IFS='|' read -r r_ip r_status r_acao r_arquivo <<< "$entry"
  # Trunca arquivo para exibição (pega só o basename)
  r_arq_short="$(basename "${r_arquivo}" 2>/dev/null || echo "${r_arquivo}")"
  [[ ${#r_arq_short} -gt 18 ]] && r_arq_short="${r_arq_short:0:15}..."
  printf "${_C_CYAN}║${_C_RESET} %-17s ${_C_CYAN}║${_C_RESET} %-16s ${_C_CYAN}║${_C_RESET} %-16s ${_C_CYAN}║${_C_RESET} %-18s ${_C_CYAN}║${_C_RESET}\n" \
    "$r_ip" "$r_status" "$r_acao" "$r_arq_short"
done
printf "${_C_CYAN}╚═══════════════════╩══════════════════╩══════════════════╩════════════════════╝${_C_RESET}\n"
echo ""
log_ok "Status CSV: ${STATUS_CSV}"

prompt_clear_creds
MAIN
chmod +x "${AUTO_DIR}/nsx_sb_main.sh"

# ---------------------------------------------------------------------------
# admin_exec.sh
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/admin_exec.sh" <<'ADMX'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds
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
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh; need_cmd sshpass
load_ips; ask_admin_creds; ask_root_creds
printf "${_C_BLUE_BOLD}Comando shell para executar como root: ${_C_RESET}"
read -r SHELL_CMD
[[ -z "${SHELL_CMD}" ]] && { log_err "Nenhum comando fornecido."; exit 1; }
for ip in "${EDGE_IPS[@]}"; do
  enable_root_ssh "$ip"; sleep 1
  log_cmd "${ip}: ${SHELL_CMD}"
  root_cmd_tty "$ip" "${SHELL_CMD}" || log_warn "${ip}: comando retornou erro"
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
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh; need_cmd sshpass; load_ips
echo "Nodes disponíveis:"
for i in "${!EDGE_IPS[@]}"; do echo "  [$i] ${EDGE_IPS[$i]}"; done
printf "${_C_BLUE_BOLD}Número do node ou IP direto: ${_C_RESET}"; read -r SEL
if [[ "$SEL" =~ ^[0-9]+$ ]] && [[ -n "${EDGE_IPS[$SEL]:-}" ]]; then
  TARGET_IP="${EDGE_IPS[$SEL]}"
else
  TARGET_IP="$SEL"
fi
printf "${_C_BLUE_BOLD}Usuário [admin]: ${_C_RESET}"; read -r LOGIN_USER
LOGIN_USER="${LOGIN_USER:-admin}"
if [[ "$LOGIN_USER" == "root" ]]; then
  ask_root_creds; export SSHPASS="${ROOT_PASS}"
else
  ask_admin_creds; export SSHPASS="${NSX_PASS}"; LOGIN_USER="${NSX_USER}"
fi
log "Conectando em ${LOGIN_USER}@${TARGET_IP}..."
sshpass -e ssh -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${_KNOWN_HOSTS}" -o ConnectTimeout=15 \
  "${LOGIN_USER}@${TARGET_IP}"
unset SSHPASS
CLISCRIPT
chmod +x "${AUTO_DIR}/nsx_ssh_cli.sh"

# ---------------------------------------------------------------------------
# MANUAL.md
# ---------------------------------------------------------------------------
cat > "${DOCS_DIR}/MANUAL.md" <<'MANUALDOC'
# NSX Edge Automation — Manual de Uso  v3.1

## Fluxo automático de Support Bundle (v3.1)

| Situação detectada | Ação automática |
|---|---|
| Bundle ≤ 7 dias em file-store | **Pula** — bundle ainda válido |
| Bundle > 7 dias em file-store | **Deleta** antigos + **gera** novo |
| Nenhum bundle encontrado | **Gera** novo |
| Geração em andamento | **Pula** — aguarda conclusão externa |

Não há prompt interativo de confirmação. O script decide automaticamente.
Ao final, exibe um **relatório compacto** (tabela ciano) com 1 linha por node.

## Pré-requisitos

- `sshpass` instalado
- `edge_nodes.txt` com IPs dos Edge Nodes

## Deploy

```bash
curl -fsSL https://raw.githubusercontent.com/leopoldocosta/nsx-edge-automation/main/automations/support_bundle/deploy_nsx_sb_check.sh | bash
```

## Uso

```bash
cd ~/nsx-edge-automation/automations/support_bundle
./test_connections.sh   # valida acesso
./nsx_sb_main.sh        # coleta support bundle
```

## Cores no terminal

| Cor | Significado |
|---|---|
| Branco | Info geral |
| Verde | Sucesso / bundle recente |
| Amarelo | Aviso / bundle antigo |
| Vermelho | Erro |
| Magenta | Comando SSH enviado |
| Ciano | Cabeçalhos e relatório final |
| Azul | Box de log / bordas |
| Azul bold | Prompts interativos |
MANUALDOC

cat > "${EXAMPLES_DIR}/ip_list_example.txt" <<'IPEX'
192.168.100.10
192.168.100.11
192.168.100.12
IPEX

echo ""
if ! command -v sshpass &>/dev/null; then
  echo "[WARN] sshpass não encontrado. Execute: bash ${AUTO_DIR}/install_dependencies.sh"
else
  echo "[OK] sshpass encontrado: $(command -v sshpass)"
fi

echo ""
echo "================================================================"
echo "  Deploy concluído! v3.1"
echo "================================================================"
echo ""
echo "  Novidades v3.1:"
echo "    - Fluxo totalmente automático, sem prompt interativo:"
echo "      bundle ≤ 7d → pular | bundle > 7d → deletar + gerar | nenhum → gerar"
echo "    - delete_old_bundles(): apaga .tgz com mtime > 7 dias via root SSH"
echo "    - check_bundle_status(): classifica em recent/old/none/inprogress"
echo "    - Relatório compacto ao final: tabela ciano com 1 linha por node"
echo "      colunas: NODE | STATUS | AÇÃO | ARQUIVO"
echo ""
echo "  Novidades v3.0:"
echo "    - Evidência Stage 1 em 2 boxes (azul: última linha log, verde: arquivo .tgz)"
echo ""
echo "Próximos passos:"
echo "  1. cd ${AUTO_DIR} && ./test_connections.sh"
echo "  2. cd ${AUTO_DIR} && ./nsx_sb_main.sh"
echo ""
