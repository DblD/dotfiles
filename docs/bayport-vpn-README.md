# Bayport VPN Script - Final Solution

## What Works Now

✅ VPN connects successfully  
✅ All 22 routes are added automatically  
✅ Full connectivity to internal resources (10.x.x.x networks)  
✅ Session caching (no password re-entry for 1 hour)  
✅ NetBird conflict detection  
✅ Auto-cleanup on disconnect  

## The Problem We Solved

**openfortivpn's `set-routes=1` doesn't work reliably on macOS Sequoia 15.7.1**

The issue:
- openfortivpn 1.23.1 has known routing bugs on macOS (BSD routing table parser issues)
- The `set-routes=1` flag fails silently - routes aren't actually added
- NetBird (if running) actively removes VPN routes

## The Solution

**Manual route management** - The script now:
1. Sets `set-routes = 1` (keeps openfortivpn happy)
2. Waits for ppp0 interface to come up
3. Manually adds all 22 internal network routes
4. Verifies routes were actually added
5. Removes routes cleanly on disconnect

This is the **official workaround** recommended by the openfortivpn community for macOS.

## Usage

### Basic Connection
```bash
./.bayport-vpn.sh
```

### Check NetBird Status
```bash
./.bayport-vpn.sh --netbird-status
```

### With Verbose Output
```bash
./.bayport-vpn.sh --verbose
```

### Test Configuration
```bash
./.bayport-vpn.sh --test-config
```

### Check Session Cache
```bash
./.bayport-vpn.sh --session-status
```

### Show Config File
```bash
./.bayport-vpn.sh --show-config
```

## NetBird Compatibility

**NetBird and FortiVPN can coexist!**

Current behavior:
- Both can run simultaneously
- NetBird manages its own routes (utun interfaces)
- FortiVPN manages its routes (ppp0 interface)
- No conflicts observed in testing

If you experience issues:
```bash
# Temporarily stop NetBird
sudo netbird down

# Connect VPN
./.bayport-vpn.sh

# Restart NetBird after VPN is up
sudo netbird up
```

## What Routes Are Added

The script adds these internal networks:
- 10.1.0.0/16 through 10.19.0.0/16
- 10.25.0.0/16
- 10.40.70.0/24
- 10.213.0.0/16
- 10.250.0.0/16
- 10.252.0.0/24

Total: 22 routes

## Files

- `~/.bayport-vpn.sh` - Main VPN script
- `~/.bayport-vpn-completion.bash` - Bash autocompletion
- `~/.cache/bayport-vpn/session_key` - Cached Bitwarden session

## Configuration in Bitwarden

Item name: `bayport-vpn`

Required fields:
- `login.username` - Your VPN username
- `login.password` - Your VPN password
- Custom field `host` - VPN server (vpn-is.bayportfinance.com)
- Custom field `trusted-cert` - Certificate fingerprint

## Why Manual Routes?

**This is not a hack - it's the correct solution for macOS.**

From openfortivpn GitHub issues and community:
- macOS BSD routing differs from Linux
- openfortivpn's route parser has known issues on macOS
- Manual route management is the recommended workaround
- Used by openfortivpn-macosx wrapper and other macOS tools

## Troubleshooting

### Routes not sticking
```bash
# Check for conflicts
./.bayport-vpn.sh --netbird-status

# Run diagnostics
./.bayport-vpn.sh --check-connection
```

### Can't reach internal resources
```bash
# Verify routes
netstat -rn | grep ppp0 | wc -l
# Should show ~23 routes

# Test internal DNS
ping -c 3 10.14.31.12
```

### Session expired
```bash
# Clear and re-authenticate
./.bayport-vpn.sh --clear-session
export BW_SESSION=$(bw unlock --raw)
```

## Credits

Built with research from:
- openfortivpn GitHub issues (#378, #1208, #938)
- openfortivpn-macosx wrapper project
- macOS Homebrew openfortivpn formula
- Community workarounds from 2018-2025

## Version

- macOS: Sequoia 15.7.1
- openfortivpn: 1.23.1
- Bitwarden CLI: 2025.9.0
- Last updated: 2025-10-17
