# NSX Edge Support Bundle Automation

Bash automation kit for collecting and verifying **support bundles** on NSX Edge Nodes (NSX-T / VMware NSX).

> **Notice:** This repository contains generic infrastructure automation scripts. No proprietary data, credentials, or environment-specific references are included.

## Features

- Controlled enable/disable of root SSH access
- Support bundle request via admin CLI
- Automated verification of bundle generation (log + file presence)
- Interactive IP list input (paste multi-line from clipboard)
- SSH key (Ed25519) or password authentication
- Free-form command executor in both admin and root modes
- Connectivity and validation test script
- Compatible with **Ubuntu/Debian (WSL included)** and **Oracle Linux / RHEL-family**

## Repository Structure

```
.
├── src/
│   ├── lib/
│   │   └── common.sh             # Shared functions (SSH, credentials, IPs)
│   ├── install_dependencies.sh   # Package installer (apt / dnf / yum)
│   ├── setup_keys.sh             # SSH key generation and distribution
│   ├── test_connections.sh       # Connectivity and command validation
│   ├── nsx_sb_main.sh            # Main orchestrator (Phase 1 + Phase 2)
│   ├── admin_exec.sh             # Ad-hoc admin CLI command executor
│   └── root_exec.sh              # Ad-hoc root Linux command executor
├── docs/
│   └── MANUAL.md                 # Usage guide and architecture
├── examples/
│   └── ip_list_example.txt       # Sample IP list format
├── .gitignore
└── README.md
```

## Requirements

| Package | Ubuntu/Debian | Oracle Linux / RHEL |
|---|---|---|
| SSH client | `openssh-client` | `openssh-clients` |
| SSH with password | `sshpass` | `sshpass` |
| Interactive automation | `expect` | `expect` |
| Persistent session | `screen` | `screen` |

## Quick Start

```bash
cd src
./install_dependencies.sh   # Install required packages
./setup_keys.sh             # Generate and distribute SSH keys
./test_connections.sh       # Validate environment (disables root SSH at end)
./nsx_sb_main.sh            # Run full automation (disables root SSH at end)
```

### Running in background (recommended for long executions)

```bash
screen -S nsx_sb
cd src && ./nsx_sb_main.sh
# Detach: Ctrl+A, D
# Reattach: screen -r nsx_sb
```

## Security

- Passwords are collected interactively and cleared from memory with `unset` after use
- Root SSH is enabled **only during execution** and disabled automatically at the end
- SSH private keys are stored in `.ssh_keys/` which is covered by `.gitignore`
- Session credential file (if created) is auto-removed after 30 minutes

## Adjusting for Your NSX Version

Edit `src/lib/common.sh` to match your NSX CLI commands:

```bash
enable_root_ssh()    # Command to enable root login via SSH
disable_root_ssh()   # Command to disable root login via SSH
request_support_bundle()  # Command to trigger bundle generation
check_support_bundle()    # Log/file paths to verify generation
```

## License

MIT — free to use for infrastructure automation.
