#!/usr/bin/env bash
# =============================================================================
# deploy_nsx_sb_check.sh  v4.0
# Deploy local do kit NSX Edge Automation - Support Bundle
#
# USO:
#   bash deploy_nsx_sb_check.sh [--dir /caminho/destino]
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
echo "  NSX Edge Automation — Support Bundle Kit  v4.0"
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
# lib/common.sh
# ---------------------------------------------------------------------------
cat > "${LIB_DIR}/common.sh" <<'COMMON'
#!/usr/bin/env bash
# lib/common.sh
# Biblioteca compartilhada para todos os scripts NSX Edge Automation.
# Autenticação: sempre sshpass (senha). Sem chaves SSH.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_DIR="${AUTO_DIR:-$(pwd)}"

LOG_DIR="${AUTO_DIR}/logs"
RUN_DIR="${AUTO_DIR}/run"
EDGE_FILE="${AUTO_DIR}/edge_nodes.txt"
EDGE_EXAMPLE="${AUTO_DIR}/edge_nodes.example"

mkdir -p "${LOG_DIR}" "${RUN_DIR}"

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
# Credenciais — coletadas interativamente UMA VEZ e reutilizadas
# Armazenadas apenas em memória, nunca em disco.
# ---------------------------------------------------------------------------
ask_admin_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Credenciais admin já carregadas, pulando prompt."
    return 0
  fi
  read -rp  "Usuário admin [admin]: " NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  IFS= read -rsp "Senha admin (todos os caracteres especiais aceitos): " NSX_PASS; echo
  export NSX_USER NSX_PASS
  log "Credenciais coletadas para '${NSX_USER}'. Serão reutilizadas em todos os nodes."
}

ask_root_creds(){
  if [[ -n "${ROOT_PASS:-}" ]]; then
    log "Credenciais root já carregadas, pulando prompt."
    return 0
  fi
  IFS= read -rsp "Senha root (todos os caracteres especiais aceitos): " ROOT_PASS; echo
  export ROOT_PASS
  log "Credenciais root coletadas. Serão reutilizadas em todos os nodes."
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER 2>/dev/null || true
  log "Credenciais removidas da memória."
}

prompt_clear_creds(){
  echo ""
  read -rp "Limpar credenciais da memória? [S/n]: " _CLR
  if [[ "${_CLR,,}" == "n" ]]; then
    log "Credenciais mantidas na sessão."
  else
    clear_creds
  fi
}

# ---------------------------------------------------------------------------
# SSH — sempre via sshpass (senha). Sem chaves SSH.
# ---------------------------------------------------------------------------
ssh_admin(){
  local ip="$1"; shift
  export SSHPASS="${NSX_PASS}"
  sshpass -e ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
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
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
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
  log "${ip}: habilitando root SSH..."
  log "${ip}: >> set ssh root-login"
  admin_cmd "$ip" 'set ssh root-login' || true
  log "${ip}: >> get service ssh"
  admin_cmd "$ip" 'get service ssh' || true
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: desabilitando root SSH..."
  log "${ip}: >> clear ssh root-login"
  admin_cmd "$ip" 'clear ssh root-login' || true
  log "${ip}: >> get service ssh"
  admin_cmd "$ip" 'get service ssh' || true
}

# ---------------------------------------------------------------------------
# Support Bundle
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
if command -v apt-get &>/dev/null; then
  apt-get update -qq && apt-get install -y sshpass
elif command -v yum &>/dev/null; then
  yum install -y sshpass
elif command -v dnf &>/dev/null; then
  dnf install -y sshpass
else
  echo "[ERR] Gerenciador de pacotes não reconhecido. Instale sshpass manualmente."
  exit 1
fi
echo "[OK] sshpass instalado."
INST
chmod +x "${AUTO_DIR}/install_dependencies.sh"

# ---------------------------------------------------------------------------
# setup_keys.sh (placeholder)
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/setup_keys.sh" <<'SETUP'
#!/usr/bin/env bash
# setup_keys.sh — placeholder
# Chaves SSH não são usadas nesta versão.
# A autenticação é sempre por senha via sshpass.
# Execute test_connections.sh para validar a conectividade.
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
    admin_cmd "$ip" 'get version' || echo "FAIL"

    echo "--- [3] admin: get service ssh ---"
    admin_cmd "$ip" 'get service ssh' || echo "FAIL"

    echo "--- [4] admin: get managers ---"
    admin_cmd "$ip" 'get managers' || echo "FAIL"

    echo "--- [5] enable root SSH ---"
    enable_root_ssh "$ip"
    sleep 2

    echo "--- [6] root: uname -a ---"
    root_cmd "$ip" 'uname -a' || echo "FAIL"

    echo "--- [7] root: uptime ---"
    root_cmd "$ip" 'uptime' || echo "FAIL"

    echo "--- [8] root: df -h /var/log ---"
    root_cmd "$ip" 'df -h /var/log' || echo "FAIL"

    echo "--- [9] presença do log support_bundle ---"
    root_cmd "$ip" 'ls -lh /var/log/support_bundle 2>/dev/null || echo FILE_NOT_FOUND'

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
# nsx_sb_main.sh
# ---------------------------------------------------------------------------
cat > "${AUTO_DIR}/nsx_sb_main.sh" <<'MAIN'
#!/usr/bin/env bash
# nsx_sb_main.sh - Orquestrador: Fase 1 (solicitar SB) + Fase 2 (verificar a cada 5 min)
# Recomendado: rodar dentro de screen ou tmux (~35 min no total)
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

# ---- FASE 1: Habilitar root SSH + Solicitar Support Bundle ----
log "=== FASE 1: Solicitação do Support Bundle ==="
for ip in "${EDGE_IPS[@]}"; do
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n'     "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Fase 1 concluída. Aguardando geração dos bundles..."

# ---- FASE 2: Verificar a cada 5 min, por até 30 min (6 rodadas) ----
log "=== FASE 2: Verificação ==="
declare -A NODE_DONE
for ip in "${EDGE_IPS[@]}"; do NODE_DONE["$ip"]="false"; done

for ((round=1; round<=6; round++)); do
  log "Verificação ${round}/6 — aguardando 5 min..."
  sleep 300
  for ip in "${EDGE_IPS[@]}"; do
    [[ "${NODE_DONE[$ip]}" == "true" ]] && continue
    OUT="$(check_support_bundle "$ip" || true)"
    if grep -qiE 'error|fail|unable|denied' <<< "$OUT"; then
      log_err  "${ip}: erro detectado — encerrando verificações para este node."
      printf '%s,phase2,error,%q,%s\n'   "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    elif grep -qiE 'complete|generated|success' <<< "$OUT" && ! grep -q 'FILE_NOT_FOUND' <<< "$OUT"; then
      log_ok   "${ip}: bundle confirmado."
      printf '%s,phase2,success,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    else
      log_warn "${ip}: ainda pendente..."
      printf '%s,phase2,pending,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
  done
done

# ---- FINAL: Desabilitar root SSH em todos os nodes ----
log "=== FINAL: Desabilitando root SSH ==="
for ip in "${EDGE_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

log_ok "Concluído. CSV de status: ${STATUS_CSV}"
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
  admin_cmd "$ip" "${NSX_CMD}" || log_warn "${ip}: comando retornou erro"
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
  root_cmd "$ip" "${SHELL_CMD}" || log_warn "${ip}: comando retornou erro"

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
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
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

- `sshpass` instalado: `bash install_dependencies.sh`
- Arquivo `edge_nodes.txt` com IPs dos Edge Nodes (um por linha)

## Fluxo de uso

### 1. Deploy (primeira vez ou após reinstalação)

```bash
bash deploy_nsx_sb_check.sh
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
As credenciais ficam em memória durante a sessão e são apagadas ao final.
Nunca são escritas em disco.
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
  echo "[WARN] sshpass não encontrado. Execute:"
  echo "       bash ${AUTO_DIR}/install_dependencies.sh"
else
  echo "[OK] sshpass encontrado: $(command -v sshpass)"
fi

# ---------------------------------------------------------------------------
# Resumo final
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  Deploy concluído!"
echo "================================================================"
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
