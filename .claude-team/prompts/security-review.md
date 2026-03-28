# Security Review & Hardening: bayport-vpn.sh

## Context

You are reviewing and hardening `scripts/bayport-vpn.sh` — a ~1276-line Bash script that connects to a FortiVPN server using credentials fetched from Bitwarden CLI. It runs on macOS, uses `sudo`, caches a Bitwarden session key to disk, writes a temp config file containing a plaintext password, and manages network routes.

## Your Deliverables

Fix every security issue listed below **in the script itself**. Do not just report findings — implement the fixes.

## Issues to Fix

### 1. CRITICAL — Remove `eval` (line ~1170)

```bash
eval "$vpn_cmd" &
```

This is a command injection risk. If any Bitwarden field (host, username, password, trusted-cert) contains shell metacharacters, they'll be executed.

**Fix:** Build the command as a Bash array and execute it directly:

```bash
local vpn_args=("sudo" "openfortivpn" "--pppd-accept-remote" "-c" "$config_file")
if [ "$VERBOSE" = true ]; then vpn_args+=("-v"); fi
if [ "$DEBUG" = true ]; then vpn_args+=("-vv"); fi
"${vpn_args[@]}" &
```

### 2. HIGH — Temp config file permissions race

`create_vpn_config()` (line ~996) creates a temp file with `mktemp` then writes credentials to it. Between creation and write, the file has default permissions (often 644).

**Fix:** Set permissions BEFORE writing credentials:

```bash
TEMP_CONFIG=$(mktemp)
chmod 600 "$TEMP_CONFIG"
# THEN write the config
cat > "$TEMP_CONFIG" << EOF
...
EOF
```

### 3. MEDIUM — Session key stored as plaintext file

`save_session_key()` writes the Bitwarden session key to `~/.cache/bayport-vpn/session_key` as plain text. Anyone with read access to the user's home can steal vault access.

**Fix:** Use macOS `security` (Keychain) for storage:

```bash
save_session_key() {
    local session_key=$1
    if [ "$(uname -s)" = "Darwin" ]; then
        security add-generic-password -U -a "$USER" -s "bayport-vpn-session" -w "$session_key" 2>/dev/null
    else
        # Fallback to file-based with strict permissions for Linux
        ensure_session_cache_dir
        echo "$session_key" > "$SESSION_CACHE_FILE"
        chmod 600 "$SESSION_CACHE_FILE"
    fi
}

load_cached_session() {
    local cached_key=""
    if [ "$(uname -s)" = "Darwin" ]; then
        cached_key=$(security find-generic-password -a "$USER" -s "bayport-vpn-session" -w 2>/dev/null) || return 1
    else
        [ -f "$SESSION_CACHE_FILE" ] || return 1
        # ... existing file age check ...
        cached_key=$(cat "$SESSION_CACHE_FILE")
    fi
    # validate and return
}

clear_session_cache() {
    if [ "$(uname -s)" = "Darwin" ]; then
        security delete-generic-password -a "$USER" -s "bayport-vpn-session" 2>/dev/null
    else
        rm -f "$SESSION_CACHE_FILE"
    fi
}
```

Keep the file-based fallback for Linux, but prefer Keychain on macOS. The session timeout logic will need adjustment — store the timestamp separately or use Keychain metadata.

### 4. MEDIUM — Secret leakage in debug/verbose output

- Line ~825: `log_debug "Session key (first 10 chars): ${SESSION_KEY:0:10}..."`  — remove this entirely, or replace with a hash.
- Line ~985: `echo "  VPN Password: ${VPN_PASSWORD:0:3}***"` — replace with a fixed mask like `********`.

**Fix:** Never log any portion of secrets. Use:
```bash
echo "  VPN Password: ********"
```
And remove the session key debug line completely.

### 5. LOW — Input validation on Bitwarden fields

`parse_vpn_config()` pulls values from Bitwarden JSON but doesn't validate format. A compromised or mis-configured Bitwarden item could inject unexpected values.

**Fix:** Add basic validation after parsing:

```bash
# Validate host looks like a hostname/IP
if ! [[ "$VPN_HOST" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    log_error "VPN host contains invalid characters: $VPN_HOST"
    return 1
fi

# Validate username is alphanumeric-ish
if ! [[ "$VPN_USERNAME" =~ ^[a-zA-Z0-9@._-]+$ ]]; then
    log_error "VPN username contains invalid characters"
    return 1
fi

# Validate trusted-cert is a hex hash
if ! [[ "$VPN_TRUSTED_CERT" =~ ^[a-fA-F0-9:]+$ ]]; then
    log_error "Trusted cert hash contains invalid characters"
    return 1
fi
```

### 6. LOW — Secure temp file cleanup

The `cleanup()` function uses `rm -f` on the temp config. Add a `shred` if available to overwrite the password before unlinking:

```bash
if [ -n "$TEMP_CONFIG" ] && [ -f "$TEMP_CONFIG" ]; then
    if command -v shred >/dev/null 2>&1; then
        shred -u "$TEMP_CONFIG" 2>/dev/null
    elif command -v gshred >/dev/null 2>&1; then
        gshred -u "$TEMP_CONFIG" 2>/dev/null
    else
        rm -f "$TEMP_CONFIG"
    fi
fi
```

## Constraints

- Do NOT change the script's overall flow, UX, or feature set
- Do NOT change logging colors, banner styles, or option names
- Keep the file-based session fallback working for Linux — Keychain is macOS-only enhancement
- Run `bash -n scripts/bayport-vpn.sh` after your changes to verify no syntax errors
- Test that `--help`, `--check-deps`, and `--dry-run` still work (read their output, confirm they look right)

## Status File

After each significant step, update your status file at `.claude-team/agents/security-review.md`:

```
# Agent: security-review
**Status:** In Progress | Blocked | Done
**Current task:** <what you're working on now>
**Completed:** <what you've finished>
**Blockers:** <any issues>
**Updated:** <timestamp>
```
