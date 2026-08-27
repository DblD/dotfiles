# Sanitize bayport-vpn for Team Distribution

## Context

You are creating a sanitized, generic version of `scripts/bayport-vpn.sh` and `scripts/bayport-vpn-completion.bash` for distribution to the team via a GitLab repo. The original script has company-specific references that need to be replaced with configurable/generic equivalents.

The output goes to: `/tmp/openfortivpn-wrapper/` — create all files there.

## Source Files

- Main script: `/Users/dbld/.code/dotfiles/scripts/bayport-vpn.sh` (2381 lines)
- Completion: `/Users/dbld/.code/dotfiles/scripts/bayport-vpn-completion.bash`
- README (for reference): `/Users/dbld/.code/dotfiles/docs/bayport-vpn-README.md`

## Deliverables

Create these files in `/tmp/openfortivpn-wrapper/`:

### 1. `bin/fortivpn-wrapper.sh` — Sanitized main script

Read the source and apply these transformations:

| Find | Replace With |
|------|-------------|
| `bayport-vpn` (in paths, cache dirs, keystore labels, config names) | `fortivpn-wrapper` |
| `Bayport VPN Connection Script` (banner) | `OpenFortiVPN Split-Tunnel Wrapper` |
| `bayport-vpn-session` (keystore service name) | `fortivpn-wrapper-session` |
| `bayport-vpn-probe` (secret-tool probe) | `fortivpn-wrapper-probe` |
| `~/.cache/bayport-vpn/` | `~/.cache/fortivpn-wrapper/` |
| `~/.config/bayport-vpn/` | `~/.config/fortivpn-wrapper/` |
| Hardcoded port `10443` in check_connection, show_config, connect_vpn | Read from Bitwarden custom field `port` with default 10443 — add `VPN_PORT` variable parsed in `parse_vpn_config()` |
| Hardcoded subnet list in `default_routes()` | Replace with example subnets and a clear comment: "# CUSTOMIZE: Replace with your internal subnets" |
| `# Bayport VPN Routes Configuration` | `# OpenFortiVPN Wrapper — Routes Configuration` |
| `# Bayport VPN Split DNS Configuration` | `# OpenFortiVPN Wrapper — Split DNS Configuration` |

Also:
- The script name derivation (`get_item_name`) derives the Bitwarden item name from the script filename. This is fine — document it in the README. When team members rename the script (e.g. `client-vpn.sh`), it looks for a Bitwarden item named `client-vpn`.
- Add a `VPN_PORT` variable (default 10443) parsed from Bitwarden custom field `port` in `parse_vpn_config()`. Use `$VPN_PORT` everywhere instead of hardcoded 10443.
- Keep ALL the security hardening, split-tunnel enforcement, keystore detection, DNS leak testing, etc. — just remove company-specific values.

### 2. `bin/fortivpn-wrapper-completion.bash` — Sanitized completion

Copy from source, replace `bayport-vpn` references with `fortivpn-wrapper`.

### 3. `config/routes.conf.example` — Example routes config

```
# OpenFortiVPN Wrapper — Routes Configuration
# One CIDR subnet per line. Lines starting with # are comments.
# Copy this file to ~/.config/fortivpn-wrapper/routes.conf and customize.
#
# Example internal subnets:
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
```

### 4. `config/dns.conf.example` — Example DNS config

```
# OpenFortiVPN Wrapper — Split DNS Configuration
# Internal domains that should resolve via VPN DNS (one per line).
# Copy this file to ~/.config/fortivpn-wrapper/dns.conf and customize.
#
# Optionally specify VPN DNS server (auto-detected from pppd if not set):
# nameserver 10.1.0.10
#
# Internal domains:
# corp.example.com
# internal.example.com
```

### 5. `mise.toml` — Task runner config

```toml
[tools]
# No tool dependencies managed by mise — deps installed via setup

[tasks.setup]
description = "Install dependencies and configure the wrapper"
run = "./setup.sh"

[tasks.install]
description = "Install the wrapper script and completion to ~/.local/bin"
run = """
mkdir -p ~/.local/bin
cp bin/fortivpn-wrapper.sh ~/.local/bin/
chmod +x ~/.local/bin/fortivpn-wrapper.sh
echo "Installed to ~/.local/bin/fortivpn-wrapper.sh"
echo "Add ~/.local/bin to PATH if not already there"
"""

[tasks.install-completion]
description = "Install bash completion"
run = """
mkdir -p ~/.local/share/bash-completion/completions
cp bin/fortivpn-wrapper-completion.bash ~/.local/share/bash-completion/completions/fortivpn-wrapper
echo "Completion installed. Restart shell or: source ~/.local/share/bash-completion/completions/fortivpn-wrapper"
"""

[tasks.init-config]
description = "Create config files from examples"
run = """
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fortivpn-wrapper"
mkdir -p "$config_dir"
if [ ! -f "$config_dir/routes.conf" ]; then
    cp config/routes.conf.example "$config_dir/routes.conf"
    echo "Created $config_dir/routes.conf — edit with your internal subnets"
else
    echo "routes.conf already exists, skipping"
fi
if [ ! -f "$config_dir/dns.conf" ]; then
    cp config/dns.conf.example "$config_dir/dns.conf"
    echo "Created $config_dir/dns.conf — edit with your internal domains"
else
    echo "dns.conf already exists, skipping"
fi
"""

[tasks.connect]
description = "Connect to VPN (pass script name as argument for Bitwarden item lookup)"
run = "~/.local/bin/fortivpn-wrapper.sh"

[tasks.check]
description = "Run dependency and connection checks"
run = "~/.local/bin/fortivpn-wrapper.sh --check-deps && ~/.local/bin/fortivpn-wrapper.sh --check-connection"

[tasks.verify]
description = "Verify split-tunnel routing is correct"
run = "~/.local/bin/fortivpn-wrapper.sh --verify-routes"

[tasks.status]
description = "Show VPN session and NetBird status"
run = "~/.local/bin/fortivpn-wrapper.sh --session-status && ~/.local/bin/fortivpn-wrapper.sh --netbird-status"
```

### 6. `setup.sh` — Bootstrap script

Create a setup script that:
- Detects OS (macOS/Linux)
- Checks for and installs dependencies: `bw`, `jq`, `openfortivpn`
  - macOS: `brew install bitwarden-cli jq openfortivpn`
  - Linux (Debian/Ubuntu): `sudo apt install jq` + instructions for bw and openfortivpn
  - Linux (Fedora/RHEL): `sudo dnf install jq` + instructions
- Installs the script to `~/.local/bin/`
- Installs completion
- Creates initial config from examples
- Prompts user to log into Bitwarden (`bw login`)
- Runs `--check-deps` to verify everything works
- Prints next steps

### 7. `.gitignore`

```
# OS
.DS_Store
*.swp
*~

# Config with secrets (examples are tracked, actual configs are not)
config/routes.conf
config/dns.conf
!config/*.example
```

### 8. `README.md` — Full documentation

Write a clean README with:

- **What it does**: OpenFortiVPN wrapper with strict split-tunnel enforcement, cross-platform support (macOS + Linux), auto-reconnect, DNS leak protection
- **Features list** (bullet points): split-tunnel, split DNS, keystore detection, health monitoring, route leak detection, etc.
- **Quick start**: clone, run setup.sh, configure Bitwarden item, connect
- **Bitwarden setup**: What fields are needed (username, password, host, port, trusted-cert custom fields)
- **Configuration**: routes.conf and dns.conf explained
- **Usage examples**: common commands
- **How the script name works**: Script filename = Bitwarden item name. Rename to `client-vpn.sh` → looks for `client-vpn` in Bitwarden. Symlink for multiple VPNs.
- **Troubleshooting**: common issues
- **Security model**: What protections are in place (no eval, keystore detection, input validation, DNS leak test, etc.)

Do NOT include any Bayport/company references. This should read as a generic open-source-style tool.

## Constraints

- Do NOT modify the original files in `/Users/dbld/.code/dotfiles/`
- All output goes to `/tmp/openfortivpn-wrapper/`
- Run `bash -n` on the sanitized script to verify syntax
- Verify no `bayport` references remain: `grep -ri bayport /tmp/openfortivpn-wrapper/`

## Status File

Update `.claude-team/agents/sanitizer.md`:

```
# Agent: sanitizer
**Status:** In Progress | Blocked | Done
**Current task:** <what>
**Completed:** <what>
**Blockers:** <any>
**Updated:** <timestamp>
```
