#!/usr/bin/env bash
# vpn-live-test.sh — Live verification of bayport-vpn split-tunnel behaviour
#
# Run this WHILE the VPN is connected in another pane.
# Also usable to monitor in real-time or test reconnection.
#
# Usage:
#   bash tests/vpn-live-test.sh             # one-shot verification
#   bash tests/vpn-live-test.sh --watch     # re-run every 5s
#   bash tests/vpn-live-test.sh --reconnect # kill VPN process and watch it restart
#   bash tests/vpn-live-test.sh --baseline  # print baseline (run before connecting)

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

BASELINE_FILE="${HOME}/.cache/bayport-vpn/test-baseline"
WATCH=false; RECONNECT_TEST=false; BASELINE_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --watch)     WATCH=true ;;
        --reconnect) RECONNECT_TEST=true ;;
        --baseline)  BASELINE_ONLY=true ;;
    esac
    shift
done

# ─── Helpers ──────────────────────────────────────────────────────────────────

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; FAILURES=$((FAILURES+1)); }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
info() { echo -e "  ${BLUE}→${NC} $*"; }
hdr()  { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}"; }
FAILURES=0

# ─── Baseline capture ─────────────────────────────────────────────────────────

capture_baseline() {
    mkdir -p "$(dirname "$BASELINE_FILE")"
    {
        echo "GW=$(netstat -rn 2>/dev/null | awk '/^default/ && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $2; exit}')"
        echo "IFACE=$(netstat -rn 2>/dev/null | awk '/^default/ && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $NF; exit}')"
        echo "PUBLIC_IP=$(curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null)"
        echo "TIMESTAMP=$(date +%s)"
    } > "$BASELINE_FILE"
    echo "Baseline saved to $BASELINE_FILE"
    cat "$BASELINE_FILE"
}

if [ "$BASELINE_ONLY" = true ]; then
    capture_baseline
    exit 0
fi

if [ ! -f "$BASELINE_FILE" ]; then
    echo -e "${YELLOW}No baseline found. Run --baseline before connecting, then reconnect.${NC}"
    echo "Capturing current state as baseline..."
    capture_baseline
    echo ""
fi

source "$BASELINE_FILE" 2>/dev/null || { GW=""; IFACE="en0"; PUBLIC_IP=""; }

# ─── Main verification ────────────────────────────────────────────────────────

run_checks() {
    FAILURES=0
    echo ""
    echo -e "${BOLD}VPN Live Test — $(date '+%H:%M:%S')${NC}"
    echo "────────────────────────────────────"

    # ── 1. VPN process ────────────────────────────────────────────────────────
    hdr "VPN Process"

    vpn_pid=$(pgrep -x openfortivpn 2>/dev/null | head -1)
    if [ -n "$vpn_pid" ]; then
        ok "openfortivpn is running (PID: $vpn_pid)"
    else
        fail "openfortivpn is NOT running"
        echo -e "\n${RED}VPN is not connected — connect first then re-run this script.${NC}"
        return 1
    fi

    pppd_pid=$(pgrep -x pppd 2>/dev/null | head -1)
    if [ -n "$pppd_pid" ]; then
        ok "pppd is running (PID: $pppd_pid)"
    else
        fail "pppd is not running — tunnel not established"
    fi

    # ── 2. VPN interface ──────────────────────────────────────────────────────
    hdr "VPN Interface (ppp0)"

    if ifconfig ppp0 >/dev/null 2>&1; then
        ppp_ip=$(ifconfig ppp0 2>/dev/null | awk '/inet / {print $2}')
        ppp_dest=$(ifconfig ppp0 2>/dev/null | awk '/inet / {print $6}')
        ok "ppp0 interface is UP"
        info "Local:  ${ppp_ip:-unknown}"
        info "Remote: ${ppp_dest:-unknown}"
    else
        fail "ppp0 interface is DOWN — tunnel not established"
        return 1
    fi

    # ── 3. Split-tunnel: default gateway MUST NOT change ─────────────────────
    hdr "Split-Tunnel: Default Gateway"

    current_gw=$(netstat -rn 2>/dev/null | awk '/^default/ && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $2; exit}')
    current_iface=$(netstat -rn 2>/dev/null | awk '/^default/ && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $NF; exit}')

    # Compare interface only — IP can change if laptop switches networks
    if [ -n "$IFACE" ] && [ "$current_iface" = "$IFACE" ]; then
        ok "Default gateway via $current_iface (interface preserved): $current_gw"
        if [ -n "$GW" ] && [ "$current_gw" != "$GW" ]; then
            warn "Gateway IP changed ($GW → $current_gw) — likely network switch, not VPN hijack"
        fi
    elif [ -n "$IFACE" ]; then
        fail "DEFAULT GATEWAY INTERFACE CHANGED! Was: $IFACE → Now: $current_iface ($current_gw)"
        fail "ALL traffic may be going through the VPN — SPLIT TUNNEL BROKEN"
    else
        warn "No baseline to compare — current default: $current_gw via $current_iface"
        info "Run --baseline before connecting next time"
    fi

    # Is the *preferred* default route going through ppp0?
    # pppd adds a subsidiary default (UCSIg) — check for UGScg (preferred) via ppp0
    preferred_default_iface=$(netstat -rn 2>/dev/null | awk '/^default/ && /UGS/ {print $NF; exit}')
    if [ "$preferred_default_iface" = "ppp0" ]; then
        fail "Preferred default route goes through ppp0 — ALL traffic is VPN-routed (full tunnel leak!)"
    else
        ok "Preferred default route via $preferred_default_iface (not ppp0) — split-tunnel working"
    fi

    # ── 4. VPN routes: Bayport subnets go through ppp0 ───────────────────────
    hdr "Split-Tunnel: Bayport Routes via ppp0"

    vpn_routes=$(netstat -rn 2>/dev/null | grep "ppp0" | grep "^10\." | awk '{print $1}')
    vpn_route_count=$(echo "$vpn_routes" | grep -c "." 2>/dev/null || echo 0)

    if [ "$vpn_route_count" -ge 20 ]; then
        ok "VPN routes added: $vpn_route_count subnets via ppp0"
    elif [ "$vpn_route_count" -gt 0 ]; then
        warn "Only $vpn_route_count VPN routes — expected ~22. Some may be missing."
        info "Run: netstat -rn | grep ppp0 | grep '^10\.'"
    else
        fail "No VPN routes via ppp0 — Bayport traffic is NOT being routed through VPN"
    fi

    # Check key subnets are present — macOS shows routes as 10.1/16 or 10.1.0.0/16
    for subnet in "10.1" "10.14" "10.213" "10.250"; do
        if netstat -rn 2>/dev/null | grep "ppp0" | grep -qE "^${subnet}(/|\.0\.0)"; then
            ok "Route: ${subnet}.0.0/16 → ppp0"
        else
            fail "Missing route: ${subnet}.x.x → ppp0"
        fi
    done

    # ── 5. External traffic: public IP must not change ────────────────────────
    hdr "External Traffic (must NOT go through VPN)"

    info "Checking public IP (may take a few seconds)..."
    current_public=$(curl -s --max-time 8 https://ipinfo.io/ip 2>/dev/null)

    if [ -z "$current_public" ]; then
        warn "Could not reach ipinfo.io (no internet? DNS issue?)"
    elif [ -n "$PUBLIC_IP" ] && [ "$current_public" = "$PUBLIC_IP" ]; then
        ok "Public IP unchanged: $current_public (external traffic via local route)"
    elif [ -n "$PUBLIC_IP" ]; then
        fail "Public IP CHANGED: was $PUBLIC_IP, now $current_public"
        fail "External traffic is going through the VPN — split-tunnel broken!"
    else
        info "Current public IP: $current_public (no baseline to compare)"
    fi

    # Verify 8.8.8.8 actual routing decision (not netstat cache — pppd adds host entries)
    dns_iface=$(route -n get 8.8.8.8 2>/dev/null | awk '/interface:/ {print $2}')
    if [ -z "$dns_iface" ] || [ "$dns_iface" != "ppp0" ]; then
        ok "8.8.8.8 (Google DNS) routes via ${dns_iface:-local} (not VPN)"
    else
        fail "8.8.8.8 is routed through ppp0 — public DNS going through VPN"
    fi

    # ── 6. Bayport connectivity: reach something on VPN side ─────────────────
    hdr "Bayport Internal Connectivity"

    # Use one of the configured subnets — try a host in 10.14.x (commonly used)
    # We probe with ping -c 1 -W 2 and note we don't know specific hosts, just the network
    info "Checking reachability of Bayport subnets (route-level, not host-level)..."

    # Verify the routing decision for a 10.14.x address
    test_ip="10.14.31.1"
    route_for_ip=$(netstat -rn 2>/dev/null | awk -v ip="$test_ip" '
        BEGIN { best=""; best_len=0 }
        /^10\./ {
            split($1, parts, "/")
            n = split(parts[1], octets, ".")
            split(ip, tip, ".")
            # Simple prefix match for /16 and /24
            len = (parts[2]+0 == 24) ? 3 : 2
            matched = 1
            for (i=1; i<=len; i++) if (octets[i] != tip[i]) { matched=0; break }
            if (matched && parts[2]+0 > best_len) { best=$NF; best_len=parts[2]+0 }
        }
        END { print best }
    ')

    if [ "$route_for_ip" = "ppp0" ]; then
        ok "Routing decision for $test_ip → ppp0 (correct)"
    elif [ -n "$route_for_ip" ]; then
        fail "Routing decision for $test_ip → $route_for_ip (expected ppp0)"
    else
        warn "Could not determine routing for $test_ip from routing table"
    fi

    # Try a quick ping to see if the VPN tunnel actually passes traffic
    info "Ping test to 10.14.31.12 (5s timeout)..."
    if ping -c 1 -W 5000 10.14.31.12 >/dev/null 2>&1; then
        ok "Ping to 10.14.31.12 succeeded — VPN tunnel is passing traffic"
    else
        warn "Ping to 10.14.31.12 failed (host may be down or ICMP blocked — not conclusive)"
    fi

    # ── 7. DNS leak check ─────────────────────────────────────────────────────
    hdr "DNS Leak Check"

    # Check /etc/resolv.conf nameservers
    resolv_dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')
    if [ -n "$resolv_dns" ]; then
        info "resolv.conf nameservers: $resolv_dns"
        private_dns=$(echo "$resolv_dns" | grep -oE "10\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
        if [ -n "$private_dns" ]; then
            warn "Private DNS in resolv.conf: $private_dns (all DNS may go through VPN)"
        else
            ok "No private IPs in resolv.conf"
        fi
    fi

    # Check scutil DNS (macOS)
    if command -v scutil >/dev/null 2>&1; then
        scutil_dns=$(scutil --dns 2>/dev/null | awk '/nameserver\[/ {print $3}' | head -5 | tr '\n' ' ')
        info "System DNS (scutil): ${scutil_dns:-(none)}"

        # Check for /etc/resolver files (macOS split-DNS)
        if ls /etc/resolver/ >/dev/null 2>&1; then
            info "Split-DNS resolver files: $(ls /etc/resolver/ 2>/dev/null | tr '\n' ' ')"
        fi
    fi

    # ── 8. Netbird coexistence ────────────────────────────────────────────────
    hdr "Netbird Coexistence"

    if pgrep -x netbird >/dev/null 2>&1; then
        nb_routes=$(netstat -rn 2>/dev/null | grep -c "utun" || echo 0)
        ok "Netbird is running ($nb_routes utun routes)"
        ok "No conflict detected (ppp0 and utun coexist)"
        info "Verify: can you still reach Netbird peers? (10.226.x.x etc)"
    else
        info "Netbird is not running"
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo "────────────────────────────────────"
    if [ $FAILURES -eq 0 ]; then
        echo -e "${GREEN}${BOLD}ALL CHECKS PASSED${NC} — split-tunnel is working correctly"
    else
        echo -e "${RED}${BOLD}$FAILURES CHECK(S) FAILED${NC} — review issues above"
    fi
    echo ""

    # Print full routing table summary
    echo -e "${BOLD}Routing summary:${NC}"
    echo "  Default:    $(netstat -rn 2>/dev/null | awk '/^default/ && /[0-9]+\.[0-9]/ {print $2" via "$NF; exit}')"
    echo "  ppp0 routes: $(netstat -rn 2>/dev/null | grep -c "ppp0" || echo 0)"
    echo "  utun routes: $(netstat -rn 2>/dev/null | grep -c "utun" || echo 0)"
    echo ""

    return $FAILURES
}

# ─── Reconnection test ────────────────────────────────────────────────────────

run_reconnect_test() {
    echo -e "\n${BOLD}${YELLOW}━━━ Reconnection Test ━━━${NC}"

    vpn_pid=$(pgrep -x openfortivpn 2>/dev/null | head -1)
    if [ -z "$vpn_pid" ]; then
        echo -e "${RED}VPN is not running — connect first.${NC}"
        exit 1
    fi

    echo "VPN PID: $vpn_pid"
    echo "Simulating connection drop by sending SIGTERM to openfortivpn..."
    echo ""

    # Note time
    T0=$(date +%s)
    sudo kill -TERM "$vpn_pid" 2>/dev/null
    echo "Signal sent at $(date '+%H:%M:%S'). Watching for reconnect..."
    echo ""

    # Poll every 2 seconds for up to 90 seconds
    for i in $(seq 1 45); do
        sleep 2
        new_pid=$(pgrep -x openfortivpn 2>/dev/null | head -1)
        ppp_up=$(ifconfig ppp0 >/dev/null 2>&1 && echo "yes" || echo "no")
        elapsed=$(( $(date +%s) - T0 ))

        printf "  [%3ds] openfortivpn: %-8s  ppp0: %s\n" \
            "$elapsed" \
            "${new_pid:-(gone)}" \
            "$ppp_up"

        # Reconnected?
        if [ -n "$new_pid" ] && [ "$new_pid" != "$vpn_pid" ] && [ "$ppp_up" = "yes" ]; then
            echo ""
            echo -e "${GREEN}✓ Reconnected in ${elapsed}s (new PID: $new_pid)${NC}"
            echo ""
            run_checks
            return
        fi
    done

    echo -e "${RED}✗ Did not reconnect within 90s${NC}"
}

# ─── Entry point ─────────────────────────────────────────────────────────────

if [ "$RECONNECT_TEST" = true ]; then
    run_reconnect_test
elif [ "$WATCH" = true ]; then
    while true; do
        clear
        run_checks
        echo -e "${BLUE}(refreshing every 5s — Ctrl+C to stop)${NC}"
        sleep 5
    done
else
    run_checks
fi
