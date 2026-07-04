#!/usr/bin/env python3
"""Unit tests for the review: deliverable watch decision logic (no herdr needed).

Imports the Watcher class from ../scripts/claude-team-watch and exercises
maybe_spawn_reviewer / clear_review in isolation, monkeypatching the herdr-facing
methods (spawn_reviewer, sidebar, emit, manifest_write)."""
import importlib.machinery
import importlib.util
import json
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
    w.await_and_finish_review = lambda *a, **k: None  # don't block/poll in unit tests
    return w, calls


def v_review(detail, ok=False, det_checks=None, state="pending"):
    checks = list(det_checks or [])
    checks.append({"type": "review", "ok": ok, "detail": detail, "review_state": state})
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
check("det-check failing -> no spawn (end-of-task mode)", took is False and calls == [])

# 2b. per_turn: reviewer DOES spawn even while deterministic checks fail (continuous review)
w, calls = mk()
agent = {"checks": {"review": {"persona": "p", "per_turn": True}}}
took = w.maybe_spawn_reviewer("pt", "p", v_review("reviewer not yet run", det_checks=det_fail), agent, {})
check("per_turn -> spawns despite failing deterministic check", took is True and calls == ["pt"])

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
took = w.maybe_spawn_reviewer("w5", "p", v_review("reviewer verdict PARTIAL - fix X", state="verdict"), agent, {})
check("verdict-present -> no spawn (nudges normally)", took is False and calls == [])

# 5b. a malformed verdict (file present, no valid grade) -> not pending -> no spawn
w, calls = mk()
agent = {"checks": {"review": {"persona": "p"}}}
took = w.maybe_spawn_reviewer("w5b", "p", v_review("no valid VERDICT line", state="malformed"), agent, {})
check("malformed verdict -> no spawn", took is False and calls == [])

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

# 8. is_our_reviewer: true ONLY for a parent we put under review (guards a
#    legitimately-named worker like `security-review` from being mis-routed)
w, _ = mk()
mdir = os.path.join(w.project, ".claude-team", "manifest")
os.makedirs(mdir, exist_ok=True)
with open(os.path.join(mdir, "team-x.json"), "w") as fh:
    json.dump({"agents": {"w8": {"review_spawned": True}, "plain": {}}}, fh)
check("is_our_reviewer: spawned parent -> true", w.is_our_reviewer("w8-review") is True)
check("is_our_reviewer: unknown parent -> false", w.is_our_reviewer("nope-review") is False)
check("is_our_reviewer: parent without review_spawned -> false",
      w.is_our_reviewer("plain-review") is False)

# 9. verdict_ready: the cross-model completion signal — true only with a valid VERDICT line
w, _ = mk()
rd = os.path.join(w.project, ".claude-team", "reviews")
with open(os.path.join(rd, "vr_ok.verdict"), "w") as fh:
    fh.write("VERDICT: VERIFIED\nfeedback: none\n")
with open(os.path.join(rd, "vr_bad.verdict"), "w") as fh:
    fh.write("looks good to me, but no verdict line here\n")
check("verdict_ready: valid VERDICT line -> true", w.verdict_ready("vr_ok") is True)
check("verdict_ready: file without VERDICT -> false", w.verdict_ready("vr_bad") is False)
check("verdict_ready: absent file -> false", w.verdict_ready("vr_missing") is False)

print("UNIT: %d fail" % len(fails))
sys.exit(1 if fails else 0)
