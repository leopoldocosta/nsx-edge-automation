# NSX Edge Automations

Bash automation toolkit for managing NSX Edge Nodes (NSX-T / VMware NSX).

Designed to be extended: each use case lives in its own folder under `automations/`, all sharing a common SSH/auth library.

> **Notice:** No proprietary data, credentials, environment-specific references, or real IP addresses are included in this repository.

## Repository Structure

```
.
├── lib/
│   └── common.sh                      # Shared: SSH, auth, IP loading, root control
│
├── automations/
│   └── support_bundle/                # Use case: NSX support bundle collection
│       ├── edge_nodes.example         # IP list template (copy to edge_nodes.txt)
│       ├── install_dependencies.sh
│       ├── setup_keys.sh
│       ├── test_connections.sh
│       ├── nsx_sb_main.sh
│       ├── admin_exec.sh
│       ├── root_exec.sh
│       └── README.md
│
├── docs/
│   ├── MANUAL.md                      # General usage guide
│   └── CONTRIBUTING.md                # How to add a new automation
│
├── examples/
│   └── ip_list_example.txt
│
├── .gitignore
└── README.md
```

## Quick Start

```bash
# 1. Go to the automation you need
cd automations/support_bundle

# 2. Create your IP list from the template
cp edge_nodes.example edge_nodes.txt
# Edit edge_nodes.txt with real IPs (never committed)

# 3. Install dependencies
./install_dependencies.sh

# 4. Set up SSH keys (one time)
./setup_keys.sh

# 5. Test connections
./test_connections.sh

# 6. Run the automation
./nsx_sb_main.sh
```

## IP Address Management

Each automation folder contains an `edge_nodes.example` file as a template.
The actual `edge_nodes.txt` is **never committed** (covered by `.gitignore`).

```
edge_nodes.example   ← versioned template, safe to commit
edge_nodes.txt       ← your real IPs, local only, git-ignored
```

Populate by pasting IPs directly (one per line), or copying from a spreadsheet.

## Security

- Passwords collected interactively, cleared from memory after use
- Root SSH enabled only during execution, disabled automatically at the end
- SSH private keys stored in `.ssh_keys/` (git-ignored)
- Session credential file auto-deleted after 30 minutes

## Adding a New Automation

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

## License

MIT — free to use for infrastructure automation.
