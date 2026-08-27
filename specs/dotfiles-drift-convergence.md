# Chore: Dotfiles Drift Audit & Convergence

## Issue
N/A (GitLab CLI configured for mw-lab-gitlab.netbird.cloud but repo remotes are gitlab.com/github.com — skipped)

## Description

Establish a complete understanding of how the dotfiles repo is configured, deployed, and used — including drift between the repo, local machine, and remote origins. Produce a runnable validation script and converge the git state so everything is safely backed up and aligned.

**Principle: preflight check, validation, and confirmation before every destructive or state-changing step.**

---

## Current State (verified 2026-03-27)

### Stow Deployment: HEALTHY
- All 16 stow packages correctly symlinked from `~/.config/` → repo
- `.stowrc` properly excludes non-config dirs (nix-darwin, scripts, ssh, atuin, docs, Brewfile, setup.sh)
- Non-stow packages (ssh, scripts) deployed via `setup.sh` manual symlinks
- Home-dir bootstrap files (`~/.zshenv`, `~/.zshrc`, `~/.gitconfig`) intentionally separate

### Git State: AT RISK
- `tmux/overhaul`: 40 commits, 11 unpushed (VPN hardening), 6 uncommitted changes, 3 untracked files
- Worktrees: 2 local-only branches (`vpn-harden/resilience-hardening`, `vpn-harden/security-review`)
- `origin/master` has diverged from local master (`48b319f..a2a3673`)
- No Time Machine backup configured
- Reflog: 90-day default retention (local-only safety net)

### Risk Matrix

| Asset | Remote backup? | Recovery if disk dies? |
|-------|---------------|----------------------|
| First 29 commits (tmux/overhaul) | Yes | Yes |
| Last 11 commits (VPN hardening) | **No** | **No** |
| 6 uncommitted changes | **No** | **No** |
| 3 untracked files (claude-team) | **No** | **No** |
| Worktree branches | **No** | **No** |
| master | Yes | Yes |

---

## Relevant Files

| File | Role |
|------|------|
| `scripts/dotfiles-check.sh` | **CREATE** — runnable validation script |
| `.stowrc` | Reference |
| `setup.sh` | Reference — update `.stowrc` ignore for `specs` + `tests` |

## Step by Step Tasks

IMPORTANT: Execute in order, top to bottom. Every task has a preflight gate and a confirmation check.

---

### 1. Preflight — Secure All Unprotected Work
- **Task ID**: preflight-secure
- **Depends On**: none
- **Assigned To**: lead
- **Parallel**: false

**This is the safety net. Nothing else happens until this passes.**

**1a. Snapshot uncommitted state:**
```bash
# PREFLIGHT: verify what's dirty
git status --short
git diff --stat
```
- Confirm the 6 modified + 3 untracked files match expectations
- If anything unexpected appears → STOP, investigate

**1b. Stash uncommitted changes with a named stash:**
```bash
# PREFLIGHT: verify stash is empty (no conflicts)
git stash list

# ACTION: save dirty state
git stash push -u -m "preflight: uncommitted work before convergence (2026-03-27)"

# CONFIRM: working tree is clean
git status --short  # must be empty
git stash list      # must show the new stash
```

**1c. Push tmux/overhaul (11 unpushed commits):**
```bash
# PREFLIGHT: verify what we're pushing
git log --oneline origin/tmux/overhaul..HEAD
# should show exactly 11 commits

# ACTION: push
git push origin tmux/overhaul

# CONFIRM: remote matches local
git rev-parse HEAD
git rev-parse origin/tmux/overhaul
# both must match
```

**1d. Push worktree branches:**
```bash
# PREFLIGHT: list worktrees and their branches
git worktree list

# ACTION: push each
git push origin vpn-harden/resilience-hardening
git push origin vpn-harden/security-review

# CONFIRM: both exist on remote
git branch -r | grep vpn-harden
```

**Gate: ALL of the above must succeed before proceeding. If any push fails (auth, conflict, network), stop and resolve.**

---

### 2. Restore Working State
- **Task ID**: restore-working-state
- **Depends On**: preflight-secure
- **Assigned To**: lead
- **Parallel**: false

```bash
# PREFLIGHT: verify stash exists
git stash list | grep "preflight: uncommitted work"

# ACTION: restore
git stash pop

# CONFIRM: dirty files are back
git status --short
git diff --stat
# must match the original 6 modified + 3 untracked
```

---

### 3. Update Local Master
- **Task ID**: update-local-master
- **Depends On**: restore-working-state
- **Assigned To**: lead
- **Parallel**: false

```bash
# PREFLIGHT: confirm we're on tmux/overhaul, not master
git branch --show-current  # must say tmux/overhaul

# PREFLIGHT: check if master can fast-forward
git fetch origin master
git log --oneline master..origin/master
# review what's incoming — should be safe

# ACTION: fast-forward master without switching branches
git fetch origin master:master

# CONFIRM:
git log --oneline -3 master
git rev-parse master
git rev-parse origin/master
# both must match
```

**Gate: if fast-forward fails (diverged), STOP. Do NOT force-update. Report the divergence.**

---

### 4. Create Validation Script
- **Task ID**: create-validation-script
- **Depends On**: update-local-master
- **Assigned To**: worker
- **Parallel**: false

Create `scripts/dotfiles-check.sh` — a runnable script that validates the full dotfiles deployment at any time. Must be idempotent, read-only, and safe to run repeatedly.

**Checks to implement:**

| Check | Method | Pass condition |
|-------|--------|---------------|
| Stow symlinks | For each repo package dir not in `.stowrc` ignore list, verify `~/.config/<pkg>` is a symlink pointing to the repo | All links valid |
| No orphaned links | For each symlink in `~/.config/` pointing to the repo, verify target exists | Zero orphans |
| Stow conflict-free | `stow -n . 2>&1` | Zero CONFLICT lines |
| SSH config linked | `readlink ~/.ssh/config` | Points to repo `ssh/ssh-config` |
| Scripts linked | Check `~/.local/bin/claude-team`, `~/.bayport-vpn.sh` exist and point to repo | All present |
| Brew drift | `brew bundle check --file=Brewfile 2>&1` | Exit 0, or list missing |
| Git push state | `git log --oneline @{push}..HEAD 2>/dev/null` | Zero unpushed commits |
| Git dirty state | `git status --short` | Report (not fail) uncommitted |
| Home bootstrap | `~/.zshenv` exists and contains ZDOTDIR | Present |
| Remote reachable | `git ls-remote origin HEAD` | Exit 0 |

**Output format:** Each check prints `PASS: <name>` or `FAIL: <name> — <reason>`. Exit code = number of failures.

**Confirm:** Run the script after creation and verify output makes sense against known state.

---

### 5. Commit Uncommitted Work (requires user decision)
- **Task ID**: commit-uncommitted
- **Depends On**: create-validation-script
- **Assigned To**: lead
- **Parallel**: false

**STOP and present this decision to the user:**

The 6 modified files + 3 untracked span multiple concerns. Propose splitting into logical commits:

| Proposed commit | Files | Message |
|----------------|-------|---------|
| A: Terminal DX | `starship/starship.toml`, `tmux/tmux.conf`, `zsh/.zshrc` | `feat: starship two-line prompt, tmux env fix, bun + claude aliases` |
| B: Infra/tooling | `Brewfile`, `setup.sh`, `ssh/ssh-config` | `chore: add yq, claude-team setup, gitlab.mwlab.dev ssh host` |
| C: Claude team system | `.claude-team/`, `scripts/claude-team`, `tmuxinator/tmuxinator/teams.yml` | `feat: add claude-team worker dispatch system` |
| D: Validation | `scripts/dotfiles-check.sh`, `specs/dotfiles-drift-convergence.md` | `chore: add dotfiles validation script and convergence spec` |

**Wait for user to confirm, adjust, or override the split before committing.**

```bash
# PREFLIGHT per commit: show exactly what's being staged
git diff --cached --stat

# CONFIRM per commit: verify the commit looks right
git log --oneline -1
git diff --stat HEAD~1
```

---

### 6. Push and Final Validation
- **Task ID**: push-and-validate
- **Depends On**: commit-uncommitted
- **Assigned To**: lead
- **Parallel**: false

```bash
# PREFLIGHT: confirm everything is committed
git status --short  # should be empty (or only intentionally ignored files)

# ACTION: push
git push origin tmux/overhaul

# CONFIRM: run the validation script
bash scripts/dotfiles-check.sh

# CONFIRM: all checks pass, zero unpushed commits
```

---

## Validation Commands

```bash
# Validation script exists and is executable
test -x scripts/dotfiles-check.sh && echo "PASS: script exists"

# Validation script runs clean (or reports only known/expected items)
bash scripts/dotfiles-check.sh

# No unpushed commits on any local branch
git log --oneline --branches --not --remotes | wc -l | xargs -I{} test {} -eq 0 && echo "PASS: all pushed"

# Stow dry-run clean
cd /Users/dbld/.code/dotfiles && stow -n . 2>&1 | grep -c "CONFLICT" | xargs -I{} test {} -eq 0 && echo "PASS: stow clean"

# Both remotes reachable
git ls-remote origin HEAD >/dev/null 2>&1 && echo "PASS: origin reachable"
git ls-remote gitlab HEAD >/dev/null 2>&1 && echo "PASS: gitlab reachable"
```

## Abort & Recovery Procedures

### If push fails (task 1c/1d)
```bash
# Check auth
ssh -T git@github.com
# Check remote state
git remote -v
git ls-remote origin
# If network issue: retry. If auth issue: fix credentials first.
```

### If stash pop conflicts (task 2)
```bash
# Don't panic — stash is preserved on conflict
git stash list                    # stash is still there
git checkout -- .                 # discard failed merge attempt
git stash show -p stash@{0}      # inspect what's in the stash
# Apply file by file if needed:
git checkout stash@{0} -- <file>
```

### If master fast-forward fails (task 3)
```bash
# Do NOT force-update. Check what diverged:
git log --oneline --left-right master...origin/master
# Report to user for manual resolution
```

### If validation script reports failures (task 6)
```bash
# Re-run stow to fix broken symlinks
stow -D . && stow .
# Re-run setup.sh for manual symlinks
bash setup.sh
# Re-check
bash scripts/dotfiles-check.sh
```

### Nuclear option (full rollback to pre-convergence state)
```bash
# Find the stash (even if popped, reflog has it)
git reflog | grep "preflight"
# Reset to the commit before any convergence work
git reset --hard <pre-convergence-sha>
# Restore stash if needed
git stash apply stash@{N}
```

## Notes

- **Preflight-first**: every task starts with verification of preconditions before changing state
- **Confirm-after**: every action is followed by a check that it did what was expected
- **No silent failures**: if any gate fails, the plan stops and reports rather than continuing
- The `tmux/overhaul` branch name no longer reflects its content (it's a catch-all now) — consider renaming after convergence, as a separate chore
- `.stowrc` should add `specs` and `tests` to the ignore list so they don't get stowed
- Consider whether `bat` config, `~/.zshenv`, `~/.gitconfig` should be brought into the repo (separate chore)
- The worktree branches (`vpn-harden/*`) appear to already be merged into `tmux/overhaul` via commit `3e40e71` — after confirming, they can be cleaned up (separate chore)
