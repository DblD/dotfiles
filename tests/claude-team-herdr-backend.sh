#!/usr/bin/env bash
# Dry-run tests for `claude-team --backend herdr`. No live herdr needed.
#
# Live smoke (needs the herdr service running) — verified manually:
#   SM=~/.code/scratch/herdr-team-smoke; mkdir -p "$SM/.claude-team/agents"
#   echo 'reply SMOKE-OK then stop.' > "$SM/.claude-team/agents/hello.md"
#   printf 'name: smoke\nproject: %s\nworktrees: false\nagents:\n  - {name: lead, role: lead}\n  - {name: hello, role: worker, mode: interactive, prompt: .claude-team/agents/hello.md}\n' "$SM" > "$SM/smoke.yaml"
#   claude-team spawn "$SM/smoke.yaml" --backend herdr    # -> workspace team-herdr-team-smoke, lead root + hello pane
#   claude-team --stop herdr-team-smoke --backend herdr   # -> workspace close
set -uo pipefail
export PATH="/opt/homebrew/opt/herdr/bin:$PATH"
CT="$(cd "$(dirname "$0")/.." && pwd)/scripts/claude-team"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/proj/.claude-team/agents"
cat > "$TMP/proj/.claude-team/agents/w1.md" <<'P'
you are worker one. reply OK.
P
cat > "$TMP/team.yaml" <<Y
name: t1
project: $TMP/proj
worktrees: false
agents:
  - { name: lead, role: lead }
  - { name: w1, role: worker, mode: interactive, prompt: .claude-team/agents/w1.md,
      deliverable: { branch_pushed: agent/w1, check: "true" } }
  - { name: w2, role: worker, mode: interactive, runner: pi, model: rtx3090/Qwen3-14B-AWQ, prompt: .claude-team/agents/w1.md }
  - { name: w3, role: worker, mode: interactive, runner: bogus, prompt: .claude-team/agents/w1.md }
  - { name: w4, role: worker, mode: interactive,
      deliverable: { branch_pushed: agent/w4, check: "true" } }
  - { name: w5, role: worker, mode: interactive, prompt: .claude-team/agents/w1.md }
Y

pass=0; fail=0
check(){ if echo "$2" | grep -qF -- "$3"; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (missing: $3)"; fail=$((fail+1)); fi }
check_eq(){ if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got: $2, want: $3)"; fail=$((fail+1)); fi }

OUT=$("$CT" spawn "$TMP/team.yaml" --backend herdr --dry-run 2>&1)

# session name is derived from the project basename: team-<basename> = team-proj
check "workspace create (herdr) for derived session" "$OUT" "herdr workspace create --cwd '$TMP/proj' --label 'team-proj'"
# Task 2: worker spawn (workers are tabs, stateless label addressing)
check "worker tab create w1" "$OUT" "tab create --workspace <ws:team-proj> --cwd '$TMP/proj' --label 'w1'"
check_eq "lead not spawned as tab" "$(echo "$OUT" | grep -cF -- "--label 'lead'")" "0"
check "backend env propagated" "$OUT" "--env CLAUDE_TEAM_BACKEND=herdr"
# Task 3: send / injection
check "worker cmd via pane run (herdr)"        "$OUT" "herdr pane run <pane:w1>"
check "injected worker_cmd carries \$(cat prompt)" "$OUT" "$TMP/proj/.claude-team/agents/w1.md"
# runner: field — w1 stays claude (unchanged), w2 runs pi with model, w3 (unknown) skipped
W1LINE=$(echo "$OUT" | grep -F "pane run <pane:w1>")
check "w1 (claude) base launch shape"    "$W1LINE" "unset CLAUDECODE && claude --allow-dangerously-skip-permissions"
# A contracted worker (declares a deliverable) runs under `watch` with no human
# in the loop, so it MUST launch bypassed (--dangerously-skip-permissions) or it
# stalls at the plan/permission gate and the completion protocol dead-locks. Its
# permission-profile deny-list is the safety rail. w1 is contracted -> BOTH the
# --allow- flag AND the bypass flag are present (2 occurrences of the substring).
check "w1 (contracted claude) launches bypassed" \
  "$W1LINE" " --dangerously-skip-permissions"
# w5 is an UNCONTRACTED claude worker (no deliverable) -> NOT auto-bypassed; it
# carries only --allow-dangerously-skip-permissions, never the bare bypass flag
# (the leading space distinguishes it from the --allow- form). Bypass stays
# opt-in via --yolo for uncontracted workers.
W5LINE=$(echo "$OUT" | grep -F "pane run <pane:w5>")
check_eq "w5 (uncontracted claude) not auto-bypassed" \
  "$(echo "$W5LINE" | grep -cF -- ' --dangerously-skip-permissions')" "0"
# w1 now carries a deliverable (see below), so --append-system-prompt points at
# the contract-injected temp copy rather than the original file — match the flag
# syntax path-agnostically here, and verify the actual file content further down.
check "w1 (claude) prompt via --append-system-prompt" "$W1LINE" "--append-system-prompt \"\$(cat '"
W2LINE=$(echo "$OUT" | grep -F "pane run <pane:w2>")
check "w2 (pi) uses pi with model"       "$W2LINE" "clear && pi --model rtx3090/Qwen3-14B-AWQ"
check "w2 (pi) prompt via -p \$(cat)"    "$W2LINE" "-p \"\$(cat '$TMP/proj/.claude-team/agents/w1.md')\""
check_eq "w2 (pi) carries no claude flags" "$(echo "$W2LINE" | grep -c 'dangerously-skip-permissions')" "0"
check "w3 unknown runner errors"         "$OUT" "unknown runner: bogus (skipping)"
check_eq "w3 not spawned"                "$(echo "$OUT" | grep -cF "<pane:w3>")" "0"
# Task 1: deliverable parsing + contract injection at spawn
check "contract injected note"    "$OUT" "deliverable contract injected for w1"
check "contract file is a temp copy (original untouched)" \
  "$(cat "$TMP/proj/.claude-team/agents/w1.md")" "you are worker one. reply OK."
check_eq "original prompt has no contract" \
  "$(grep -c 'DELIVERABLE CONTRACT' "$TMP/proj/.claude-team/agents/w1.md")" "0"
# w1's --append-system-prompt now targets the injected temp copy; confirm the
# actual file claude reads carries both the original text and the contract.
W1_PROMPT_PATH=$(echo "$W1LINE" | sed -n "s/.*--append-system-prompt \"\$(cat '\([^']*\)').*/\1/p")
check "w1 injected prompt carries original content" \
  "$(cat "$W1_PROMPT_PATH" 2>/dev/null)" "you are worker one. reply OK."
check "w1 injected prompt carries the deliverable contract" \
  "$(cat "$W1_PROMPT_PATH" 2>/dev/null)" "DELIVERABLE CONTRACT"
# Contract-only agent: w4 declares a deliverable but has no prompt/task at
# all — inject_contract must still produce a temp file (contract text only)
# and the emitted command must carry it via --append-system-prompt, so a
# promptless deliverable agent isn't launched with no contract at all.
check "contract injected note for promptless w4" "$OUT" "deliverable contract injected for w4"
W4LINE=$(echo "$OUT" | grep -F "pane run <pane:w4>")
check "w4 (promptless) gets --append-system-prompt" "$W4LINE" "--append-system-prompt \"\$(cat '"
W4_PROMPT_PATH=$(echo "$W4LINE" | sed -n "s/.*--append-system-prompt \"\$(cat '\([^']*\)').*/\1/p")
check "w4 contract-only file exists" "$([ -f "$W4_PROMPT_PATH" ] && echo yes)" "yes"
check "w4 contract-only file carries the deliverable contract" \
  "$(cat "$W4_PROMPT_PATH" 2>/dev/null)" "DELIVERABLE CONTRACT"

# --- verify: pure fixture (no herdr) ---
VP="$TMP/vproj"; mkdir -p "$VP/.claude-team/manifest" "$TMP/bare.git"
git init -q --bare "$TMP/bare.git"
git init -q "$VP"; git -C "$VP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$VP" remote add origin "$TMP/bare.git"
git -C "$VP" branch -q agent/ok && git -C "$VP" push -q origin agent/ok
cat > "$VP/.claude-team/manifest/team-vproj.json" <<J
{"session":"team-vproj","config_path":"none","project":"$VP","spawned_at":"t",
 "agents":{
  "good":{"state":"pending","nudges":0,"verifications":[],"collected":false,"reaped":false,
          "work_dir":"$VP","checks":{"branch_pushed":"agent/ok","check":"true"}},
  "bad": {"state":"pending","nudges":0,"verifications":[],"collected":false,"reaped":false,
          "work_dir":"$VP","checks":{"branch_pushed":"agent/missing","check":"false"}},
  "vac": {"state":"pending","nudges":0,"verifications":[],"collected":false,"reaped":false,
          "work_dir":"$VP","checks":{"branch_pushed":"","check":""}}}}
J
VOUT=$(cd "$VP" && "$CT" verify vproj 2>&1); VRC=$?
check "verify: good agent PASS"   "$VOUT" "good: PASS"
check "verify: bad agent FAIL"    "$VOUT" "bad: FAIL"
check "verify: vacuous PASS"      "$VOUT" "vac: PASS"
check "verify: teaching detail"   "$VOUT" "not found on origin"
check_eq "verify: exit 1 on any unmet" "$VRC" "1"
VJ=$(cd "$VP" && "$CT" verify vproj good --json 2>&1); VJRC=$?
check "verify --json met"          "$VJ" '"met": true'
check_eq "verify: exit 0 all met"  "$VJRC" "0"
"$CT" verify nosuchsession >/dev/null 2>&1; check_eq "verify: exit 2 no manifest" "$?" "2"
(cd "$VP" && "$CT" verify vproj nosuchagent >/dev/null 2>&1)
check_eq "verify: exit 2 unknown agent" "$?" "2"
# --json output must be strict JSONL: every line parses (round-trip pin)
VJALL=$(cd "$VP" && "$CT" verify vproj --json)
echo "$VJALL" | python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]'
check_eq "verify: --json lines all parse" "$?" "0"

# --- status: manifest-only fallback (no live herdr workspace/tmux session, just a manifest) ---
SOUT=$(cd "$VP" && "$CT" status vproj 2>&1 || true)
check "status shows PROTOCOL column" "$SOUT" "PROTOCOL"
check "status shows pending state"   "$SOUT" "pending"

# Row-anchored: "met" is a substring of "unmet", so pin each row individually
# rather than grepping the whole table for "met" (that would pass even if
# every row showed "unmet").
SVOUT=$(cd "$VP" && "$CT" status vproj --verify 2>&1 || true)
check "status --verify good row met"   "$(echo "$SVOUT" | grep -E '^\s*good\b')" " met"
check "status --verify bad row unmet"  "$(echo "$SVOUT" | grep -E '^\s*bad\b')" "unmet"

# --- rendering pins: nudged xN + manifest-recorded "met" on the same agent ---
# Separate small fixture (not mixed into vproj's good/bad/vac set, which
# `verify` iterates and whose exit-code invariants shouldn't shift).
cat > "$VP/.claude-team/manifest/team-vproj2.json" <<J
{"session":"team-vproj2","config_path":"none","project":"$VP","spawned_at":"t",
 "agents":{
  "nud": {"state":"working","nudges":2,
          "verifications":[{"ts":"t1","met":false,"detail":"first"},{"ts":"t2","met":true,"detail":"second"}],
          "collected":false,"reaped":false,"work_dir":"$VP","checks":{"branch_pushed":"","check":""}}}}
J
NSOUT=$(cd "$VP" && "$CT" status vproj2 2>&1 || true)
check "status renders nudged xN (working+nudges)" "$(echo "$NSOUT" | grep -E '^\s*nud\b')" "nudged x2"
check "status renders met from manifest's last verification" "$(echo "$NSOUT" | grep -E '^\s*nud\b')" " met"

# --- corrupt-manifest resilience: status must degrade, never die under -euo pipefail ---
CP="$TMP/corruptproj"; mkdir -p "$CP/.claude-team/manifest"
printf '{"session":"team-corrupt","config_path":"none","proje' > "$CP/.claude-team/manifest/team-corrupt.json"
COUT=$(cd "$CP" && "$CT" status corrupt 2>&1); CRC=$?
check_eq "status on truncated manifest exits 0" "$CRC" "0"
check "status on truncated manifest prints session table" "$COUT" "team-corrupt"
check "status on truncated manifest warns"        "$COUT" "warning: unreadable manifest for team-corrupt"

# Task 4: stop (needs a live workspace to pass the has-session gate)
if command -v herdr >/dev/null && herdr status server 2>/dev/null | grep running >/dev/null; then
  # Task 2: manifest seeding at spawn — lead + unknown-runner worker so NOTHING
  # launches, but the workspace + manifest are real.
  MPROJ="$TMP/mproj"; mkdir -p "$MPROJ/.claude-team/agents"
  echo "x" > "$MPROJ/.claude-team/agents/mw.md"
  cat > "$TMP/mteam.yaml" <<Y
name: mtest
project: $MPROJ
worktrees: false
agents:
  - { name: lead, role: lead }
  - { name: mw, role: worker, runner: nosuchrunner, prompt: .claude-team/agents/mw.md,
      deliverable: { branch_pushed: agent/mw, check: "true" } }
Y
  WSID=$(herdr workspace list | yq -p json -r '.result.workspaces[] | select(.label=="team-mproj") | .workspace_id')
  [ -n "$WSID" ] && herdr workspace close "$WSID" >/dev/null 2>&1

  "$CT" spawn "$TMP/mteam.yaml" --backend herdr >/dev/null 2>&1 || true
  Man="$MPROJ/.claude-team/manifest/team-mproj.json"
  check "manifest seeded"        "$(ls "$Man" 2>/dev/null)" "$Man"
  check "manifest records backend (persist half of backend-stick)" "$(cat "$Man" 2>/dev/null)" '"backend": "herdr"'
  check "manifest has mw checks" "$(cat "$Man" 2>/dev/null)" '"branch_pushed": "agent/mw"'
  check "manifest agent pending" "$(cat "$Man" 2>/dev/null)" '"state": "pending"'
  # re-spawn into the existing session must MERGE-PRESERVE protocol state,
  # not wipe it: simulate watch-owned progress (nudges/state), spawn again
  # with the SAME config, and assert the progress survived with checks intact.
  python3 - "$Man" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["agents"]["mw"]["nudges"] = 1
d["agents"]["mw"]["state"] = "working"
json.dump(d, open(p, "w"), indent=2)
PY
  "$CT" spawn "$TMP/mteam.yaml" --backend herdr >/dev/null 2>&1 || true
  check "respawn preserves nudges" "$(cat "$Man" 2>/dev/null)" '"nudges": 1'
  check "respawn preserves state"  "$(cat "$Man" 2>/dev/null)" '"state": "working"'
  check "respawn keeps mw checks"  "$(cat "$Man" 2>/dev/null)" '"branch_pushed": "agent/mw"'
  WSID=$(herdr workspace list | yq -p json -r '.result.workspaces[] | select(.label=="team-mproj") | .workspace_id')
  [ -n "$WSID" ] && herdr workspace close "$WSID" >/dev/null 2>&1

  herdr workspace create --label 'team-cttest' --no-focus >/dev/null 2>&1
  SOUT=$("$CT" --stop cttest --backend herdr --dry-run 2>&1)
  check "stop emits workspace close" "$SOUT" "workspace close (label 'team-cttest')"
  WSID=$(herdr workspace list 2>/dev/null | yq -p json -r '.result.workspaces[] | select(.label=="team-cttest") | .workspace_id')
  [ -n "$WSID" ] && herdr workspace close "$WSID" >/dev/null 2>&1
else
  echo "  skip: stop test (no herdr server)"
fi

# --- tell: guaranteed-submission instruction delivery ---

# herdr dry-run: send-text then send-keys enter (bare session name normalizes to team-proj)
TOUT=$("$CT" tell proj w1 "do the thing" --backend herdr --dry-run 2>&1)
check "tell (herdr) sends text to pane"   "$TOUT" "pane send-text <pane:w1>"
check "tell (herdr) carries the message"  "$TOUT" 'do the thing'
check "tell (herdr) presses enter"        "$TOUT" "send-keys <pane:w1> enter"
check "tell (herdr) confirms delivery"    "$TOUT" "told w1: do the thing"

# tmux dry-run: send-keys with message + Enter
TT=$("$CT" tell proj w1 "do the thing" --backend tmux --dry-run 2>&1)
check "tell (tmux) uses send-keys"        "$TT" "tmux send-keys"
check "tell (tmux) carries message+Enter" "$TT" "do the thing Enter"

# --wait on tmux is a no-op with a warning
TW=$("$CT" tell proj w1 "go" --wait --backend tmux --dry-run 2>&1)
check "tell (tmux) --wait unsupported"    "$TW" "not supported on tmux backend"

# --- status: one-glance agent table ---

if command -v herdr >/dev/null && herdr status server 2>/dev/null | grep running >/dev/null; then
  SJ=$(herdr workspace create --label 'team-stattest' --no-focus 2>/dev/null)
  SWS=$(echo "$SJ" | yq -p json -r '.result.workspace.workspace_id')
  if [ -n "$SWS" ] && [ "$SWS" != "null" ]; then
    herdr tab create --workspace "$SWS" --label w1 --no-focus >/dev/null 2>&1
    STOUT=$("$CT" status stattest --backend herdr 2>&1)
    check "status shows session header" "$STOUT" "team-stattest"
    check "status lists agent w1"       "$STOUT" "w1"
    check "status prints table header"  "$STOUT" "AGENT"
    herdr workspace close "$SWS" >/dev/null 2>&1
  else
    echo "  FAIL: status live test (could not create team-stattest workspace)"; fail=$((fail+1))
  fi
else
  echo "  skip: status live test (no herdr server)"
fi

# --- status: manifest project-path retry (live session, $PWD lookup deliberately misses) ---
if command -v herdr >/dev/null && herdr status server 2>/dev/null | grep running >/dev/null; then
  RTP="$TMP/retryproj"; mkdir -p "$RTP/.claude-team/manifest"
  cat > "$RTP/.claude-team/manifest/team-retrytest.json" <<J
{"session":"team-retrytest","config_path":"none","project":"$RTP","spawned_at":"t",
 "agents":{"w1":{"state":"pending","nudges":0,"verifications":[],"collected":false,"reaped":false,
  "work_dir":"$RTP","checks":{"branch_pushed":"","check":""}}}}
J
  RJ=$(herdr workspace create --cwd "$RTP" --label 'team-retrytest' --no-focus 2>/dev/null)
  RWS=$(echo "$RJ" | yq -p json -r '.result.workspace.workspace_id')
  if [ -n "$RWS" ] && [ "$RWS" != "null" ]; then
    herdr tab create --workspace "$RWS" --cwd "$RTP" --label w1 --no-focus >/dev/null 2>&1
    # run from $TMP (not $RTP, not $RTP/..) so the plain $PWD lookup misses and
    # the retry against the workspace root pane's cwd is what finds the manifest
    ROUT=$(cd "$TMP" && "$CT" status retrytest --backend herdr 2>&1)
    check "status manifest retry via project cwd finds w1's PROTOCOL" \
      "$(echo "$ROUT" | grep -E '^\s*w1\b')" "pending"
    herdr workspace close "$RWS" >/dev/null 2>&1
  else
    echo "  FAIL: status manifest retry test (could not create team-retrytest workspace)"; fail=$((fail+1))
  fi
else
  echo "  skip: status manifest retry test (no herdr server)"
fi

# --- status: corrupt manifest degrades gracefully with a live session too ---
if command -v herdr >/dev/null && herdr status server 2>/dev/null | grep running >/dev/null; then
  CP2="$TMP/corruptproj2"; mkdir -p "$CP2/.claude-team/manifest"
  printf '{"session":"team-corrupt2","broken' > "$CP2/.claude-team/manifest/team-corrupt2.json"
  CJ=$(herdr workspace create --cwd "$CP2" --label 'team-corrupt2' --no-focus 2>/dev/null)
  CWS=$(echo "$CJ" | yq -p json -r '.result.workspace.workspace_id')
  if [ -n "$CWS" ] && [ "$CWS" != "null" ]; then
    herdr tab create --workspace "$CWS" --cwd "$CP2" --label w1 --no-focus >/dev/null 2>&1
    C2OUT=$(cd "$TMP" && "$CT" status corrupt2 --backend herdr 2>&1); C2RC=$?
    check_eq "status (live) on truncated manifest exits 0" "$C2RC" "0"
    check "status (live) on truncated manifest warns" "$C2OUT" "warning: unreadable manifest for team-corrupt2"
    check "status (live) on truncated manifest still lists w1" "$C2OUT" "w1"
    herdr workspace close "$CWS" >/dev/null 2>&1
  else
    echo "  FAIL: status live corrupt-manifest test (could not create team-corrupt2 workspace)"; fail=$((fail+1))
  fi
else
  echo "  skip: status live corrupt-manifest test (no herdr server)"
fi

# status with no matching sessions exits 0 (tmux backend, bogus name)
NOUT=$("$CT" status definitely-not-a-real-session --backend tmux 2>&1); NRC=$?
check "status missing session says none running" "$NOUT" "no team sessions running"
check_eq "status missing session exits 0" "$NRC" "0"

# --- watch supervisor ---

# no server needed: watch with no args prints usage and exits nonzero
WOUT=$("$CT" watch 2>&1); WRC=$?
check "watch no-args prints usage" "$WOUT" "Usage:"
check_eq "watch no-args exits nonzero" "$([ "$WRC" -ne 0 ] && echo yes || echo no)" "yes"

# --reap: watcher compiles and advertises the flag in usage (both files)
CTW="$(dirname "$CT")/claude-team-watch"
check_eq "watch helper py_compile" "$(python3 -m py_compile "$CTW" 2>&1 && echo ok)" "ok"
check "watch helper usage mentions --reap" "$(python3 "$CTW" --help 2>&1)" "--reap"
check "orchestrator usage mentions --reap" "$("$CT" --help 2>&1)" "--reap"

# live watch: report-agent blocked must surface a "needs you" line within ~5s
if command -v herdr >/dev/null && herdr status server 2>/dev/null | grep running >/dev/null; then
  WJ=$(herdr workspace create --label 'team-watchtest' --no-focus 2>/dev/null)
  WPANE=$(echo "$WJ" | yq -p json -r '.result.root_pane.pane_id')
  if [ -n "$WPANE" ] && [ "$WPANE" != "null" ]; then
    WLOG="$TMP/watch.log"
    "$CT" watch watchtest > "$WLOG" 2>&1 &
    WPID=$!
    sleep 2  # let it subscribe
    herdr pane report-agent "$WPANE" --source test --agent claude --state working --seq 1 >/dev/null 2>&1
    sleep 1
    herdr pane report-agent "$WPANE" --source test --agent claude --state blocked --seq 2 >/dev/null 2>&1
    hit=no
    for _ in $(seq 1 10); do
      if grep -q "needs you" "$WLOG"; then hit=yes; break; fi
      sleep 0.5
    done
    check_eq "watch reports blocked agent (needs you)" "$hit" "yes"
    check "watch printed working transition" "$(cat "$WLOG")" "-> working"
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
    herdr workspace close "${WPANE%%:*}" >/dev/null 2>&1
  else
    echo "  FAIL: watch live test (could not create team-watchtest workspace)"; fail=$((fail+1))
  fi
else
  echo "  skip: watch live test (no herdr server)"
fi

# --- completion protocol: nudge loop (live) ---
# Drive the full unmet->nudge->met->complete cycle with report-agent only (no
# real agent). The nudge types into the pane's SHELL — harmless; the pane-read
# assertion sees the typed text.
if command -v herdr >/dev/null && herdr status server 2>/dev/null | grep running >/dev/null; then
  NP="$TMP/nproj"; mkdir -p "$NP/.claude-team/manifest"
  rm -f /tmp/ct-nudge-flag
  # self-heal stale workspace first (same pattern as team-mproj)
  NWS=$(herdr workspace list | yq -p json -r '.result.workspaces[] | select(.label=="team-nudgetest") | .workspace_id')
  [ -n "$NWS" ] && herdr workspace close "$NWS" >/dev/null 2>&1
  herdr workspace create --cwd "$NP" --label team-nudgetest --no-focus >/dev/null 2>&1
  NWS=$(herdr workspace list | yq -p json -r '.result.workspaces[] | select(.label=="team-nudgetest") | .workspace_id')
  NT1=$(herdr tab list --workspace "$NWS" | yq -p json -r '.result.tabs[0].tab_id')
  herdr tab rename "$NT1" lead >/dev/null 2>&1
  NPANE=$(herdr tab create --workspace "$NWS" --cwd "$NP" --label wnudge --no-focus | yq -p json -r '.result.root_pane.pane_id')
  cat > "$NP/.claude-team/manifest/team-nudgetest.json" <<J
{"session":"team-nudgetest","config_path":"none","project":"$NP","spawned_at":"t",
 "agents":{"wnudge":{"state":"pending","nudges":0,"verifications":[],"collected":false,
  "reaped":false,"work_dir":"$NP","checks":{"branch_pushed":"","check":"test -f /tmp/ct-nudge-flag"}}}}
J
  WOUT="$TMP/nwatch.out"
  "$CT" watch nudgetest --backend herdr > "$WOUT" 2>&1 &
  WPID=$!
  sleep 2
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state working --seq 1 >/dev/null 2>&1
  sleep 1
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state idle --seq 2 >/dev/null 2>&1
  sleep 4
  check "nudge sent on unmet"  "$(cat "$WOUT")" "nudged"
  # NB: --source recent returns empty for a plain shell pane; visible sees the
  # typed nudge text reliably.
  check "nudge text is teaching" "$(herdr pane read "$NPANE" --source visible)" "ct-nudge-flag"
  check "manifest nudges=1" "$(cat "$NP/.claude-team/manifest/team-nudgetest.json")" '"nudges": 1'
  # second unmet cycle: nudge #1's text (containing the literal sentinel phrase)
  # now sits in the pane scrollback — the sentinel must NOT mistake it for a
  # worker-declared BLOCKED; this must nudge again, not escalate.
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state working --seq 21 >/dev/null 2>&1
  sleep 1
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state idle --seq 22 >/dev/null 2>&1
  sleep 4
  check "second nudge (own nudge not mistaken for BLOCKED)" "$(cat "$NP/.claude-team/manifest/team-nudgetest.json")" '"nudges": 2'
  # third unmet cycle: nudges exhausted -> escalate to incomplete, never reap
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state working --seq 41 >/dev/null 2>&1
  sleep 1
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state idle --seq 42 >/dev/null 2>&1
  sleep 4
  check "escalated to incomplete" "$(cat "$NP/.claude-team/manifest/team-nudgetest.json")" '"state": "incomplete"'
  check "escalation logged" "$(cat "$WOUT")" "escalated"
  check "unmet worker not reaped" "$(herdr tab list --workspace "$NWS" | yq -p json -r '.result.tabs[].label')" "wnudge"
  # ABSORBING escalation: another unmet idle must NOT re-escalate (the
  # escalation nudge provokes a worker reply -> without absorption this loops
  # forever with toasts/chimes; observed live 2026-07-02).
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state working --seq 45 >/dev/null 2>&1
  sleep 1
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state idle --seq 46 >/dev/null 2>&1
  sleep 4
  check_eq "escalation fired exactly once (absorbing)" \
    "$(grep -c 'escalated to human' "$WOUT")" "1"
  check "absorbed cycle logged" "$(cat "$WOUT")" "staying quiet"
  # met-beats-count recovery: verify runs BEFORE the nudge-count check, so a
  # post-escalation cycle with the deliverable met must still reach complete
  # (recovery now flows through the absorbing branch).
  touch /tmp/ct-nudge-flag
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state working --seq 51 >/dev/null 2>&1
  sleep 1
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state idle --seq 52 >/dev/null 2>&1
  sleep 4
  check "complete after flag (post-escalation)" "$(cat "$NP/.claude-team/manifest/team-nudgetest.json")" '"state": "complete"'
  # collect() ran on the complete path, so the manifest must record it
  # (collected/reaped are live fields, not dead schema)
  check "collected recorded in manifest" "$(cat "$NP/.claude-team/manifest/team-nudgetest.json")" '"collected": true'
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; rm -f /tmp/ct-nudge-flag
  herdr workspace close "$NWS" >/dev/null 2>&1
else
  echo "  skip: nudge loop live test (no herdr server)"
fi

# --- review: deliverable (agent-as-verifier) — pure fixtures, no herdr ---
# The reviewer is a separate (optionally diverse-model) agent that reads the
# worker's session and writes a graded verdict artifact; `verify` folds that
# artifact in as one more check (VERIFIED+ = met, PARTIAL- = unmet).
RVP="$TMP/rvproj"; mkdir -p "$RVP/.claude-team/manifest" "$RVP/.claude-team/reviews" "$RVP/.claude-team/verifiers"
echo "read-only reviewer role card" > "$RVP/.claude-team/verifiers/code-review.md"
cat > "$RVP/.claude-team/manifest/team-rvproj.json" <<J
{"session":"team-rvproj","config_path":"none","project":"$RVP","backend":"herdr","spawned_at":"t",
 "agents":{
  "revok":  {"state":"pending","nudges":0,"verifications":[],"collected":false,"reaped":false,
             "work_dir":"$RVP","checks":{"branch_pushed":"","check":"","review":{"persona":".claude-team/verifiers/code-review.md","profile":"council-fable"}}},
  "revno":  {"state":"pending","nudges":0,"verifications":[],"collected":false,"reaped":false,
             "work_dir":"$RVP","checks":{"branch_pushed":"","check":"","review":{"persona":".claude-team/verifiers/code-review.md","profile":"council-fable"}}},
  "revwait":{"state":"pending","nudges":0,"verifications":[],"collected":false,"reaped":false,
             "work_dir":"$RVP","checks":{"branch_pushed":"","check":"","review":{"persona":".claude-team/verifiers/code-review.md","profile":"council-fable"}}}}}
J
printf 'VERDICT: VERIFIED\nreasons: allowlist genuinely rewired; deny/round-trip tests green\n' > "$RVP/.claude-team/reviews/revok.verdict"
printf 'VERDICT: PARTIAL\nfeedback: nova-web engine still on 1.4.12 - bump it\n'                > "$RVP/.claude-team/reviews/revno.verdict"
# revwait: no verdict artifact yet (reviewer not run)
RVOUT=$(cd "$RVP" && "$CT" verify rvproj 2>&1); RVRC=$?
check    "verify: review VERIFIED -> PASS"       "$RVOUT" "revok: PASS"
check    "verify: review PARTIAL -> FAIL"        "$RVOUT" "revno: FAIL"
check    "verify: review feedback surfaced"      "$RVOUT" "nova-web engine still on 1.4.12"
check    "verify: review not-yet-run -> FAIL"    "$RVOUT" "revwait: FAIL"
check    "verify: review not-yet-run teaching"   "$RVOUT" "reviewer not yet run"
check_eq "verify: review any-unmet exit 1"       "$RVRC"  "1"
RVJ=$(cd "$RVP" && "$CT" verify rvproj revok --json 2>&1)
check    "verify: review --json met"             "$RVJ"   '"met": true'
check    "verify: review --json type"            "$RVJ"   '"type": "review"'
# claude-team review <session> <agent> --dry-run: spawns a reviewer on the
# DIVERSE profile, reading the worker's session, targeting the verdict artifact.
RDOUT=$(cd "$RVP" && "$CT" review rvproj revok --dry-run --backend herdr 2>&1)
check "review: names the reviewer tab"           "$RDOUT" "revok-review"
check "review: reviewer uses the review profile" "$RDOUT" "council-fable"
check "review: reviewer targets verdict artifact" "$RDOUT" "reviews/revok.verdict"
check "review: reviewer authors a review artifact"  "$RDOUT" "reviews/revok.review.md"
check "review: reviewer reads worker session"    "$RDOUT" "session"
# backend STICKS per session: review WITHOUT --backend resolves herdr from the
# manifest's "backend" field, instead of silently defaulting to tmux (the bug).
RSTICK=$(cd "$RVP" && "$CT" review rvproj revok --dry-run 2>&1)
check    "review: backend sticks (herdr spawn, no --backend flag)" "$RSTICK" "pane run"
check_eq "review: no tmux fallback when manifest=herdr"            "$(echo "$RSTICK" | grep -c 'tmux ')" "0"
# Finding-1 regression: the fixture's review omits `model`, so with a whitespace
# delimiter the fields shifted and a filesystem PATH was passed as --model. Assert
# no --model appears (model empty) and the reviewer spawns in the work_dir.
check_eq "review: no bogus --model when model omitted" "$(echo "$RDOUT" | grep -c -- '--model')" "0"
check    "review: reviewer spawned in work_dir"        "$RDOUT" "--cwd '$RVP'"

# malformed verdict: file present but no valid VERDICT line -> distinct 'malformed'
# state, blamed on the reviewer (not "reviewer not yet run", which would nudge the worker)
printf 'the worker did fine I think, looks good\n' > "$RVP/.claude-team/reviews/revwait.verdict"
RVB=$(cd "$RVP" && "$CT" verify rvproj revwait --json 2>&1)
check "verify: malformed verdict -> not met"        "$RVB" '"met": false'
check "verify: malformed verdict state"             "$RVB" '"review_state": "malformed"'
check "verify: malformed blames reviewer not worker" "$RVB" "not the worker's fault"
rm -f "$RVP/.claude-team/reviews/revwait.verdict"

# review: watch decision logic (maybe_spawn_reviewer / clear_review) — python unit
if UOUT=$(python3 "$(dirname "$0")/claude-team-review-unit.py" 2>&1); then
  echo "$UOUT" | sed 's/^/  /'; pass=$((pass + $(echo "$UOUT" | grep -c '  ok:')))
else
  echo "$UOUT" | sed 's/^/  /'; fail=$((fail + $(echo "$UOUT" | grep -c 'FAIL:')))
fi

# --- live: guaranteed agent kickoff (be_confirm_launch) — needs herdr + claude ---
# The launch path was intermittently dropping the Enter, leaving the agent's
# command sitting unexecuted (agent_status stuck at "unknown"). This asserts a
# REAL spawn confirms the agent started — the test category whose absence let a
# green suite coexist with "can't reliably open a pane with an agent in it".
if command -v herdr >/dev/null && herdr status server 2>/dev/null | grep running >/dev/null; then
  LP="$TMP/launchproj"; mkdir -p "$LP/.claude-team/tasks"; git init -q "$LP" 2>/dev/null
  echo 'Reply READY and stop. Do not use any tools.' > "$LP/.claude-team/tasks/noop.md"
  cat > "$LP/launch.yaml" <<Y
name: launchtest
project: $LP
worktrees: false
agents:
  - { name: lead, role: lead }
  - { name: w1, role: worker, mode: interactive, task: .claude-team/tasks/noop.md, deliverable: { check: "true" } }
Y
  # be_confirm_launch polls the worker's LIVE agent_status during spawn and only
  # prints "agent started" once it leaves "unknown" (a real agent ran); on a
  # dropped launch that never recovers it prints "did NOT start". Assert on that
  # result rather than re-reading status after (a quick agent reverts to a shell).
  LOUT=$("$CT" spawn "$LP/launch.yaml" --backend herdr --yolo 2>&1)
  check    "launch: real spawn confirms agent started" "$LOUT" "agent started"
  check_eq "launch: no start-failure reported"         "$(echo "$LOUT" | grep -c 'did NOT start')" "0"
  # session derives from the project BASENAME (launchproj), not the config name
  "$CT" --stop launchproj --backend herdr >/dev/null 2>&1
else
  echo "  skip: launch-confirm live test (no herdr server)"
fi

echo "== pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
