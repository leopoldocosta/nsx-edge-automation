# Automation: Support Bundle Collection

Collects and verifies NSX support bundles across all Edge Nodes.

## Workflow

```
Phase 1 (immediate)
  ├── Enable root SSH on each node
  ├── Request support bundle generation
  └── Log status

Phase 2 (check every 5 min, up to 30 min)
  ├── Read /var/log/support_bundle
  ├── Search for .tgz / .tar.gz files
  ├── Stop early on error
  └── Disable root SSH on all nodes when done
```

## Setup

```bash
cd automations/support_bundle

# 1. Create your IP list
cp edge_nodes.example edge_nodes.txt
vim edge_nodes.txt   # add your Edge Node IPs

# 2. Install dependencies (first time only)
./install_dependencies.sh

# 3. Set up SSH keys (first time only)
./setup_keys.sh

# 4. Validate environment
./test_connections.sh

# 5. Run (recommended inside screen)
screen -S nsx_sb
./nsx_sb_main.sh
```

## Ad-hoc Commands

```bash
./admin_exec.sh   # run any NSX-T CLI command as admin
./root_exec.sh    # run any Linux command as root
```
