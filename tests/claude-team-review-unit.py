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
    # register_review (the new non-blocking seam replacing the old inline await)
    # runs real: it only records the review in-flight (w.reviews[...]) and does no
    # I/O, so it never blocks the "loop" — that is exactly the property under test.
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
check("pending -> review registered in-flight (non-blocking, no inline wait)",
      "w1" in w.reviews and w.reviews["w1"]["pane"] == "pane1")

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

# 10. the event-loop tick reaches poll_reviews even with NO socket data waiting.
#     This is the non-blocking property: _tick is exactly what the loop calls each
#     iteration, so proving it polls on a select timeout proves the loop reaches the
#     poll on an idle system (verdicts land asynchronously, between pane events).
import socket as _socket
w, _ = mk()
ticks = []
w.poll_reviews = lambda: ticks.append(True)
srv, cli = _socket.socketpair()
try:
    d = w._tick(srv, 0.05)                 # nothing written to cli -> select times out
    check("idle tick polls with no socket data", d == b"" and ticks == [True])
    cli.sendall(b'{"e":1}\n')
    d2 = w._tick(srv, 0.5)                  # data present -> still polls, returns bytes
    check("busy tick polls and returns bytes", ticks == [True, True] and d2 == b'{"e":1}\n')
finally:
    srv.close()
    cli.close()

# 11. two reviews in-flight resolve INDEPENDENTLY — one verdict-ready, one still
#     pending. Resolving the ready one must not block, drop, or resolve the other.
#     protocol_on_finished is stubbed to record which parent it resolved (real state).
w, _ = mk()
resolved = []
w.pane_for_label = lambda l: None
w.collect = lambda *a, **k: True
w.manifest_mark = lambda *a, **k: None
w.protocol_on_finished = lambda label, pane: (resolved.append(label) or "inert")
w.register_review("ra", "pane-a")
w.register_review("rb", "pane-b")
check("two reviews in-flight simultaneously", set(w.reviews) == {"ra", "rb"})
with open(os.path.join(w.project, ".claude-team", "reviews", "ra.verdict"), "w") as fh:
    fh.write("VERDICT: VERIFIED\n")
w.poll_reviews()
check("verdict-ready review resolves its parent", resolved == ["ra"])
check("resolved review dropped from in-flight", "ra" not in w.reviews)
check("pending review survives (not blocked by the other)", "rb" in w.reviews)

# 12. a timed-out review still resolves its parent (never stranded) — continues
#     with the same watcher; rb never got a verdict, force its deadline into the past.
w.reviews["rb"]["deadline"] = 0.0
w.poll_reviews()
check("timed-out review still resolves its parent", resolved == ["ra", "rb"])
check("timed-out review dropped from in-flight", "rb" not in w.reviews)

# 13-17. workspace-liveness self-exit (F3): the tick confirms our workspace still
#     exists and exits once it's gone, but only after LIVENESS_GONE_QUORUM (2)
#     CONSECUTIVE 'gone' readings — one transient/partial reply must not kill a
#     live supervisor. Any error / malformed reply resets the counter, never exits.
import time as _time
def gone_watcher():
    w, _ = mk()
    w.ws = "wsX"; w._last_live_check = 0.0
    return w

# a single 'gone' observation does NOT exit (quorum not met)
w = gone_watcher()
w.rpc = lambda method=None, params=None: {"workspaces": [{"label": "team-other"}]}
try:
    w._maybe_check_alive(); first_survived = True
except SystemExit:
    first_survived = False
check("single 'gone' does not exit (quorum)", first_survived and w._gone_count == 1)
# a second CONSECUTIVE 'gone' -> exit(0)
w._last_live_check = 0.0
try:
    w._maybe_check_alive(); exited = False
except SystemExit as e:
    exited = (e.code == 0)
check("two consecutive 'gone' -> exit(0)", exited)

# a 'present' reply between resets the counter (no exit next time)
w = gone_watcher()
w.rpc = lambda method=None, params=None: {"workspaces": [{"label": "team-other"}]}
w._maybe_check_alive()                                   # gone_count -> 1
w._last_live_check = 0.0
w.rpc = lambda method=None, params=None: {"workspaces": [{"label": "team-x"}]}  # present
w._maybe_check_alive()
check("'present' resets the gone counter", w._gone_count == 0)

# malformed rpc results must not crash or exit; they reset. Two shapes:
#   (a) result isn't a dict -> .get raises AttributeError
#   (b) 'workspaces' isn't iterable -> the any(...) raises TypeError
for label, bad in (("non-dict result", ["not-a-dict"]),
                   ("non-iterable workspaces", {"workspaces": 42})):
    w = gone_watcher(); w._gone_count = 1
    w.rpc = (lambda b: (lambda method=None, params=None: b))(bad)
    try:
        w._maybe_check_alive(); safe = True
    except SystemExit:
        safe = False
    check("malformed reply (%s) -> no exit, resets" % label,
          safe and w._gone_count == 0)

# within the interval -> skip the RPC entirely (cheap)
w = gone_watcher(); w._last_live_check = _time.monotonic()
called = []
w.rpc = lambda *a, **k: (called.append(1), {"workspaces": []})[1]
w._maybe_check_alive()
check("within interval -> no liveness RPC", called == [])

# 16-19. review audit trail (F2): capture_review_artifact prefers the reviewer's
#     authored review file and folds it into results/; missing/empty -> False so
#     the caller falls back to the (flaky) pane scrape.
w, _ = mk()
rev_dir = os.path.join(w.project, ".claude-team", "reviews")
check("no authored review -> capture False", w.capture_review_artifact("w1") is False)
open(os.path.join(rev_dir, "w1.review.md"), "w").close()   # empty
check("empty authored review -> capture False", w.capture_review_artifact("w1") is False)
with open(os.path.join(rev_dir, "w1.review.md"), "w") as fh:
    fh.write("claim: tests pass -> ran suite, 0 fail\nconclusion: VERIFIED\n")
ok = w.capture_review_artifact("w1")
res = os.path.join(w.project, ".claude-team", "results", "w1-review.md")
body = open(res).read() if os.path.exists(res) else ""
check("authored review -> capture True", ok is True)
check("authored review lands in results",
      "claim: tests pass" in body and "conclusion: VERIFIED" in body)

# 20. F2 hardening: a non-UTF-8 review file must NOT crash the watcher (read uses
#     errors="replace"; a bare utf-8 read would raise UnicodeDecodeError, uncaught).
w, _ = mk()
with open(os.path.join(w.project, ".claude-team", "reviews", "w1.review.md"), "wb") as fh:
    fh.write(b"claim ok \xff\xfe raw-bytes\nconclusion: VERIFIED\n")
try:
    ok = w.capture_review_artifact("w1"); crashed = False
except Exception:
    ok, crashed = False, True
check("non-UTF-8 review captured, no crash", (not crashed) and ok is True)

# 21. F2 hardening: clear_review drops BOTH the verdict AND the review artifact,
#     so a stale review.md can't be captured as the next cycle's audit trail.
w, _ = mk()
rd = os.path.join(w.project, ".claude-team", "reviews")
open(os.path.join(rd, "w1.verdict"), "w").close()
open(os.path.join(rd, "w1.review.md"), "w").close()
w.clear_review("w1", {"review_spawned": True})
check("clear_review removes stale verdict", not os.path.exists(os.path.join(rd, "w1.verdict")))
check("clear_review removes stale review.md", not os.path.exists(os.path.join(rd, "w1.review.md")))

# 22-25. startup_reverify (item 4): verify workers ALREADY idle when watch started —
#     they emit no working->idle transition, so handle() never catches them. Skips
#     reviewers, already-collected/reaped workers, and non-idle panes.
w, _ = mk()
w.ws = "wsX"
w.manifest = lambda: {"agents": {
    "w1": {"checks": {"check": "true"}, "collected": False, "reaped": False},
    "w2": {"checks": {"check": "true"}, "collected": True,  "reaped": False}}}
w.rpc = lambda method=None, params=None: {"tabs": [
    {"label": "w1", "agent_status": "idle"},          # contracted, not collected -> verify
    {"label": "w2", "agent_status": "idle"},          # already collected -> skip
    {"label": "w3", "agent_status": "working"},        # not idle -> skip
    {"label": "rev1-review", "agent_status": "idle"}]} # reviewer -> skip
w.pane_for_label = lambda l: "pane-" + l
resolved = []
w.resolve_finished = lambda label, pane: resolved.append((label, pane))
w.startup_reverify()
check("startup: verifies the already-idle contracted worker", resolved == [("w1", "pane-w1")])
check("startup: skips collected / working / reviewer panes",
      not any(l in ("w2", "w3", "rev1-review") for l, _ in resolved))
check("startup: records last_status so a later event won't double-fire",
      w.last_status.get("pane-w1") == "idle")
# malformed rpc reply -> no crash, no work
w, _ = mk(); w.ws = "wsX"
w.manifest = lambda: {"agents": {}}
w.rpc = lambda *a, **k: ["not-a-dict"]
did = []
w.resolve_finished = lambda *a: did.append(1)
w.startup_reverify()
check("startup: malformed rpc reply -> no crash, no work", did == [])

print("UNIT: %d fail" % len(fails))
sys.exit(1 if fails else 0)
