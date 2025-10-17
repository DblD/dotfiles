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
        log_debug "Removing temporary config file: $TEMP_CONFIG"
        rm -f "$TEMP_CONFIG"
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
    vpn_item=$(get_vpn_config "$item_name" "$session_key")
    if [ $? -ne 0 ] || [ -z "$vpn_item" ]; then
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
    vpn_item=$(get_vpn_config "$item_name" "$session_key")
    if [ $? -ne 0 ] || [ -z "$vpn_item" ]; then
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

    log_info "Checking dependencies..."

    for cmd in bw jq openfortivpn mktemp; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
            log_error "Missing required command: $cmd"
        else
            local version=$(if [ "$cmd" = "bw" ]; then $cmd --version; elif [ "$cmd" = "jq" ]; then $cmd --version; elif [ "$cmd" = "openfortivpn" ]; then $cmd --version 2>&1 | head -n1; else echo "installed"; fi)
            log_success "$cmd is installed ($version)"
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install missing dependencies and try again"
        return 1
    fi

    # Check sudo access
    if sudo -n true 2>/dev/null; then
        log_success "Sudo access confirmed"
    else
        log_warn "Sudo access may require password (needed for VPN connection)"
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

save_session_key() {
    local session_key=$1
    ensure_session_cache_dir

    log_debug "Saving session key to cache"
    echo "$session_key" > "$SESSION_CACHE_FILE"
    chmod 600 "$SESSION_CACHE_FILE"

    log_success "Session key cached (valid for ${SESSION_TIMEOUT}s)"
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
        SESSION_KEY=$BW_SESSION
        echo "$SESSION_KEY"
        return 0
    fi

    # Try to load cached session
    local cached_session=$(load_cached_session)
    if [ -n "$cached_session" ]; then
        SESSION_KEY=$cached_session
        echo "$SESSION_KEY"
        return 0
    fi

    # No cached session, need to unlock
    log_info "Unlocking Bitwarden vault..."

    # Check vault status
    local vault_status=$(bw status | jq -r '.status')
    log_debug "Vault status: $vault_status"

    if [ "$vault_status" = "locked" ]; then
        log_info "Please enter your Bitwarden master password to unlock the vault"
        SESSION_KEY=$(bw unlock --raw 2>&1)
        local unlock_status=$?

        if [ $unlock_status -ne 0 ] || [ -z "$SESSION_KEY" ] || [[ "$SESSION_KEY" == *"Error"* ]]; then
            log_error "Failed to unlock Bitwarden vault"
            log_debug "Unlock output: $SESSION_KEY"
            log_info "Tip: You can also manually unlock and export the session:"
            log_info "  export BW_SESSION=\$(bw unlock --raw)"
            log_info "  Then run this script again"
            return 1
        fi
        log_success "Bitwarden vault unlocked"
    elif [ "$vault_status" = "unlocked" ]; then
        log_warn "Vault already unlocked, but no session key found"
        SESSION_KEY=$(bw unlock --raw)
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

    log_info "Retrieving VPN configuration from Bitwarden..."
    log_debug "Item name: $item_name"

    local vpn_item=$(bw get item "$item_name" --session "$session_key" 2>&1)
    local bw_exit_code=$?

    if [ $bw_exit_code -ne 0 ]; then
        log_error "Failed to retrieve VPN item from Bitwarden"
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
        log_debug "Raw output: $vpn_item"
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
        echo "  VPN Password: ${VPN_PASSWORD:0:3}***"
        echo "  VPN Trusted Cert: ${VPN_TRUSTED_CERT:0:20}..."
    fi

    return 0
}

# Create VPN configuration file
create_vpn_config() {
    log_debug "Creating temporary VPN config file..."

    TEMP_CONFIG=$(mktemp)
    log_debug "Temporary config file: $TEMP_CONFIG"

    # Detect OS
    local os_type=$(uname -s)
    log_debug "Operating system: $os_type"

    # Write the VPN config to the temporary file
    if [ "$os_type" = "Darwin" ]; then
        log_debug "Using macOS-specific configuration"
        cat > "$TEMP_CONFIG" << EOF
persistent=10
host = $VPN_HOST
port = 10443
username = $VPN_USERNAME
password = $VPN_PASSWORD
trusted-cert = $VPN_TRUSTED_CERT
set-routes = 1
set-dns = 0
pppd-use-peerdns = 1
EOF
    else
        log_debug "Using Linux/Unix configuration"
        cat > "$TEMP_CONFIG" << EOF
persistent=10
host = $VPN_HOST
port = 10443
username = $VPN_USERNAME
password = $VPN_PASSWORD
trusted-cert = $VPN_TRUSTED_CERT
EOF
    fi

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

    log_info "Waiting for VPN interface..."

    while [ $count -lt $timeout ]; do
        if ifconfig ppp0 >/dev/null 2>&1; then
            log_success "VPN interface ppp0 is up"
            return 0
        fi
        sleep 1
        ((count++))

        # Show progress every 5 seconds
        if [ $((count % 5)) -eq 0 ]; then
            log_debug "Still waiting for ppp0... ($count/${timeout}s)"
        fi
    done

    log_error "Timeout waiting for VPN interface (${timeout}s)"
    return 1
}

# Connect to VPN
connect_vpn() {
    local config_file=$1

    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY RUN MODE - Not actually connecting to VPN"
        log_info "Would execute: sudo openfortivpn --pppd-accept-remote -c $config_file"
        return 0
    fi

    log_info "Connecting to VPN at $VPN_HOST:10443..."
    log_warn "This will require sudo password"
    echo ""

    # Build openfortivpn command with appropriate verbosity
    local vpn_cmd="sudo openfortivpn --pppd-accept-remote -c \"$config_file\""

    # Add verbose flag if requested
    if [ "$VERBOSE" = true ]; then
        vpn_cmd="$vpn_cmd -v"
    fi

    if [ "$DEBUG" = true ]; then
        vpn_cmd="$vpn_cmd -vv"
    fi

    log_debug "Command: sudo openfortivpn --pppd-accept-remote -c <config_file> [flags]"

    log_info "Establishing VPN connection..."
    echo ""

    # Start VPN in background
    eval "$vpn_cmd" &
    local vpn_pid=$!

    # Wait for interface to come up
    if ! wait_for_vpn_interface 30; then
        log_error "VPN interface failed to initialize"
        kill $vpn_pid 2>/dev/null
        return 1
    fi

    # Add routes automatically
    if ! add_vpn_routes; then
        log_warn "Route configuration had issues, but continuing..."
    fi

    echo ""
    log_success "VPN connected and configured!"
    log_info "Press Ctrl+C to disconnect"
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
    log_info "Starting VPN connection script..."

    # Parse arguments
    parse_args "$@"

    # Check dependencies
    if ! check_dependencies; then
        return 1
    fi

    # Get item name
    local item_name=$(get_item_name)

    # Get Bitwarden session
    local session_key=$(get_bitwarden_session)
    if [ -z "$session_key" ]; then
        return 1
    fi

    # Get VPN config from Bitwarden
    local vpn_item
    vpn_item=$(get_vpn_config "$item_name" "$session_key")
    if [ $? -ne 0 ] || [ -z "$vpn_item" ]; then
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
    local config_file=$(create_vpn_config)
    if [ -z "$config_file" ]; then
        return 1
    fi

    # Connect to VPN
    connect_vpn "$config_file"
    return $?
}

# Run main function
main "$@"
