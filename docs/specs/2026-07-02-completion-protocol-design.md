# Completion Protocol — Design Spec

**Date:** 2026-07-02 · **Status:** approved by Dario (brainstormed 2026-07-02) · **Target:** `claude-team` on the herdr backend (branch `feat/claude-team-herdr-backend`)

## Problem

Workers report their own completion (status files, final messages) and nothing verifies it. Observed failures: a worker's "done" summary while its branch was never pushed (human instruction "push it" then sat unsubmitted in the pane for an hour); status files stuck at "Starting" after real work finished. "Task completed" must become a machine-checked fact, not a vibe.

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

> DELIVERABLE CONTRACT: your task is complete only when (1) branch `agent/fix-build` is pushed to origin, (2) `npx tsc --noEmit` exits clean in your working directory. When all hold, state `DELIVERABLE MET`. If you cannot meet the contract, state `DELIVERABLE BLOCKED:` followed by the reason.

The `BLOCKED` sentinel lets the nudge loop distinguish "forgot" from "genuinely stuck".

At spawn, the session's resolved config path is recorded in the manifest header so `verify` and `watch` can re-read deliverables later without re-passing arguments.

## 2 · `claude-team verify <session> [agent] [--json]`

Pure, side-effect-free checker.

- Reads the config path from the manifest header (`.claude-team/manifest/<session>.json`); error exit 2 if the manifest or config is missing.
- For each agent with a `deliverable` (or the single named agent):
  - `branch_pushed`: `git -C <work_dir> ls-remote origin <ref>` non-empty.
  - `check`: run in the agent's `work_dir` with a **120 s timeout** (a hung build must not wedge the verifier); timeout counts as failed with detail "timeout".
- `work_dir` = the agent's worktree if `worktrees: true` (same resolution as spawn), else the project path.
- Output: human `PASS`/`FAIL` lines; `--json` emits one object per agent: `{"agent": "...", "met": bool, "checks": [{"type": "branch_pushed|check", "target": "...", "ok": bool, "detail": "..."}]}`.
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
                     did not meet its deliverable — needs you" → NEVER reap
```

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

## Out of scope (v1)

Session-level "all complete" gate on `stop`; deliverable types beyond the two; cross-machine manifests; retro-fitting deliverables into running sessions.
