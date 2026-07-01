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
Y

pass=0; fail=0
check(){ if echo "$2" | grep -qF "$3"; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (missing: $3)"; fail=$((fail+1)); fi }

OUT=$("$CT" spawn "$TMP/team.yaml" --backend herdr --dry-run 2>&1)

# session name is derived from the project basename: team-<basename> = team-proj
check "workspace create (herdr) for derived session" "$OUT" "herdr workspace create --cwd '$TMP/proj' --label 'team-proj'"
# Task 2: worker spawn
check "worker pane split (herdr)" "$OUT" "herdr pane split '<pane:lead>' --direction down"
check "worker rename w1"           "$OUT" "herdr pane rename <pane:w1> 'w1'"
check "lead is NOT split (root pane)" "$(echo "$OUT" | grep -c "pane rename <pane:lead>")" "0"
# Task 3: send / injection
check "worker cmd via pane run (herdr)"        "$OUT" "herdr pane run <pane:w1>"
check "injected worker_cmd carries \$(cat prompt)" "$OUT" "$TMP/proj/.claude-team/agents/w1.md"
# Task 4: stop (needs a live workspace to pass the has-session gate)
if command -v herdr >/dev/null && herdr status server 2>/dev/null | grep -q running; then
  herdr workspace create --label 'team-cttest' --no-focus >/dev/null 2>&1
  SOUT=$("$CT" --stop cttest --backend herdr --dry-run 2>&1)
  check "stop emits workspace close" "$SOUT" "workspace close (label 'team-cttest')"
  WSID=$(herdr workspace list 2>/dev/null | yq -p json -r '.result.workspaces[] | select(.label=="team-cttest") | .workspace_id')
  [ -n "$WSID" ] && herdr workspace close "$WSID" >/dev/null 2>&1
else
  echo "  skip: stop test (no herdr server)"
fi

echo "== pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
