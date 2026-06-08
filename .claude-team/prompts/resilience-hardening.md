# Resilience Hardening: bayport-vpn.sh

## Context

You are improving the resilience of `scripts/bayport-vpn.sh` — a ~1276-line Bash script that connects to a FortiVPN server using credentials from Bitwarden CLI, manages routes on macOS, and caches Bitwarden sessions. The script works but has no reconnection logic, hardcoded routes, and some signal handling gaps.

Also update `scripts/bayport-vpn-completion.bash` which is missing several flags.

## Your Deliverables

Implement all the resilience improvements listed below directly in the script.

## Issues to Fix

### 1. MEDIUM — Connection health monitoring & auto-reconnect

Currently `connect_vpn()` just does `wait $vpn_pid` and exits when the VPN drops. There's no health check or reconnect.

**Fix:** Add a health-check loop that monitors the connection and optionally reconnects:

```bash
# After VPN is up and routes configured, enter monitoring loop
monitor_vpn_connection() {
    local vpn_pid=$1
    local max_reconnects=${MAX_RECONNECTS:-3}
    local reconnect_count=0
    local health_interval=30  # seconds between checks

    while true; do
        sleep "$health_interval"

        # Check if VPN process is still running
        if ! kill -0 "$vpn_pid" 2>/dev/null; then
            log_warn "VPN process died (PID: $vpn_pid)"

            if [ $reconnect_count -ge $max_reconnects ]; then
                log_error "Max reconnection attempts ($max_reconnects) reached. Giving up."
                return 1
            fi

            ((reconnect_count++))
            log_info "Attempting reconnection ($reconnect_count/$max_reconnects)..."

            # Brief backoff
            sleep $((reconnect_count * 5))

            # Restart VPN
            "${vpn_args[@]}" &
            vpn_pid=$!

            if wait_for_vpn_interface 30; then
                add_vpn_routes
                log_success "Reconnected successfully"
                reconnect_count=0  # reset on success
            else
                log_error "Reconnection failed"
                kill $vpn_pid 2>/dev/null
            fi
            continue
        fi

        # Check interface is still up
        if ! ifconfig ppp0 >/dev/null 2>&1; then
            log_warn "ppp0 interface disappeared but VPN process still running"
        fi
    done
}
```

Integrate this into `connect_vpn()` — replace the simple `wait $vpn_pid` with the monitoring loop. Add a `--no-reconnect` flag to disable it. Add `--max-reconnects N` to configure the limit.

### 2. MEDIUM — Externalize route configuration

The 22 subnets are hardcoded in `add_vpn_routes()` (lines ~1050-1073). Any network change requires editing the script.

**Fix:** Load routes from a config file with a hardcoded fallback:

```bash
ROUTES_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/bayport-vpn/routes.conf"

load_routes() {
    local routes=()

    if [ -f "$ROUTES_CONFIG" ]; then
        log_info "Loading routes from $ROUTES_CONFIG"
        while IFS= read -r line; do
            # Skip comments and blank lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            # Basic CIDR validation
            if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                routes+=("$line")
            else
                log_warn "Skipping invalid route: $line"
            fi
        done < "$ROUTES_CONFIG"
    fi

    # Fallback to defaults if no config or empty config
    if [ ${#routes[@]} -eq 0 ]; then
        log_debug "Using default hardcoded routes"
        routes=(
            "10.1.0.0/16"
            ... existing list ...
        )
    fi

    echo "${routes[@]}"
}
```

Add a `--init-routes` flag that creates the config file from the defaults, so users can customize.

### 3. MEDIUM — Sudo keepalive

Long-running operations can cause the sudo credential cache to expire, causing later `sudo route` commands to fail or prompt unexpectedly.

**Fix:** Add a background sudo keepalive:

```bash
start_sudo_keepalive() {
    # Refresh sudo timestamp every 60 seconds
    while true; do
        sudo -n true 2>/dev/null
        sleep 60
    done &
    SUDO_KEEPALIVE_PID=$!
    log_debug "Sudo keepalive started (PID: $SUDO_KEEPALIVE_PID)"
}

stop_sudo_keepalive() {
    if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null
        log_debug "Sudo keepalive stopped"
    fi
}
```

Start it after `precheck_permissions` succeeds. Stop it in `cleanup()`.

### 4. LOW — Signal handling gap

The trap (line 119) handles `EXIT INT TERM` but not `HUP`. If the terminal disconnects (SSH, tmux detach), cleanup won't run.

**Fix:**
```bash
trap cleanup EXIT INT TERM HUP
```

### 5. LOW — Update bash completion

`scripts/bayport-vpn-completion.bash` line 11 is missing these flags that exist in the script:
- `--check-connection`
- `--show-config`
- `--netbird-status`

And you'll be adding:
- `--no-reconnect`
- `--max-reconnects`
- `--init-routes`

Update the completion script to include all of them. Also add `--max-reconnects` to the section that handles numeric arguments (like `--session-timeout`).

## Constraints

- Do NOT change the script's security model — another agent is handling security fixes. Avoid touching: `eval` usage, temp file permissions, session key storage, input validation, or secret masking.
- Do NOT change logging colors, banner styles, or the Bitwarden integration
- Keep backwards compatibility — existing flags must keep working
- Run `bash -n scripts/bayport-vpn.sh` after your changes to verify no syntax errors
- Run `bash -n scripts/bayport-vpn-completion.bash` to verify completion script syntax

## Status File

After each significant step, update your status file at `.claude-team/agents/resilience-hardening.md`:

```
# Agent: resilience-hardening
**Status:** In Progress | Blocked | Done
**Current task:** <what you're working on now>
**Completed:** <what you've finished>
**Blockers:** <any issues>
**Updated:** <timestamp>
```
