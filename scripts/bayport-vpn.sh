#!/bin/bash

# Enhanced VPN Connection Script
# Connects to VPN using credentials from Bitwarden

set -euo pipefail  # Exit on error, undefined vars, and pipe failures

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Initialize variables
VERBOSE=false
DEBUG=false
DRY_RUN=false
TEMP_CONFIG=""
SESSION_KEY=""
SESSION_CACHE_DIR="${HOME}/.cache/bayport-vpn"
SESSION_CACHE_FILE="${SESSION_CACHE_DIR}/session_key"
SESSION_TIMEOUT=0  # 0 = persist until reboot (default); >0 = wall-clock seconds
VPN_ROUTES_ADDED=()  # Track routes we added for cleanup
NO_RECONNECT=false
MAX_RECONNECTS=${MAX_RECONNECTS:-3}
SUDO_KEEPALIVE_PID=""
VPN_PID=""   # Track VPN process for reliable shutdown
VPN_LOG=""   # Capture openfortivpn output for failure classification
TAIL_PID=""  # Track verbose log tail for cleanup
ROUTES_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/bayport-vpn/routes.conf"
DNS_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/bayport-vpn/dns.conf"

# Platform detection globals (set by detect_platform)
OS_TYPE=""
HAS_IFCONFIG=false
HAS_IP=false
HAS_NETSTAT=false
HAS_RESOLVECTL=false
HAS_SCUTIL=false
KEYSTORE_BACKEND=""   # Detected keystore (keychain, secret-tool, pass, file)

# Split-tunnel state
DEFAULT_GW=""
DEFAULT_GW_IFACE=""
VPN_DNS_CONFIGURED=false
VPN_DNS_SERVERS=()
VPN_DNS_DOMAINS=()

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [ "$DEBUG" = true ] || [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

log_prompt() {
    echo -e "\n${YELLOW}┌─────────────────────────────────────────────────┐${NC}" >&2
    echo -e "${YELLOW}│ USER INPUT REQUIRED                              │${NC}" >&2
    echo -e "${YELLOW}└─────────────────────────────────────────────────┘${NC}" >&2
    echo -e "${YELLOW}➜${NC} $1" >&2
    echo "" >&2
}

log_step() {
    echo -e "\n${BLUE}━━━ $1${NC}" >&2
}

log_progress() {
    echo -ne "${BLUE}[⋯]${NC} $1\r" >&2
}

log_progress_done() {
    echo -e "${GREEN}[✓]${NC} $1          " >&2
}

# ─── Platform Detection & Helpers ─────────────────────────────────────────────

# Portable timeout: uses coreutils timeout if available, else bash-native fallback
_timeout() {
    local secs=$1; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        # Bash-native fallback for stock macOS (no coreutils)
        "$@" &
        local cmd_pid=$!
        ( sleep "$secs"; kill "$cmd_pid" 2>/dev/null ) &
        local watchdog_pid=$!
        wait "$cmd_pid" 2>/dev/null
        local ret=$?
        kill "$watchdog_pid" 2>/dev/null
        wait "$watchdog_pid" 2>/dev/null
        return $ret
    fi
}

# Get a unique identifier for the current boot session
# Changes on reboot, used to invalidate cached BW sessions
_get_boot_id() {
    if [ -f /proc/sys/kernel/random/boot_id ]; then
        # Linux: kernel boot_id is unique per boot
        cat /proc/sys/kernel/random/boot_id
    else
        # macOS: use kernel boot time (seconds since epoch)
        sysctl -n kern.boottime 2>/dev/null | sed 's/^{ sec = \([0-9]*\).*/\1/'
    fi
}

detect_platform() {
    OS_TYPE=$(uname -s)
    command -v ifconfig >/dev/null 2>&1 && HAS_IFCONFIG=true
    command -v ip >/dev/null 2>&1 && HAS_IP=true
    command -v netstat >/dev/null 2>&1 && HAS_NETSTAT=true
    command -v resolvectl >/dev/null 2>&1 && HAS_RESOLVECTL=true
    command -v scutil >/dev/null 2>&1 && HAS_SCUTIL=true
    log_debug "Platform: $OS_TYPE (ifconfig=$HAS_IFCONFIG, ip=$HAS_IP, netstat=$HAS_NETSTAT, resolvectl=$HAS_RESOLVECTL, scutil=$HAS_SCUTIL)"
}

# Cross-platform: check if VPN interface is up
check_interface_up() {
    if [ "$OS_TYPE" = "Darwin" ] || { [ "$HAS_IFCONFIG" = true ] && [ "$HAS_IP" != true ]; }; then
        ifconfig ppp0 >/dev/null 2>&1
    else
        ip link show ppp0 >/dev/null 2>&1
    fi
}

# Cross-platform: add a route through ppp0
platform_route_add() {
    local subnet=$1
    if [ "$OS_TYPE" = "Darwin" ]; then
        sudo route add -net "$subnet" -interface ppp0 >/dev/null 2>&1
    else
        sudo ip route add "$subnet" dev ppp0 >/dev/null 2>&1
    fi
}

# Cross-platform: delete a route
platform_route_delete() {
    local subnet=$1
    if [ "$OS_TYPE" = "Darwin" ]; then
        sudo route delete -net "$subnet" >/dev/null 2>&1
    else
        sudo ip route del "$subnet" dev ppp0 >/dev/null 2>&1
    fi
}

# Cross-platform: count VPN routes via ppp0 for 10.x.x.x subnets
count_vpn_routes() {
    if [ "$OS_TYPE" = "Darwin" ] || { [ "$HAS_NETSTAT" = true ] && [ "$HAS_IP" != true ]; }; then
        netstat -rn 2>/dev/null | grep "ppp0" | grep -c "^10\." || echo "0"
    else
        ip route show dev ppp0 2>/dev/null | grep -c "^10\." || echo "0"
    fi
}

# Cross-platform: list VPN routes
list_vpn_routes() {
    if [ "$OS_TYPE" = "Darwin" ] || { [ "$HAS_NETSTAT" = true ] && [ "$HAS_IP" != true ]; }; then
        netstat -rn 2>/dev/null | grep "ppp0" | grep "^10\."
    else
        ip route show dev ppp0 2>/dev/null | grep "^10\."
    fi
}

# Cross-platform: list all routes through ppp0 (for leak detection)
list_all_ppp0_routes() {
    if [ "$OS_TYPE" = "Darwin" ] || { [ "$HAS_NETSTAT" = true ] && [ "$HAS_IP" != true ]; }; then
        netstat -rn 2>/dev/null | grep "ppp0"
    else
        ip route show dev ppp0 2>/dev/null
    fi
}

# Cross-platform: check for ppp interfaces
check_ppp_interface_exists() {
    if [ "$OS_TYPE" = "Darwin" ] || { [ "$HAS_IFCONFIG" = true ] && [ "$HAS_IP" != true ]; }; then
        ifconfig 2>/dev/null | grep -q "^ppp"
    else
        ip link show 2>/dev/null | grep -q "ppp"
    fi
}

# Cross-platform: count utun interfaces
count_utun_interfaces() {
    if [ "$OS_TYPE" = "Darwin" ] || [ "$HAS_IFCONFIG" = true ]; then
        ifconfig 2>/dev/null | grep -c "^utun" || echo "0"
    else
        ip link show 2>/dev/null | grep -c "utun" || echo "0"
    fi
}

# Cross-platform: list utun interfaces
list_utun_interfaces() {
    if [ "$OS_TYPE" = "Darwin" ] || [ "$HAS_IFCONFIG" = true ]; then
        ifconfig 2>/dev/null | grep "^utun"
    else
        ip link show 2>/dev/null | grep "utun"
    fi
}

# Cross-platform: count routes via utun
count_utun_routes() {
    if [ "$OS_TYPE" = "Darwin" ] || { [ "$HAS_NETSTAT" = true ] && [ "$HAS_IP" != true ]; }; then
        netstat -rn 2>/dev/null | grep -c "utun" || echo "0"
    else
        ip route 2>/dev/null | grep -c "utun" || echo "0"
    fi
}

# ─── Default Gateway Management ──────────────────────────────────────────────

capture_default_gateway() {
    if [ "$OS_TYPE" = "Darwin" ]; then
        DEFAULT_GW=$(netstat -rn 2>/dev/null | awk '/^default/ && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $2; exit}')
        DEFAULT_GW_IFACE=$(netstat -rn 2>/dev/null | awk '/^default/ && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $NF; exit}')
    else
        DEFAULT_GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
        DEFAULT_GW_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    fi

    if [ -z "$DEFAULT_GW" ]; then
        log_error "Could not determine default gateway"
        return 1
    fi

    log_info "Default gateway: $DEFAULT_GW via $DEFAULT_GW_IFACE"
    return 0
}

verify_default_gateway() {
    if [ -z "$DEFAULT_GW" ]; then
        log_debug "No saved default gateway to verify against"
        return 0
    fi

    local current_gw current_iface

    if [ "$OS_TYPE" = "Darwin" ]; then
        current_gw=$(netstat -rn 2>/dev/null | awk '/^default/ && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $2; exit}')
        current_iface=$(netstat -rn 2>/dev/null | awk '/^default/ && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $NF; exit}')
    else
        current_gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
        current_iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    fi

    if [ "$current_gw" != "$DEFAULT_GW" ] || [ "$current_iface" != "$DEFAULT_GW_IFACE" ]; then
        log_error "DEFAULT ROUTE HIJACKED! Was: $DEFAULT_GW via $DEFAULT_GW_IFACE, Now: ${current_gw:-<none>} via ${current_iface:-<none>}"
        return 1
    fi

    log_debug "Default gateway verified: $current_gw via $current_iface"
    return 0
}

restore_default_gateway() {
    if [ -z "$DEFAULT_GW" ]; then
        log_warn "No saved default gateway to restore"
        return 1
    fi

    log_warn "Restoring default gateway to $DEFAULT_GW via $DEFAULT_GW_IFACE..."

    if [ "$OS_TYPE" = "Darwin" ]; then
        sudo route delete default -interface ppp0 2>/dev/null || true
        sudo route delete default 2>/dev/null || true
        sudo route add default "$DEFAULT_GW" 2>/dev/null || true
    else
        sudo ip route del default dev ppp0 2>/dev/null || true
        sudo ip route del default 2>/dev/null || true
        sudo ip route add default via "$DEFAULT_GW" dev "$DEFAULT_GW_IFACE" 2>/dev/null || true
    fi

    if verify_default_gateway; then
        log_success "Default gateway restored successfully"
    else
        log_error "CRITICAL: Failed to restore default gateway!"
        if [ "$OS_TYPE" = "Darwin" ]; then
            log_error "Manual fix: sudo route add default $DEFAULT_GW"
        else
            log_error "Manual fix: sudo ip route add default via $DEFAULT_GW dev $DEFAULT_GW_IFACE"
        fi
        return 1
    fi
}

# ─── Split DNS Management ────────────────────────────────────────────────────

detect_vpn_dns() {
    local dns_servers=()

    # pppd with usepeerdns writes DNS servers to these locations
    local pppd_resolv=""
    for f in /etc/ppp/resolv.conf /var/run/ppp/resolv.conf /run/ppp/resolv.conf; do
        if [ -f "$f" ]; then
            pppd_resolv="$f"
            break
        fi
    done

    if [ -n "$pppd_resolv" ]; then
        log_debug "Reading VPN DNS from $pppd_resolv"
        while IFS= read -r line; do
            if [[ "$line" =~ ^nameserver[[:space:]]+([0-9.]+) ]]; then
                dns_servers+=("${BASH_REMATCH[1]}")
            fi
        done < "$pppd_resolv"
    fi

    if [ ${#dns_servers[@]} -gt 0 ]; then
        VPN_DNS_SERVERS=("${dns_servers[@]}")
        log_debug "Auto-detected VPN DNS: ${VPN_DNS_SERVERS[*]}"
    else
        log_debug "Could not auto-detect VPN DNS servers"
    fi
}

load_dns_config() {
    VPN_DNS_DOMAINS=()
    local explicit_servers=()

    if [ ! -f "$DNS_CONFIG" ]; then
        log_debug "No DNS config at $DNS_CONFIG — split DNS not configured"
        return 1
    fi

    log_info "Loading DNS config from $DNS_CONFIG"
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "$line" =~ ^nameserver[[:space:]]+([0-9.]+) ]]; then
            explicit_servers+=("${BASH_REMATCH[1]}")
        elif [[ "$line" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
            VPN_DNS_DOMAINS+=("$line")
        else
            log_warn "Skipping invalid DNS config line: $line"
        fi
    done < "$DNS_CONFIG"

    # Explicit servers override auto-detected ones
    if [ ${#explicit_servers[@]} -gt 0 ]; then
        VPN_DNS_SERVERS=("${explicit_servers[@]}")
    fi

    if [ ${#VPN_DNS_DOMAINS[@]} -eq 0 ]; then
        log_debug "No domains in DNS config — split DNS not configured"
        return 1
    fi

    return 0
}

configure_split_dns() {
    if ! load_dns_config; then
        log_info "Split DNS not configured (create $DNS_CONFIG to enable)"
        return 0
    fi

    # Auto-detect VPN DNS if not explicitly configured
    if [ ${#VPN_DNS_SERVERS[@]} -eq 0 ]; then
        detect_vpn_dns
    fi

    if [ ${#VPN_DNS_SERVERS[@]} -eq 0 ]; then
        log_warn "Could not determine VPN DNS servers — split DNS skipped"
        log_info "Add 'nameserver <ip>' to $DNS_CONFIG to set explicitly"
        return 0
    fi

    log_info "Configuring split DNS for ${#VPN_DNS_DOMAINS[@]} domain(s) via ${VPN_DNS_SERVERS[*]}"

    if [ "$OS_TYPE" = "Darwin" ]; then
        # macOS: create /etc/resolver/<domain> files
        sudo mkdir -p /etc/resolver
        for domain in "${VPN_DNS_DOMAINS[@]}"; do
            local resolver_file="/etc/resolver/$domain"
            {
                echo "# Auto-generated by bayport-vpn — do not edit"
                for ns in "${VPN_DNS_SERVERS[@]}"; do
                    echo "nameserver $ns"
                done
            } | sudo tee "$resolver_file" >/dev/null
            log_debug "Created resolver: $resolver_file"
        done
        VPN_DNS_CONFIGURED=true
        log_success "Split DNS configured (macOS /etc/resolver)"
    elif [ "$HAS_RESOLVECTL" = true ]; then
        # Linux with systemd-resolved
        sudo resolvectl dns ppp0 "${VPN_DNS_SERVERS[@]}" 2>/dev/null || true
        sudo resolvectl domain ppp0 "~${VPN_DNS_DOMAINS[0]}" $(printf '~%s ' "${VPN_DNS_DOMAINS[@]:1}") 2>/dev/null || true
        VPN_DNS_CONFIGURED=true
        log_success "Split DNS configured (resolvectl)"
    else
        # No supported split DNS method on this Linux system
        log_warn "Split DNS requires systemd-resolved on Linux (resolvectl not found)"
        log_info "VPN will work but DNS for internal domains must be configured manually"
    fi
}

remove_split_dns() {
    if [ "$VPN_DNS_CONFIGURED" != true ]; then
        return 0
    fi

    log_info "Removing split DNS configuration..."

    if [ "$OS_TYPE" = "Darwin" ] || { [ "$HAS_RESOLVECTL" != true ] && [ -d /etc/resolver ]; }; then
        # Remove /etc/resolver/<domain> files we created
        for domain in "${VPN_DNS_DOMAINS[@]}"; do
            local resolver_file="/etc/resolver/$domain"
            if [ -f "$resolver_file" ]; then
                sudo rm -f "$resolver_file"
                log_debug "Removed resolver: $resolver_file"
            fi
        done
    fi

    # resolvectl auto-cleans when interface goes down, but be explicit
    if [ "$HAS_RESOLVECTL" = true ] && [ "$OS_TYPE" != "Darwin" ]; then
        sudo resolvectl revert ppp0 2>/dev/null || true
    fi

    VPN_DNS_CONFIGURED=false
    log_success "Split DNS removed"
}

# ─── Route Management ────────────────────────────────────────────────────────

# Remove VPN routes
remove_vpn_routes() {
    if [ ${#VPN_ROUTES_ADDED[@]} -eq 0 ]; then
        log_debug "No routes to remove"
        return 0
    fi

    log_info "Removing VPN routes..."
    local removed=0

    for route in "${VPN_ROUTES_ADDED[@]}"; do
        if platform_route_delete "$route"; then
            removed=$((removed + 1))
            log_debug "Removed route: $route"
        else
            log_debug "Could not remove route: $route (may already be gone)"
        fi
    done

    if [ $removed -gt 0 ]; then
        log_success "Removed $removed VPN routes"
    fi

    VPN_ROUTES_ADDED=()
}

# Cleanup function (guarded against double-run from INT+EXIT)
CLEANUP_DONE=false
cleanup() {
    if [ "$CLEANUP_DONE" = true ]; then return; fi
    CLEANUP_DONE=true
    local exit_code=$?
    log_debug "Running cleanup..."

    # Kill verbose log tail if running
    if [ -n "$TAIL_PID" ]; then
        kill "$TAIL_PID" 2>/dev/null || true
        TAIL_PID=""
    fi

    # Kill VPN process and pppd (runs as root via sudo)
    if [ -n "$VPN_PID" ]; then
        log_info "Stopping VPN process (PID: $VPN_PID)..."
        sudo kill "$VPN_PID" 2>/dev/null || true
        # Give it a moment to exit cleanly
        local wait_count=0
        while kill -0 "$VPN_PID" 2>/dev/null && [ $wait_count -lt 5 ]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done
        # Force kill if still alive
        if kill -0 "$VPN_PID" 2>/dev/null; then
            log_warn "VPN process didn't stop gracefully, force killing..."
            sudo kill -9 "$VPN_PID" 2>/dev/null || true
        fi
        VPN_PID=""
    fi
    # Clean up any orphaned pppd processes from our VPN
    sudo pkill -x pppd 2>/dev/null || true

    # Stop sudo keepalive if running
    stop_sudo_keepalive

    # Remove split DNS configuration
    remove_split_dns

    # Remove VPN routes if any were added
    remove_vpn_routes

    # Clean up temp files (config may contain password, log may contain sensitive data)
    for tmpfile in "$TEMP_CONFIG" "$VPN_LOG"; do
        if [ -n "$tmpfile" ] && [ -f "$tmpfile" ]; then
            log_debug "Securely removing: $tmpfile"
            if command -v shred >/dev/null 2>&1; then
                shred -u "$tmpfile" 2>/dev/null
            elif command -v gshred >/dev/null 2>&1; then
                gshred -u "$tmpfile" 2>/dev/null
            else
                rm -f "$tmpfile"
            fi
        fi
    done

    # Verify default route is restored
    if [ -n "$DEFAULT_GW" ]; then
        if ! verify_default_gateway; then
            log_warn "Default gateway changed during session — restoring..."
            restore_default_gateway
        else
            log_debug "Default gateway intact after cleanup"
        fi
    fi

    # Note: We keep the session key cached for reuse
    # Session key will be cleared on timeout or manual clear

    if [ $exit_code -ne 0 ]; then
        log_error "Script exited with code: $exit_code"
    fi

    exit $exit_code
}

# Set trap for cleanup
trap cleanup EXIT INT TERM HUP

# Usage function
usage() {
    cat << EOF
Usage: $(basename $0) [OPTIONS]

Connect to VPN using credentials stored in Bitwarden.

OPTIONS:
    -v, --verbose       Enable verbose output
    -d, --debug         Enable debug output (includes verbose)
    -n, --dry-run       Show configuration without connecting
    -h, --help          Show this help message
    --check-deps        Check if required dependencies are installed
    --test-config       Test Bitwarden configuration
    --check-connection  Test connectivity to VPN server
    --show-config       Show the generated OpenFortiVPN config file
    --session-status    Show cached session status
    --clear-session     Clear cached session key
    --session-timeout N Set session timeout in seconds (0 = until reboot, default: 0)
    --netbird-status    Check NetBird status and conflicts
    --no-reconnect      Disable automatic reconnection on VPN drop
    --max-reconnects N  Max reconnection attempts (default: 3, env: MAX_RECONNECTS)
    --init-routes       Create routes/DNS config files from defaults for customization
    --verify-routes     Check current routing table for split-tunnel correctness
    --check-cert        Check if server certificate has changed and offer to update
    --ignore-conflicts  Skip VPN conflict warnings (NetBird, OpenVPN, etc.)

ENVIRONMENT VARIABLES:
    BW_SESSION          Bitwarden session key (optional, will prompt if not set)

EXAMPLES:
    # Connect to VPN
    $(basename $0)

    # Connect with verbose output
    $(basename $0) --verbose

    # Test configuration without connecting
    $(basename $0) --dry-run

    # Check dependencies
    $(basename $0) --check-deps

    # Check cached session status
    $(basename $0) --session-status

    # Clear cached session (force re-authentication)
    $(basename $0) --clear-session

    # Set custom session timeout (2 hours)
    $(basename $0) --session-timeout 7200

    # Test connectivity to VPN server
    $(basename $0) --check-connection

    # Show the generated config file
    $(basename $0) --show-config

    # Check NetBird status
    $(basename $0) --netbird-status

    # Connect without auto-reconnect
    $(basename $0) --no-reconnect

    # Connect with up to 5 reconnection attempts
    $(basename $0) --max-reconnects 5

    # Create routes/DNS config files for customization
    $(basename $0) --init-routes

    # Verify split-tunnel routing is correct
    $(basename $0) --verify-routes

    # Check if server certificate changed and update Bitwarden
    $(basename $0) --check-cert

REQUIREMENTS:
    - bw (Bitwarden CLI)
    - jq (JSON processor)
    - openfortivpn
    - sudo privileges

Bitwarden item must contain:
    - login.username: VPN username
    - login.password: VPN password
    - custom field "host": VPN server hostname
    - custom field "trusted-cert": VPN certificate hash

EOF
    exit 0
}

# Check VPN server connectivity
check_connection() {
    local item_name=$(get_item_name)
    local session_key=$(get_bitwarden_session)

    if [ -z "$session_key" ]; then
        log_error "Cannot check connection without Bitwarden session"
        return 1
    fi

    local vpn_item
    if ! vpn_item=$(get_vpn_config "$item_name" "$session_key") || [ -z "$vpn_item" ]; then
        return 1
    fi

    if ! parse_vpn_config "$vpn_item"; then
        return 1
    fi

    log_info "Running connectivity diagnostics for $VPN_HOST:10443"
    echo ""

    # 1. DNS Resolution
    log_info "1. Testing DNS resolution..."
    if nslookup "$VPN_HOST" >/dev/null 2>&1; then
        local ip=$(nslookup "$VPN_HOST" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1)
        if [ -z "$ip" ]; then
            ip=$(dig +short "$VPN_HOST" 2>/dev/null | head -1)
        fi
        log_success "DNS resolves to: $ip"
    else
        log_error "DNS resolution failed for $VPN_HOST"
        log_info "Try: nslookup $VPN_HOST"
        return 1
    fi
    echo ""

    # 2. Ping test
    log_info "2. Testing ICMP ping..."
    if ping -c 3 -W 2 "$VPN_HOST" >/dev/null 2>&1; then
        log_success "Host is reachable via ping"
    else
        log_warn "Ping failed (may be blocked by firewall - not necessarily an issue)"
    fi
    echo ""

    # 3. Port connectivity
    log_info "3. Testing TCP connection to port 10443..."
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 5 "$VPN_HOST" 10443 2>/dev/null; then
            log_success "Port 10443 is open and accepting connections"
        else
            log_error "Cannot connect to port 10443"
            log_info "This is likely why the VPN connection times out"
            log_info "Possible causes:"
            log_info "  - Corporate firewall blocking port 10443"
            log_info "  - VPN server is down"
            log_info "  - You need to be on a different network"
            return 1
        fi
    else
        log_warn "netcat (nc) not available, skipping port test"
    fi
    echo ""

    # 4. SSL/TLS test
    log_info "4. Testing SSL/TLS handshake..."
    if command -v openssl >/dev/null 2>&1; then
        if echo "Q" | _timeout 5 openssl s_client -connect "$VPN_HOST:10443" >/dev/null 2>&1; then
            log_success "SSL/TLS handshake successful"

            # Show certificate info
            log_info "Certificate details:"
            echo "Q" | _timeout 5 openssl s_client -connect "$VPN_HOST:10443" 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /'
        else
            log_warn "SSL/TLS handshake failed (may require VPN auth)"
        fi
    else
        log_warn "openssl not available, skipping SSL test"
    fi
    echo ""

    # 5. OpenFortiVPN test
    log_info "5. Testing with openfortivpn..."
    log_info "Running: openfortivpn $VPN_HOST:10443 --no-routes --pppd-log /dev/null (will timeout after 10s)"
    if _timeout 10 openfortivpn "$VPN_HOST:10443" --no-routes --pppd-log /dev/null 2>&1 | grep -q "STATUS"; then
        log_success "OpenFortiVPN can communicate with server"
    else
        log_warn "OpenFortiVPN test inconclusive"
    fi
    echo ""

    # 6. DNS leak check (pre-connection baseline)
    log_info "6. Checking current DNS configuration for leaks..."
    dns_leak_test false || true
    echo ""

    log_success "Diagnostics complete!"
    echo ""
    log_info "Summary:"
    log_info "  VPN Host: $VPN_HOST"
    log_info "  Port: 10443"
    log_info "  Username: $VPN_USERNAME"
    echo ""
    log_info "If port 10443 is blocked, try:"
    log_info "  - Connecting from a different network (home/mobile hotspot)"
    log_info "  - Checking with your network admin about firewall rules"
    log_info "  - Verifying the VPN server is online and accessible"

    return 0
}

# Show generated config
show_config() {
    local item_name=$(get_item_name)
    local session_key=$(get_bitwarden_session)

    if [ -z "$session_key" ]; then
        log_error "Cannot show config without Bitwarden session"
        return 1
    fi

    local vpn_item
    if ! vpn_item=$(get_vpn_config "$item_name" "$session_key") || [ -z "$vpn_item" ]; then
        return 1
    fi

    if ! parse_vpn_config "$vpn_item"; then
        return 1
    fi

    log_info "Generated OpenFortiVPN Configuration"
    log_info "OS Detected: $OS_TYPE"
    echo ""

    cat << EOF
persistent=10              # Keep connection alive, retry 10 times
host = $VPN_HOST          # VPN server hostname
port = 10443               # VPN port
username = $VPN_USERNAME   # Your username
password = ********        # Password (hidden)
trusted-cert = $VPN_TRUSTED_CERT  # Server certificate fingerprint
set-routes = 0             # Routes managed by this script (split-tunnel)
set-dns = 0                # DNS managed by this script (split DNS)
pppd-use-peerdns = 1       # Learn VPN DNS servers via pppd
EOF

    echo ""
    log_info "Split-tunnel enforcement:"
    log_info "  set-routes = 0: openfortivpn will NOT modify the routing table"
    log_info "  set-dns = 0: openfortivpn will NOT modify system DNS"
    log_info "  Routes and DNS are managed by this script to prevent traffic leakage"

    if [ "$OS_TYPE" = "Darwin" ]; then
        echo ""
        log_info "macOS-specific notes:"
        log_info "  pppd-use-peerdns = 1: Tells pppd to learn DNS from VPN server"
        log_info "  Split DNS via /etc/resolver/<domain> files"
        log_info "  Routes via: route add -net <subnet> -interface ppp0"
    else
        echo ""
        log_info "Linux-specific notes:"
        log_info "  pppd-use-peerdns = 1: pppd writes DNS to /etc/ppp/resolv.conf"
        if [ "$HAS_RESOLVECTL" = true ]; then
            log_info "  Split DNS via: resolvectl dns/domain ppp0"
        else
            log_info "  Split DNS via /etc/resolver/<domain> files"
        fi
        log_info "  Routes via: ip route add <subnet> dev ppp0"
    fi

    echo ""
    log_info "Connection command that will be used:"
    echo "  sudo openfortivpn --pppd-accept-remote -c <config_file>"
    echo ""
    log_info "Additional flags based on verbosity:"
    echo "  --verbose: adds -v flag (verbose output)"
    echo "  --debug: adds -vv flag (extra verbose output)"

    return 0
}

# Check dependencies
check_dependencies() {
    local missing_deps=()

    log_info "Platform: $OS_TYPE ($(uname -m))"
    log_info "Session storage backend: $KEYSTORE_BACKEND"
    echo ""

    # Core dependencies
    log_progress "Checking core dependencies..."

    for cmd in bw jq openfortivpn mktemp; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "" >&2  # Clear progress line
        log_error "Missing core dependencies: ${missing_deps[*]}"
        log_info "Install missing dependencies and try again"
        return 1
    fi

    log_progress_done "Core: bw, jq, openfortivpn, mktemp"

    # Platform-specific dependencies
    log_progress "Checking platform dependencies..."
    local platform_deps=()
    local platform_missing=()

    if [ "$OS_TYPE" = "Darwin" ]; then
        platform_deps=("route" "ifconfig" "pppd" "scutil")
    else
        # Linux: prefer ip, fall back to route+ifconfig
        if command -v ip &>/dev/null; then
            platform_deps=("ip" "pppd")
        else
            platform_deps=("route" "ifconfig" "pppd")
        fi
    fi

    for cmd in "${platform_deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            platform_missing+=("$cmd")
        fi
    done

    if [ ${#platform_missing[@]} -ne 0 ]; then
        log_warn "Missing platform tools: ${platform_missing[*]}"
    else
        log_progress_done "Platform ($OS_TYPE): ${platform_deps[*]}"
    fi

    # Session storage backend details
    log_progress "Checking session storage..."
    case "$KEYSTORE_BACKEND" in
        keychain)
            log_progress_done "Session: macOS Keychain (via security)"
            ;;
        secret-tool)
            log_progress_done "Session: GNOME Keyring (via secret-tool)"
            ;;
        pass)
            log_progress_done "Session: password-store (via pass)"
            ;;
        file)
            log_progress_done "Session: file-based ($SESSION_CACHE_DIR)"
            ;;
    esac

    # Optional tools
    local opt_tools=()
    if command -v shred >/dev/null 2>&1; then
        opt_tools+=("shred")
    elif command -v gshred >/dev/null 2>&1; then
        opt_tools+=("gshred")
    fi
    if command -v dig >/dev/null 2>&1; then
        opt_tools+=("dig")
    fi
    if command -v nc >/dev/null 2>&1; then
        opt_tools+=("nc")
    fi
    if [ ${#opt_tools[@]} -gt 0 ]; then
        log_progress_done "Optional: ${opt_tools[*]}"
    else
        log_progress_done "Optional: none detected"
    fi

    # Show platform tool availability
    log_info "Platform: $OS_TYPE"
    if [ "$OS_TYPE" = "Darwin" ]; then
        log_info "  Network tools: ifconfig=$HAS_IFCONFIG, netstat=$HAS_NETSTAT, scutil=$HAS_SCUTIL"
        log_info "  Route command: route add -net <subnet> -interface ppp0"
    else
        log_info "  Network tools: ip=$HAS_IP, ifconfig=$HAS_IFCONFIG, netstat=$HAS_NETSTAT, resolvectl=$HAS_RESOLVECTL"
        if [ "$HAS_IP" = true ]; then
            log_info "  Route command: ip route add <subnet> dev ppp0"
        elif [ "$HAS_IFCONFIG" = true ]; then
            log_info "  Route command: route add -net <subnet> -interface ppp0 (fallback)"
        else
            log_error "  No network management tool found (need 'ip' or 'ifconfig')"
            return 1
        fi
    fi

    return 0
}

# Pre-check and request all permissions needed
precheck_permissions() {
    log_step "Pre-checking required permissions"

    local needs_sudo=false
    local needs_bw_unlock=false

    # Check if we need sudo (for VPN connection and route management)
    # Skip for dry-run — no routes or interfaces are touched
    if [ "$DRY_RUN" != true ] && ! sudo -n true 2>/dev/null; then
        needs_sudo=true
    fi

    # Check if Bitwarden needs unlocking
    if [ -z "${BW_SESSION:-}" ]; then
        local cached_session=$(load_cached_session 2>/dev/null)
        if [ -z "$cached_session" ]; then
            local vault_status=$(bw status 2>/dev/null | jq -r '.status' 2>/dev/null)
            if [ "$vault_status" = "locked" ]; then
                needs_bw_unlock=true
            fi
        fi
    fi

    # Request permissions upfront if needed
    if [ "$needs_sudo" = true ] || [ "$needs_bw_unlock" = true ]; then
        echo ""
        echo -e "${YELLOW}╔════════════════════════════════════════════════╗${NC}" >&2
        echo -e "${YELLOW}║  PERMISSIONS REQUIRED                          ║${NC}" >&2
        echo -e "${YELLOW}╚════════════════════════════════════════════════╝${NC}" >&2
        echo ""

        if [ "$needs_sudo" = true ]; then
            log_info "✓ Sudo access (for VPN routing and network configuration)"
        fi

        if [ "$needs_bw_unlock" = true ]; then
            log_info "✓ Bitwarden vault unlock (for credential retrieval)"
        fi

        echo ""
        log_info "Requesting permissions now to avoid interruptions later..."
        echo ""

        # Pre-authenticate sudo
        if [ "$needs_sudo" = true ]; then
            log_prompt "Enter sudo password for VPN operations"
            if ! sudo -v; then
                log_error "Sudo authentication failed"
                return 1
            fi
            log_success "Sudo authentication successful"
            echo ""
        fi

        # Note: Bitwarden unlock will be handled in get_bitwarden_session
        # but user is now aware it will be needed
    fi

    return 0
}

# Show NetBird status
show_netbird_status() {
    log_info "NetBird Status Check"
    echo ""

    # Check if NetBird is running
    if pgrep -x netbird >/dev/null 2>&1; then
        local netbird_pid=$(pgrep -x netbird)
        echo -e "  Status: ${RED}RUNNING${NC} (PID: $netbird_pid)" >&2
        echo -e "  ${YELLOW}⚠ WARNING: NetBird interferes with VPN routing${NC}" >&2
        echo "" >&2

        # Show NetBird interfaces
        local utun_count
        utun_count=$(count_utun_interfaces)
        echo "  Active utun interfaces: $utun_count" >&2
        list_utun_interfaces 2>/dev/null | sed 's/^/    /' >&2
        echo "" >&2

        # Check NetBird routes
        local netbird_routes
        netbird_routes=$(count_utun_routes)
        echo "  Routes via utun: $netbird_routes" >&2
        echo "" >&2

        echo -e "  ${BLUE}To stop NetBird:${NC}" >&2
        echo "    sudo netbird down" >&2
        echo "" >&2

        return 1
    else
        echo -e "  Status: ${GREEN}STOPPED${NC}" >&2
        echo -e "  ${GREEN}✓ Safe to connect VPN${NC}" >&2
        echo "" >&2

        if command -v netbird >/dev/null 2>&1; then
            echo "  NetBird is installed but not running" >&2
        fi
        echo "" >&2

        return 0
    fi
}

# Check for VPN conflicts (NetBird, other VPNs, etc.)
check_vpn_conflicts() {
    log_info "Checking for VPN conflicts..."

    local conflicts_found=0

    # Check for NetBird
    if pgrep -x netbird >/dev/null 2>&1; then
        log_error "NetBird is running!"
        log_warn "NetBird can interfere with routing. Consider stopping it:"
        log_info "  sudo netbird down"
        log_info "  OR: sudo brew services stop netbird"
        conflicts_found=$((conflicts_found + 1))

        # Show NetBird interfaces
        local netbird_ifaces
        netbird_ifaces=$(count_utun_interfaces)
        log_info "NetBird has $netbird_ifaces utun interfaces active"
    fi

    # Check for other VPN software
    if pgrep -i "openvpn" >/dev/null 2>&1; then
        log_warn "OpenVPN is running - may conflict"
        conflicts_found=$((conflicts_found + 1))
    fi

    if pgrep -i "wireguard\|wg" >/dev/null 2>&1; then
        log_warn "WireGuard is running - may conflict"
        conflicts_found=$((conflicts_found + 1))
    fi

    # Check for existing ppp interfaces
    if check_ppp_interface_exists; then
        log_warn "PPP interface already exists - previous VPN connection may not be cleaned up"
        log_info "Run: sudo pkill -9 openfortivpn && sudo pkill -9 pppd"
        conflicts_found=$((conflicts_found + 1))
    fi

    if [ $conflicts_found -gt 0 ]; then
        log_warn "Found $conflicts_found potential conflicts"
        return 1
    else
        log_success "No VPN conflicts detected"
        return 0
    fi
}

# Session management functions
ensure_session_cache_dir() {
    if [ ! -d "$SESSION_CACHE_DIR" ]; then
        log_debug "Creating session cache directory: $SESSION_CACHE_DIR"
        mkdir -p "$SESSION_CACHE_DIR"
        chmod 700 "$SESSION_CACHE_DIR"
    fi
}

# Detect available keystore backend for session storage
# Sets KEYSTORE_BACKEND to: keychain, secret-tool, pass, or file
# Assumes OS_TYPE is already set by detect_platform()
detect_keystore() {
    # macOS: try Keychain via security command
    if [ "$OS_TYPE" = "Darwin" ] && command -v security >/dev/null 2>&1; then
        KEYSTORE_BACKEND="keychain"
        log_debug "Keystore backend: macOS Keychain"
        return 0
    fi

    # Linux/other: try secret-tool (GNOME Keyring / libsecret)
    if command -v secret-tool >/dev/null 2>&1; then
        # Probe whether secret-tool can talk to a keyring (times out if no D-Bus)
        local st_exit=0
        _timeout 2 secret-tool lookup service bayport-vpn-probe >/dev/null 2>&1 || st_exit=$?
        # 0 = found, 1 = not found (both mean secret-tool is functional)
        if [ $st_exit -le 1 ]; then
            KEYSTORE_BACKEND="secret-tool"
            log_debug "Keystore backend: secret-tool (GNOME Keyring)"
            return 0
        fi
    fi

    # Try pass (password-store)
    if command -v pass >/dev/null 2>&1; then
        # Verify pass is initialized
        if [ -d "${PASSWORD_STORE_DIR:-$HOME/.password-store}" ]; then
            KEYSTORE_BACKEND="pass"
            log_debug "Keystore backend: pass (password-store)"
            return 0
        fi
    fi

    # Fallback: file-based with strict permissions
    KEYSTORE_BACKEND="file"
    log_debug "Keystore backend: file-based ($SESSION_CACHE_DIR)"
    return 0
}

# Read session key from the active keystore backend (stdout)
# Returns 0 if a key was found, 1 otherwise
_read_session_from_backend() {
    local key=""
    case "$KEYSTORE_BACKEND" in
        keychain)
            key=$(security find-generic-password -a "$USER" -s "bayport-vpn-session" -w 2>/dev/null) || true
            ;;
        secret-tool)
            key=$(secret-tool lookup service bayport-vpn username "$USER" 2>/dev/null) || true
            ;;
        pass)
            key=$(pass show bayport-vpn/session 2>/dev/null) || true
            ;;
        file)
            [ -f "$SESSION_CACHE_FILE" ] && key=$(cat "$SESSION_CACHE_FILE")
            ;;
    esac
    if [ -n "$key" ]; then
        echo "$key"
        return 0
    fi
    return 1
}

save_session_key() {
    local session_key=$1

    log_progress "Saving session to cache..."
    ensure_session_cache_dir

    case "$KEYSTORE_BACKEND" in
        keychain)
            security add-generic-password -U -a "$USER" -s "bayport-vpn-session" -w "$session_key" 2>/dev/null
            ;;
        secret-tool)
            echo -n "$session_key" | secret-tool store --label='bayport-vpn session' service bayport-vpn username "$USER" 2>/dev/null
            ;;
        pass)
            echo "$session_key" | pass insert -f bayport-vpn/session >/dev/null 2>&1
            ;;
        file)
            install -m 600 /dev/null "$SESSION_CACHE_FILE"
            echo "$session_key" > "$SESSION_CACHE_FILE"
            ;;
    esac

    # Store timestamp and boot ID for session validity tracking
    install -m 600 /dev/null "${SESSION_CACHE_DIR}/session_timestamp"
    date +%s > "${SESSION_CACHE_DIR}/session_timestamp"

    # Store boot ID so session is invalidated on reboot
    install -m 600 /dev/null "${SESSION_CACHE_DIR}/session_boot_id"
    _get_boot_id > "${SESSION_CACHE_DIR}/session_boot_id"

    if [ "$SESSION_TIMEOUT" -gt 0 ]; then
        log_progress_done "Session cached via $KEYSTORE_BACKEND (valid for $((SESSION_TIMEOUT / 60)) minutes)"
    else
        log_progress_done "Session cached via $KEYSTORE_BACKEND (valid until reboot)"
    fi
}

load_cached_session() {
    local cached_key=""
    local file_age=0

    # Check boot ID — invalidate session if machine was rebooted
    if [ -f "${SESSION_CACHE_DIR}/session_boot_id" ]; then
        local saved_boot_id current_boot_id
        saved_boot_id=$(cat "${SESSION_CACHE_DIR}/session_boot_id" 2>/dev/null)
        current_boot_id=$(_get_boot_id)
        if [ "$saved_boot_id" != "$current_boot_id" ]; then
            log_warn "Machine was rebooted since last session — clearing cache"
            clear_session_cache >/dev/null 2>&1
            return 1
        fi
    fi

    # Check timestamp for wall-clock timeout (only if SESSION_TIMEOUT > 0)
    if [ -f "${SESSION_CACHE_DIR}/session_timestamp" ]; then
        local saved_ts
        saved_ts=$(cat "${SESSION_CACHE_DIR}/session_timestamp" 2>/dev/null)
        if [ -n "$saved_ts" ]; then
            file_age=$(($(date +%s) - saved_ts))
        fi
    else
        log_debug "No session timestamp found"
        return 1
    fi

    if [ "$SESSION_TIMEOUT" -gt 0 ] && [ $file_age -gt $SESSION_TIMEOUT ]; then
        log_warn "Cached session expired (${file_age}s old, timeout: ${SESSION_TIMEOUT}s)"
        clear_session_cache >/dev/null 2>&1
        return 1
    fi

    # Load session key from backend
    cached_key=$(_read_session_from_backend) || true

    if [ -z "$cached_key" ]; then
        log_debug "No cached session found in $KEYSTORE_BACKEND"
        return 1
    fi

    # Verify the session key is still valid (bw status is fast, avoids slow bw list items)
    log_debug "Found cached session (${file_age}s old via $KEYSTORE_BACKEND), validating..."
    if bw status --session "$cached_key" 2>/dev/null | jq -r '.status' 2>/dev/null | grep -q "unlocked"; then
        log_success "Using cached session key (${file_age}s old)"
        echo "$cached_key"
        return 0
    else
        log_warn "Cached session key is invalid, clearing cache"
        clear_session_cache >/dev/null 2>&1
        return 1
    fi
}

clear_session_cache() {
    local cleared=false

    case "$KEYSTORE_BACKEND" in
        keychain)
            security delete-generic-password -a "$USER" -s "bayport-vpn-session" 2>/dev/null && cleared=true
            ;;
        secret-tool)
            secret-tool clear service bayport-vpn username "$USER" 2>/dev/null && cleared=true
            ;;
        pass)
            pass rm -f bayport-vpn/session >/dev/null 2>&1 && cleared=true
            ;;
        file)
            [ -f "$SESSION_CACHE_FILE" ] && rm -f "$SESSION_CACHE_FILE" && cleared=true
            ;;
    esac

    # Always clean up timestamp and boot ID
    for f in "${SESSION_CACHE_DIR}/session_timestamp" "${SESSION_CACHE_DIR}/session_boot_id"; do
        if [ -f "$f" ]; then
            rm -f "$f"
            cleared=true
        fi
    done

    if [ "$cleared" = true ]; then
        log_info "Clearing cached session key..."
        log_success "Session cache cleared"
    else
        log_info "No cached session to clear"
    fi
}

show_session_status() {
    log_info "Session cache status:"
    echo ""
    echo "  Backend: $KEYSTORE_BACKEND"
    if [ "$SESSION_TIMEOUT" -gt 0 ]; then
        echo "  Timeout: ${SESSION_TIMEOUT}s ($((SESSION_TIMEOUT / 60)) minutes)"
    else
        echo "  Timeout: persist until reboot"
    fi
    echo ""

    # Check boot ID
    local boot_match=true
    if [ -f "${SESSION_CACHE_DIR}/session_boot_id" ]; then
        local saved_boot_id current_boot_id
        saved_boot_id=$(cat "${SESSION_CACHE_DIR}/session_boot_id" 2>/dev/null)
        current_boot_id=$(_get_boot_id)
        if [ "$saved_boot_id" != "$current_boot_id" ]; then
            boot_match=false
        fi
    fi

    # Check timestamp
    local file_age=0
    local has_timestamp=false

    if [ -f "${SESSION_CACHE_DIR}/session_timestamp" ]; then
        local saved_ts
        saved_ts=$(cat "${SESSION_CACHE_DIR}/session_timestamp" 2>/dev/null)
        if [ -n "$saved_ts" ]; then
            file_age=$(($(date +%s) - saved_ts))
            has_timestamp=true
        fi
    fi

    # Check if a session exists in the backend
    local has_session=false
    _read_session_from_backend >/dev/null 2>&1 && has_session=true

    if [ "$has_session" = false ] && [ "$has_timestamp" = false ]; then
        echo -e "  Status: ${RED}No cached session${NC}"
        return 0
    fi

    echo "  Age: ${file_age}s ($((file_age / 60)) minutes)"

    if [ "$boot_match" = false ]; then
        echo -e "  Status: ${RED}Expired${NC} (machine was rebooted)"
    elif [ "$SESSION_TIMEOUT" -gt 0 ] && [ $file_age -gt $SESSION_TIMEOUT ]; then
        echo -e "  Status: ${RED}Expired${NC} (exceeded timeout by $((file_age - SESSION_TIMEOUT))s)"
    else
        echo -e "  Status: ${GREEN}Valid${NC}"
        if [ "$SESSION_TIMEOUT" -gt 0 ]; then
            local remaining=$((SESSION_TIMEOUT - file_age))
            echo "  Expires in: ${remaining}s ($((remaining / 60)) minutes)"
        else
            echo "  Expires: on reboot"
        fi

        if [ "$has_session" = true ]; then
            local cached_key=""
            cached_key=$(_read_session_from_backend) || true
            if [ -n "$cached_key" ] && bw status --session "$cached_key" 2>/dev/null | jq -r '.status' 2>/dev/null | grep -q "unlocked"; then
                echo -e "  Verification: ${GREEN}Session key is valid${NC}"
            else
                echo -e "  Verification: ${RED}Session key is invalid${NC}"
            fi
        fi
    fi
}

# Sudo keepalive — refresh sudo timestamp periodically to prevent expiry
start_sudo_keepalive() {
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

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -d|--debug)
                DEBUG=true
                VERBOSE=true
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            --check-deps)
                check_dependencies
                exit $?
                ;;
            --test-config)
                TEST_CONFIG=true
                shift
                ;;
            --check-connection)
                check_connection
                exit $?
                ;;
            --show-config)
                show_config
                exit $?
                ;;
            --session-status)
                show_session_status
                exit 0
                ;;
            --netbird-status)
                show_netbird_status
                exit $?
                ;;
            --clear-session)
                clear_session_cache
                exit 0
                ;;
            --session-timeout)
                shift
                if [ $# -eq 0 ] || [[ ! $1 =~ ^[0-9]+$ ]]; then
                    log_error "--session-timeout requires a numeric value"
                    exit 1
                fi
                SESSION_TIMEOUT=$1
                log_info "Session timeout set to ${SESSION_TIMEOUT}s"
                shift
                ;;
            --no-reconnect)
                NO_RECONNECT=true
                shift
                ;;
            --max-reconnects)
                shift
                if [ $# -eq 0 ] || [[ ! $1 =~ ^[0-9]+$ ]]; then
                    log_error "--max-reconnects requires a numeric value"
                    exit 1
                fi
                MAX_RECONNECTS=$1
                log_info "Max reconnects set to $MAX_RECONNECTS"
                shift
                ;;
            --init-routes)
                init_routes_config
                exit $?
                ;;
            --verify-routes)
                verify_routes
                exit $?
                ;;
            --check-cert)
                CHECK_CERT_ONLY=true
                shift
                ;;
            --ignore-conflicts)
                IGNORE_CONFLICTS=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo ""
                usage
                ;;
        esac
    done
}

# Get Bitwarden item name from script name
get_item_name() {
    ITEM_NAME=$(basename "$0" .sh | sed 's/^\.//')
    log_info "Looking for Bitwarden item: '$ITEM_NAME'"
    log_debug "Computed from script name: $(basename "$0")"
    echo "$ITEM_NAME"
}

# Get or create Bitwarden session
get_bitwarden_session() {
    log_debug "Checking Bitwarden session..."

    # Check if bw is logged in
    if ! bw login --check &> /dev/null; then
        log_error "Bitwarden is not logged in. Please run 'bw login' first"
        return 1
    fi

    # Check if a session key already exists in environment
    if [ -n "${BW_SESSION:-}" ]; then
        log_debug "Using existing BW_SESSION from environment"
        if bw status --session "$BW_SESSION" 2>/dev/null | jq -r '.status' 2>/dev/null | grep -q "unlocked"; then
            SESSION_KEY=$BW_SESSION
        else
            log_warn "Environment BW_SESSION is invalid, will try cached session"
        fi
    fi

    # Try to load cached session with validation (load_cached_session already validates)
    if [ -z "$SESSION_KEY" ]; then
        local cached_session=$(load_cached_session)
        if [ -n "$cached_session" ]; then
            SESSION_KEY=$cached_session
        fi
    fi

    # If we got a session from env or cache, sync and return
    if [ -n "$SESSION_KEY" ]; then
        log_debug "Syncing Bitwarden vault..."
        bw sync --session "$SESSION_KEY" >/dev/null 2>&1 || log_debug "Sync failed (non-fatal, continuing with local cache)"
        echo "$SESSION_KEY"
        return 0
    fi

    # No cached session, need to unlock
    log_step "Unlocking Bitwarden vault"

    log_progress "Checking vault status..."
    local vault_status=$(bw status | jq -r '.status')
    log_progress_done "Vault status: $vault_status"
    log_debug "Vault status: $vault_status"

    if [ "$vault_status" = "locked" ]; then
        local max_attempts=3
        local attempt=1
        local unlock_successful=false

        while [ $attempt -le $max_attempts ]; do
            if [ $attempt -gt 1 ]; then
                echo ""
                log_warn "Attempt $attempt of $max_attempts"
            fi

            log_prompt "Please enter your Bitwarden master password to unlock the vault"

            # Capture session key (bw unlock prompts interactively)
            # Use only stdout, suppress stderr to avoid capturing password prompt
            SESSION_KEY=$(bw unlock --raw 2>/dev/null)
            local unlock_status=$?

            echo "" >&2  # Add newline after password input

            # Check if unlock command succeeded
            if [ $unlock_status -ne 0 ] || [ -z "$SESSION_KEY" ]; then
                if [ $attempt -lt $max_attempts ]; then
                    log_error "Unlock failed - incorrect password or 2FA required"
                    attempt=$((attempt + 1))
                    continue
                else
                    log_error "Failed to unlock Bitwarden vault after $max_attempts attempts"
                    echo ""
                    log_info "Troubleshooting tips:"
                    log_info "  1. Make sure you are entering the correct master password"
                    log_info "  2. Check if you have 2FA enabled and need to enter a code"
                    log_info "  3. Try unlocking manually: export BW_SESSION=\$(bw unlock --raw)"
                    log_info "  4. Then run this script again"
                    return 1
                fi
            fi

            # Validate the session key immediately with visual feedback
            log_progress "Validating session key..."
            if bw status --session "$SESSION_KEY" 2>/dev/null | jq -r '.status' 2>/dev/null | grep -q "unlocked"; then
                log_progress_done "Session key validated successfully"
                unlock_successful=true
                break
            else
                echo "" >&2  # Clear progress line

                if [ $attempt -lt $max_attempts ]; then
                    log_error "Authentication failed - please try again"
                    log_debug "Session validation failed for attempt $attempt"
                    attempt=$((attempt + 1))
                else
                    log_error "Session validation failed after $max_attempts attempts"
                    log_debug "Session key validation failed (key redacted)"
                    echo ""
                    log_info "This usually means:"
                    log_info "  1. Incorrect password was entered multiple times"
                    log_info "  2. Bitwarden CLI version incompatibility"
                    log_info "  3. Network connectivity issue with Bitwarden servers"
                    echo ""
                    log_info "Try running: bw sync && bw unlock"
                    return 1
                fi
            fi
        done

        if [ "$unlock_successful" = true ]; then
            log_success "Bitwarden vault unlocked successfully"
        else
            return 1
        fi
    elif [ "$vault_status" = "unlocked" ]; then
        log_warn "Vault already unlocked, but no session key found"
        log_info "Re-running unlock to get session key..."

        SESSION_KEY=$(bw unlock --raw 2>/dev/null)
        echo "" >&2  # Add newline after password input

        # Validate the session key
        log_progress "Validating session key..."
        if bw status --session "$SESSION_KEY" 2>/dev/null | jq -r '.status' 2>/dev/null | grep -q "unlocked"; then
            log_progress_done "Session key validated successfully"
        else
            echo "" >&2
            log_error "Session key validation failed"
            log_info "Try running: bw lock && bw unlock"
            return 1
        fi
    else
        log_error "Unexpected vault status: $vault_status"
        return 1
    fi
    # Sync vault so all reads/edits use the latest data
    log_debug "Syncing Bitwarden vault..."
    bw sync --session "$SESSION_KEY" >/dev/null 2>&1 || log_debug "Sync failed (non-fatal, continuing with local cache)"

    # Save the new session key to cache
    save_session_key "$SESSION_KEY"

    echo "$SESSION_KEY"
}

# Retrieve VPN configuration from Bitwarden
get_vpn_config() {
    local item_name=$1
    local session_key=$2

    log_step "Retrieving VPN configuration from Bitwarden"
    log_debug "Item name: $item_name"

    # FIX: Add retry logic for Bitwarden API calls
    local max_retries=2
    local retry_count=0
    local vpn_item=""
    local bw_exit_code=0

    while [ $retry_count -lt $max_retries ]; do
        log_progress "Retrieving item '$item_name' from Bitwarden (attempt $((retry_count + 1))/$max_retries)..."

        vpn_item=$(bw get item "$item_name" --session "$session_key" 2>&1)
        bw_exit_code=$?

        if [ $bw_exit_code -eq 0 ]; then
            log_progress_done "Retrieved VPN configuration from Bitwarden"
            break
        fi

        echo "" >&2  # Clear progress line
        retry_count=$((retry_count + 1))

        if [ $retry_count -lt $max_retries ]; then
            log_warn "Retrieval failed, retrying in 2 seconds..."
            sleep 2
        fi
    done
    if [ $bw_exit_code -ne 0 ]; then
        log_error "Failed to retrieve VPN item from Bitwarden after $max_retries attempts"
        log_error "Bitwarden error: $vpn_item"
        echo ""
        log_info "Item '$item_name' not found in your vault."
        echo ""
        log_info "Available items in your vault:"
        bw list items --session "$session_key" 2>/dev/null | jq -r '.[].name' | sed 's/^/  - /' || echo "  (Unable to list items)"
        echo ""
        log_info "To use this script, either:"
        log_info "  1. Create a Bitwarden item named: '$item_name'"
        log_info "  2. Rename this script to match an existing item (e.g., .myitem-vpn.sh)"
        return 1
    fi

    log_debug "VPN item retrieved successfully"

    # Validate it's valid JSON
    if ! echo "$vpn_item" | jq empty 2>/dev/null; then
        log_error "Retrieved item is not valid JSON"
        log_debug "Raw output from Bitwarden:"
        echo "$vpn_item" | head -10 | sed 's/^/  /'
        echo ""
        log_info "This usually means:"
        log_info "  1. The Bitwarden session expired during retrieval"
        log_info "  2. There's a network connectivity issue"
        log_info "  3. The Bitwarden CLI returned an error message instead of JSON"
        echo ""
        log_info "Try running: --clear-session to force re-authentication"
        return 1
    fi

    echo "$vpn_item"
}

# Parse VPN configuration
parse_vpn_config() {
    local vpn_item=$1

    log_debug "Parsing VPN configuration..."

    # Show raw item in debug mode
    if [ "$DEBUG" = true ]; then
        log_debug "Raw Bitwarden item structure:"
        echo "$vpn_item" | jq '.' 2>&1 | head -20 | sed 's/^/  /'
    fi

    VPN_USERNAME=$(echo "$vpn_item" | jq -r '.login.username' 2>&1)
    VPN_PASSWORD=$(echo "$vpn_item" | jq -r '.login.password' 2>&1)
    VPN_TRUSTED_CERT=$(echo "$vpn_item" | jq -r '.fields[]? | select(.name=="trusted-cert") | .value' 2>&1)
    VPN_HOST=$(echo "$vpn_item" | jq -r '.fields[]? | select(.name=="host") | .value' 2>&1)

    # Validate required fields
    local missing_fields=()

    if [ -z "$VPN_USERNAME" ] || [ "$VPN_USERNAME" = "null" ]; then
        missing_fields+=("username")
    fi

    if [ -z "$VPN_PASSWORD" ] || [ "$VPN_PASSWORD" = "null" ]; then
        missing_fields+=("password")
    fi

    if [ -z "$VPN_HOST" ] || [ "$VPN_HOST" = "null" ]; then
        missing_fields+=("host")
    fi

    if [ -z "$VPN_TRUSTED_CERT" ] || [ "$VPN_TRUSTED_CERT" = "null" ]; then
        missing_fields+=("trusted-cert")
    fi

    if [ ${#missing_fields[@]} -ne 0 ]; then
        log_error "Missing required fields in Bitwarden item: ${missing_fields[*]}"
        log_info "Required fields: username, password, host (custom field), trusted-cert (custom field)"
        return 1
    fi

    # Validate field formats to prevent injection of unexpected values
    if ! [[ "$VPN_HOST" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "VPN host contains invalid characters"
        return 1
    fi

    if ! [[ "$VPN_USERNAME" =~ ^[a-zA-Z0-9@._-]+$ ]]; then
        log_error "VPN username contains invalid characters"
        return 1
    fi

    if ! [[ "$VPN_TRUSTED_CERT" =~ ^[a-fA-F0-9:]+$ ]]; then
        log_error "Trusted cert hash contains invalid characters"
        return 1
    fi

    # Log parsed values if verbose
    if [ "$VERBOSE" = true ]; then
        log_success "Configuration parsed successfully:"
        echo "  VPN Host: $VPN_HOST"
        echo "  VPN Username: $VPN_USERNAME"
        echo "  VPN Password: ********"
        echo "  VPN Trusted Cert: ${VPN_TRUSTED_CERT:0:20}..."
    fi

    return 0
}

# Fetch the current SSL certificate hash from the VPN server
# Returns the SHA-256 fingerprint in the format openfortivpn expects
fetch_server_cert() {
    local host=$1
    local port=${2:-10443}

    log_progress "Fetching certificate from $host:$port..."

    local cert_output
    cert_output=$(echo "Q" | _timeout 10 openssl s_client -connect "$host:$port" 2>/dev/null)

    if [ -z "$cert_output" ]; then
        log_error "Could not connect to $host:$port to fetch certificate"
        return 1
    fi

    # Get SHA-256 fingerprint (openfortivpn uses this format)
    local fingerprint
    fingerprint=$(echo "$cert_output" | openssl x509 -outform der 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')

    if [ -z "$fingerprint" ]; then
        log_error "Could not extract certificate fingerprint"
        return 1
    fi

    log_progress_done "Certificate fetched"
    echo "$fingerprint"
}

# Check if the stored trusted-cert matches the server's current cert
# If mismatched, offer to update the Bitwarden item
check_and_update_cert() {
    local item_name=$1
    local session_key=$2

    log_step "Verifying server certificate"

    local server_cert
    if ! server_cert=$(fetch_server_cert "$VPN_HOST" 10443) || [ -z "$server_cert" ]; then
        log_warn "Could not fetch server certificate — skipping verification"
        log_info "Connection will proceed with stored cert; openfortivpn will reject if wrong"
        return 0
    fi

    # Normalize both for comparison (lowercase, no colons)
    local stored_norm server_norm
    stored_norm=$(echo "$VPN_TRUSTED_CERT" | tr '[:upper:]' '[:lower:]' | tr -d ':')
    server_norm=$(echo "$server_cert" | tr '[:upper:]' '[:lower:]' | tr -d ':')

    if [ "$stored_norm" = "$server_norm" ]; then
        log_success "Server certificate matches stored hash"
        return 0
    fi

    echo ""
    log_warn "SERVER CERTIFICATE HAS CHANGED"
    echo ""
    echo "  Stored:  ${VPN_TRUSTED_CERT}" >&2
    echo "  Server:  ${server_cert}" >&2
    echo ""
    log_warn "This can happen when the server's SSL certificate is renewed."
    log_info "If you expect this change, update the stored cert to continue connecting."
    echo ""

    log_prompt "Update the trusted-cert in Bitwarden? (y/N)"
    read -r update_cert || update_cert="n"

    if [[ ! "$update_cert" =~ ^[Yy] ]]; then
        log_info "Keeping old certificate. Connection may fail."
        return 0
    fi

    # Update the Bitwarden item
    log_progress "Updating trusted-cert in Bitwarden..."

    # Get the full item JSON, update the trusted-cert field
    local item_json
    item_json=$(bw get item "$item_name" --session "$session_key" 2>/dev/null)
    if [ -z "$item_json" ]; then
        log_error "Failed to retrieve Bitwarden item for update"
        return 1
    fi

    # Update the trusted-cert field and strip read-only server fields
    # bw edit rejects fields like object, revisionDate, deletedDate etc.
    local item_id
    item_id=$(echo "$item_json" | jq -r '.id')
    local updated_json
    updated_json=$(echo "$item_json" | jq --arg cert "$server_cert" '
        del(.object, .revisionDate, .creationDate, .deletedDate) |
        .fields = [(.fields // [])[] | if .name == "trusted-cert" then .value = $cert else . end]
    ')

    if [ -z "$updated_json" ]; then
        log_error "Failed to construct updated JSON"
        return 1
    fi

    log_debug "Encoding and pushing updated item to Bitwarden (id: $item_id)..."

    # bw edit expects: <json> | bw encode | bw edit item <id>
    local encoded
    encoded=$(echo "$updated_json" | bw encode 2>&1)
    if [ -z "$encoded" ]; then
        log_error "bw encode produced empty output"
        log_info "You can manually update the trusted-cert field in Bitwarden to:"
        echo "  $server_cert"
        return 1
    fi
    log_debug "Encoded payload length: ${#encoded}"

    local edit_result
    edit_result=$(echo "$encoded" | bw edit item "$item_id" --session "$session_key" 2>&1) || true

    if echo "$edit_result" | jq -e '.id' >/dev/null 2>&1; then
        log_progress_done "Certificate updated in Bitwarden"
        VPN_TRUSTED_CERT="$server_cert"
        log_success "Trusted cert updated to: ${server_cert}"
        return 0
    else
        log_error "Failed to update Bitwarden item."
        if [ -n "$edit_result" ]; then
            log_debug "bw edit output: $edit_result"
        fi
        log_info "You can manually update the trusted-cert field in Bitwarden to:"
        echo "  $server_cert"
        return 1
    fi
}

# Create VPN configuration file
create_vpn_config() {
    log_debug "Creating temporary VPN config file..."

    TEMP_CONFIG=$(mktemp)
    chmod 600 "$TEMP_CONFIG"
    log_debug "Temporary config file: $TEMP_CONFIG"
    log_debug "Operating system: $OS_TYPE"

    # Split-tunnel: we manage routes and DNS ourselves on ALL platforms
    # set-routes=0 prevents openfortivpn from adding routes (including default)
    # set-dns=0 prevents openfortivpn from modifying system DNS
    # pppd-use-peerdns=1 lets pppd learn VPN DNS servers for our split-DNS setup
    if [ "$OS_TYPE" = "Darwin" ]; then
        log_debug "Using macOS configuration (split-tunnel enforced)"
    else
        log_debug "Using Linux configuration (split-tunnel enforced)"
    fi

    cat > "$TEMP_CONFIG" << EOF
persistent=10
host = $VPN_HOST
port = 10443
username = $VPN_USERNAME
password = $VPN_PASSWORD
trusted-cert = $VPN_TRUSTED_CERT
set-routes = 0
set-dns = 0
pppd-use-peerdns = 1
EOF

    # Verify config file was created
    if [ ! -f "$TEMP_CONFIG" ]; then
        log_error "Failed to create temporary config file"
        return 1
    fi

    # Show config if verbose (without password)
    if [ "$VERBOSE" = true ]; then
        log_info "VPN configuration:"
        sed 's/password = .*/password = ***/' "$TEMP_CONFIG" | sed 's/^/  /' >&2
    fi

    echo "$TEMP_CONFIG"
}

# Default route list — used as fallback when no config file exists
default_routes() {
    cat <<'ROUTES'
10.1.0.0/16
10.2.0.0/16
10.3.0.0/16
10.4.0.0/16
10.5.0.0/16
10.6.0.0/16
10.7.0.0/16
10.8.0.0/16
10.9.0.0/16
10.10.0.0/16
10.12.0.0/16
10.13.0.0/16
10.14.0.0/16
10.16.0.0/16
10.17.0.0/16
10.18.0.0/16
10.19.0.0/16
10.25.0.0/16
10.40.70.0/24
10.213.0.0/16
10.250.0.0/16
10.252.0.0/24
ROUTES
}

# Load routes from config file, falling back to hardcoded defaults
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
        while IFS= read -r line; do
            routes+=("$line")
        done < <(default_routes)
    fi

    printf '%s\n' "${routes[@]}"
}

# Create routes and DNS config files from defaults
init_routes_config() {
    local config_dir
    config_dir=$(dirname "$ROUTES_CONFIG")
    local created_any=false

    mkdir -p "$config_dir"

    # Routes config
    if [ -f "$ROUTES_CONFIG" ]; then
        log_warn "Routes config already exists: $ROUTES_CONFIG"
        log_info "Remove it first if you want to regenerate from defaults"
    else
        {
            echo "# Bayport VPN Routes Configuration"
            echo "# One CIDR subnet per line. Lines starting with # are comments."
            echo "# Edit this file to customize which subnets route through the VPN."
            echo "#"
            default_routes
        } > "$ROUTES_CONFIG"
        log_success "Routes config created: $ROUTES_CONFIG"
        created_any=true
    fi

    # DNS config
    if [ -f "$DNS_CONFIG" ]; then
        log_warn "DNS config already exists: $DNS_CONFIG"
        log_info "Remove it first if you want to regenerate"
    else
        cat > "$DNS_CONFIG" << 'DNSEOF'
# Bayport VPN Split DNS Configuration
# Internal domains that should resolve via VPN DNS (one per line).
# Lines starting with # are comments.
#
# Optionally specify VPN DNS server (auto-detected from pppd if not set):
# nameserver 10.1.0.10
#
# Internal domains — uncomment and edit:
# example.internal
# corp.example.com
DNSEOF
        log_success "DNS config created: $DNS_CONFIG"
        created_any=true
    fi

    if [ "$created_any" = true ]; then
        log_info "Edit these files to customize your VPN routes and split DNS"
    fi

    return 0
}

# Verify split-tunnel routing is correct
verify_routes() {
    log_info "Split-tunnel route verification"
    echo ""

    local issues=0

    # 1. Check VPN interface
    log_info "1. VPN interface status"
    if check_interface_up; then
        log_success "   ppp0 interface is UP"
    else
        log_warn "   ppp0 interface is DOWN (VPN not connected)"
        echo ""
        log_info "Connect to VPN first, then re-run --verify-routes"
        return 0
    fi
    echo ""

    # 2. Default gateway check
    log_info "2. Default gateway check"
    local current_gw current_iface
    if [ "$OS_TYPE" = "Darwin" ]; then
        current_gw=$(netstat -rn 2>/dev/null | awk '/^default/ && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $2; exit}')
        current_iface=$(netstat -rn 2>/dev/null | awk '/^default/ && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $NF; exit}')
    else
        current_gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
        current_iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    fi

    echo "   Default gateway: ${current_gw:-<none>} via ${current_iface:-<none>}"

    if [[ "${current_iface:-}" == *ppp* ]]; then
        log_error "   LEAK DETECTED: Default route goes through VPN tunnel!"
        log_error "   ALL traffic is going through the VPN — this is NOT split-tunnel"
        issues=$((issues + 1))
    else
        log_success "   Default route is on local interface (not through VPN)"
    fi

    if [ -n "$DEFAULT_GW" ]; then
        if [ "$current_gw" = "$DEFAULT_GW" ] && [ "$current_iface" = "$DEFAULT_GW_IFACE" ]; then
            log_success "   Matches saved gateway: $DEFAULT_GW via $DEFAULT_GW_IFACE"
        else
            log_warn "   Does NOT match saved gateway: $DEFAULT_GW via $DEFAULT_GW_IFACE"
            issues=$((issues + 1))
        fi
    fi
    echo ""

    # 3. VPN routes check
    log_info "3. VPN routes via ppp0"
    local vpn_route_count
    vpn_route_count=$(count_vpn_routes)
    echo "   Routes for 10.x.x.x subnets via ppp0: $vpn_route_count"

    if [ "$vpn_route_count" -gt 0 ]; then
        list_vpn_routes 2>/dev/null | sed 's/^/     /' >&2
    fi
    echo ""

    # 4. Leak detection — check for non-10.x routes through ppp0
    log_info "4. Checking for route leakage"
    local all_ppp0_routes non_10_routes
    all_ppp0_routes=$(list_all_ppp0_routes 2>/dev/null || true)
    non_10_routes=$(echo "$all_ppp0_routes" | grep -v "^10\." | grep -v "^$" || true)

    if [ -n "$non_10_routes" ]; then
        # Filter out the ppp0 link-local/point-to-point routes which are normal
        local suspicious
        suspicious=$(echo "$non_10_routes" | grep -v "^link#" | grep -v "^169\.254" || true)
        if [ -n "$suspicious" ]; then
            log_warn "   Non-internal routes going through ppp0:"
            echo "$suspicious" | sed 's/^/     /' >&2

            # Check specifically for default route through ppp0
            if echo "$suspicious" | grep -qi "default\|0\.0\.0\.0"; then
                log_error "   CRITICAL: Default route is going through ppp0!"
                issues=$((issues + 1))
            else
                log_warn "   These routes may indicate partial leakage"
                issues=$((issues + 1))
            fi
        else
            log_success "   No suspicious routes through ppp0"
        fi
    else
        log_success "   No non-internal routes through ppp0"
    fi
    echo ""

    # 5. DNS check
    log_info "5. DNS configuration"
    if [ "$VPN_DNS_CONFIGURED" = true ]; then
        log_success "   Split DNS is active for ${#VPN_DNS_DOMAINS[@]} domain(s)"
        for domain in "${VPN_DNS_DOMAINS[@]}"; do
            echo "     - $domain" >&2
        done
    else
        log_info "   Split DNS not configured (general DNS is not affected by VPN)"
    fi
    echo ""

    # Summary
    if [ $issues -eq 0 ]; then
        log_success "Split-tunnel verification PASSED — no leakage detected"
    else
        log_error "Split-tunnel verification FAILED — $issues issue(s) found"
        return 1
    fi

    return 0
}

# Add VPN routes
add_vpn_routes() {
    log_info "Configuring VPN split-tunnel routes..."

    # Load subnets from config file or use defaults
    local -a subnets
    mapfile -t subnets < <(load_routes)

    local routes_added=0
    local routes_failed=0

    for subnet in "${subnets[@]}"; do
        if platform_route_add "$subnet"; then
            VPN_ROUTES_ADDED+=("$subnet")
            routes_added=$((routes_added + 1))
            log_debug "Added route: $subnet -> ppp0"
        else
            routes_failed=$((routes_failed + 1))
            log_debug "Failed to add route: $subnet (may already exist)"
        fi
    done

    # Verify routes in routing table
    sleep 1  # Give routes time to settle
    local actual_count
    actual_count=$(count_vpn_routes)

    log_success "Requested $routes_added routes, failed $routes_failed"
    log_info "Routing table shows $actual_count routes via ppp0"

    # Verify actual routes match what we tried to add
    if [ "$actual_count" -lt "$((routes_added / 2))" ]; then
        log_error "Route mismatch! Added $routes_added but only $actual_count exist"
        log_error "Something is removing routes (NetBird? Another VPN?)"
        log_info "Showing current ppp0 routes:"
        list_vpn_routes 2>/dev/null | head -10 | sed 's/^/  /' >&2
        return 1
    fi

    # Verify at least some routes were added
    if [ $routes_added -eq 0 ]; then
        log_error "Failed to add any routes! VPN may not work correctly."
        return 1
    fi

    log_success "Route verification passed"
    return 0
}

# Wait for VPN interface to come up
wait_for_vpn_interface() {
    local timeout=${1:-30}
    local count=0

    log_progress "Waiting for VPN interface ppp0..."

    while [ $count -lt $timeout ]; do
        if check_interface_up; then
            log_progress_done "VPN interface ppp0 is up"
            return 0
        fi

        # Early abort: check log for auth/cert failure every 3s
        if [ $((count % 3)) -eq 2 ] && [ -n "${VPN_LOG:-}" ] && [ -f "$VPN_LOG" ]; then
            local early_class
            early_class=$(classify_vpn_failure "$VPN_LOG")
            if [ "$early_class" = "auth" ] || [ "$early_class" = "cert" ]; then
                echo "" >&2
                log_debug "Detected $early_class failure in log — aborting wait early"
                return 1
            fi
        fi

        # Also abort if VPN process already exited
        if [ -n "${VPN_PID:-}" ] && ! kill -0 "$VPN_PID" 2>/dev/null; then
            echo "" >&2
            log_debug "VPN process exited during interface wait"
            return 1
        fi

        sleep 1
        count=$((count + 1))

        # Show progress indicator
        local dots=$((count % 4))
        local progress_dots=$(printf '.%.0s' $(seq 1 $dots))
        log_progress "Waiting for VPN interface ppp0${progress_dots} (${count}/${timeout}s)"
    done

    echo "" >&2  # Clear progress line
    log_error "Timeout waiting for VPN interface (${timeout}s)"
    return 1
}

# Classify VPN failure from log output
# Returns: "auth", "cert", "network", or "unknown"
# Auth/cert failures must NOT be retried (account lockout risk)
classify_vpn_failure() {
    local log_file=$1

    if [ ! -f "$log_file" ]; then
        echo "unknown"
        return
    fi

    local log_tail
    log_tail=$(tail -50 "$log_file" 2>/dev/null)

    # Auth failures — DO NOT retry (account lockout risk)
    if echo "$log_tail" | grep -qi "could not authenticate to gateway"; then
        echo "auth"
        return
    fi
    if echo "$log_tail" | grep -qi "login failed\|authentication failed\|invalid credentials"; then
        echo "auth"
        return
    fi
    if echo "$log_tail" | grep -qi "permission denied.*login\|access denied"; then
        echo "auth"
        return
    fi

    # Certificate failures — DO NOT retry (needs manual intervention)
    if echo "$log_tail" | grep -qi "certificate.*validation failed\|gateway certificate.*failed"; then
        echo "cert"
        return
    fi
    if echo "$log_tail" | grep -qi "trusted-cert.*mismatch\|server certificate.*changed"; then
        echo "cert"
        return
    fi
    if echo "$log_tail" | grep -qi "SSL.*error\|TLS.*handshake.*failed"; then
        echo "cert"
        return
    fi

    # Network failures — safe to retry
    if echo "$log_tail" | grep -qi "timed\? out\|connection refused\|network unreachable\|no route to host\|connection reset\|connection closed"; then
        echo "network"
        return
    fi

    echo "unknown"
}

# Handle VPN failure based on classification
# Returns 0 if retry is safe, 1 if we should bail out
handle_vpn_failure() {
    local log_file=$1
    local failure_type
    failure_type=$(classify_vpn_failure "$log_file")

    case "$failure_type" in
        auth)
            echo ""
            log_error "AUTHENTICATION FAILURE — not retrying to prevent account lockout"
            echo ""
            log_info "Possible causes:"
            log_info "  - Incorrect password (may have changed)"
            log_info "  - Account locked or disabled on the VPN gateway"
            log_info "  - 2FA/MFA required but not provided"
            echo ""
            log_info "Actions:"
            log_info "  1. Verify your credentials: $(basename "$0") --test-config"
            log_info "  2. Update password in Bitwarden if changed"
            log_info "  3. Check with IT if your VPN account is active"
            echo ""
            if [ -f "$log_file" ]; then
                log_info "Last few lines from VPN log:"
                tail -5 "$log_file" 2>/dev/null | sed 's/^/  /' >&2
            fi
            return 1
            ;;
        cert)
            echo ""
            log_error "CERTIFICATE FAILURE — not retrying"
            echo ""
            log_info "The server's SSL certificate doesn't match the stored trusted-cert."
            log_info "This usually means the certificate was renewed."
            echo ""
            log_info "Actions:"
            log_info "  1. Update certificate: $(basename "$0") --check-cert"
            log_info "  2. Then reconnect"
            echo ""
            if [ -f "$log_file" ]; then
                log_info "Last few lines from VPN log:"
                tail -5 "$log_file" 2>/dev/null | sed 's/^/  /' >&2
            fi
            return 1
            ;;
        network)
            log_warn "Network connectivity issue detected"
            return 0  # Safe to retry
            ;;
        *)
            UNKNOWN_FAILURE_COUNT=$((${UNKNOWN_FAILURE_COUNT:-0} + 1))
            log_warn "VPN process exited (cause unclear) [$UNKNOWN_FAILURE_COUNT consecutive]"
            if [ -f "$log_file" ]; then
                log_debug "Last few lines from VPN log:"
                tail -5 "$log_file" 2>/dev/null | sed 's/^/  /' >&2
            fi
            if [ "$UNKNOWN_FAILURE_COUNT" -ge 2 ]; then
                log_error "Multiple unknown failures — stopping to prevent possible account lockout"
                return 1
            fi
            return 0  # Unknown — allow one cautious retry
            ;;
    esac
}

# Monitor VPN connection and auto-reconnect on failure
# Distinguishes auth/cert failures (bail immediately) from network drops (retry)
monitor_vpn_connection() {
    local vpn_pid=$1
    local config_file=$2
    local max_reconnects=$MAX_RECONNECTS
    local reconnect_count=0
    local health_interval=30  # seconds between checks

    # Build command array for safe reconnection (no eval)
    local vpn_args=("sudo" "openfortivpn" "--pppd-accept-remote" "-c" "$config_file")
    [ "$VERBOSE" = true ] && vpn_args+=("-v")
    [ "$DEBUG" = true ] && vpn_args+=("-vv")

    while true; do
        sleep "$health_interval"

        # Check if VPN process is still running
        if ! kill -0 "$vpn_pid" 2>/dev/null; then
            log_warn "VPN process died (PID: $vpn_pid)"

            # Classify the failure before deciding whether to retry
            if ! handle_vpn_failure "$VPN_LOG"; then
                # Auth or cert failure — bail immediately
                return 1
            fi

            if [ "$NO_RECONNECT" = true ]; then
                log_info "Auto-reconnect disabled (--no-reconnect). Exiting."
                return 1
            fi

            if [ $reconnect_count -ge $max_reconnects ]; then
                log_error "Max reconnection attempts ($max_reconnects) reached. Giving up."
                return 1
            fi

            reconnect_count=$((reconnect_count + 1))
            log_info "Attempting reconnection ($reconnect_count/$max_reconnects)..."

            # Exponential backoff: 5s, 15s, 30s, 60s, capped at 60s
            local backoff=$((reconnect_count * reconnect_count * 5))
            if [ $backoff -gt 60 ]; then backoff=60; fi
            log_info "Waiting ${backoff}s before reconnecting..."
            sleep "$backoff"

            # Clear old log for fresh failure classification
            : > "$VPN_LOG"

            # Restart VPN
            "${vpn_args[@]}" >> "$VPN_LOG" 2>&1 &
            vpn_pid=$!
            VPN_PID=$vpn_pid  # Update global for cleanup trap

            if wait_for_vpn_interface 30; then
                # Re-verify default gateway after reconnect
                if ! verify_default_gateway; then
                    log_warn "Default gateway changed after reconnect — restoring..."
                    restore_default_gateway
                fi
                add_vpn_routes
                configure_split_dns
                log_success "Reconnected successfully (PID: $vpn_pid)"
                reconnect_count=0  # reset on success
                UNKNOWN_FAILURE_COUNT=0
            else
                # Check if reconnect failed due to auth/cert
                if ! kill -0 "$vpn_pid" 2>/dev/null; then
                    if ! handle_vpn_failure "$VPN_LOG"; then
                        return 1  # Auth/cert — stop retrying
                    fi
                fi
                log_error "Reconnection failed"
                kill "$vpn_pid" 2>/dev/null
            fi
            continue
        fi

        # Check interface is still up
        if ! check_interface_up; then
            log_warn "ppp0 interface disappeared but VPN process still running"
        fi

        # Periodically verify default gateway hasn't been hijacked
        if ! verify_default_gateway; then
            log_warn "Default gateway hijacked during VPN session — restoring..."
            restore_default_gateway
        fi
    done
}

# DNS leak test — verify VPN DNS is scoped to internal domains only
# Usage: dns_leak_test <vpn_connected: true|false>
dns_leak_test() {
    local vpn_connected="${1:-false}"
    local test_domain="google.com"
    local issues=0

    log_info "Checking DNS configuration for leaks..."

    if [ "$OS_TYPE" = "Darwin" ]; then
        # macOS: check /etc/resolver/ for blanket DNS overrides
        if [ -d "/etc/resolver" ]; then
            local has_resolver_files=false
            for f in /etc/resolver/*; do
                [ -e "$f" ] || continue
                has_resolver_files=true
                local fname
                fname=$(basename "$f")
                log_debug "  /etc/resolver/$fname: $(grep nameserver "$f" 2>/dev/null | head -1)"

                # Blanket overrides cover ALL queries for a TLD or default
                if [[ "$fname" =~ ^(default|com|net|org|io|co)$ ]]; then
                    log_warn "Blanket DNS override: /etc/resolver/$fname"
                    log_warn "  Routes ALL .$fname lookups through VPN DNS"
                    issues=$((issues + 1))
                fi
            done
            if [ "$has_resolver_files" = false ]; then
                log_debug "No /etc/resolver/ entries found"
            fi
        fi

        # Check scutil DNS for global override to private IP
        if command -v scutil >/dev/null 2>&1; then
            local global_dns
            global_dns=$(scutil --dns 2>/dev/null | awk '/^resolver #1/{found=1} found && /nameserver\[0\]/{print $3; exit}')
            if [ -n "$global_dns" ]; then
                log_debug "Primary DNS resolver: $global_dns"
                if [[ "$global_dns" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
                    log_warn "Primary DNS is a private IP ($global_dns) — likely VPN DNS"
                    log_warn "  All DNS queries may be routed through VPN"
                    issues=$((issues + 1))
                fi
            fi
        fi

    else
        # Linux: check systemd-resolved and resolv.conf
        if command -v resolvectl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
            log_debug "systemd-resolved is active"

            # Check if VPN DNS is set as global default
            local global_dns
            global_dns=$(resolvectl dns 2>/dev/null | grep "Global:" | awk '{for(i=2;i<=NF;i++) print $i}')
            if [ -n "$global_dns" ]; then
                for dns in $global_dns; do
                    if [[ "$dns" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
                        log_warn "Global DNS set to private IP ($dns) — VPN DNS leak"
                        issues=$((issues + 1))
                    fi
                done
            fi

            # Check if VPN interface has default routing domain (~.)
            local vpn_iface="ppp0"
            if ip link show "$vpn_iface" >/dev/null 2>&1; then
                local vpn_domains
                vpn_domains=$(resolvectl domain "$vpn_iface" 2>/dev/null)
                if echo "$vpn_domains" | grep -q '~\.$'; then
                    log_warn "VPN interface ($vpn_iface) is the default DNS route (~.)"
                    log_warn "  All DNS queries are being routed through VPN"
                    issues=$((issues + 1))
                fi
            fi
        else
            # No systemd-resolved — check /etc/resolv.conf
            if [ -f "/etc/resolv.conf" ]; then
                local nameservers
                nameservers=$(grep "^nameserver" /etc/resolv.conf | awk '{print $2}')
                local private_count=0
                local total_count=0
                for ns in $nameservers; do
                    total_count=$((total_count + 1))
                    if [[ "$ns" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
                        log_debug "resolv.conf has private DNS: $ns"
                        private_count=$((private_count + 1))
                    fi
                done
                # If ALL nameservers are private, that's likely a full VPN DNS override
                if [ $total_count -gt 0 ] && [ $private_count -eq $total_count ]; then
                    log_warn "All nameservers in /etc/resolv.conf are private IPs"
                    log_warn "  DNS is fully overridden — likely VPN DNS leak"
                    issues=$((issues + 1))
                elif [ $private_count -gt 0 ]; then
                    log_debug "Some private nameservers in resolv.conf ($private_count/$total_count)"
                fi
            fi
        fi
    fi

    # Active DNS resolution test (only meaningful when VPN is connected)
    if [ "$vpn_connected" = true ] && command -v dig >/dev/null 2>&1; then
        log_info "Testing DNS resolution path for $test_domain..."

        local dig_server
        dig_server=$(dig +time=3 +tries=1 "$test_domain" 2>/dev/null | grep "^;; SERVER:" | awk '{print $3}' | sed 's/#.*//')

        if [ -n "$dig_server" ]; then
            log_debug "DNS server used for $test_domain: $dig_server"
            if [[ "$dig_server" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
                log_warn "Public domain ($test_domain) resolved via private DNS ($dig_server)"
                log_warn "  DNS is leaking through VPN"
                issues=$((issues + 1))
            else
                log_success "Public DNS ($test_domain) resolved via $dig_server (not VPN)"
            fi
        else
            log_debug "Could not determine DNS server for $test_domain"
        fi
    elif [ "$vpn_connected" = true ]; then
        log_debug "dig not available — skipping active DNS resolution test"
    fi

    # Summary
    if [ $issues -gt 0 ]; then
        echo ""
        log_warn "DNS leak check found $issues issue(s)"
        log_info "Remediation:"
        if [ "$OS_TYPE" = "Darwin" ]; then
            log_info "  - Remove blanket overrides from /etc/resolver/"
            log_info "  - Only keep resolver files for internal domains"
            log_info "  - Example: /etc/resolver/corp.internal with VPN DNS"
        else
            log_info "  - Configure split DNS via systemd-resolved"
            log_info "  - Set VPN DNS only for internal domains, not globally"
            log_info "  - Example: resolvectl domain ppp0 '~corp.internal'"
        fi
        return 1
    else
        log_success "No DNS leak detected"
        return 0
    fi
}

# Connect to VPN
connect_vpn() {
    local config_file=$1

    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY RUN MODE - Not actually connecting to VPN"
        log_info "Would execute: sudo openfortivpn --pppd-accept-remote -c $config_file"
        echo ""
        # Run DNS leak check against current system state
        log_step "DNS leak pre-check (current system state)"
        dns_leak_test false || true
        return 0
    fi

    log_step "Connecting to VPN at $VPN_HOST:10443"

    # Capture default gateway BEFORE VPN connects
    log_info "Saving current default gateway for split-tunnel enforcement..."
    if ! capture_default_gateway; then
        log_error "Cannot proceed without a default gateway"
        return 1
    fi

    # Build openfortivpn command as array (avoids eval and shell injection)
    local vpn_args=("sudo" "openfortivpn" "--pppd-accept-remote" "-c" "$config_file")

    # Add verbose flag if requested
    [ "$VERBOSE" = true ] && vpn_args+=("-v")
    [ "$DEBUG" = true ] && vpn_args+=("-vv")

    log_debug "Command: sudo openfortivpn --pppd-accept-remote -c <config_file> [flags]"

    # Create log file to capture VPN output for failure classification
    VPN_LOG=$(mktemp)
    chmod 600 "$VPN_LOG"
    log_debug "VPN output log: $VPN_LOG"

    log_step "Establishing VPN connection"

    # Start VPN in background, capturing output for failure analysis
    "${vpn_args[@]}" > "$VPN_LOG" 2>&1 &
    local vpn_pid=$!
    VPN_PID=$vpn_pid  # Store globally for cleanup trap

    # Tail the log in background if verbose
    TAIL_PID=""
    if [ "$VERBOSE" = true ]; then
        tail -f "$VPN_LOG" 2>/dev/null | sed 's/^/  [vpn] /' >&2 &
        TAIL_PID=$!
    fi

    # Wait for interface to come up
    if ! wait_for_vpn_interface 30; then
        echo "" >&2  # Clear progress line
        [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null && TAIL_PID=""

        # Check log for auth/cert failure (process may still be alive doing internal retries)
        if ! handle_vpn_failure "$VPN_LOG"; then
            kill "$vpn_pid" 2>/dev/null || true
            return 1  # Auth or cert failure — do not retry
        fi

        log_error "VPN interface failed to initialize"
        kill "$vpn_pid" 2>/dev/null
        return 1
    fi

    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null && TAIL_PID=""

    # CRITICAL: Verify default gateway was NOT hijacked by openfortivpn
    log_step "Verifying split-tunnel integrity"
    if ! verify_default_gateway; then
        log_warn "openfortivpn modified the default route — fixing immediately..."
        restore_default_gateway
    else
        log_success "Default gateway intact — split-tunnel verified"
    fi

    # Add only our specific internal routes
    log_step "Configuring VPN routes"
    if ! add_vpn_routes; then
        log_warn "Route configuration had issues, but continuing..."
    fi

    # Configure split DNS
    log_step "Configuring split DNS"
    configure_split_dns

    # DNS leak check (post-connection)
    log_step "DNS leak check"
    dns_leak_test true || log_warn "DNS leak issues detected — review warnings above"

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${GREEN}║  ✓ VPN CONNECTED AND CONFIGURED               ║${NC}" >&2
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}" >&2
    echo ""
    log_info "VPN Host: $VPN_HOST:10443"
    log_info "Interface: ppp0"
    log_info "Split-tunnel: ENFORCED (only internal subnets via VPN)"
    log_info "Default gateway: $DEFAULT_GW via $DEFAULT_GW_IFACE (preserved)"
    echo ""
    echo -e "${YELLOW}Press Ctrl+C to disconnect${NC}" >&2
    echo ""

    # Monitor connection with auto-reconnect, or simple wait if disabled
    if [ "$NO_RECONNECT" = true ]; then
        log_debug "Auto-reconnect disabled, waiting for VPN process"
        local exit_code=0
        wait $vpn_pid || exit_code=$?
        # Show failure reason even when not retrying
        if [ $exit_code -ne 0 ]; then
            handle_vpn_failure "$VPN_LOG" || true
        fi
    else
        log_debug "Monitoring VPN connection (max reconnects: $MAX_RECONNECTS)"
        monitor_vpn_connection "$vpn_pid" "$config_file"
        local exit_code=$?
    fi

    echo ""
    log_success "VPN disconnected"
    return $exit_code
}

# Main function
main() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${BLUE}║  Bayport VPN Connection Script                 ║${NC}" >&2
    echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}" >&2
    echo ""

    # Detect keystore backend (OS_TYPE already set by detect_platform at top level)
    detect_keystore

    # Parse arguments
    parse_args "$@"

    # Check dependencies
    log_step "Checking dependencies"
    if ! check_dependencies; then
        return 1
    fi

    # Pre-check permissions (sudo, Bitwarden)
    if ! precheck_permissions; then
        return 1
    fi

    # Keep sudo alive throughout the session (skip for dry-run)
    if [ "$DRY_RUN" != true ]; then
        start_sudo_keepalive
    fi

    # Get item name
    local item_name
    item_name=$(get_item_name)

    # Get Bitwarden session
    local session_key
    session_key=$(get_bitwarden_session)
    if [ -z "$session_key" ]; then
        return 1
    fi

    # Get VPN config from Bitwarden
    local vpn_item
    if ! vpn_item=$(get_vpn_config "$item_name" "$session_key") || [ -z "$vpn_item" ]; then
        return 1
    fi

    # Test config mode
    if [ "${TEST_CONFIG:-false}" = true ]; then
        log_info "Testing configuration..."
        if parse_vpn_config "$vpn_item"; then
            log_success "Configuration test passed!"
            return 0
        else
            return 1
        fi
    fi

    # Parse VPN config
    if ! parse_vpn_config "$vpn_item"; then
        return 1
    fi

    # Verify server certificate matches stored hash (and offer to update if changed)
    check_and_update_cert "$item_name" "$session_key"

    # Cert-check-only mode
    if [ "${CHECK_CERT_ONLY:-false}" = true ]; then
        log_success "Certificate check complete"
        return 0
    fi

    # Check for VPN conflicts (NetBird, stale ppp, other VPNs)
    if ! check_vpn_conflicts; then
        if [ "${IGNORE_CONFLICTS:-false}" = true ]; then
            log_warn "Ignoring conflicts (--ignore-conflicts)"
        else
            log_warn "Proceeding in 5s unless you press Ctrl+C (use --ignore-conflicts to skip)..."
            local countdown=5
            while [ $countdown -gt 0 ]; do
                printf "\r  Continuing in %ds... " "$countdown" >&2
                if read -r -t 1 abort_input 2>/dev/null; then
                    # User pressed Enter or typed something — abort
                    echo "" >&2
                    log_info "Resolve conflicts and try again"
                    return 1
                fi
                countdown=$((countdown - 1))
            done
            printf "\r                        \r" >&2  # Clear countdown line
            log_info "Proceeding with conflicts..."
        fi
    fi

    # Create VPN config file
    local config_file
    config_file=$(create_vpn_config)
    if [ -z "$config_file" ]; then
        return 1
    fi

    # Connect to VPN
    connect_vpn "$config_file"
    return $?
}

# Initialize platform detection (must run before any platform-dependent code)
detect_platform

# Run main function
main "$@"
