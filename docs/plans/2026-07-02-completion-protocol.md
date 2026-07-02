# Completion Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliverable contracts per agent, a pure `verify` subcommand, a watch-driven nudge loop (max 2, then escalate), and a session manifest — per `docs/specs/2026-07-02-completion-protocol-design.md`.

**Architecture:** `spawn` seeds a manifest (resolved work_dir + checks per agent) and injects the contract into worker prompts; `claude-team verify` is a pure checker reading the manifest; `claude-team-watch` gates collect/reap on verify, nudges via herdr `send-text`+`enter`, owns all manifest state, and mirrors protocol state to the sidebar via `report-metadata`.

**Tech Stack:** bash (scripts/claude-team, yq v4, python3 one-liners for JSON), python3 stdlib (scripts/claude-team-watch), tests in tests/claude-team-herdr-backend.sh (existing `check`/`check_eq` helpers; 33 existing checks must stay green).

**Conventions that bite:** commit messages must NOT contain the bareword "claude" outside `claude-team`-style tokens are fine in THIS repo (dotfiles hook allows "claude-team"); never touch live workspaces `bayport`/`ops-panel`/`skool-ops`/`team-skool-cli`; close every workspace a test creates; herdr RPC sockets are one-shot.

---

### Task 1: Deliverable parsing + contract injection in spawn

**Files:** Modify `scripts/claude-team` (cmd_spawn agent loop ~line 690 and ~717-760); Test `tests/claude-team-herdr-backend.sh`.

- [ ] **Step 1: Add failing assertions** — in the test file, extend the team.yaml heredoc's w1 agent and add checks after the existing dry-run assertions:

```bash
# in the heredoc, replace the w1 line with:
  - { name: w1, role: worker, mode: interactive, prompt: .claude-team/agents/w1.md,
      deliverable: { branch_pushed: agent/w1, check: "true" } }
# new assertions (after the runner checks):
check "contract injected note"    "$OUT" "deliverable contract injected for w1"
check "contract file is a temp copy (original untouched)" \
  "$(cat "$TMP/proj/.claude-team/agents/w1.md")" "you are worker one. reply OK."
check_eq "original prompt has no contract" \
  "$(grep -c 'DELIVERABLE CONTRACT' "$TMP/proj/.claude-team/agents/w1.md")" "0"
```

- [ ] **Step 2: Run — expect FAIL** — `bash tests/claude-team-herdr-backend.sh` → "contract injected note" missing.

- [ ] **Step 3: Implement.** In `cmd_spawn`, next to the `runner=`/`model=` reads (~line 690) add:

```bash
    local d_branch d_check
    d_branch=$(yq -r ".agents[$i].deliverable.branch_pushed // \"\"" "$config_file")
    d_check=$(yq -r ".agents[$i].deliverable.check // \"\"" "$config_file")
```

Add this function near `resolve_prompt` (~line 290):

```bash
# Append the deliverable contract to a COPY of the prompt file (never in place).
# Echoes the path to use (the copy, or the original when no deliverable).
inject_contract() { # $1=prompt_file $2=agent $3=branch_pushed $4=check
  local f="$1" name="$2" branch="$3" chk="$4"
  [[ -z "$branch" && -z "$chk" ]] && { echo "$f"; return; }
  local out; out=$(mktemp "${TMPDIR:-/tmp}/ct-contract-${name}.XXXXXX.md")
  [[ -n "$f" && -f "$f" ]] && cat "$f" > "$out"
  {
    echo ""
    echo "DELIVERABLE CONTRACT: your task is complete only when:"
    [[ -n "$branch" ]] && echo "- branch \`$branch\` is pushed to origin"
    [[ -n "$chk" ]] && echo "- \`$chk\` exits clean (0) in your working directory"
    echo "When all hold, state DELIVERABLE MET. If you cannot meet the contract,"
    echo "state DELIVERABLE BLOCKED: followed by the reason. Any claim about"
    echo "execution results (tests, builds, migrations) must include the raw"
    echo "command output - summaries don't count; a claim contradicted by its"
    echo "output is void."
  } >> "$out"
  echo "$out"
}
```

In the agent loop after `final_prompt_file` is fully resolved (immediately before the `--- Show assembled prompt` block ~line 740), add:

```bash
    if [[ -n "$d_branch" || -n "$d_check" ]]; then
      final_prompt_file=$(inject_contract "$final_prompt_file" "$name" "$d_branch" "$d_check")
      temp_files+=("$final_prompt_file")
      dim "  deliverable contract injected for $name"
    fi
```

Note: a deliverable agent with NO prompt (interactive) gets a contract-only prompt file — that is correct and intended (the contract seeds the session).

- [ ] **Step 4: Run — expect PASS** (all three new checks; prior 33 green).
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(claude-team): deliverable fields + contract injection at spawn"`

---

### Task 2: Manifest seeding at spawn

**Files:** Modify `scripts/claude-team` (cmd_spawn, before the agent loop; agent loop records work_dir); Test same file.

- [ ] **Step 1: Add failing live-gated test** (inside the existing `if command -v herdr … running` block, before the stop test). Uses a lead + an unknown-runner worker so NOTHING launches, but the workspace + manifest are real:

```bash
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
  "$CT" spawn "$TMP/mteam.yaml" --backend herdr >/dev/null 2>&1 || true
  Man="$MPROJ/.claude-team/manifest/team-mproj.json"
  check "manifest seeded"        "$(ls "$Man" 2>/dev/null)" "$Man"
  check "manifest has mw checks" "$(cat "$Man" 2>/dev/null)" '"branch_pushed": "agent/mw"'
  check "manifest agent pending" "$(cat "$Man" 2>/dev/null)" '"state": "pending"'
  WSID=$(herdr workspace list | yq -p json -r '.result.workspaces[] | select(.label=="team-mproj") | .workspace_id')
  [ -n "$WSID" ] && herdr workspace close "$WSID" >/dev/null 2>&1
```

- [ ] **Step 2: Run — expect FAIL** (no manifest file).

- [ ] **Step 3: Implement.** Add near `inject_contract`:

```bash
# Seed .claude-team/manifest/<session>.json (atomic; python3 for correct JSON).
# Watch owns all writes AFTER seeding. Called once per spawn, live mode only.
manifest_seed() { # $1=session $2=project_path $3=config_file
  $DRY_RUN && return 0
  local dir="$2/${TEAM_DIR}/manifest"
  mkdir -p "$dir"
  MS_SESSION="$1" MS_PROJECT="$2" MS_CONFIG="$3" MS_OUT="$dir/$1.json" python3 - <<'PYEOF'
import json, os, subprocess, tempfile
cfg = os.environ["MS_CONFIG"]
def yq(expr):
    return subprocess.run(["yq", "-r", expr, cfg], capture_output=True, text=True).stdout.strip()
n = int(yq(".agents | length") or 0)
agents = {}
for i in range(n):
    name = yq(f".agents[{i}].name")
    if yq(f'.agents[{i}].role // "worker"') == "lead":
        continue
    branch = yq(f'.agents[{i}].deliverable.branch_pushed // ""')
    check = yq(f'.agents[{i}].deliverable.check // ""')
    agents[name] = {"state": "pending", "nudges": 0, "verifications": [],
                    "collected": False, "reaped": False, "work_dir": "",
                    "checks": {"branch_pushed": branch, "check": check}}
doc = {"session": os.environ["MS_SESSION"], "config_path": os.path.abspath(cfg),
       "project": os.environ["MS_PROJECT"],
       "spawned_at": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
       "agents": agents}
out = os.environ["MS_OUT"]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out))
with os.fdopen(fd, "w") as f:
    json.dump(doc, f, indent=2)
os.replace(tmp, out)
PYEOF
}

manifest_set_workdir() { # $1=manifest $2=agent $3=work_dir  (spawn records resolved path)
  $DRY_RUN && return 0
  [[ -f "$1" ]] || return 0
  MW_MAN="$1" MW_AGENT="$2" MW_DIR="$3" python3 - <<'PYEOF'
import json, os, tempfile
man = os.environ["MW_MAN"]
doc = json.load(open(man))
a = doc["agents"].get(os.environ["MW_AGENT"])
if a is not None:
    a["work_dir"] = os.environ["MW_DIR"]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(man))
with os.fdopen(fd, "w") as f:
    json.dump(doc, f, indent=2)
os.replace(tmp, man)
PYEOF
}
```

In `cmd_spawn`, right after the session-exists block (`be_new_session` ~line 531), add:

```bash
  local manifest_file="${project_path}/${TEAM_DIR}/manifest/${session}.json"
  manifest_seed "$session" "$project_path" "$config_file"
```

In the agent loop, immediately after `work_dir` is final (after the worktree block, ~line 712):

```bash
    [[ "$role" != "lead" ]] && manifest_set_workdir "$manifest_file" "$name" "$work_dir"
```

- [ ] **Step 4: Run — expect PASS** (3 new checks; workspace closed by the test).
- [ ] **Step 5: Commit** — `git commit -am "feat(claude-team): manifest seeding at spawn (resolved work_dir + checks)"`

---

### Task 3: `claude-team verify <session> [agent] [--json]`

**Files:** Modify `scripts/claude-team` (new `cmd_verify` before `cmd_status` ~line 968; dispatch case + usage); Test same file.

- [ ] **Step 1: Add failing tests** (pure — no herdr needed; place before the live-gated block). Builds a fixture manifest + a local bare remote:

```bash
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
          "work_dir":"$VP","checks":{"branch_pushed":"agent/missing","check":"false"}}}}
J
VOUT=$(cd "$VP" && "$CT" verify vproj 2>&1); VRC=$?
check "verify: good agent PASS"   "$VOUT" "good: PASS"
check "verify: bad agent FAIL"    "$VOUT" "bad: FAIL"
check "verify: teaching detail"   "$VOUT" "not found on origin"
check_eq "verify: exit 1 on any unmet" "$VRC" "1"
VJ=$(cd "$VP" && "$CT" verify vproj good --json 2>&1); VJRC=$?
check "verify --json met"          "$VJ" '"met": true'
check_eq "verify: exit 0 all met"  "$VJRC" "0"
"$CT" verify nosuchsession >/dev/null 2>&1; check_eq "verify: exit 2 no manifest" "$?" "2"
```

- [ ] **Step 2: Run — expect FAIL** (`verify` unknown command).

- [ ] **Step 3: Implement `cmd_verify`** (insert before `cmd_status`):

```bash
# --- Verify deliverables (pure: reads manifest, writes nothing) ---
cmd_verify() {
  local session="${1:-}" only_agent="${2:-}" as_json=false
  [[ "${2:-}" == "--json" ]] && { as_json=true; only_agent=""; }
  [[ "${3:-}" == "--json" ]] && as_json=true
  [[ -z "$session" ]] && { red "usage: claude-team verify <session> [agent] [--json]"; exit 2; }
  [[ "$session" != team-* ]] && session="team-${session}"
  # find the manifest: search cwd upward conventions -> <cwd>/.claude-team/manifest,
  # else the project recorded alongside (spawn always writes under the project).
  local man=""
  for d in "$PWD" "$PWD/.."; do
    [[ -f "$d/${TEAM_DIR}/manifest/${session}.json" ]] && { man="$d/${TEAM_DIR}/manifest/${session}.json"; break; }
  done
  [[ -z "$man" ]] && { red "no manifest for $session (looked in ./${TEAM_DIR}/manifest/)"; exit 2; }
  CV_MAN="$man" CV_AGENT="$only_agent" CV_JSON="$as_json" python3 - <<'PYEOF'
import json, os, subprocess, sys
man = json.load(open(os.environ["CV_MAN"]))
only, as_json = os.environ["CV_AGENT"], os.environ["CV_JSON"] == "true"
worst = 0
for name, a in man["agents"].items():
    if only and name != only:
        continue
    checks, results, met = a.get("checks", {}), [], True
    wd = a.get("work_dir") or man.get("project") or "."
    b = checks.get("branch_pushed") or ""
    if b:
        r = subprocess.run(["git", "-C", wd, "ls-remote", "origin", b],
                           capture_output=True, text=True, timeout=60)
        ok = bool(r.stdout.strip())
        detail = ("branch %s is on origin" % b) if ok else \
                 ("branch %s not found on origin - push it (git push -u origin %s)" % (b, b))
        results.append({"type": "branch_pushed", "target": b, "ok": ok, "detail": detail})
        met &= ok
    c = checks.get("check") or ""
    if c:
        try:
            r = subprocess.run(["bash", "-c", c], cwd=wd, capture_output=True,
                               text=True, timeout=120)
            ok = r.returncode == 0
            tail = (r.stdout + r.stderr).strip().splitlines()[-1:] or [""]
            detail = ("`%s` exited 0" % c) if ok else \
                     ("`%s` exited %d in %s - last output: %s ; fix until it exits 0"
                      % (c, r.returncode, wd, tail[0][:160]))
        except subprocess.TimeoutExpired:
            ok, detail = False, "`%s` timed out after 120s - make it faster or fix the hang" % c
        results.append({"type": "check", "target": c, "ok": ok, "detail": detail})
        met &= ok
    if not checks.get("branch_pushed") and not checks.get("check"):
        met = True  # no deliverable declared -> vacuously met, protocol inert
    if as_json:
        print(json.dumps({"agent": name, "met": met, "checks": results}))
    else:
        print("%s: %s" % (name, "PASS" if met else "FAIL"))
        for r in results:
            print("  [%s] %s" % ("ok" if r["ok"] else "XX", r["detail"]))
    if not met:
        worst = 1
sys.exit(worst)
PYEOF
}
```

Add dispatch case next to `status)`/`watch)` (~line 1233): `verify) shift; cmd_verify "$@"; exit $? ;;` — check how `status`/`watch` are dispatched at ~1233-1236 and match exactly (they receive `"${2:-}"`; verify needs all args: use `verify) cmd_verify "${2:-}" "${3:-}" "${4:-}" ;;`). Add usage line: `  claude-team verify <session> [agent]  Check declared deliverables (pure, read-only)`.

- [ ] **Step 4: Run — expect PASS** (7 new checks).
- [ ] **Step 5: Commit** — `git commit -am "feat(claude-team): verify subcommand (pure deliverable checker, teaching errors)"`

---

### Task 4: Watch — manifest ownership + verify-gated policy loop

**Files:** Modify `scripts/claude-team-watch`; Modify `scripts/claude-team` (`cmd_watch` exports `CLAUDE_TEAM_BIN`); Test live-gated section.

- [ ] **Step 1: Add failing live test** (inside the herdr-gated block; drives the full nudge→complete cycle with `pane report-agent`, no real agent):

```bash
  # --- completion protocol: nudge loop (live) ---
  NP="$TMP/nproj"; mkdir -p "$NP/.claude-team/manifest"
  rm -f /tmp/ct-nudge-flag
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
  check "nudge text is teaching" "$(herdr pane read "$NPANE" --source recent --lines 10)" "ct-nudge-flag"
  check "manifest nudges=1" "$(cat "$NP/.claude-team/manifest/team-nudgetest.json")" '"nudges": 1'
  touch /tmp/ct-nudge-flag
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state working --seq 3 >/dev/null 2>&1
  sleep 1
  herdr pane report-agent "$NPANE" --source cttest --agent claude --state idle --seq 4 >/dev/null 2>&1
  sleep 4
  check "complete after flag" "$(cat "$NP/.claude-team/manifest/team-nudgetest.json")" '"state": "complete"'
  kill "$WPID" 2>/dev/null; rm -f /tmp/ct-nudge-flag
  herdr workspace close "$NWS" >/dev/null 2>&1
```

- [ ] **Step 2: Run — expect FAIL** (no nudge behavior).

- [ ] **Step 3: Implement in `scripts/claude-team-watch`.** (a) In `scripts/claude-team`'s `cmd_watch` (~1079), before exec'ing the python, add: `export CLAUDE_TEAM_BIN="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"`. (b) In the watcher add a manifest/protocol section after `reap_tab`:

```python
    # ---- completion protocol ------------------------------------------------
    MAX_NUDGES = 2

    def manifest_path(self):
        if not self.project:
            return None
        return os.path.join(self.project, ".claude-team", "manifest",
                            "%s.json" % self.session)

    def manifest(self):
        p = self.manifest_path()
        if not p or not os.path.exists(p):
            return None
        try:
            return json.load(open(p))
        except (OSError, json.JSONDecodeError):
            return None

    def manifest_write(self, doc):
        p = self.manifest_path()
        if not p:
            return
        import tempfile
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f, indent=2)
        os.replace(tmp, p)

    def run_verify(self, label):
        """Run `claude-team verify <session> <label> --json` in the project dir."""
        ct = os.environ.get("CLAUDE_TEAM_BIN", "claude-team")
        try:
            p = subprocess.run([ct, "verify", self.session, label, "--json"],
                               cwd=self.project, capture_output=True, text=True,
                               timeout=180)
        except (OSError, subprocess.TimeoutExpired):
            return None
        for line in p.stdout.splitlines():
            try:
                obj = json.loads(line)
                if obj.get("agent") == label:
                    return obj
            except json.JSONDecodeError:
                continue
        return None

    def sidebar(self, pane_id, text):
        """Best-effort protocol status on the worker's pane (never raises)."""
        try:
            subprocess.run([HERDR, "pane", "report-metadata", pane_id,
                            "--source", "claude-team-watch",
                            "--custom-status", text],
                           capture_output=True, timeout=10, check=False)
        except (OSError, subprocess.TimeoutExpired):
            pass

    def nudge(self, pane_id, text):
        """Guaranteed-submitted instruction to the worker (send-text + enter)."""
        try:
            subprocess.run([HERDR, "pane", "send-text", pane_id, text],
                           capture_output=True, timeout=10, check=False)
            subprocess.run([HERDR, "pane", "send-keys", pane_id, "enter"],
                           capture_output=True, timeout=10, check=False)
            return True
        except (OSError, subprocess.TimeoutExpired):
            return False

    def pane_blocked_sentinel(self, pane_id):
        try:
            p = subprocess.run([HERDR, "pane", "read", pane_id, "--source",
                                "recent-unwrapped", "--lines", "60"],
                               capture_output=True, text=True, timeout=10, check=False)
            return "DELIVERABLE BLOCKED" in p.stdout
        except (OSError, subprocess.TimeoutExpired):
            return False

    def protocol_on_finished(self, label, pane_id):
        """Verify-gated completion. Returns True when collect/reap may proceed."""
        doc = self.manifest()
        agent = (doc or {}).get("agents", {}).get(label)
        checks = (agent or {}).get("checks", {})
        if not agent or not (checks.get("branch_pushed") or checks.get("check")):
            return True  # no deliverable declared -> protocol inert
        self.sidebar(pane_id, "verifying…")
        v = self.run_verify(label)
        met = bool(v and v.get("met"))
        agent["verifications"].append(
            {"ts": datetime.now().isoformat(timespec="seconds"), "met": met,
             "detail": "; ".join(c["detail"] for c in (v or {}).get("checks", []))})
        if met:
            agent["state"] = "complete"
            self.manifest_write(doc)
            self.sidebar(pane_id, "✓ complete")
            self.emit("verified", "%s: deliverable met" % label, label=label)
            return True
        blocked = self.pane_blocked_sentinel(pane_id)
        if blocked or agent["nudges"] >= self.MAX_NUDGES:
            agent["state"] = "blocked" if blocked else "incomplete"
            self.manifest_write(doc)
            self.sidebar(pane_id, "✗ %s — needs you" % agent["state"])
            self.notify_blocked(label, pane_id)
            self.nudge(pane_id, "deliverable unmet after %d nudge(s) - escalated "
                       "to human; stand by" % agent["nudges"])
            self.emit("escalated", "%s: %s - needs you" % (label, agent["state"]),
                      label=label, state=agent["state"])
            return False  # never reap
        agent["nudges"] += 1
        agent["state"] = "working"
        self.manifest_write(doc)
        failing = "; ".join(c["detail"] for c in (v or {}).get("checks", [])
                            if not c.get("ok")) or "deliverable checks failed"
        self.nudge(pane_id, "DELIVERABLE UNMET: %s - finish the deliverable or "
                   "state DELIVERABLE BLOCKED: <reason>" % failing)
        self.sidebar(pane_id, "nudged ×%d" % agent["nudges"])
        self.emit("nudged", "%s: nudged (%d/%d): %s"
                  % (label, agent["nudges"], self.MAX_NUDGES, failing),
                  label=label, nudges=agent["nudges"])
        return False  # not complete yet; await next idle
```

(c) Wire into `handle()` — replace the finished branch:

```python
            elif status in ("idle", "done") and prev == "working":
                self.emit("finished", "%s: finished" % label, label=label, pane=pane)
                if self.protocol_on_finished(label, pane):
                    collected = self.collect(label, pane)
                    if self.reap and collected:
                        self.reap_tab(label, pane)
```

- [ ] **Step 4: Run — expect PASS** (5 new live checks; `python3 -m py_compile scripts/claude-team-watch` clean). Debounce note: the `status == prev` guard in `handle()` already suppresses duplicate idle events; the nudge sets manifest state and the next REAL working→idle re-enters the protocol.
- [ ] **Step 5: Commit** — `git commit -am "feat(claude-team): watch verify-gated nudge loop + manifest ownership + sidebar mirroring"`

---

### Task 5: status columns (DELIVERABLE / PROTOCOL)

**Files:** Modify `scripts/claude-team` (`cmd_status` ~968); Test.

- [ ] **Step 1: Failing test** (pure — reuse the Task 3 fixture, after its checks):

```bash
SOUT=$(cd "$VP" && "$CT" status vproj --backend herdr --dry-run 2>&1 || true)
# status is read-only; --dry-run not needed but harmless. vproj has no live
# workspace, so assert the manifest-driven fallback listing instead:
SOUT=$(cd "$VP" && "$CT" status vproj 2>&1 || true)
check "status shows PROTOCOL column" "$SOUT" "PROTOCOL"
check "status shows pending state"   "$SOUT" "pending"
```

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement.** In `cmd_status`, after the existing per-agent row assembly, load the manifest once per session and append two columns:

```bash
  # inside the per-session loop, before printing rows:
  local man="" 
  for d in "$PWD" "$PWD/.."; do
    [[ -f "$d/${TEAM_DIR}/manifest/${s}.json" ]] && man="$d/${TEAM_DIR}/manifest/${s}.json"
  done
  # per agent row: derive protocol + deliverable from the manifest (or "-")
  proto="-"; deliv="-"
  if [[ -n "$man" ]]; then
    proto=$(MAN="$man" A="$name" python3 -c 'import json,os;a=json.load(open(os.environ["MAN"]))["agents"].get(os.environ["A"],{});n=a.get("nudges",0);s=a.get("state","-");print(f"nudged x{n}" if s=="working" and n>0 else s)')
    deliv=$(MAN="$man" A="$name" python3 -c 'import json,os;a=json.load(open(os.environ["MAN"]))["agents"].get(os.environ["A"],{});v=a.get("verifications",[]);print("met" if (v and v[-1]["met"]) else ("unmet" if v else "-"))')
  fi
```

Extend the printf format with `DELIVERABLE` and `PROTOCOL` header columns and `$deliv` `$proto` values. **Important**: cmd_status's exact row-printing shape must be read first (it was written by a prior task at ~968-1078) — adapt the two-column addition to its actual loop variables; if the live workspace doesn't exist but a manifest does, print manifest-only rows (agent name from the manifest keys, STATE "-"). Add `--verify` flag: when present, run `cmd_verify "$s" >/dev/null 2>&1` per session first and reload the manifest (fresh verifications). Usage line update.

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat(claude-team): status DELIVERABLE + PROTOCOL columns from manifest"`

---

### Task 6: Full verification + docs + push

- [ ] **Step 1:** `bash tests/claude-team-herdr-backend.sh` — expect **all ~51 checks green** (33 prior + ~18 new).
- [ ] **Step 2:** `shellcheck -x -S error scripts/claude-team` → 0 errors; `python3 -m py_compile scripts/claude-team-watch` → clean.
- [ ] **Step 3:** Update `usage()` — verify + status --verify + deliverable config example:

```
Config format additions:
  agents:
    - name: backend
      deliverable:                 # optional completion contract
        branch_pushed: agent/backend   # verified via git ls-remote
        check: "npx tsc --noEmit"      # verified via exit code (120s timeout)
```

- [ ] **Step 4:** Live workspace hygiene check: `herdr workspace list` must show only `bayport`, `ops-panel`, `team-skool-cli` (+ any user-created).
- [ ] **Step 5: Commit + push** — `git commit -am "docs(claude-team): usage for completion protocol" && git push`

---

## Self-Review

- **Spec coverage:** config schema+injection→T1; manifest(+work_dir refinement)→T2; verify semantics/exit codes/timeout/teaching errors→T3; policy loop/nudges/BLOCKED/escalation-tell/sidebar/atomic manifest→T4; status columns+--verify→T5; edge cases: no-deliverable inert (T3 vacuous + T4 early return), debounce (existing status==prev guard + documented), watch-restart (manifest re-read every event via `manifest()`), tmux limitation (verify/status work; nudge herdr-only — unchanged, documented in usage). Not covered: none.
- **Placeholder scan:** Task 5 Step 3 intentionally instructs adapting to cmd_status's real loop shape (that code region was authored post-spec by a subagent; exact variable names must be read at implementation time) — acceptable as an explicit read-first instruction, not a TBD.
- **Type consistency:** manifest keys (`state/nudges/verifications/collected/reaped/work_dir/checks{branch_pushed,check}`) identical across T2 seed, T3 verify reader, T4 watch writer, T5 status reader. `CLAUDE_TEAM_BIN` set in T4(a), consumed in T4(b). Session `team-` prefix normalized in verify (T3) matching cmd_stop convention.
