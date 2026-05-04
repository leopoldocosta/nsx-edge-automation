# Contributing: Adding a New Automation

## Step-by-step

### 1. Create the folder

```bash
mkdir automations/<your_automation_name>
cd automations/<your_automation_name>
```

### 2. Create the IP list template

```bash
cat > edge_nodes.example <<'EOF'
# edge_nodes.example
# Copy to edge_nodes.txt and add your real IPs.
# 192.168.1.10
# 192.168.1.11
EOF
```

### 3. Create your main script

Start every script with:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"      # tells common.sh where to store logs/keys/IPs
source "${SCRIPT_DIR}/../../lib/common.sh"

load_ips         # loads edge_nodes.txt (prompts if missing)
ask_admin_creds  # only if SSH keys not yet set up

# ... your automation logic ...

clear_creds
```

### 4. Available functions from common.sh

| Function | Description |
|---|---|
| `load_ips` | Loads `edge_nodes.txt`, prompts to fill if empty |
| `ask_admin_creds` | Prompts for admin username and password |
| `clear_creds` | Unsets all credential variables |
| `admin_cmd ip cmd` | Runs NSX CLI command as admin (key or password) |
| `root_cmd ip cmd` | Runs Linux command as root (key or password) |
| `enable_root_ssh ip` | Enables root SSH login via admin CLI |
| `disable_root_ssh ip` | Disables root SSH login via admin CLI |
| `log msg` | Timestamped log line |
| `log_ok msg` | Timestamped OK line |
| `log_warn msg` | Timestamped WARN line |
| `log_err msg` | Timestamped ERR line |
| `need_cmd binary` | Exits if binary not found in PATH |

### 5. Add a README.md

Document: purpose, workflow, prerequisites, and usage example.

### 6. Commit

```bash
git add automations/<your_automation_name>/
git commit -m "feat(automations): add <your_automation_name>"
git push origin main
```
