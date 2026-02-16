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
OS_TYPE=""            # Detected OS (Darwin, Linux, etc.)
KEYSTORE_BACKEND=""   # Detected keystore (keychain, secret-tool, pass, file)

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

# Remove VPN routes
remove_vpn_routes() {
    if [ ${#VPN_ROUTES_ADDED[@]} -eq 0 ]; then
        log_debug "No routes to remove"
        return 0
    fi

    log_info "Removing VPN routes..."
    local removed=0

    for route in "${VPN_ROUTES_ADDED[@]}"; do
        if sudo route delete -net "$route" >/dev/null 2>&1; then
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

    # Remove VPN routes if any were added
    remove_vpn_routes

    if [ -n "$TEMP_CONFIG" ] && [ -f "$TEMP_CONFIG" ]; then
        log_debug "Securely removing temporary config file: $TEMP_CONFIG"
        if command -v shred >/dev/null 2>&1; then
            shred -u "$TEMP_CONFIG" 2>/dev/null
        elif command -v gshred >/dev/null 2>&1; then
            gshred -u "$TEMP_CONFIG" 2>/dev/null
        else
            rm -f "$TEMP_CONFIG"
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
trap cleanup EXIT INT TERM

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

    local os_type=$(uname -s)

    log_info "Generated OpenFortiVPN Configuration"
    log_info "OS Detected: $os_type"
    echo ""

    if [ "$os_type" = "Darwin" ]; then
        log_info "macOS Configuration:"
        echo ""
        cat << EOF
persistent=10              # Keep connection alive, retry 10 times
host = $VPN_HOST          # VPN server hostname
port = 10443               # VPN port
username = $VPN_USERNAME   # Your username
password = ********        # Password (hidden)
trusted-cert = $VPN_TRUSTED_CERT  # Server certificate fingerprint
set-dns = 0                # Don't set DNS via resolvconf (macOS specific)
pppd-use-peerdns = 1       # Use DNS from VPN server via pppd (macOS specific)
EOF
        echo ""
        log_info "macOS-specific flags explained:"
        log_info "  • set-dns = 0: Prevents using resolvconf (not available on macOS)"
        log_info "  • pppd-use-peerdns = 1: Tells pppd to accept DNS from VPN server"
        log_info "    This is how DNS configuration works on macOS"
    else
        log_info "Linux/Unix Configuration:"
        echo ""
        cat << EOF
persistent=10              # Keep connection alive, retry 10 times
host = $VPN_HOST          # VPN server hostname
port = 10443               # VPN port
username = $VPN_USERNAME   # Your username
password = ********        # Password (hidden)
trusted-cert = $VPN_TRUSTED_CERT  # Server certificate fingerprint
EOF
        echo ""
        log_info "Standard Linux configuration without macOS-specific DNS flags"
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
        local utun_count=$(ifconfig | grep -c "^utun")
        echo "  Active utun interfaces: $utun_count" >&2
        ifconfig | grep "^utun" | sed 's/^/    /' >&2
        echo "" >&2

        # Check NetBird routes
        local netbird_routes=$(netstat -rn | grep "utun" | wc -l | xargs)
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
        local netbird_ifaces=$(ifconfig | grep -c "^utun")
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
    if ifconfig | grep -q "^ppp"; then
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
        timeout 2 secret-tool lookup service bayport-vpn-probe >/dev/null 2>&1 || st_exit=$?
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

    # Store timestamp for session timeout tracking (all backends)
    install -m 600 /dev/null "${SESSION_CACHE_DIR}/session_timestamp"
    date +%s > "${SESSION_CACHE_DIR}/session_timestamp"

    log_progress_done "Session cached via $KEYSTORE_BACKEND (valid for $((SESSION_TIMEOUT / 60)) minutes)"
}

load_cached_session() {
    local cached_key=""
    local file_age=$((SESSION_TIMEOUT + 1))

    # Check timestamp for timeout (unified across all backends)
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

    if [ $file_age -gt $SESSION_TIMEOUT ]; then
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

    # Verify the session key is still valid
    log_debug "Found cached session (${file_age}s old via $KEYSTORE_BACKEND), validating..."
    if bw list items --session "$cached_key" >/dev/null 2>&1; then
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

    # Always clean up timestamp
    if [ -f "${SESSION_CACHE_DIR}/session_timestamp" ]; then
        rm -f "${SESSION_CACHE_DIR}/session_timestamp"
        cleared=true
    fi

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
    echo "  Timeout: ${SESSION_TIMEOUT}s ($(($SESSION_TIMEOUT / 60)) minutes)"
    echo ""

    # Check timestamp
    local file_age=$((SESSION_TIMEOUT + 1))
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
    # Check if a session exists in the backend
    local has_session=false
    _read_session_from_backend >/dev/null 2>&1 && has_session=true

    if [ "$has_session" = false ] && [ "$has_timestamp" = false ]; then
        echo "  Status: ${RED}No cached session${NC}"
        return 0
    fi

    echo "  Age: ${file_age}s ($(($file_age / 60)) minutes)"

    local remaining=$((SESSION_TIMEOUT - file_age))

    if [ $file_age -gt $SESSION_TIMEOUT ]; then
        echo "  Status: ${RED}Expired${NC} (exceeded timeout by $((file_age - SESSION_TIMEOUT))s)"
    else
        echo "  Status: ${GREEN}Valid${NC}"
        echo "  Expires in: ${remaining}s ($(($remaining / 60)) minutes)"

        if [ "$has_session" = true ]; then
            local cached_key=""
            cached_key=$(_read_session_from_backend) || true
            if [ -n "$cached_key" ] && bw list items --session "$cached_key" >/dev/null 2>&1; then
                echo "  Verification: ${GREEN}Session key is valid${NC}"
            else
                echo "  Verification: ${RED}Session key is invalid${NC}"
            fi
        fi
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

# Create VPN configuration file
create_vpn_config() {
    log_debug "Creating temporary VPN config file..."

    TEMP_CONFIG=$(mktemp)
    chmod 600 "$TEMP_CONFIG"
    log_debug "Temporary config file: $TEMP_CONFIG"

    # Write the VPN config (unified split-tunnel: no routes, no DNS override)
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

# Add VPN routes (macOS workaround for openfortivpn routing bug)
add_vpn_routes() {
    log_info "Configuring VPN routes (macOS workaround)..."

    # Define the subnets that need to be routed through VPN
    # These are the internal networks you need to access
    local subnets=(
        "10.1.0.0/16"
        "10.2.0.0/16"
        "10.3.0.0/16"
        "10.4.0.0/16"
        "10.5.0.0/16"
        "10.6.0.0/16"
        "10.7.0.0/16"
        "10.8.0.0/16"
        "10.9.0.0/16"
        "10.10.0.0/16"
        "10.12.0.0/16"
        "10.13.0.0/16"
        "10.14.0.0/16"
        "10.16.0.0/16"
        "10.17.0.0/16"
        "10.18.0.0/16"
        "10.19.0.0/16"
        "10.25.0.0/16"
        "10.40.70.0/24"
        "10.213.0.0/16"
        "10.250.0.0/16"
        "10.252.0.0/24"
    )

    local routes_added=0
    local routes_failed=0

    for subnet in "${subnets[@]}"; do
        if sudo route add -net "$subnet" -interface ppp0 >/dev/null 2>&1; then
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
    local actual_count=$(netstat -rn | grep "ppp0" | grep "^10\." | wc -l | xargs)

    log_success "Requested $routes_added routes, failed $routes_failed"
    log_info "Routing table shows $actual_count routes via ppp0"

    # Verify actual routes match what we tried to add
    if [ "$actual_count" -lt "$((routes_added / 2))" ]; then
        log_error "Route mismatch! Added $routes_added but only $actual_count exist"
        log_error "Something is removing routes (NetBird? Another VPN?)"
        log_info "Showing current ppp0 routes:"
        netstat -rn | grep "ppp0" | grep "^10\." | head -10 | sed 's/^/  /' >&2
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
        if ifconfig ppp0 >/dev/null 2>&1; then
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
                    ((issues++))
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
                    ((issues++))
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
                        ((issues++))
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
                    ((issues++))
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
                    ((total_count++))
                    if [[ "$ns" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
                        log_debug "resolv.conf has private DNS: $ns"
                        ((private_count++))
                    fi
                done
                # If ALL nameservers are private, that's likely a full VPN DNS override
                if [ $total_count -gt 0 ] && [ $private_count -eq $total_count ]; then
                    log_warn "All nameservers in /etc/resolv.conf are private IPs"
                    log_warn "  DNS is fully overridden — likely VPN DNS leak"
                    ((issues++))
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
                ((issues++))
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

    # Build openfortivpn command as array (avoids eval and shell injection)
    local vpn_args=("sudo" "openfortivpn" "--pppd-accept-remote" "-c" "$config_file")

    # Add verbose flag if requested
    if [ "$VERBOSE" = true ]; then
        vpn_args+=("-v")
    fi

    if [ "$DEBUG" = true ]; then
        vpn_args+=("-vv")
    fi

    log_debug "Command: sudo openfortivpn --pppd-accept-remote -c <config_file> [flags]"

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

    # Add routes automatically
    log_step "Configuring VPN routes"
    if ! add_vpn_routes; then
        log_warn "Route configuration had issues, but continuing..."
    fi

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
    echo ""
    echo -e "${YELLOW}Press Ctrl+C to disconnect${NC}" >&2
    echo ""

    # Wait for VPN process (user will Ctrl+C to exit)
    wait $vpn_pid
    local exit_code=$?

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

    # Detect platform — sets OS_TYPE (will be replaced by detect_platform() from resilience agent)
    OS_TYPE=$(uname -s)

    # Detect keystore backend (must run after OS_TYPE is set, before parse_args)
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

# Run main function
main "$@"
