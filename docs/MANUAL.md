# Usage Manual

## Prerequisites

- Edge Nodes reachable via SSH (port 22)
- Admin user with permission to manage SSH service settings
- CLI commands may vary by product version — adjust `src/lib/common.sh` as needed

## Architecture Overview

### Phase 1 — Request
1. Enables root SSH on each Edge Node (via admin CLI)
2. Triggers support bundle generation
3. Logs status per node to `logs/sb_status_<timestamp>.csv`

### Phase 2 — Verification
1. Waits ~30 minutes (configurable)
2. Checks every 5 minutes:
   - Reads `/var/log/support_bundle` log file
   - Searches for `.tgz`/`.tar.gz` bundle files
   - Detects active generation processes
3. Stops early on error detection
4. Disables root SSH on all nodes at completion

## Variables

| Variable | Description | Lifetime |
|---|---|---|
| `NSX_USER` | Admin username | Session |
| `NSX_PASS` | Admin password | Cleared after 30 min |
| `ROOT_PASS` | Root password (if no key) | Cleared after use |

## SSH Key Flow

```
[setup_keys.sh]
  ├── Generates: .ssh_keys/nsx_admin_key (Ed25519)
  ├── Generates: .ssh_keys/nsx_root_key  (Ed25519)
  └── Distributes pubkeys via:
       admin: 'set user admin ssh-key "<pubkey>"'
       root:  'set user root ssh-key "<pubkey>"'
```

After initial setup, all subsequent connections use keys — no password needed.

## Log Files

| File | Content |
|---|---|
| `logs/sb_run_<ts>.log` | Full execution log |
| `logs/sb_status_<ts>.csv` | Per-node status (ip, phase, status, details, timestamp) |
| `logs/test_<ts>.log` | Test run output |

## Migrating Between Distros

`install_dependencies.sh` reads `/etc/os-release` to detect:
- Ubuntu/Debian → `apt-get`
- Oracle Linux, RHEL, CentOS, Rocky, AlmaLinux, Fedora → `dnf` or `yum`

## Customization

All shared functions are in `src/lib/common.sh`. Key functions to review:

```bash
enable_root_ssh(ip)         # Adjust NSX CLI command for your version
disable_root_ssh(ip)        # Adjust NSX CLI command for your version
request_support_bundle(ip)  # Adjust SB trigger command
check_support_bundle(ip)    # Adjust file paths and grep patterns
```
