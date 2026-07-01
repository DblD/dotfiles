# claude-team `--backend herdr` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:executing-plans (inline) or subagent-driven-development. Steps use `- [ ]` checkboxes.

**Goal:** Add a `--backend herdr` option to `claude-team` so it stands up agent teams in herdr (agent-multiplexer) instead of tmux, keeping tmux as the default.

**Architecture:** Introduce a thin backend-dispatch layer. Every current `tmux …` call in the spawn/attach/stop paths is replaced by a `be_<op>()` function that branches on `$BACKEND` (`tmux` default, `herdr`). The herdr branch emits/executes herdr socket-CLI commands, reusing the existing `run_cmd()`/`$DRY_RUN` machinery so `--dry-run` works for free. A `name→pane_id` map (`HERDR_PANE`) tracks workers (herdr addresses panes by id, not `session:window`).

**Tech Stack:** Bash, `yq` (already a dep; use `yq -p json` for herdr JSON), herdr 0.7.1 CLI, plain-shell tests under `tests/` (matches existing `tests/*.sh`).

**Scope (MVP):** spawn (control room + workers + send), attach, stop, has-session, worktree-per-worker. Defer: events board, `agent attach --takeover`, state-aware auto-cleanup (follow-up).

**Proven patterns (from spike `~/.code/scratch/herdr-spike-live/`):**
- inject: `herdr pane run <pane> "$worker_cmd"` (worker_cmd already contains `-p "$(cat file)"`; pane shell expands it) — **must wait for shell-ready first**.
- capture pane id: workspace/split return it, or list-diff.

---

## File Structure
- Modify: `scripts/claude-team` — add `BACKEND` var, `--backend` flag, `be_*()` dispatch fns, replace tmux calls in `cmd_launch`/`cmd_spawn`/`cmd_stop`/`cmd_cleanup`.
- Create: `tests/claude-team-herdr-backend.sh` — dry-run assertions (no live herdr needed).

---

### Task 1: Backend var, flag, and test harness

**Files:** Modify `scripts/claude-team` (near vars ~21 and arg parse); Create `tests/claude-team-herdr-backend.sh`.

- [ ] **Step 1: Write failing test**
```bash
# tests/claude-team-herdr-backend.sh
#!/usr/bin/env bash
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
check "workspace create for session t1" "$OUT" "herdr workspace create --cwd '$TMP/proj' --label 't1'"

echo "== pass=$pass fail=$fail =="; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run — expect FAIL**
Run: `bash tests/claude-team-herdr-backend.sh`
Expected: FAIL (`--backend` unknown or no herdr output).

- [ ] **Step 3: Implement flag + var**
In `scripts/claude-team` near line 21 add:
```bash
BACKEND="${CLAUDE_TEAM_BACKEND:-tmux}"   # tmux | herdr
HERDR_BIN="$(command -v herdr || echo /opt/homebrew/bin/herdr)"
HERDR_WS=""
declare -A HERDR_PANE
```
In the argument-parsing loop add:
```bash
    --backend) BACKEND="$2"; shift 2 ;;
```
Add to usage text: `  --backend <tmux|herdr>               Pane backend (default tmux)`.

- [ ] **Step 4: Add `be_new_session` + wire into `cmd_spawn` session-create**
Add function:
```bash
be_new_session() { # $1=session $2=project_path
  case "$BACKEND" in
    tmux) run_cmd tmux new-session -d -s "$1" -n "lead" -c "$2" ;;
    herdr)
      if $DRY_RUN; then
        dim "[dry-run] $HERDR_BIN workspace create --cwd '$2' --label '$1' --no-focus"
        HERDR_WS="<ws>"; HERDR_PANE[lead]="<pane:lead>"
      else
        local j; j=$("$HERDR_BIN" workspace create --cwd "$2" --label "$1" --no-focus)
        HERDR_WS=$(echo "$j" | yq -p json -r '.result.workspace.workspace_id')
        HERDR_PANE[lead]=$(echo "$j" | yq -p json -r '.result.root_pane.pane_id')
      fi ;;
    *) red "unknown backend: $BACKEND"; exit 1 ;;
  esac
}
```
Replace the `cmd_spawn` session-create block (~423-425) `if ! tmux has-session…; then … tmux new-session …; fi` with:
```bash
  if ! be_has_session "$session"; then
    green "Creating session: $session"
    be_new_session "$session" "$project_path"
  fi
```
And add `be_has_session`:
```bash
be_has_session() { # $1=session
  case "$BACKEND" in
    tmux)  tmux has-session -t "$1" 2>/dev/null ;;
    herdr) "$HERDR_BIN" workspace list 2>/dev/null | grep -qF "\"label\":\"$1\"" ;;
  esac
}
```

- [ ] **Step 5: Run — expect PASS**
Run: `bash tests/claude-team-herdr-backend.sh`
Expected: `pass=1 fail=0`.

- [ ] **Step 6: Commit**
```bash
git add scripts/claude-team tests/claude-team-herdr-backend.sh
git commit -m "feat(claude-team): add --backend flag + herdr session create"
```

---

### Task 2: Worker spawn (pane split / worktree) + rename

**Files:** Modify `scripts/claude-team` (worker-creation ~535).

- [ ] **Step 1: Add failing assertions** to `tests/claude-team-herdr-backend.sh` before the `== pass` line:
```bash
check "worker pane split w1" "$OUT" "herdr pane split"
check "worker rename w1"      "$OUT" "herdr pane rename <pane:w1> 'w1'"
```
Also add a worktrees variant:
```bash
sed 's/worktrees: false/worktrees: true/' "$TMP/team.yaml" > "$TMP/team-wt.yaml"
OUTWT=$("$CT" spawn "$TMP/team-wt.yaml" --backend herdr --dry-run 2>&1)
check "worktree per worker" "$OUTWT" "herdr worktree create --cwd '$TMP/proj' --branch 'agent/w1'"
```

- [ ] **Step 2: Run — expect FAIL** (`bash tests/claude-team-herdr-backend.sh`).

- [ ] **Step 3: Implement `be_new_worker`**
```bash
be_new_worker() { # $1=session $2=name $3=work_dir  ($4=use_worktrees $5=base_branch $6=prefix)
  case "$BACKEND" in
    tmux) run_cmd tmux new-window -t "$1" -n "$2" -c "$3" ;;
    herdr)
      if $DRY_RUN; then
        if [[ "${4:-false}" == true ]]; then
          dim "[dry-run] $HERDR_BIN worktree create --cwd '$3' --branch '${6:-agent}/$2' --base '${5:-develop}' --label '$2' --no-focus"
        else
          dim "[dry-run] $HERDR_BIN pane split '${HERDR_PANE[lead]}' --direction down --cwd '$3' --no-focus"
        fi
        dim "[dry-run] $HERDR_BIN pane rename <pane:$2> '$2'"
        HERDR_PANE[$2]="<pane:$2>"
      else
        local before after new
        before=$("$HERDR_BIN" pane list --workspace "$HERDR_WS" | yq -p json -r '.result.panes[].pane_id' | sort)
        if [[ "${4:-false}" == true ]]; then
          "$HERDR_BIN" worktree create --cwd "$3" --branch "${6:-agent}/$2" --base "${5:-develop}" --label "$2" --no-focus >/dev/null
        else
          "$HERDR_BIN" pane split "${HERDR_PANE[lead]}" --direction down --cwd "$3" --no-focus >/dev/null
        fi
        after=$("$HERDR_BIN" pane list --workspace "$HERDR_WS" | yq -p json -r '.result.panes[].pane_id' | sort)
        new=$(comm -13 <(echo "$before") <(echo "$after") | head -1)
        "$HERDR_BIN" pane rename "$new" "$2" >/dev/null
        HERDR_PANE[$2]="$new"
        be_wait_ready "$new"
      fi ;;
  esac
}
be_wait_ready() { # $1=pane
  "$HERDR_BIN" pane run "$1" 'echo __READY__' >/dev/null 2>&1
  "$HERDR_BIN" wait output "$1" --match '__READY__' --source recent --timeout 8000 >/dev/null 2>&1 || true
}
```
Replace `run_cmd tmux new-window -t "$session" -n "$name" -c "$work_dir"` (~535) with:
```bash
    be_new_worker "$session" "$name" "$work_dir" "$use_worktrees" "$base_branch" "$branch_prefix"
```

- [ ] **Step 4: Run — expect PASS** (all 4 checks).
- [ ] **Step 5: Commit** `git commit -am "feat(claude-team): herdr worker spawn + worktree"`

---

### Task 3: Send worker command (injection) + lead

**Files:** Modify `scripts/claude-team` (~544-552, and lead send ~386/550).

- [ ] **Step 1: Add failing assertion**:
```bash
check "worker cmd via pane run (with \$(cat prompt))" "$OUT" "herdr pane run <pane:w1>"
check "worker cmd carries -p cat prompt" "$OUT" 'cat '"$TMP"'/proj/.claude-team/agents/w1.md'
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `be_send` + `be_send_lead`, replace tmux send-keys**
```bash
be_send() { # $1=session $2=name $3=cmd $4=mode
  case "$BACKEND" in
    tmux)
      if [[ "$4" == "headless" ]]; then
        run_cmd tmux set-option -t "$1:$2" remain-on-exit off 2>/dev/null
        run_cmd tmux send-keys -t "$1:$2" "$3 ; exit" Enter
      else
        run_cmd tmux send-keys -t "$1:$2" "$3" Enter
      fi ;;
    herdr)
      if $DRY_RUN; then dim "[dry-run] $HERDR_BIN pane run <pane:$2> \"$3\""
      else run_cmd "$HERDR_BIN" pane run "${HERDR_PANE[$2]}" "$3"; fi ;;
  esac
}
be_send_lead() { # $1=session $2=cmd
  case "$BACKEND" in
    tmux)  run_cmd tmux send-keys -t "$1:lead" "$2" Enter ;;
    herdr) if $DRY_RUN; then dim "[dry-run] $HERDR_BIN pane run <pane:lead> \"$2\""
           else run_cmd "$HERDR_BIN" pane run "${HERDR_PANE[lead]}" "$2"; fi ;;
  esac
}
```
Replace the three `tmux send-keys … "${worker_cmd}"…` / `"$(claude_cmd)"` worker sends (~544-552) with `be_send "$session" "$name" "$worker_cmd" "$mode"` (and `be_send "$session" "$name" "$(claude_cmd)" "$mode"` for the no-prompt branch). Replace lead sends (~386/550) with `be_send_lead "$session" "$(claude_cmd)"`.

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `git commit -am "feat(claude-team): herdr send (worker+lead), keeps \$(cat) injection"`

---

### Task 4: Attach + stop + list

**Files:** Modify `scripts/claude-team` (attach ~391/613/631, stop ~762, list ~712).

- [ ] **Step 1: Add failing assertions** (run a `--stop` in dry-run):
```bash
SOUT=$("$CT" --stop t1 --backend herdr --dry-run 2>&1 || true)
check "stop closes workspace" "$SOUT" "herdr workspace"
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `be_attach`, `be_stop`, `be_list_sessions`**
```bash
be_attach() { # $1=session
  case "$BACKEND" in
    tmux)  if [[ -z "${TMUX:-}" ]]; then run_cmd tmux attach-session -t "$1"; else run_cmd tmux switch-client -t "$1"; fi ;;
    herdr) if $DRY_RUN; then dim "[dry-run] $HERDR_BIN  (attach) / workspace focus '$1'"
           else run_cmd "$HERDR_BIN" workspace focus "$(be_ws_id "$1")"; fi ;;
  esac
}
be_stop() { # $1=session
  case "$BACKEND" in
    tmux)  run_cmd tmux kill-session -t "$1" ;;
    herdr) if $DRY_RUN; then dim "[dry-run] $HERDR_BIN workspace close <ws:$1>"
           else run_cmd "$HERDR_BIN" workspace close "$(be_ws_id "$1")"; fi ;;
  esac
}
be_ws_id() { "$HERDR_BIN" workspace list | yq -p json -r ".result.workspaces[] | select(.label==\"$1\") | .workspace_id"; }
```
Replace the tmux attach/switch, kill-session, and list-sessions calls in `cmd_launch`/`cmd_stop`/`cmd_list` with `be_attach`/`be_stop`/backend list. (Guard `cmd_stop` to accept `--backend`.)

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `git commit -am "feat(claude-team): herdr attach/stop/list"`

---

### Task 5: shellcheck + live smoke

- [ ] **Step 1:** `shellcheck -x scripts/claude-team` — expect no *new* errors vs baseline (record baseline first: `git stash; shellcheck scripts/claude-team | wc -l; git stash pop`).
- [ ] **Step 2:** Live smoke on a scratch project (herdr service running):
  `claude-team spawn tests/fixtures/smoke.yaml --backend herdr --no-yolo` → confirm a workspace `team-smoke` appears with lead + 1 worker pane, worker gets the prompt. Then `claude-team --stop team-smoke --backend herdr`.
- [ ] **Step 3: Commit** any fixups. `git commit -am "chore(claude-team): shellcheck + smoke fixups"`

---

## Self-Review
- Spec coverage: flag ✓(T1), session ✓(T1), worker+worktree ✓(T2), injection ✓(T3), attach/stop/list ✓(T4), quality ✓(T5). Events board / takeover / auto-cleanup = deferred (documented, YAGNI).
- Placeholder scan: none — all steps carry real code/commands.
- Type consistency: `HERDR_PANE[name]`, `HERDR_WS`, `be_new_session/has_session/new_worker/wait_ready/send/send_lead/attach/stop/ws_id` used consistently.
