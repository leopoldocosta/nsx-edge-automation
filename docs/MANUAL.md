# General Usage Manual

## Repository Design

This toolkit follows a **shared library + isolated automations** pattern:

```
lib/common.sh          ← single source of truth for SSH, auth, IP loading
automations/<name>/    ← self-contained folder per use case
```

Each automation:
- Sources `../../lib/common.sh`
- Sets `export AUTO_DIR="${SCRIPT_DIR}"` before sourcing, so logs, keys and IP file resolve to its own folder
- Contains its own `edge_nodes.example` template

## IP File Convention

| File | Committed | Purpose |
|---|---|---|
| `edge_nodes.example` | ✅ Yes | Template, no real IPs |
| `edge_nodes.txt` | ❌ No (git-ignored) | Your real IP list |

Populate `edge_nodes.txt` by:
1. Copying the example: `cp edge_nodes.example edge_nodes.txt`
2. Editing with real IPs (one per line)
3. Or pasting directly when the script prompts you

## Credentials Lifecycle

| Credential | When collected | When cleared |
|---|---|---|
| `NSX_PASS` | Start of script | `unset` after use / 30-min auto-clear |
| `ROOT_PASS` | Per-node when no key | `unset` immediately after each node |
| SSH keys | Once via `setup_keys.sh` | Never — stored in `.ssh_keys/` (git-ignored) |

## Root SSH Policy

- **Enabled** only at the moment an automation needs root access
- **Disabled** immediately after each node completes
- **Disabled** on all nodes in the FINAL cleanup step
- `test_connections.sh` also disables root SSH after validation

## Adding a New Automation

See [CONTRIBUTING.md](CONTRIBUTING.md).
