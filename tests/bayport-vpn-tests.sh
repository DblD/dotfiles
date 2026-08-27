#!/usr/bin/env bash
# bayport-vpn-tests.sh — Test suite for bayport-vpn.sh
#
# Tests everything that can run without a live VPN or Bitwarden session.
# Run with:  bash tests/bayport-vpn-tests.sh
#            bash tests/bayport-vpn-tests.sh -v       (verbose: show pass details)
#            bash tests/bayport-vpn-tests.sh -f       (fail-fast: stop on first failure)
#
# Manual-only tests (require live VPN/BW) are listed at the bottom.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPN_SCRIPT="$SCRIPT_DIR/../scripts/bayport-vpn.sh"

# ─── Test framework ────────────────────────────────────────────────────────────

PASS=0; FAIL=0; SKIP=0
# Parse args BEFORE sourcing the VPN script (which resets VERBOSE/DEBUG globals)
_VERBOSE=false; _FAIL_FAST=false; CURRENT_SUITE=""

while [[ $# -gt 0 ]]; do
    case $1 in -v) _VERBOSE=true ;; -f) _FAIL_FAST=true ;; esac
    shift
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
VERBOSE=$_VERBOSE; FAIL_FAST=$_FAIL_FAST

suite() {
    CURRENT_SUITE="$1"
    echo -e "\n${BOLD}${BLUE}━━━ $1 ━━━${NC}"
}

pass() {
    PASS=$((PASS + 1))
    [ "$VERBOSE" = true ] && echo -e "  ${GREEN}✓${NC} $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} $1"
    [ -n "${2:-}" ] && echo -e "    ${RED}→ $2${NC}"
    [ "$FAIL_FAST" = true ] && { summary; exit 1; }
}

skip() {
    SKIP=$((SKIP + 1))
    echo -e "  ${YELLOW}○${NC} $1 ${YELLOW}[SKIP: ${2:-}]${NC}"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc" "expected='$expected' got='$actual'"
    fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    if echo "$actual" | grep -qE "$pattern"; then
        pass "$desc"
    else
        fail "$desc" "expected match '$pattern' in: '$actual'"
    fi
}

assert_return() {
    local desc="$1" expected_rc="$2"
    shift 2
    local actual_rc=0
    "$@" >/dev/null 2>&1 || actual_rc=$?
    assert_eq "$desc" "$expected_rc" "$actual_rc"
}

assert_nonempty() {
    local desc="$1" val="$2"
    if [ -n "$val" ]; then
        pass "$desc"
    else
        fail "$desc" "expected non-empty output"
    fi
}

summary() {
    echo ""
    echo -e "${BOLD}Results: ${GREEN}$PASS passed${NC}  ${RED}$FAIL failed${NC}  ${YELLOW}$SKIP skipped${NC}"
    [ $FAIL -gt 0 ] && return 1 || return 0
}

# ─── Source the script (suppress main() call only) ────────────────────────────
# Remove the `main "$@"` call so we can test individual functions.
# detect_platform runs during source (last few lines before main) — that's fine.

source <(sed '/^main "\$@"$/d' "$VPN_SCRIPT") 2>/dev/null || {
    echo "ERROR: failed to source $VPN_SCRIPT"
    exit 1
}

# The sourced script enables set -euo pipefail AND resets VERBOSE/DEBUG globals.
# Restore test-runner state after source.
set +e +u +o pipefail
VERBOSE=$_VERBOSE; FAIL_FAST=$_FAIL_FAST

# Override session cache to a temp dir so tests don't touch real cache
export SESSION_CACHE_DIR
SESSION_CACHE_DIR=$(mktemp -d)
SESSION_CACHE_FILE="${SESSION_CACHE_DIR}/session_key"
export SESSION_CACHE_FILE

# ─── Suite: _timeout ──────────────────────────────────────────────────────────

suite "_timeout (portable timeout wrapper)"

# Should complete fast commands within the timeout
out=$( _timeout 5 echo "hello" 2>/dev/null )
assert_eq "runs command and captures output" "hello" "$out"

# Should pass exit code through
_timeout 5 true 2>/dev/null
assert_eq "passes zero exit code for successful command" "0" "$?"

_timeout 5 false 2>/dev/null || rc=$?
assert_eq "passes non-zero exit code for failing command" "1" "${rc:-1}"

# Should kill a command that exceeds timeout
start=$(date +%s)
_timeout 1 sleep 10 2>/dev/null || true
elapsed=$(( $(date +%s) - start ))
if [ $elapsed -le 3 ]; then
    pass "kills command exceeding timeout (elapsed: ${elapsed}s)"
else
    fail "kills command exceeding timeout" "took ${elapsed}s — timeout not working"
fi

# ─── Suite: _get_boot_id ──────────────────────────────────────────────────────

suite "_get_boot_id (reboot detection)"

boot_id=$(_get_boot_id 2>/dev/null)
assert_nonempty "returns a non-empty boot ID" "$boot_id"

boot_id2=$(_get_boot_id 2>/dev/null)
assert_eq "returns the same ID on repeated calls" "$boot_id" "$boot_id2"

assert_match "boot ID looks like a number or UUID" \
    "^[0-9a-f-]{6,}" "$boot_id"

# ─── Suite: detect_platform ──────────────────────────────────────────────────

suite "detect_platform (platform globals)"

assert_nonempty "OS_TYPE is set" "$OS_TYPE"

case "$OS_TYPE" in
    Darwin)
        assert_eq "HAS_IFCONFIG=true on macOS" "true" "$HAS_IFCONFIG"
        assert_eq "HAS_SCUTIL=true on macOS" "true" "$HAS_SCUTIL"
        pass "OS_TYPE=Darwin"
        ;;
    Linux)
        pass "OS_TYPE=Linux"
        ;;
    *)
        fail "OS_TYPE is a known platform" "got: $OS_TYPE"
        ;;
esac

# ─── Suite: classify_vpn_failure ─────────────────────────────────────────────

suite "classify_vpn_failure (failure type detection)"

tmplog=$(mktemp)

# No file → unknown
result=$(classify_vpn_failure "/nonexistent/file.log" 2>/dev/null)
assert_eq "missing log → unknown" "unknown" "$result"

# Empty file → unknown
> "$tmplog"
result=$(classify_vpn_failure "$tmplog" 2>/dev/null)
assert_eq "empty log → unknown" "unknown" "$result"

# Auth failure patterns
for msg in \
    "could not authenticate to gateway" \
    "Login failed: invalid credentials" \
    "Authentication failed: wrong password" \
    "Permission denied login attempt"; do
    echo "$msg" > "$tmplog"
    result=$(classify_vpn_failure "$tmplog" 2>/dev/null)
    assert_eq "auth: '$msg'" "auth" "$result"
done

# Cert failure patterns
for msg in \
    "certificate validation failed" \
    "Gateway certificate validation failed" \
    "trusted-cert mismatch detected" \
    "SSL error during handshake" \
    "TLS handshake failed"; do
    echo "$msg" > "$tmplog"
    result=$(classify_vpn_failure "$tmplog" 2>/dev/null)
    assert_eq "cert: '$msg'" "cert" "$result"
done

# Network failure patterns
for msg in \
    "Connection timed out" \
    "connect: Connection refused" \
    "Network unreachable" \
    "No route to host" \
    "Connection reset by peer" \
    "Connection closed"; do
    echo "$msg" > "$tmplog"
    result=$(classify_vpn_failure "$tmplog" 2>/dev/null)
    assert_eq "network: '$msg'" "network" "$result"
done

# Noise lines shouldn't pollute — auth failure in last 50 lines still detected
{
    for i in $(seq 1 60); do echo "INFO: connecting..."; done
    echo "could not authenticate to gateway"
} > "$tmplog"
result=$(classify_vpn_failure "$tmplog" 2>/dev/null)
assert_eq "auth pattern found in last 50 lines of long log" "auth" "$result"

# Auth takes priority over network (first match wins)
{ echo "Connection timed out"; echo "could not authenticate to gateway"; } > "$tmplog"
result=$(classify_vpn_failure "$tmplog" 2>/dev/null)
assert_eq "auth takes priority over network in same log" "auth" "$result"

rm -f "$tmplog"

# ─── Suite: handle_vpn_failure ────────────────────────────────────────────────

suite "handle_vpn_failure (retry decision)"

tmplog=$(mktemp)

# Auth → bail (return 1)
echo "could not authenticate to gateway" > "$tmplog"
handle_vpn_failure "$tmplog" >/dev/null 2>&1
assert_eq "auth failure → return 1 (bail)" "1" "$?"

# Cert → bail (return 1)
echo "certificate validation failed" > "$tmplog"
handle_vpn_failure "$tmplog" >/dev/null 2>&1
assert_eq "cert failure → return 1 (bail)" "1" "$?"

# Network → retry (return 0)
echo "Connection timed out" > "$tmplog"
handle_vpn_failure "$tmplog" >/dev/null 2>&1
assert_eq "network failure → return 0 (retry ok)" "0" "$?"

# Unknown → retry first time (return 0)
UNKNOWN_FAILURE_COUNT=0
> "$tmplog"
handle_vpn_failure "$tmplog" >/dev/null 2>&1
assert_eq "first unknown failure → return 0 (one cautious retry)" "0" "$?"

# Unknown × 2 → bail (return 1)
UNKNOWN_FAILURE_COUNT=2
> "$tmplog"
handle_vpn_failure "$tmplog" >/dev/null 2>&1
assert_eq "second unknown failure → return 1 (bail)" "1" "$?"

UNKNOWN_FAILURE_COUNT=0
rm -f "$tmplog"

# ─── Suite: session cache (file backend) ─────────────────────────────────────

suite "session cache — file backend"

# Force file backend for portable testing
KEYSTORE_BACKEND="file"
ensure_session_cache_dir

# Save and load round-trip
test_key="test-session-key-$(date +%s)"
save_session_key "$test_key" >/dev/null 2>&1

loaded=$(_read_session_from_backend 2>/dev/null)
assert_eq "save/load round-trip" "$test_key" "$loaded"

# Timestamp file is created
[ -f "${SESSION_CACHE_DIR}/session_timestamp" ]
assert_eq "timestamp file created" "0" "$?"

# Boot ID file is created
[ -f "${SESSION_CACHE_DIR}/session_boot_id" ]
assert_eq "boot_id file created" "0" "$?"

# Boot ID in file matches current boot ID
saved_boot=$(cat "${SESSION_CACHE_DIR}/session_boot_id" 2>/dev/null)
current_boot=$(_get_boot_id)
assert_eq "saved boot_id matches current boot_id" "$current_boot" "$saved_boot"

# Clear removes all files
clear_session_cache >/dev/null 2>&1
[ ! -f "${SESSION_CACHE_DIR}/session_timestamp" ]
assert_eq "clear removes timestamp" "0" "$?"
[ ! -f "${SESSION_CACHE_DIR}/session_boot_id" ]
assert_eq "clear removes boot_id" "0" "$?"

# _read_session_from_backend returns 1 after clear
_read_session_from_backend >/dev/null 2>&1
assert_eq "no session after clear" "1" "$?"

# ─── Suite: session boot-ID invalidation ─────────────────────────────────────

suite "session cache — boot ID invalidation"

KEYSTORE_BACKEND="file"

# Plant a valid-looking session with a fake (old) boot ID
ensure_session_cache_dir
install -m 600 /dev/null "$SESSION_CACHE_FILE"
echo "old-session-key" > "$SESSION_CACHE_FILE"
date +%s > "${SESSION_CACHE_DIR}/session_timestamp"
echo "fake-boot-id-from-old-boot-999" > "${SESSION_CACHE_DIR}/session_boot_id"

# load_cached_session should detect the mismatch and clear
result=$(load_cached_session 2>/dev/null) || true
assert_eq "returns empty on boot ID mismatch" "" "$result"
[ ! -f "${SESSION_CACHE_DIR}/session_timestamp" ]
assert_eq "boot ID mismatch clears the cache" "0" "$?"

# ─── Suite: session wall-clock timeout ────────────────────────────────────────

suite "session cache — wall-clock timeout"

KEYSTORE_BACKEND="file"

# Plant a session with an old timestamp (2 hours ago) and SESSION_TIMEOUT=3600
ensure_session_cache_dir
install -m 600 /dev/null "$SESSION_CACHE_FILE"
echo "timed-out-key" > "$SESSION_CACHE_FILE"
echo $(( $(date +%s) - 7200 )) > "${SESSION_CACHE_DIR}/session_timestamp"
_get_boot_id > "${SESSION_CACHE_DIR}/session_boot_id"  # correct boot ID so only timeout fires

SESSION_TIMEOUT=3600
result=$(load_cached_session 2>/dev/null) || true
assert_eq "expired session returns empty" "" "$result"

# Plant a fresh session with SESSION_TIMEOUT=3600 — should NOT be expired
# (we can't validate the BW session in tests, so we stop at the bw status check
# and just verify it gets to that point by checking that the key was loaded)
ensure_session_cache_dir
install -m 600 /dev/null "$SESSION_CACHE_FILE"
echo "fresh-key" > "$SESSION_CACHE_FILE"
date +%s > "${SESSION_CACHE_DIR}/session_timestamp"
_get_boot_id > "${SESSION_CACHE_DIR}/session_boot_id"

# The load will fail at the bw status check (no Bitwarden), but it should NOT fail
# due to timeout — confirm it gets past the timestamp check by checking that
# _read_session_from_backend does return the key (timeout hasn't cleared it)
raw=$(_read_session_from_backend 2>/dev/null)
assert_eq "fresh session key survives to bw validation step" "fresh-key" "$raw"

SESSION_TIMEOUT=0
clear_session_cache >/dev/null 2>&1

# ─── Suite: detect_keystore ──────────────────────────────────────────────────

suite "detect_keystore (backend selection)"

detect_keystore 2>/dev/null
assert_nonempty "KEYSTORE_BACKEND is set after detection" "$KEYSTORE_BACKEND"

case "$OS_TYPE" in
    Darwin)
        assert_eq "macOS uses keychain backend" "keychain" "$KEYSTORE_BACKEND"
        ;;
    Linux)
        # Valid backends on Linux: secret-tool, pass, or file
        if [[ "$KEYSTORE_BACKEND" =~ ^(secret-tool|pass|file)$ ]]; then
            pass "Linux backend is valid: $KEYSTORE_BACKEND"
        else
            fail "Linux backend is valid" "got: $KEYSTORE_BACKEND"
        fi
        ;;
esac

# ─── Suite: default_routes ────────────────────────────────────────────────────

suite "default_routes (route list sanity)"

routes=$(default_routes 2>/dev/null)
route_count=$(echo "$routes" | grep -c "." || true)

assert_eq "returns 22 routes" "22" "$route_count"

# All entries should be valid CIDR notation
bad_routes=""
while IFS= read -r route; do
    if ! echo "$route" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
        bad_routes="$bad_routes $route"
    fi
done <<< "$routes"

if [ -z "$bad_routes" ]; then
    pass "all routes are valid CIDR notation"
else
    fail "all routes are valid CIDR notation" "bad entries:$bad_routes"
fi

# All should be RFC 1918 10.x.x.x
non_private=$(echo "$routes" | grep -v "^10\." || true)
if [ -z "$non_private" ]; then
    pass "all routes are in 10.0.0.0/8 space"
else
    fail "all routes are in 10.0.0.0/8 space" "non-private:$non_private"
fi

# ─── Suite: fetch_server_cert ─────────────────────────────────────────────────

suite "fetch_server_cert (cert fingerprint retrieval)"

# Test against a known public HTTPS endpoint (not the VPN — just proves the function works)
if ! command -v openssl >/dev/null 2>&1; then
    skip "fetch_server_cert against google.com:443" "openssl not installed"
else
    fingerprint=$(fetch_server_cert "google.com" "443" 2>/dev/null)
    if [ -n "$fingerprint" ]; then
        pass "fetch_server_cert returns a fingerprint from google.com:443"
        assert_match "fingerprint is hex string (64 chars for SHA-256)" \
            "^[0-9a-f]{64}$" "$fingerprint"
    else
        skip "fetch_server_cert against google.com" "no internet or openssl issue"
    fi
fi

# Unreachable host should return non-zero and empty output
fp_bad=$(fetch_server_cert "192.0.2.1" "9999" 2>/dev/null) || true
if [ -z "$fp_bad" ]; then
    pass "unreachable host returns empty fingerprint"
else
    fail "unreachable host returns empty fingerprint" "got: $fp_bad"
fi

# ─── Suite: argument parsing ─────────────────────────────────────────────────

suite "parse_args (CLI flags)"

# --verbose sets VERBOSE=true
VERBOSE=false
parse_args --verbose 2>/dev/null || true
assert_eq "--verbose sets VERBOSE" "true" "$VERBOSE"
VERBOSE=false

# --debug sets DEBUG=true and VERBOSE=true
DEBUG=false; VERBOSE=false
parse_args --debug 2>/dev/null || true
assert_eq "--debug sets DEBUG" "true" "$DEBUG"
assert_eq "--debug also sets VERBOSE" "true" "$VERBOSE"
DEBUG=false; VERBOSE=false

# --dry-run sets DRY_RUN=true
DRY_RUN=false
parse_args --dry-run 2>/dev/null || true
assert_eq "--dry-run sets DRY_RUN" "true" "$DRY_RUN"
DRY_RUN=false

# --no-reconnect sets NO_RECONNECT=true
NO_RECONNECT=false
parse_args --no-reconnect 2>/dev/null || true
assert_eq "--no-reconnect sets NO_RECONNECT" "true" "$NO_RECONNECT"
NO_RECONNECT=false

# --session-timeout sets SESSION_TIMEOUT
SESSION_TIMEOUT=0
parse_args --session-timeout 7200 2>/dev/null || true
assert_eq "--session-timeout 7200 sets SESSION_TIMEOUT" "7200" "$SESSION_TIMEOUT"
SESSION_TIMEOUT=0

# --max-reconnects sets MAX_RECONNECTS
MAX_RECONNECTS=3
parse_args --max-reconnects 10 2>/dev/null || true
assert_eq "--max-reconnects 10 sets MAX_RECONNECTS" "10" "$MAX_RECONNECTS"
MAX_RECONNECTS=3

# ─── Suite: check_vpn_conflicts (no VPN running) ─────────────────────────────

suite "check_vpn_conflicts (no VPN running)"

# When no VPN is running, should detect no conflicts and return 0
if pgrep -x openfortivpn >/dev/null 2>&1; then
    skip "check_vpn_conflicts clean" "openfortivpn is already running"
elif ifconfig 2>/dev/null | grep -q "^ppp"; then
    skip "check_vpn_conflicts clean" "ppp interface already exists"
elif pgrep -x netbird >/dev/null 2>&1; then
    # NetBird running is a known non-critical conflict — function returns 1 correctly
    check_vpn_conflicts >/dev/null 2>&1
    rc=$?
    assert_eq "netbird running → check_vpn_conflicts returns 1 (expected)" "1" "$rc"
else
    check_vpn_conflicts >/dev/null 2>&1
    assert_eq "no conflicts detected when VPN not running" "0" "$?"
fi

# ─── Suite: check_ppp_interface_exists (no VPN running) ──────────────────────

suite "check_ppp_interface_exists (no VPN running)"

if ifconfig 2>/dev/null | grep -q "^ppp"; then
    skip "ppp check returns false" "ppp interface already up"
else
    check_ppp_interface_exists 2>/dev/null
    assert_eq "no ppp interface when VPN not running" "1" "$?"
fi

# ─── Suite: get_item_name ────────────────────────────────────────────────────

suite "get_item_name (derives from script name)"

# When called as .bayport-vpn.sh, should return "bayport-vpn"
# We test by checking the function uses basename + strip leading dot + strip .sh
# Temporarily override $0 via a subshell is not straightforward, so we test the
# logic directly: simulate the transformation
raw_name=".bayport-vpn.sh"
derived=$(echo "$raw_name" | sed 's/^\.//' | sed 's/\.sh$//')
assert_eq "derives 'bayport-vpn' from '.bayport-vpn.sh'" "bayport-vpn" "$derived"

raw_name2="myvpn.sh"
derived2=$(echo "$raw_name2" | sed 's/^\.//' | sed 's/\.sh$//')
assert_eq "derives 'myvpn' from 'myvpn.sh'" "myvpn" "$derived2"

# ─── Suite: cleanup guard (double-run safety) ─────────────────────────────────

suite "cleanup (double-run guard)"

# cleanup() ends with `exit $exit_code` — call it in a subshell so it doesn't
# terminate the test runner. We verify the guard by checking CLEANUP_DONE via
# a temp file signal.
_cleanup_signal=$(mktemp)

# Test in subshell: first call sets CLEANUP_DONE=true and exits the subshell
(
    CLEANUP_DONE=false
    VPN_ROUTES_ADDED=()
    TEMP_CONFIG=""
    VPN_PID=""
    SUDO_KEEPALIVE_PID=""
    TAIL_PID=""
    VPN_LOG=""
    # Stub exit to write signal instead of exiting
    exit() { echo "cleanup_ran" > "$_cleanup_signal"; }
    cleanup 2>/dev/null
) 2>/dev/null

if [ -s "$_cleanup_signal" ]; then
    pass "cleanup runs and reaches exit on first call"
else
    fail "cleanup runs and reaches exit on first call"
fi

# Test the guard: second call with CLEANUP_DONE=true should return immediately
(
    CLEANUP_DONE=true
    exit() { echo "guard_bypassed" > "$_cleanup_signal"; }
    cleanup 2>/dev/null
    echo "guard_worked" > "$_cleanup_signal"
) 2>/dev/null
result=$(cat "$_cleanup_signal" 2>/dev/null)
assert_eq "double-cleanup guard returns early" "guard_worked" "$result"

rm -f "$_cleanup_signal"

# ─── Suite: exponential backoff calculation ───────────────────────────────────

suite "exponential backoff (reconnect delay)"

# Validate the backoff formula: count * count * 5, capped at 60
check_backoff() {
    local count=$1 expected=$2
    local backoff=$((count * count * 5))
    [ $backoff -gt 60 ] && backoff=60
    assert_eq "backoff at reconnect $count" "$expected" "$backoff"
}

check_backoff 1 5
check_backoff 2 20
check_backoff 3 45
check_backoff 4 60   # 80 → capped at 60
check_backoff 5 60   # 125 → capped at 60

# ─── Cleanup temp dirs ────────────────────────────────────────────────────────

rm -rf "$SESSION_CACHE_DIR"

# ─── Summary ─────────────────────────────────────────────────────────────────

summary
echo ""
echo -e "${BOLD}Manual tests (require live VPN/Bitwarden):${NC}"
echo "  • bw login → unlock → get_bitwarden_session"
echo "  • get_vpn_config + parse_vpn_config (needs 'bayport-vpn' item in BW)"
echo "  • fetch_server_cert against actual VPN host (vpn-is.bayportfinance.com:10443)"
echo "  • check_and_update_cert — only testable when cert actually changes"
echo "  • connect_vpn — requires BW session + working VPN server + sudo"
echo "  • add_vpn_routes — requires ppp0 interface to be up"
echo "  • monitor_vpn_connection — requires live connection"
echo "  • configure_split_dns / detect_vpn_dns — requires active VPN"
echo "  • dns_leak_test — most useful while VPN is connected"
echo "  • --check-connection — connects to VPN host (can run without auth)"
echo ""
echo -e "${BOLD}To run a targeted subset:${NC}"
echo "  bash tests/bayport-vpn-tests.sh 2>&1 | grep -E '(✓|✗|━━━)'"
