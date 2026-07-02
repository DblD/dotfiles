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
  - { name: w1, role: worker, mode: interactive, prompt: .claude-team/agents/w1.md }
  - { name: w2, role: worker, mode: interactive, runner: pi, model: rtx3090/Qwen3-14B-AWQ, prompt: .claude-team/agents/w1.md }
  - { name: w3, role: worker, mode: interactive, runner: bogus, prompt: .claude-team/agents/w1.md }
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
check "w1 (claude) launch unchanged"     "$W1LINE" "unset CLAUDECODE && claude --allow-dangerously-skip-permissions"
check "w1 (claude) prompt via --append-system-prompt" "$W1LINE" "--append-system-prompt \"\$(cat '$TMP/proj/.claude-team/agents/w1.md')\""
W2LINE=$(echo "$OUT" | grep -F "pane run <pane:w2>")
check "w2 (pi) uses pi with model"       "$W2LINE" "clear && pi --model rtx3090/Qwen3-14B-AWQ"
check "w2 (pi) prompt via -p \$(cat)"    "$W2LINE" "-p \"\$(cat '$TMP/proj/.claude-team/agents/w1.md')\""
check_eq "w2 (pi) carries no claude flags" "$(echo "$W2LINE" | grep -c 'dangerously-skip-permissions')" "0"
check "w3 unknown runner errors"         "$OUT" "unknown runner: bogus (skipping)"
check_eq "w3 not spawned"                "$(echo "$OUT" | grep -cF "<pane:w3>")" "0"
# Task 4: stop (needs a live workspace to pass the has-session gate)
if command -v herdr >/dev/null && herdr status server 2>/dev/null | grep running >/dev/null; then
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

# status with no matching sessions exits 0 (tmux backend, bogus name)
NOUT=$("$CT" status definitely-not-a-real-session --backend tmux 2>&1); NRC=$?
check "status missing session says none running" "$NOUT" "no team sessions running"
check_eq "status missing session exits 0" "$NRC" "0"

# --- watch supervisor ---

# no server needed: watch with no args prints usage and exits nonzero
WOUT=$("$CT" watch 2>&1); WRC=$?
check "watch no-args prints usage" "$WOUT" "Usage:"
check_eq "watch no-args exits nonzero" "$([ "$WRC" -ne 0 ] && echo yes || echo no)" "yes"

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

echo "== pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
