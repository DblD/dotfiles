#!/usr/bin/env python3
"""Unit tests for the review: deliverable watch decision logic (no herdr needed).

Imports the Watcher class from ../scripts/claude-team-watch and exercises
maybe_spawn_reviewer / clear_review in isolation, monkeypatching the herdr-facing
methods (spawn_reviewer, sidebar, emit, manifest_write)."""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WATCH = os.path.join(HERE, "..", "scripts", "claude-team-watch")
# extensionless script: infer no loader, so name a SourceFileLoader explicitly
loader = importlib.machinery.SourceFileLoader("ctwatch", WATCH)
spec = importlib.util.spec_from_loader("ctwatch", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

fails = []


def check(name, cond):
    print(("  ok: " if cond else "  FAIL: ") + name)
    if not cond:
        fails.append(name)


def mk():
    w = mod.Watcher("team-x", "/tmp/none.sock", False, reap=False)
    w.project = tempfile.mkdtemp()
    os.makedirs(os.path.join(w.project, ".claude-team", "reviews"), exist_ok=True)
    calls = []
    w.spawn_reviewer = lambda label: (calls.append(label) or True)
    w.sidebar = lambda *a, **k: None
    w.emit = lambda *a, **k: None
    w.manifest_write = lambda doc: None
    return w, calls


def v_review(detail, ok=False, det_checks=None):
    checks = list(det_checks or [])
    checks.append({"type": "review", "ok": ok, "detail": detail})
    return {"met": False, "checks": checks}


# 1. pending + deterministic checks ok + not yet spawned -> spawn + hold
w, calls = mk()
agent = {"checks": {"review": {"persona": "p"}}}
took = w.maybe_spawn_reviewer("w1", "pane1", v_review("reviewer not yet run - spawn it"), agent, {})
check("pending+detOK -> spawns and holds", took is True and calls == ["w1"])
check("pending -> state reviewing", agent.get("state") == "reviewing")
check("pending -> review_spawned + pane recorded",
      agent.get("review_spawned") is True and agent.get("review_pane") == "pane1")

# 2. deterministic check still failing -> do NOT spawn (fix deterministic first)
w, calls = mk()
agent = {"checks": {"review": {"persona": "p"}}}
det_fail = [{"type": "check", "ok": False, "detail": "check failed"}]
took = w.maybe_spawn_reviewer("w2", "p", v_review("reviewer not yet run", det_checks=det_fail), agent, {})
check("det-check failing -> no spawn", took is False and calls == [])

# 3. already spawned -> no double spawn
w, calls = mk()
agent = {"checks": {"review": {"persona": "p"}}, "review_spawned": True}
took = w.maybe_spawn_reviewer("w3", "p", v_review("reviewer not yet run"), agent, {})
check("already-spawned -> no respawn", took is False and calls == [])

# 4. no review check present -> no spawn (plain deterministic worker unaffected)
w, calls = mk()
agent = {"checks": {"branch_pushed": "b"}}
took = w.maybe_spawn_reviewer("w4", "p",
                              {"met": False, "checks": [{"type": "branch_pushed", "ok": False, "detail": "x"}]},
                              agent, {})
check("no-review-check -> no spawn", took is False and calls == [])

# 5. a real verdict is present (PARTIAL, not 'not yet run') -> no spawn; it
#    flows through the normal nudge path carrying the reviewer's feedback
w, calls = mk()
agent = {"checks": {"review": {"persona": "p"}}}
took = w.maybe_spawn_reviewer("w5", "p", v_review("reviewer verdict PARTIAL - fix X"), agent, {})
check("verdict-present -> no spawn (nudges normally)", took is False and calls == [])

# 6. clear_review drops the stale verdict + resets the spawn flag
w, _ = mk()
vf = os.path.join(w.project, ".claude-team", "reviews", "w6.verdict")
with open(vf, "w") as fh:
    fh.write("VERDICT: PARTIAL\n")
agent = {"review_spawned": True}
w.clear_review("w6", agent)
check("clear_review removes stale verdict", not os.path.exists(vf))
check("clear_review resets spawn flag", agent.get("review_spawned") is False)

# 7. reviewer label -> parent derivation
check("reviewer label -> parent", "w7-review"[:-len("-review")] == "w7")

print("UNIT: %d fail" % len(fails))
sys.exit(1 if fails else 0)
