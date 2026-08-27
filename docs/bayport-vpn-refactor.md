# bayport-vpn refactor list

Motivation: 2026-05-22 incident — connectivity broke when Bayport rotated the gateway port from `10443` to `20443`. Script reported a generic `AUTHENTICATION FAILURE` (correctly classified from openfortivpn output, but misleading as a root cause) and aborted early. Root cause took human triage to identify.

P0 #1 (hardcoded port) was fixed in `01d8c85 fix(bayport-vpn): read port from BW item instead of hardcoding 10443` on branch `tmux/overhaul`. Remaining items below.

Captured incident logs (contain plaintext password from `-vv` openfortivpn output — do not share, delete after use):
- `/tmp/bayport-replay-20260522-101533.log` — failure (port still 10443)
- `/tmp/bayport-replay-20260522-102708.log` — success after fix (port 20443)

Canonical script: `scripts/bayport-vpn.sh` (~2900 lines, 100K).

Branch state (correction to an earlier reading):
- The two AI-rewrite branches `vpn-harden/security-review` (`3e51040`) and `vpn-harden/resilience-hardening` (`37f316c`) **were merged**, via `3e40e71 merge: combine security hardening and resilience improvements for bayport-vpn`, into the bayport history that currently lives on `tmux/overhaul`. Their worktrees and named branches can be deleted.
- `master` is **2057 lines behind** on `scripts/bayport-vpn.sh` (`git diff --stat master..tmux/overhaul`). 11 bayport commits — the merge above plus the Mar–Apr `_timeout`/session-persist/classifier/cert-update/resolver-cleanup work — live only on `tmux/overhaul`. Master's last bayport commit is `df73b03` (Feb 6, rename only). This needs its own cleanup pass (see P1 #7).

---

## P0 — immediate

### 1. Port is hardcoded ✅ DONE (`01d8c85`)
- `10443` literal appeared at 17 sites: config templates, `fetch_server_cert` default + call site, six diagnostic call sites in `check_connection`, two connect/connected banner lines.
- Fix shipped: `VPN_PORT` global (default `10443`), read from optional `port` custom field on BW item with numeric validation, parameterised across all call sites. BW `bayport-vpn` item now has `port = 20443`.

### 2. No persistent connection log
- `VPN_LOG=$(mktemp)` (line 2706) and the cleanup trap (line 520) wipes the log on every exit, success or failure.
- Today's morning failure left zero forensic trail; we had to reproduce the failure live to see anything.
- Fix: write to `~/.cache/bayport-vpn/logs/connect-YYYYMMDD-HHMMSS.log`, rotate to last 10. Keep mktemp as the live tail target if convenient; copy or `tee` to the persistent path. Cleanup trap only deletes mktemp.

### 3. `--debug` leaks the plaintext password
- `--debug` adds `-vv` to openfortivpn (line 2407, 2701) — openfortivpn `-vv` dumps the cleartext password in its config-load output and again in the URL-encoded form body.
- Fix: split into `--debug` (passes `-v` only, safe to share) and `--debug-credentials` (passes `-vv`, prints a warning that the log will contain plaintext secrets). Optionally pipe persistent-log writes through a redactor that masks `credential=…` and `password = "…"` lines.

---

## P1 — short-term

### 4. Classifier blind to port/host drift
- `classify_vpn_failure` reads the openfortivpn log and matches strings. When TLS handshakes succeed but `/remote/logincheck` is dropped, openfortivpn says `Could not authenticate` — the classifier returns `AUTH FAILURE` (correct given the input) and the user sees "wrong password / locked account" hints.
- The actual cause today was wrong-port, not wrong-credentials.
- Fix: on `AUTH FAILURE`, before declaring final, probe well-known FortiGate alt-ports (`20443`, `8443`, `443`) for `/remote/logincheck`. If one returns a real HTTP status while the configured port closes the TLS session post-POST, surface that in the error message: "port may have moved — try `:20443` (responded with HTTP 200 / 405)".

### 5. No CLI override for connection params
- You can't pass `--host`, `--port`, or `--user` to test a fix without first editing BW.
- Fix: add `--host`, `--port`, `--user` flags that override the BW item for the current run only. Useful for: testing a suspected new port; sanity-checking against a known-good config without touching BW; CI/agent use cases.

### 6. `--check-cert` is too narrow
- Currently only refreshes the stored cert fingerprint when the server presents a new one.
- Rename to `--refresh-config` (keep `--check-cert` as alias): probes host/port/cert, reports drift across all three, offers to update BW. Or add `--probe-server` as a sibling diagnostic.

### 7. Branch hygiene: get bayport work onto master
- `tmux/overhaul` is currently the de facto bayport branch — carries the entire Mar–Apr post-rewrite history. Master is 2057 lines / 11 commits behind on `scripts/bayport-vpn.sh`.
- Untangle: separate the bayport commits from the tmux commits on this branch (likely via `git rebase -i` or cherry-pick onto a fresh `fix/bayport-vpn-current` branch from master), then merge that to master. Then tmux/overhaul can be slimmed back to actual tmux work.
- Once bayport is on master:
  - Delete the now-merged named branches `vpn-harden/security-review` (`3e51040`) and `vpn-harden/resilience-hardening` (`37f316c`) — content already in master via the `3e40e71` merge that's part of this carry-over.
  - Remove their worktrees: `~/.code/worktrees/security-review`, `~/.code/worktrees/resilience-hardening`.
- Stale standalone copies to remove or document:
  - `~/.code/.bayport-vpn.sh` (1.9K, Mar 23) — not a symlink; old version.
  - `~/.code/bmad-mw-lab/repos/network-media-tools/scripts/.bayport-vpn.sh` (2.2K, Oct 2025) — older still.
- `~/.bayport-vpn.sh` is correctly a symlink to `~/.code/dotfiles/scripts/bayport-vpn.sh` — leave it.

---

## P2 — structural

### 8. 2908-line monolith → sourced modules
Suggested split (orchestrator stays ~200 lines):

| Module | Functions today |
|---|---|
| `lib/log.sh` | `log_*` (lines 53–95) |
| `lib/platform.sh` | `detect_platform`, `check_interface_up`, `platform_route_*`, `count_*`, `list_*` |
| `lib/session.sh` | `detect_keystore`, `_read_session_from_backend`, `save_session_key`, `load_cached_session`, `clear_session_cache`, `show_session_status`, `start_sudo_keepalive`, `stop_sudo_keepalive` |
| `lib/bw.sh` | `get_item_name`, `get_bitwarden_session`, `get_vpn_config`, `parse_vpn_config` |
| `lib/cert.sh` | `fetch_server_cert`, `check_and_update_cert` |
| `lib/routes.sh` | `default_routes`, `load_routes`, `init_routes_config`, `verify_routes`, `add_vpn_routes`, `remove_vpn_routes` |
| `lib/dns.sh` | `detect_vpn_dns`, `load_dns_config`, `configure_split_dns`, `remove_split_dns` |
| `lib/gateway.sh` | `capture_default_gateway`, `verify_default_gateway`, `restore_default_gateway` |
| `lib/diag.sh` | `classify_vpn_failure`, `handle_vpn_failure`, `dns_leak_test`, `check_vpn_conflicts` |
| `lib/monitor.sh` | `wait_for_vpn_interface`, `monitor_vpn_connection` |
| `bayport-vpn.sh` | `parse_args`, `usage`, `check_dependencies`, `precheck_permissions`, `connect_vpn`, `cleanup`, `main` |

Sourcing model: `source "${BASH_SOURCE%/*}/lib/log.sh"` etc. at top of orchestrator.

### 9. Tests
- `tests/bayport-vpn-tests.sh` is 612 lines — content unaudited. Add fixture-driven tests for `classify_vpn_failure` using captured openfortivpn output samples (including today's TLS-OK + auth-fail-on-wrong-port pattern) before refactoring, so the split is regression-checked.

### 10. Sudo keepalive PID race (audit only)
- `start_sudo_keepalive` / `stop_sudo_keepalive` (lines 1375–1391) — verify cleanup behaviour when openfortivpn exits abnormally or the user Ctrl+Cs mid-connect. Today's run did clean up correctly but the path is non-obvious.

---

## Out of scope (for now)

- Port to Go / rewrite. At 100K of bash with platform abstraction, keystore detection, cert handling, state caching, classifier logic — the structural seams are there. Worth revisiting once P0–P1 are done and the test bed exists, but not now.
- Replace openfortivpn with a different FortiGate client. The auth-via-TLS-POST design is openfortivpn-specific; changing client changes the failure-classification surface entirely.
