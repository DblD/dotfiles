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
SESSION_TIMEOUT=3600  # 1 hour in seconds (configurable)
VPN_ROUTES_ADDED=()  # Track routes we added for cleanup
NO_RECONNECT=false
MAX_RECONNECTS=${MAX_RECONNECTS:-3}
SUDO_KEEPALIVE_PID=""
ROUTES_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/bayport-vpn/routes.conf"
DNS_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/bayport-vpn/dns.conf"

# Platform detection globals (set by detect_platform)
OS_TYPE=""
HAS_IFCONFIG=false
HAS_IP=false
HAS_NETSTAT=false
HAS_RESOLVECTL=false
HAS_SCUTIL=false

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
            ((removed++))
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

# Cleanup function
cleanup() {
    local exit_code=$?
    log_debug "Running cleanup..."

    # Stop sudo keepalive if running
    stop_sudo_keepalive

    # Remove split DNS configuration
    remove_split_dns

    # Remove VPN routes if any were added
    remove_vpn_routes

    if [ -n "$TEMP_CONFIG" ] && [ -f "$TEMP_CONFIG" ]; then
        log_debug "Removing temporary config file: $TEMP_CONFIG"
        rm -f "$TEMP_CONFIG"
    fi

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
    --session-timeout   Set session timeout in seconds (default: 3600)
    --netbird-status    Check NetBird status and conflicts
    --no-reconnect      Disable automatic reconnection on VPN drop
    --max-reconnects N  Max reconnection attempts (default: 3, env: MAX_RECONNECTS)
    --init-routes       Create routes/DNS config files from defaults for customization
    --verify-routes     Check current routing table for split-tunnel correctness

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
        if echo "Q" | timeout 5 openssl s_client -connect "$VPN_HOST:10443" >/dev/null 2>&1; then
            log_success "SSL/TLS handshake successful"

            # Show certificate info
            log_info "Certificate details:"
            echo "Q" | timeout 5 openssl s_client -connect "$VPN_HOST:10443" 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /'
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
    if timeout 10 openfortivpn "$VPN_HOST:10443" --no-routes --pppd-log /dev/null 2>&1 | grep -q "STATUS"; then
        log_success "OpenFortiVPN can communicate with server"
    else
        log_warn "OpenFortiVPN test inconclusive"
    fi
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

    log_progress "Checking dependencies..."

    for cmd in bw jq openfortivpn mktemp; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "" >&2  # Clear progress line
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install missing dependencies and try again"
        return 1
    fi

    log_progress_done "All dependencies installed (bw, jq, openfortivpn, mktemp)"

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
    if ! sudo -n true 2>/dev/null; then
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
        echo -e "${YELLOW}║  PERMISSIONS REQUIRED                           ║${NC}" >&2
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
        echo "  Status: ${RED}RUNNING${NC} (PID: $netbird_pid)" >&2
        echo "  ${YELLOW}⚠ WARNING: NetBird interferes with VPN routing${NC}" >&2
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

        echo "  ${BLUE}To stop NetBird:${NC}" >&2
        echo "    sudo netbird down" >&2
        echo "" >&2

        return 1
    else
        echo "  Status: ${GREEN}STOPPED${NC}" >&2
        echo "  ${GREEN}✓ Safe to connect VPN${NC}" >&2
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
        ((conflicts_found++))

        # Show NetBird interfaces
        local netbird_ifaces
        netbird_ifaces=$(count_utun_interfaces)
        log_info "NetBird has $netbird_ifaces utun interfaces active"
    fi

    # Check for other VPN software
    if pgrep -i "openvpn" >/dev/null 2>&1; then
        log_warn "OpenVPN is running - may conflict"
        ((conflicts_found++))
    fi

    if pgrep -i "wireguard\|wg" >/dev/null 2>&1; then
        log_warn "WireGuard is running - may conflict"
        ((conflicts_found++))
    fi

    # Check for existing ppp interfaces
    if check_ppp_interface_exists; then
        log_warn "PPP interface already exists - previous VPN connection may not be cleaned up"
        log_info "Run: sudo pkill -9 openfortivpn && sudo pkill -9 pppd"
        ((conflicts_found++))
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

save_session_key() {
    local session_key=$1
    ensure_session_cache_dir

    log_progress "Saving session to cache..."
    echo "$session_key" > "$SESSION_CACHE_FILE"
    chmod 600 "$SESSION_CACHE_FILE"
    log_progress_done "Session cached (valid for $((SESSION_TIMEOUT / 60)) minutes)"
}

load_cached_session() {
    if [ ! -f "$SESSION_CACHE_FILE" ]; then
        log_debug "No cached session found"
        return 1
    fi

    # Check if cache file is older than timeout
    if [ "$(uname -s)" = "Darwin" ]; then
        # macOS
        local file_age=$(($(date +%s) - $(stat -f %m "$SESSION_CACHE_FILE")))
    else
        # Linux
        local file_age=$(($(date +%s) - $(stat -c %Y "$SESSION_CACHE_FILE")))
    fi

    if [ $file_age -gt $SESSION_TIMEOUT ]; then
        log_warn "Cached session expired (${file_age}s old, timeout: ${SESSION_TIMEOUT}s)"
        rm -f "$SESSION_CACHE_FILE"
        return 1
    fi

    local cached_key=$(cat "$SESSION_CACHE_FILE")

    # Verify the session key is still valid
    log_debug "Found cached session (${file_age}s old), validating..."
    if bw list items --session "$cached_key" >/dev/null 2>&1; then
        log_success "Using cached session key (${file_age}s old)"
        echo "$cached_key"
        return 0
    else
        log_warn "Cached session key is invalid, clearing cache"
        rm -f "$SESSION_CACHE_FILE"
        return 1
    fi
}

clear_session_cache() {
    if [ -f "$SESSION_CACHE_FILE" ]; then
        log_info "Clearing cached session key..."
        rm -f "$SESSION_CACHE_FILE"
        log_success "Session cache cleared"
    else
        log_info "No cached session to clear"
    fi
}

show_session_status() {
    log_info "Session cache status:"
    echo ""
    echo "  Cache directory: $SESSION_CACHE_DIR"
    echo "  Cache file: $SESSION_CACHE_FILE"
    echo "  Timeout: ${SESSION_TIMEOUT}s ($(($SESSION_TIMEOUT / 60)) minutes)"
    echo ""

    if [ ! -f "$SESSION_CACHE_FILE" ]; then
        echo "  Status: ${RED}No cached session${NC}"
        return 0
    fi

    # Get file age
    if [ "$(uname -s)" = "Darwin" ]; then
        local file_age=$(($(date +%s) - $(stat -f %m "$SESSION_CACHE_FILE")))
        local created=$(date -r $(stat -f %m "$SESSION_CACHE_FILE") "+%Y-%m-%d %H:%M:%S")
    else
        local file_age=$(($(date +%s) - $(stat -c %Y "$SESSION_CACHE_FILE")))
        local created=$(date -d @$(stat -c %Y "$SESSION_CACHE_FILE") "+%Y-%m-%d %H:%M:%S")
    fi

    local remaining=$((SESSION_TIMEOUT - file_age))

    echo "  Created: $created"
    echo "  Age: ${file_age}s ($(($file_age / 60)) minutes)"

    if [ $file_age -gt $SESSION_TIMEOUT ]; then
        echo "  Status: ${RED}Expired${NC} (exceeded timeout by $((file_age - SESSION_TIMEOUT))s)"
    else
        echo "  Status: ${GREEN}Valid${NC}"
        echo "  Expires in: ${remaining}s ($(($remaining / 60)) minutes)"

        # Validate the key
        local cached_key=$(cat "$SESSION_CACHE_FILE")
        if bw list items --session "$cached_key" >/dev/null 2>&1; then
            echo "  Verification: ${GREEN}Session key is valid${NC}"
        else
            echo "  Verification: ${RED}Session key is invalid${NC}"
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
                if [[ $1 =~ ^[0-9]+$ ]]; then
                    SESSION_TIMEOUT=$1
                    log_info "Session timeout set to ${SESSION_TIMEOUT}s"
                else
                    log_error "Invalid timeout value: $1 (must be a number)"
                    exit 1
                fi
                shift
                ;;
            --no-reconnect)
                NO_RECONNECT=true
                shift
                ;;
            --max-reconnects)
                shift
                if [[ $1 =~ ^[0-9]+$ ]]; then
                    MAX_RECONNECTS=$1
                    log_info "Max reconnects set to $MAX_RECONNECTS"
                else
                    log_error "Invalid max-reconnects value: $1 (must be a number)"
                    exit 1
                fi
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
        # FIX: Validate the environment session
        if bw list items --session "$BW_SESSION" >/dev/null 2>&1; then
            SESSION_KEY=$BW_SESSION
            echo "$SESSION_KEY"
            return 0
        else
            log_warn "Environment BW_SESSION is invalid, will try cached session"
        fi
    fi

    # Try to load cached session with validation
    local cached_session=$(load_cached_session)
    if [ -n "$cached_session" ]; then
        # FIX: Double-check the cached session is still valid right before using it
        log_debug "Double-checking cached session validity..."
        if bw list items --session "$cached_session" >/dev/null 2>&1; then
            SESSION_KEY=$cached_session
            echo "$SESSION_KEY"
            return 0
        else
            log_warn "Cached session became invalid, clearing and retrying..."
            clear_session_cache > /dev/null 2>&1
        fi
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
                    ((attempt++))
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
            if bw list items --session "$SESSION_KEY" >/dev/null 2>&1; then
                log_progress_done "Session key validated successfully"
                unlock_successful=true
                break
            else
                echo "" >&2  # Clear progress line

                if [ $attempt -lt $max_attempts ]; then
                    log_error "Authentication failed - please try again"
                    log_debug "Session validation failed for attempt $attempt"
                    ((attempt++))
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
        if bw list items --session "$SESSION_KEY" >/dev/null 2>&1; then
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
        ((retry_count++))

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

# Create VPN configuration file
create_vpn_config() {
    log_debug "Creating temporary VPN config file..."

    TEMP_CONFIG=$(mktemp)
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

    echo "${routes[@]}"
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
        ((issues++))
    else
        log_success "   Default route is on local interface (not through VPN)"
    fi

    if [ -n "$DEFAULT_GW" ]; then
        if [ "$current_gw" = "$DEFAULT_GW" ] && [ "$current_iface" = "$DEFAULT_GW_IFACE" ]; then
            log_success "   Matches saved gateway: $DEFAULT_GW via $DEFAULT_GW_IFACE"
        else
            log_warn "   Does NOT match saved gateway: $DEFAULT_GW via $DEFAULT_GW_IFACE"
            ((issues++))
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
                ((issues++))
            else
                log_warn "   These routes may indicate partial leakage"
                ((issues++))
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
    read -ra subnets <<< "$(load_routes)"

    local routes_added=0
    local routes_failed=0

    for subnet in "${subnets[@]}"; do
        if platform_route_add "$subnet"; then
            VPN_ROUTES_ADDED+=("$subnet")
            ((routes_added++))
            log_debug "Added route: $subnet -> ppp0"
        else
            ((routes_failed++))
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
        sleep 1
        ((count++))

        # Show progress indicator
        local dots=$((count % 4))
        local progress_dots=$(printf '.%.0s' $(seq 1 $dots))
        log_progress "Waiting for VPN interface ppp0${progress_dots} (${count}/${timeout}s)"
    done

    echo "" >&2  # Clear progress line
    log_error "Timeout waiting for VPN interface (${timeout}s)"
    return 1
}

# Monitor VPN connection and auto-reconnect on failure
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

            if [ "$NO_RECONNECT" = true ]; then
                log_info "Auto-reconnect disabled (--no-reconnect). Exiting."
                return 1
            fi

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
                # Re-verify default gateway after reconnect
                if ! verify_default_gateway; then
                    log_warn "Default gateway changed after reconnect — restoring..."
                    restore_default_gateway
                fi
                add_vpn_routes
                configure_split_dns
                log_success "Reconnected successfully (PID: $vpn_pid)"
                reconnect_count=0  # reset on success
            else
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

# Connect to VPN
connect_vpn() {
    local config_file=$1

    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY RUN MODE - Not actually connecting to VPN"
        log_info "Would execute: sudo openfortivpn --pppd-accept-remote -c $config_file"
        return 0
    fi

    log_step "Connecting to VPN at $VPN_HOST:10443"

    # Capture default gateway BEFORE VPN connects
    log_info "Saving current default gateway for split-tunnel enforcement..."
    if ! capture_default_gateway; then
        log_error "Cannot proceed without a default gateway"
        return 1
    fi

    # Build openfortivpn command as array (no eval — safe from injection)
    local vpn_args=("sudo" "openfortivpn" "--pppd-accept-remote" "-c" "$config_file")

    # Add verbose flag if requested
    [ "$VERBOSE" = true ] && vpn_args+=("-v")
    [ "$DEBUG" = true ] && vpn_args+=("-vv")

    log_debug "Command: ${vpn_args[*]/<config_file>/}"

    log_step "Establishing VPN connection"

    # Start VPN in background
    "${vpn_args[@]}" &
    local vpn_pid=$!

    # Wait for interface to come up
    if ! wait_for_vpn_interface 30; then
        echo "" >&2  # Clear progress line
        log_error "VPN interface failed to initialize"
        kill $vpn_pid 2>/dev/null
        return 1
    fi

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
        wait $vpn_pid
        local exit_code=$?
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

    # Keep sudo alive throughout the session
    start_sudo_keepalive

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
