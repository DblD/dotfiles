# Completion Protocol — Design Spec

**Date:** 2026-07-02 · **Status:** approved by Dario (brainstormed 2026-07-02) · **Target:** `claude-team` on the herdr backend (branch `feat/claude-team-herdr-backend`)

## Problem

Workers report their own completion (status files, final messages) and nothing verifies it. Observed failures: a worker's "done" summary while its branch was never pushed (human instruction "push it" then sat unsubmitted in the pane for an hour); status files stuck at "Starting" after real work finished. Lineage: the 2026-04-03 BCC sprint incident (brainlayer `manual-d9ef19ca79a24f49`) — a qa agent claimed "23/23 tests passing" three times while tests failed, and the Validation Lead had no tools to verify independently. That incident produced the "verification as a composable trait" idea this protocol now implements mechanically. "Task completed" must become a machine-checked fact, not a vibe.

## Decisions (locked with Dario)

1. **Enforcement:** auto-nudge the worker (max 2) with exactly what's missing, then escalate — mark INCOMPLETE + toast. Self-healing for "forgot a step", human for real failures.
2. **Deliverable types (v1):** `branch_pushed` and `check` (arbitrary shell command, exit 0 = met). `check` subsumes results-file-exists, tests-green, build-green.
3. **Contract injection:** spawn appends the deliverable contract to the worker's prompt; worker is told to state `DELIVERABLE MET` / `DELIVERABLE BLOCKED: <reason>`.
4. **State:** per-session manifest file written by watch (sole writer); doubles as audit trail.
5. **Architecture:** approach C — four units with single responsibilities: `verify` (pure check) · `watch` (policy + manifest) · `status` (view) · `spawn` (contract). `tell` is the nudge actuator; `--reap` becomes verification-gated.

## 1 · Config schema + contract injection

Per-agent in the existing team YAML; both fields optional. **No `deliverable` key = exactly today's behavior** (backward compatible).

```yaml
agents:
  - name: fix-build
    prompt: ~/.code/scratch/x/fix-build.md
    deliverable:
      branch_pushed: agent/fix-build   # git ls-remote origin <ref> non-empty
      check: "npx tsc --noEmit"        # exit 0, run in the agent's work_dir
```

Either or both sub-keys may be present. `spawn` appends to the assembled/v1 prompt:

> DELIVERABLE CONTRACT: your task is complete only when (1) branch `agent/fix-build` is pushed to origin, (2) `npx tsc --noEmit` exits clean in your working directory. When all hold, state `DELIVERABLE MET`. If you cannot meet the contract, state `DELIVERABLE BLOCKED:` followed by the reason. Any claim about execution results (tests, builds, migrations) must include the raw command output — summaries don't count; a claim contradicted by output is void.

The `BLOCKED` sentinel lets the nudge loop distinguish "forgot" from "genuinely stuck". The raw-output sentence is the `verified-output` trait from the 2026-04-03 incident, encoded into every contract.

At spawn, the session's resolved config path is recorded in the manifest header so `verify` and `watch` can re-read deliverables later without re-passing arguments.

## 2 · `claude-team verify <session> [agent] [--json]`

Pure, side-effect-free checker.

- Reads the config path from the manifest header (`.claude-team/manifest/<session>.json`); error exit 2 if the manifest or config is missing.
- For each agent with a `deliverable` (or the single named agent):
  - `branch_pushed`: `git -C <work_dir> ls-remote origin <ref>` non-empty.
  - `check`: run in the agent's `work_dir` with a **120 s timeout** (a hung build must not wedge the verifier); timeout counts as failed with detail "timeout".
- `work_dir` = the agent's worktree if `worktrees: true` (same resolution as spawn), else the project path.
- Output: human `PASS`/`FAIL` lines; `--json` emits one object per agent: `{"agent": "...", "met": bool, "checks": [{"type": "branch_pushed|check", "target": "...", "ok": bool, "detail": "..."}]}`.
- **Teaching-error contract** (from MEA: "the error message is the documentation"): every failing check's `detail` must state what failed, what was expected, and a concrete next step — e.g. `branch agent/fix-build not found on origin — push it (git push -u origin agent/fix-build)`. These strings feed the nudges verbatim, so the nudge is self-explanatory to the worker with no extra composition.
- Exit codes: 0 all met · 1 any unmet · 2 config/session/manifest not found.
- Writes nothing. Agents without a `deliverable` are reported `met: true` with empty checks (and skipped by watch's loop).

## 3 · Watch policy loop + manifest

On a worker's `done` (or idle-after-working) transition, watch now runs verify **before** collect/reap:

```
verify(agent)
├─ met            → collect results → manifest state=complete → reap if --reap
├─ unmet, nudges<2 → tell(session, agent, "<verify detail> — finish the deliverable
│                    or state DELIVERABLE BLOCKED: <reason>") → nudges+1 → await next idle
└─ unmet, nudges≥2 OR pane output contains "DELIVERABLE BLOCKED"
                   → manifest state=incomplete|blocked → toast "<session>: <agent>
                     did not meet its deliverable — needs you" → tell the worker
                     "deliverable unmet after N nudges — escalated to human; stand by"
                     (worker knows the loop ended; from MEA's builder-side escalation
                     message) → NEVER reap
```

**Sidebar protocol status** (from MEA's builder status-bar): watch mirrors protocol state onto the worker's pane via `herdr pane report-metadata <pane> --source claude-team-watch --custom-status "<text>"` at every transition — `verifying…`, `nudged ×1`, `✓ complete`, `✗ incomplete — needs you`, `blocked`. The herdr sidebar itself becomes the protocol board; no extra window needed. Best-effort: a failed report-metadata call never affects the policy loop.

- Nudge text quotes verify's failing `detail` verbatim so the worker sees exactly what's missing.
- Debounce: one in-flight verify per agent; an idle event during verification is ignored (the post-verify state decides the next step).
- `DELIVERABLE BLOCKED` detection: scan the collected pane output (`pane read` tail) at verification time.
- Agents with no deliverable follow today's path untouched (collect → reap if flagged).

**Manifest** `.claude-team/manifest/<session>.json` — watch is the **sole writer**, written atomically (tmp file + rename) so readers never see a torn file:

```json
{
  "session": "team-x", "config_path": "/abs/path/team.yaml", "spawned_at": "…",
  "agents": {
    "fix-build": {
      "state": "pending|working|complete|incomplete|blocked",
      "nudges": 1,
      "verifications": [{"ts": "…", "met": false, "detail": "branch agent/fix-build not on origin"}],
      "collected": true, "reaped": false
    }
  }
}
```

The manifest header is seeded by `spawn` (session, config_path, spawned_at, agents=pending); watch owns all subsequent writes. Watch restart re-reads the manifest — nudge counts and states survive.

## 4 · `status` changes

Two new columns, manifest-sourced: `DELIVERABLE` (met / unmet / `-` when none declared) and `PROTOCOL` (pending / nudged×N / complete / incomplete / blocked). `status --verify` additionally runs a live verify per agent instead of trusting the last manifest entry. Sessions without a manifest render exactly as today.

## Edge cases

- **No deliverable declared** → entire protocol inert; zero behavior change.
- **Watch not running** → manifest goes stale; `status --verify` and manual `claude-team verify` still give live truth.
- **tmux backend** → `verify` and `status` work (they don't need herdr); nudging requires watch, which is herdr-only — documented limitation.
- **Worker idle during nudge composition** → nudges are `tell`-delivered (send-text + enter), which is safe into an idle TUI prompt; they appear in the pane like human instructions, fully visible/auditable.
- **Duplicate idle events** (herdr replays / flapping) → nudge increments only after a completed verify; debounce prevents double-nudging on one idle.

## Testing

1. **verify (pure):** fixture repo with a fake `origin` (local bare remote); cases: branch present/absent, check true/false/timeout, no-deliverable agent, missing manifest (exit 2), `--json` shape.
2. **Nudge loop (live, report-agent-driven like the reap test):** throwaway workspace; deliverable = `check: "test -f /tmp/flag"`. Drive working→idle → assert `tell` nudge text lands in the pane and manifest `nudges:1`; create the flag; drive idle again → assert state=complete. Then exhaust nudges → assert incomplete + no reap.
3. **End-to-end (manual smoke):** real worker with a deliberately unmeetable `branch_pushed`, confirm 2 nudges then toast + INCOMPLETE.
4. Existing 33 checks stay green; shellcheck/py_compile clean.

## Reserved v2 seam: the `review:` deliverable (agent-as-verifier)

Design source: the **Pi Verifier Agent** system at `~/.code/learning/tac/MEA/the-verifier-agent-system/` (two-agent observer: interactive Builder + input-locked read-only Verifier; on every builder stop the verifier re-checks the work via allowlisted deterministic scripts, prompts corrective feedback back, max 3 loops, then escalates to human). Our v1 is that system's mechanical skeleton on herdr primitives — watch=verifier harness, `verify`=domain script, `tell`=`verifier_prompt`, nudge cap=max_loops, toast=escalation.

The schema **reserves** a third deliverable key, not implemented in v1:

```yaml
deliverable:
  review:
    persona: .claude-team/verifiers/code-review.md   # read-only reviewer role card
    runner: pi                                       # runner-aware — local model or codex for diversity
```

v2 semantics (from the MEA design, adapted to herdr): watch spawns the reviewer in its own tab; the reviewer reads the worker's transcript — the herdr Claude integration already reports `agent_session_path`, which is exactly the session JSONL the MEA verifier consumes; it atomizes claims from the worker's original prompt + contract, runs read-only checks, and emits a `VERDICT:` line with a **CONFIDENCE grade** (PERFECT / VERIFIED / PARTIAL / FEEDBACK / FAILED) that watch treats as one more check (PARTIAL and below = unmet). Reviewer is read-only by architecture (persona tool allowlist + check-command-only bash), un-promptable by hand — gaps are fixed by editing the persona/scripts, so verification engineering compounds. Corrections flow through the same `tell` nudge path as v1.

## Out of scope (v1)

The `review:` deliverable above (reserved, v2); session-level "all complete" gate on `stop`; deliverable types beyond the two; cross-machine manifests; retro-fitting deliverables into running sessions.
