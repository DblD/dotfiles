#!/usr/bin/env bash
# Dry-run tests for `claude-team --backend herdr`. No live herdr needed.
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

echo "== pass=$pass fail=$fail =="
[ "$fail" -eq 0 ]
