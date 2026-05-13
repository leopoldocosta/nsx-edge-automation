#!/usr/bin/env bash
# =============================================================================
# deploy_nsx_sb_check.sh  —  v3.0
# Deploy local do kit NSX Edge Automation - Support Bundle
#
# USO:
#   bash deploy_nsx_sb_check.sh [--dir /caminho/destino]
#
# O script solicita os IPs dos Edge Nodes durante o deploy.
# Nenhum arquivo precisa ser editado manualmente depois.
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
  "${AUTO_DIR}/.ssh_keys" \
  "${LIB_DIR}" \
  "${DOCS_DIR}" \
  "${EXAMPLES_DIR}"

chmod 700 "${AUTO_DIR}/.ssh_keys"

echo ""
echo "================================================================"
echo " NSX Edge Automation — Deploy v3.0"
echo "================================================================"
echo " Destino : ${BASE_DIR}"
echo "================================================================"
echo ""

# ===========================================================================
# COLETA DE IPs DURANTE O DEPLOY
# Os IPs são salvos em edge_nodes.txt (git-ignored).
# Nenhuma edição manual de arquivo é necessária.
# ===========================================================================
EDGE_FILE="${AUTO_DIR}/edge_nodes.txt"

collect_ips_deploy(){
  echo "---------------------------------------------------------------"
  echo " STEP 1/5 — Edge Node IPs"
  echo "---------------------------------------------------------------"
  echo " Cole os endereços IP dos Edge Nodes NSX, um por linha."
  echo " Pressione ENTER em uma linha vazia para finalizar."
  echo ""

  : > "${EDGE_FILE}"
  local count=0
  while IFS= read -rp "  IP ${count+$(( count + 1 ))} (vazio para finalizar): " line; do
    [[ -z "$line" ]] && break
    if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$line" >> "${EDGE_FILE}"
      (( count++ )) || true
      echo "    -> adicionado"
    else
      echo "    [WARN] '${line}' nao e um IPv4 valido, ignorado."
    fi
  done

  if [[ $count -eq 0 ]]; then
    echo "  [ERRO] Nenhum IP valido informado. Abortando."
    exit 1
  fi
  echo ""
  echo "  ${count} IP(s) salvos em ${EDGE_FILE}"
  echo ""
}

collect_ips_deploy

# ===========================================================================
# .gitignore
# ===========================================================================
cat > "${BASE_DIR}/.gitignore" <<'GITIGNORE'
logs/
run/
*.log
*.csv
.env
session.env
.ssh_keys/
*.pem
*.key
id_*
edge_nodes.txt
*.swp
*.tmp
__pycache__/
GITIGNORE

# ===========================================================================
# README.md
# ===========================================================================
cat > "${BASE_DIR}/README.md" <<'README'
# NSX Edge Automations

Bash automation toolkit for managing NSX Edge Nodes (NSX-T / VMware NSX).

## Structure

```
.
├── lib/common.sh                          # Shared: SSH, auth, IP loading, root control
├── automations/
│   └── support_bundle/
│       ├── deploy_nsx_sb_check.sh         # Deploy completo (coleta IPs interativamente)
│       ├── nsx_ssh_cli.sh                 # CLI interativo admin/root via SSH
│       ├── edge_nodes.example
│       ├── install_dependencies.sh
│       ├── setup_keys.sh
│       ├── test_connections.sh
│       ├── nsx_sb_main.sh
│       ├── admin_exec.sh
│       └── root_exec.sh
├── docs/
└── examples/
```

## Quick Start

```bash
bash deploy_nsx_sb_check.sh
# IPs são coletados durante o deploy — nenhuma edição de arquivo necessária

cd ~/nsx-edge-automation/automations/support_bundle
./install_dependencies.sh
./setup_keys.sh
./test_connections.sh
screen -S nsx_sb && ./nsx_sb_main.sh

# CLI interativo para testes:
./nsx_ssh_cli.sh
```

## Password Handling
- Coletadas uma vez, reutilizadas para todos os nós
- Aceita qualquer caractere especial
- Passadas via arquivo temporário privado (600), nunca em args

## License
MIT
README

# ===========================================================================
# lib/common.sh
# ===========================================================================
cat > "${LIB_DIR}/common.sh" <<'COMMON'
#!/usr/bin/env bash
# lib/common.sh — Biblioteca compartilhada para todas as automacoes NSX Edge.
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

log(){      printf '[%s] %s\n'        "$(date '+%F %T')" "$*"; }
log_ok(){   printf '[%s] [OK]   %s\n' "$(date '+%F %T')" "$*"; }
log_warn(){ printf '[%s] [WARN] %s\n' "$(date '+%F %T')" "$*"; }
log_err(){  printf '[%s] [ERR]  %s\n' "$(date '+%F %T')" "$*"; }

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || { log_err "Comando nao encontrado: $1"; exit 1; }
}

# ---------------------------------------------------------------------------
# IP Management
# ---------------------------------------------------------------------------
collect_ips(){
  echo "Cole os IPs dos Edge Nodes, um por linha. Linha vazia para finalizar:"
  : > "${EDGE_FILE}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    [[ "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$line" >> "${EDGE_FILE}"
    else
      log_warn "Entrada invalida ignorada: ${line}"
    fi
  done
  log "$(wc -l < "${EDGE_FILE}" | tr -d ' ') IP(s) salvos em ${EDGE_FILE}"
}

load_ips(){
  if [[ ! -s "${EDGE_FILE}" ]]; then
    log_warn "${EDGE_FILE} nao encontrado ou vazio."
    collect_ips
  fi
  mapfile -t EDGE_IPS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${EDGE_FILE}" 2>/dev/null || true)
  [[ ${#EDGE_IPS[@]} -gt 0 ]] || { log_err "Nenhum IP valido em ${EDGE_FILE}."; exit 1; }
  log "${#EDGE_IPS[@]} Edge Node(s): ${EDGE_IPS[*]}"
}

# ---------------------------------------------------------------------------
# Credentials — coletadas UMA VEZ, reutilizadas para todos os nos.
# IFS= read -r preserva qualquer caractere especial (/, \, ', ", etc.)
# ---------------------------------------------------------------------------
ask_admin_creds(){
  [[ -n "${NSX_PASS:-}" ]] && { log "Credenciais admin ja carregadas."; return 0; }
  read -rp  "Usuario admin [admin]: " NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  IFS= read -rsp "Senha admin (aceita qualquer caractere especial): " NSX_PASS; echo
  export NSX_USER NSX_PASS
  log "Credenciais admin coletadas para '${NSX_USER}'. Reutilizadas em todos os nos."
}

ask_root_creds(){
  [[ -n "${ROOT_PASS:-}" ]] && { log "Credenciais root ja carregadas."; return 0; }
  IFS= read -rsp "Senha root (aceita qualquer caractere especial): " ROOT_PASS; echo
  export ROOT_PASS
  log "Credenciais root coletadas. Reutilizadas em todos os nos."
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER 2>/dev/null || true
  log "Credenciais removidas da memoria."
}

# ---------------------------------------------------------------------------
# _sshpass_safe: escreve senha em tmpfile (600), passa via SSHPASS env var.
# Nunca expoe a senha em argumentos de processo (ps aux).
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
    ssh -i "${ADMIN_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -o BatchMode=yes "admin@${ip}" "$@"
  else
    _sshpass_safe NSX_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 "${NSX_USER}@${ip}" "$@"
  fi
}

ssh_root(){
  local ip="$1"; shift
  if [[ -f "${ROOT_KEY}" ]]; then
    ssh -i "${ROOT_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -o BatchMode=yes "root@${ip}" "$@"
  else
    _sshpass_safe ROOT_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 "root@${ip}" "$@"
  fi
}

admin_cmd(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd" 2>&1; }
root_cmd(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd" 2>&1; }

enable_root_ssh(){
  local ip="$1"
  log "${ip}: habilitando root SSH..."
  admin_cmd "$ip" 'set service ssh enabled; start service ssh; set service ssh root-login enabled' || true
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: desabilitando root SSH..."
  admin_cmd "$ip" 'set service ssh root-login disabled' || true
}

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
COMMON
chmod +x "${LIB_DIR}/common.sh"

# ===========================================================================
# automations/support_bundle/edge_nodes.example
# ===========================================================================
cat > "${AUTO_DIR}/edge_nodes.example" <<'EXAMPLE'
# edge_nodes.example — Template de IPs (nunca commitado como edge_nodes.txt)
# Formato: um IPv4 por linha. Linhas com # sao ignoradas.
# 192.168.10.10
# 192.168.10.11
EXAMPLE

# ===========================================================================
# automations/support_bundle/install_dependencies.sh
# ===========================================================================
cat > "${AUTO_DIR}/install_dependencies.sh" <<'INST'
#!/usr/bin/env bash
set -euo pipefail
OS_ID="$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")"
if [[ "$OS_ID" =~ (ubuntu|debian) ]]; then
  sudo apt-get update && sudo apt-get install -y openssh-client sshpass expect screen
elif [[ "$OS_ID" =~ (ol|oracle|rhel|centos|rocky|almalinux|fedora) ]]; then
  sudo dnf install -y openssh-clients sshpass expect screen 2>/dev/null \
    || sudo yum install -y openssh-clients sshpass expect screen
else
  echo "[WARN] OS '${OS_ID}' nao reconhecido. Instale: openssh-client sshpass expect screen"
fi
echo "[OK] Dependencias instaladas."
INST
chmod +x "${AUTO_DIR}/install_dependencies.sh"

# ===========================================================================
# automations/support_bundle/setup_keys.sh
# ===========================================================================
cat > "${AUTO_DIR}/setup_keys.sh" <<'SETUP'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh-keygen; need_cmd sshpass
load_ips
ask_admin_creds
[[ -f "${ADMIN_KEY}" ]] || ssh-keygen -t ed25519 -f "${ADMIN_KEY}" -N '' -C 'nsx-admin-key' -q
[[ -f "${ROOT_KEY}" ]]  || ssh-keygen -t ed25519 -f "${ROOT_KEY}"  -N '' -C 'nsx-root-key'  -q
ADMIN_PUB="$(cat "${ADMIN_KEY}.pub")"
ROOT_PUB="$(cat "${ROOT_KEY}.pub")"
for ip in "${EDGE_IPS[@]}"; do
  log "Distribuindo chaves para ${ip}..."
  admin_cmd "$ip" "set user admin ssh-key \"${ADMIN_PUB}\"" || true
  enable_root_ssh "$ip"
  admin_cmd "$ip" "set user root ssh-key \"${ROOT_PUB}\""  || true
  disable_root_ssh "$ip"
  log_ok "${ip}: chaves distribuidas."
done
clear_creds
log_ok "Setup de chaves SSH concluido."
SETUP
chmod +x "${AUTO_DIR}/setup_keys.sh"

# ===========================================================================
# automations/support_bundle/test_connections.sh
# ===========================================================================
cat > "${AUTO_DIR}/test_connections.sh" <<'TESTC'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh
load_ips
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds
REPORT="${LOG_DIR}/test_$(date +%Y%m%d_%H%M%S).log"
log "Relatorio: ${REPORT}"
for ip in "${EDGE_IPS[@]}"; do
  {
    echo "====================================== Node: ${ip}"
    echo "--- [1] Ping ---"
    ping -c 1 -W 2 "$ip" 2>&1 || echo "WARN: ping falhou"
    echo "--- [2] admin: get version ---";    admin_cmd "$ip" 'get version'      || echo "FAIL"
    echo "--- [3] admin: get service ssh ---"; admin_cmd "$ip" 'get service ssh'  || echo "FAIL"
    echo "--- [4] admin: get managers ---";   admin_cmd "$ip" 'get managers'     || echo "FAIL"
    echo "--- [5] habilitar root SSH ---";    enable_root_ssh "$ip"; sleep 2
    echo "--- [6] root: uname -a ---";        root_cmd "$ip" 'uname -a'         || echo "FAIL"
    echo "--- [7] root: uptime ---";          root_cmd "$ip" 'uptime'           || echo "FAIL"
    echo "--- [8] root: df -h /var/log ---";  root_cmd "$ip" 'df -h /var/log'   || echo "FAIL"
    echo "--- [9] support_bundle log ---"
    root_cmd "$ip" 'ls -lh /var/log/support_bundle 2>/dev/null || echo FILE_NOT_FOUND'
    echo "--- [10] desabilitar root SSH ---"; disable_root_ssh "$ip"
    echo
  } | tee -a "$REPORT"
done
clear_creds
log_ok "Teste concluido. Relatorio: ${REPORT}"
TESTC
chmod +x "${AUTO_DIR}/test_connections.sh"

# ===========================================================================
# automations/support_bundle/nsx_sb_main.sh
# ===========================================================================
cat > "${AUTO_DIR}/nsx_sb_main.sh" <<'MAIN'
#!/usr/bin/env bash
# nsx_sb_main.sh — Orquestrador: Fase 1 (solicita SB) + Fase 2 (verifica a cada 5 min)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
need_cmd ssh
load_ips
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds
RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"
EXPIRY_EPOCH="$(( $(date +%s) + 1800 ))"
auto_clear_bg(){
  ( while [[ "$(date +%s)" -lt "$1" ]]; do sleep 5; done
    rm -f "${RUN_DIR}/session.env" 2>/dev/null || true ) >/dev/null 2>&1 &
}
if [[ -n "${NSX_PASS:-}" ]]; then
  umask 077
  printf 'export NSX_USER=%q\nexport NSX_PASS=%q\nexport ROOT_PASS=%q\n' \
    "${NSX_USER}" "${NSX_PASS}" "${ROOT_PASS:-}" > "${RUN_DIR}/session.env"
  auto_clear_bg "$EXPIRY_EPOCH"
fi
log "=== FASE 1: Solicitacao do Support Bundle ==="
for ip in "${EDGE_IPS[@]}"; do
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n'     "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Fase 1 concluida. Aguardando geracao dos bundles..."
log "=== FASE 2: Verificacao ==="
declare -A NODE_DONE
for ip in "${EDGE_IPS[@]}"; do NODE_DONE["$ip"]="false"; done
for ((round=1; round<=6; round++)); do
  log "Verificacao ${round}/6 — aguardando 5 min..."
  sleep 300
  for ip in "${EDGE_IPS[@]}"; do
    [[ "${NODE_DONE[$ip]}" == "true" ]] && continue
    OUT="$(check_support_bundle "$ip" || true)"
    if grep -qiE 'error|fail|unable|denied' <<< "$OUT"; then
      log_err "${ip}: erro detectado."
      printf '%s,phase2,error,%q,%s\n'   "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    elif grep -qiE 'complete|generated|success' <<< "$OUT" && ! grep -q 'FILE_NOT_FOUND' <<< "$OUT"; then
      log_ok "${ip}: bundle confirmado."
      printf '%s,phase2,success,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    else
      log_warn "${ip}: ainda pendente..."
      printf '%s,phase2,pending,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
  done
done
log "=== FINAL: Desabilitando root SSH ==="
for ip in "${EDGE_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
clear_creds
rm -f "${RUN_DIR}/session.env" 2>/dev/null || true
log_ok "Concluido. CSV: ${STATUS_CSV}"
MAIN
chmod +x "${AUTO_DIR}/nsx_sb_main.sh"

# ===========================================================================
# automations/support_bundle/admin_exec.sh
# ===========================================================================
cat > "${AUTO_DIR}/admin_exec.sh" <<'ADMX'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_ips
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
echo ""
for i in "${!EDGE_IPS[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"; done
echo "  [A] Todos"
read -rp 'No (numero ou A): '       SEL
read -rp 'Comando NSX-T admin CLI: ' CMD
echo ""
run(){ echo "===== admin@${1} ====="; admin_cmd "$1" "$CMD" || true; echo; }
if [[ "${SEL^^}" == "A" ]]; then for ip in "${EDGE_IPS[@]}"; do run "$ip"; done
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL>=1 && SEL<=${#EDGE_IPS[@]} )); then run "${EDGE_IPS[$((SEL-1))]}"
else echo "[ERROR] Selecao invalida."; exit 1; fi
clear_creds
ADMX
chmod +x "${AUTO_DIR}/admin_exec.sh"

# ===========================================================================
# automations/support_bundle/root_exec.sh
# ===========================================================================
cat > "${AUTO_DIR}/root_exec.sh" <<'ROTX'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_ips
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds
echo ""
for i in "${!EDGE_IPS[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"; done
echo "  [A] Todos"
read -rp 'No (numero ou A): '                              SEL
read -rp 'Comando Linux root: '                            CMD
read -rp '[AVISO] Confirma execucao root em producao? [s/N]: ' CONFIRM
[[ "${CONFIRM,,}" =~ ^(s|y)$ ]] || { echo "Cancelado."; exit 0; }
run(){
  local ip="$1"
  echo "===== root@${ip} ====="
  enable_root_ssh "$ip"; sleep 2
  root_cmd "$ip" "$CMD" || true
  disable_root_ssh "$ip"
  echo
}
if [[ "${SEL^^}" == "A" ]]; then for ip in "${EDGE_IPS[@]}"; do run "$ip"; done
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL>=1 && SEL<=${#EDGE_IPS[@]} )); then run "${EDGE_IPS[$((SEL-1))]}"
else echo "[ERROR] Selecao invalida."; exit 1; fi
clear_creds
ROTX
chmod +x "${AUTO_DIR}/root_exec.sh"

# ===========================================================================
# automations/support_bundle/nsx_ssh_cli.sh  *** NOVO ***
# CLI interativo: seleciona no, usuario (admin ou root), modo de operacao
# (comando unico ou sessao de multiplos comandos), com historico de sessao.
# ===========================================================================
cat > "${AUTO_DIR}/nsx_ssh_cli.sh" <<'CLISCRIPT'
#!/usr/bin/env bash
# =============================================================================
# nsx_ssh_cli.sh
# CLI interativo para envio de comandos SSH aos Edge Nodes NSX.
#
# Modos:
#   1. Comando unico  — digita um comando, executa, volta ao menu
#   2. Sessao        — loop interativo, multiplos comandos, "exit" para sair
#
# Usuarios suportados: admin (NSX-T CLI) e root (Linux shell)
# Historico de comandos salvo em logs/cli_history_<data>.log
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
load_ips

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
clear
echo "================================================================"
echo " NSX Edge — CLI Interativo via SSH"
echo "================================================================"
echo " Nos disponiveis:"
for i in "${!EDGE_IPS[@]}"; do
  printf '   [%2d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"
done
echo "   [A ] Todos os nos (broadcast)"
echo "================================================================"
echo ""

# ---------------------------------------------------------------------------
# Selecao do no
# ---------------------------------------------------------------------------
read -rp "Selecione o no (numero ou A): " SEL
echo ""

if [[ "${SEL^^}" == "A" ]]; then
  TARGET_IPS=("${EDGE_IPS[@]}")
  TARGET_LABEL="TODOS OS NOS"
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#EDGE_IPS[@]} )); then
  TARGET_IPS=("${EDGE_IPS[$((SEL-1))]}")
  TARGET_LABEL="${TARGET_IPS[0]}"
else
  echo "[ERROR] Selecao invalida."
  exit 1
fi

# ---------------------------------------------------------------------------
# Selecao do usuario
# ---------------------------------------------------------------------------
echo "Usuario SSH:"
echo "  [1] admin  (NSX-T CLI)"
echo "  [2] root   (Linux shell)"
echo ""
read -rp "Selecione (1 ou 2): " USR_SEL

USE_ROOT=false
case "${USR_SEL}" in
  1)
    USER_LABEL="admin"
    if [[ ! -f "${ADMIN_KEY}" ]]; then
      need_cmd sshpass
      ask_admin_creds
    fi
    ;;
  2)
    USER_LABEL="root"
    USE_ROOT=true
    if [[ ! -f "${ADMIN_KEY}" ]]; then
      need_cmd sshpass
      ask_admin_creds   # necessario para enable/disable root SSH
    fi
    if [[ ! -f "${ROOT_KEY}" ]]; then
      ask_root_creds
    fi
    ;;
  *)
    echo "[ERROR] Opcao invalida."
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Modo de operacao
# ---------------------------------------------------------------------------
echo ""
echo "Modo:"
echo "  [1] Comando unico  (executa e volta ao menu)"
echo "  [2] Sessao         (multiplos comandos ate digitar 'exit')"
echo ""
read -rp "Selecione (1 ou 2): " MODE_SEL

# ---------------------------------------------------------------------------
# Arquivo de historico
# ---------------------------------------------------------------------------
HISTORY_FILE="${LOG_DIR}/cli_history_$(date +%Y%m%d).log"
mkdir -p "${LOG_DIR}"

log_cmd(){
  local ip="$1" user="$2" cmd="$3" output="$4"
  printf '\n[%s] user=%s ip=%s\nCMD: %s\nOUT:\n%s\n%s\n' \
    "$(date '+%F %T')" "$user" "$ip" "$cmd" "$output" \
    '----------------------------------------------------------------' \
    >> "${HISTORY_FILE}"
}

# ---------------------------------------------------------------------------
# Execucao de um comando em todos os IPs alvo
# ---------------------------------------------------------------------------
exec_on_targets(){
  local cmd="$1"
  for ip in "${TARGET_IPS[@]}"; do
    echo ""
    echo "  ===== ${USER_LABEL}@${ip} ====="
    local out
    if [[ "${USE_ROOT}" == "true" ]]; then
      enable_root_ssh "$ip" >/dev/null 2>&1 || true
      sleep 1
      out="$(root_cmd "$ip" "$cmd" 2>&1 || true)"
      disable_root_ssh "$ip" >/dev/null 2>&1 || true
    else
      out="$(admin_cmd "$ip" "$cmd" 2>&1 || true)"
    fi
    echo "${out}"
    log_cmd "$ip" "${USER_LABEL}" "$cmd" "$out"
  done
  echo ""
}

# ---------------------------------------------------------------------------
# MODO 1: Comando unico
# ---------------------------------------------------------------------------
if [[ "${MODE_SEL}" == "1" ]]; then
  echo ""
  echo "----------------------------------------------------------------"
  echo " Modo: Comando Unico | Usuario: ${USER_LABEL} | Alvo: ${TARGET_LABEL}"
  echo "----------------------------------------------------------------"
  echo ""
  read -rp "Comando: " CMD
  [[ -z "$CMD" ]] && { echo "Nenhum comando informado."; clear_creds; exit 0; }
  exec_on_targets "$CMD"
  echo "  Historico salvo em: ${HISTORY_FILE}"
  clear_creds
  exit 0
fi

# ---------------------------------------------------------------------------
# MODO 2: Sessao interativa
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " SESSAO INTERATIVA"
echo " Usuario : ${USER_LABEL}"
echo " Alvo    : ${TARGET_LABEL}"
echo " Historico: ${HISTORY_FILE}"
echo " Digite 'exit' ou 'quit' para encerrar."
echo " Digite 'nos' para listar os IPs alvo."
echo " Digite 'historico' para exibir os ultimos 30 comandos."
echo "================================================================"
echo ""

while true; do
  # Prompt estilo shell
  printf "[nsx-cli][${USER_LABEL}@${TARGET_LABEL}]$ "
  IFS= read -r CMD || break

  # Comandos internos
  case "${CMD,,}" in
    exit|quit)
      echo "Encerrando sessao."
      break
      ;;
    nos|nodes)
      echo "  Nos alvo: ${TARGET_IPS[*]}"
      continue
      ;;
    historico|history)
      tail -n 60 "${HISTORY_FILE}" 2>/dev/null || echo "  Historico vazio."
      continue
      ;;
    "")
      continue
      ;;
  esac

  exec_on_targets "${CMD}"
done

clear_creds
echo ""
echo "Sessao encerrada. Historico: ${HISTORY_FILE}"
CLISCRIPT
chmod +x "${AUTO_DIR}/nsx_ssh_cli.sh"

# ===========================================================================
# docs/MANUAL.md
# ===========================================================================
cat > "${DOCS_DIR}/MANUAL.md" <<'MANUALDOC'
# Manual Geral

## Scripts disponiveis

| Script                  | Descricao                                                    |
|-------------------------|--------------------------------------------------------------|
| `deploy_nsx_sb_check.sh`| Deploy completo; coleta IPs durante a instalacao            |
| `install_dependencies.sh`| Instala openssh-client, sshpass, expect, screen            |
| `setup_keys.sh`         | Gera chaves Ed25519 e distribui para cada no                |
| `test_connections.sh`   | Valida ping, admin CLI e acesso root em todos os nos        |
| `nsx_sb_main.sh`        | Orquestrador principal do support bundle (Fases 1 e 2)      |
| `nsx_ssh_cli.sh`        | CLI interativo admin/root com historico de sessao           |
| `admin_exec.sh`         | Comando unico como admin nos nos selecionados               |
| `root_exec.sh`          | Comando unico como root (pede confirmacao)                  |

## nsx_ssh_cli.sh — CLI Interativo

Permite enviar comandos diretamente ao NSX-T CLI (admin) ou ao Linux shell (root) de um
ou todos os Edge Nodes, sem precisar abrir sessoes SSH manualmente.

```
Modos:
  1. Comando unico  — digita um comando, ve o resultado, encerra
  2. Sessao         — loop interativo, varios comandos, "exit" para sair

Comandos internos da sessao:
  exit / quit    Encerra a sessao
  nos / nodes    Lista os IPs alvo da sessao
  historico      Exibe os ultimos 60 registros do historico
```

Historico salvo automaticamente em `logs/cli_history_<data>.log`.

## Senhas
- Coletadas uma vez, reutilizadas para todos os nos
- Aceita qualquer caractere especial
- Passadas ao sshpass via arquivo temporario privado (600)
- Removidas da memoria ao final

## Politica de Root SSH
- Habilitado apenas quando necessario
- Desabilitado imediatamente apos cada no
MANUALDOC

# ===========================================================================
# docs/CONTRIBUTING.md
# ===========================================================================
cat > "${DOCS_DIR}/CONTRIBUTING.md" <<'CONTRIBDOC'
# Como Adicionar uma Nova Automacao

```bash
mkdir automations/<nome>
cd automations/<nome>
```

Inicie o script com:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_ips
ask_admin_creds

# ... logica ...

clear_creds
```

## Funcoes de lib/common.sh

| Funcao                | Descricao                                            |
|-----------------------|------------------------------------------------------|
| `load_ips`            | Carrega edge_nodes.txt, solicita se vazio            |
| `ask_admin_creds`     | Coleta usuario e senha admin (uma vez)               |
| `ask_root_creds`      | Coleta senha root (uma vez)                          |
| `clear_creds`         | Remove credenciais da memoria                        |
| `admin_cmd ip cmd`    | Executa comando NSX CLI como admin                   |
| `root_cmd ip cmd`     | Executa comando Linux como root                      |
| `enable_root_ssh ip`  | Habilita login root SSH                              |
| `disable_root_ssh ip` | Desabilita login root SSH                            |
| `log / log_ok / log_warn / log_err` | Log com timestamp                      |
| `need_cmd binario`    | Encerra se binario nao encontrado no PATH            |
CONTRIBDOC

# ===========================================================================
# examples/ip_list_example.txt
# ===========================================================================
cat > "${EXAMPLES_DIR}/ip_list_example.txt" <<'IPEX'
# Formato para edge_nodes.txt — um IPv4 por linha. # sao ignorados.
192.168.1.10
192.168.1.11
192.168.1.12
IPEX

# ===========================================================================
# Sumario final
# ===========================================================================
echo ""
echo "================================================================"
echo " Kit NSX Edge Automation instalado com sucesso! v3.0"
echo "================================================================"
echo ""
echo "  Localizacao : ${BASE_DIR}"
echo ""
echo "  IPs configurados:"
while IFS= read -r _ip; do echo "    - ${_ip}"; done < "${EDGE_FILE}"
echo ""
echo "  Proximos passos:"
echo "    cd ${AUTO_DIR}"
echo "    ./install_dependencies.sh"
echo "    ./setup_keys.sh          # configura autenticacao por chave"
echo "    ./test_connections.sh    # valida conectividade"
echo "    ./nsx_ssh_cli.sh         # CLI interativo admin/root"
echo "    screen -S nsx_sb && ./nsx_sb_main.sh"
echo ""
echo "  Senhas: coletadas uma vez, qualquer caractere aceito."
echo ""
