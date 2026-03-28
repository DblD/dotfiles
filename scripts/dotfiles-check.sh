#!/usr/bin/env bash
# dotfiles-check.sh — read-only, idempotent validation for a GNU Stow dotfiles repo

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STOW_TARGET="${HOME}/.config"

PASS_COUNT=0
FAIL_COUNT=0
INFO_COUNT=0

pass() {
  echo "PASS: $1"
  ((PASS_COUNT++))
}

fail() {
  echo "FAIL: $1 — $2"
  ((FAIL_COUNT++))
}

info() {
  echo "INFO: $1 — $2"
  ((INFO_COUNT++))
}

# ── 1. Stow symlinks ──────────────────────────────────────────────────────────
check_stow_symlinks() {
  local packages=(aerospace ghostty glow hammerspoon karabiner nix nushell nvim sketchybar skhd starship tmux tmuxinator wezterm zellij zsh)
  local all_ok=true

  for pkg in "${packages[@]}"; do
    local target="${STOW_TARGET}/${pkg}"
    if [[ ! -e "$target" && ! -L "$target" ]]; then
      fail "stow-symlinks" "${target} does not exist"
      all_ok=false
    elif [[ ! -L "$target" ]]; then
      fail "stow-symlinks" "${target} exists but is not a symlink"
      all_ok=false
    else
      local link_target resolved_target
      link_target="$(readlink "$target")"
      resolved_target="$(cd "$(dirname "$target")" && cd "$(dirname "$link_target")" && pwd)/$(basename "$link_target")"
      if [[ "$resolved_target" != "${REPO_DIR}"* ]]; then
        fail "stow-symlinks" "${target} points to ${resolved_target}, not into repo"
        all_ok=false
      fi
    fi
  done

  if $all_ok; then
    pass "stow-symlinks"
  fi
}

# ── 2. No orphaned links ──────────────────────────────────────────────────────
check_orphaned_links() {
  local orphans=()

  while IFS= read -r -d '' link; do
    local target
    target="$(readlink "$link")"
    # Resolve relative symlinks to absolute for comparison
    local resolved
    resolved="$(cd "$(dirname "$link")" && cd "$(dirname "$target")" 2>/dev/null && pwd)/$(basename "$target")" 2>/dev/null || resolved="$target"
    # Only check symlinks that point into the repo
    if [[ "$resolved" == "${REPO_DIR}"* ]] && [[ ! -e "$link" ]]; then
      orphans+=("$link")
    fi
  done < <(find "$STOW_TARGET" -maxdepth 2 -type l -print0 2>/dev/null)

  if [[ ${#orphans[@]} -eq 0 ]]; then
    pass "no-orphaned-links"
  else
    fail "no-orphaned-links" "orphaned symlinks: ${orphans[*]}"
  fi
}

# ── 3. Stow conflict-free ─────────────────────────────────────────────────────
check_stow_conflicts() {
  if ! command -v stow &>/dev/null; then
    fail "stow-conflict-free" "stow not found in PATH"
    return
  fi

  local output
  output="$(cd "$REPO_DIR" && stow -n . 2>&1)"

  if echo "$output" | grep -q "CONFLICT"; then
    fail "stow-conflict-free" "$(echo "$output" | grep CONFLICT | head -3)"
  else
    pass "stow-conflict-free"
  fi
}

# ── 4. SSH config linked ──────────────────────────────────────────────────────
check_ssh_config() {
  local ssh_config="${HOME}/.ssh/config"

  if [[ ! -L "$ssh_config" ]]; then
    fail "ssh-config-linked" "${ssh_config} is not a symlink"
  else
    local target resolved
    target="$(readlink "$ssh_config")"
    resolved="$(cd "$(dirname "$ssh_config")" && cd "$(dirname "$target")" 2>/dev/null && pwd)/$(basename "$target")" 2>/dev/null || resolved="$target"
    if [[ "$resolved" == "${REPO_DIR}/ssh/ssh-config" ]]; then
      pass "ssh-config-linked"
    else
      fail "ssh-config-linked" "${ssh_config} points to ${resolved}, expected ${REPO_DIR}/ssh/ssh-config"
    fi
  fi
}

# ── 5. Scripts linked ─────────────────────────────────────────────────────────
check_scripts_linked() {
  local -A script_links=(
    ["${HOME}/.local/bin/claude-team"]="${REPO_DIR}/scripts/claude-team"
    ["${HOME}/.bayport-vpn.sh"]="${REPO_DIR}/scripts/bayport-vpn.sh"
    ["${HOME}/.bayport-vpn-completion.bash"]="${REPO_DIR}/scripts/bayport-vpn-completion.bash"
  )
  local all_ok=true

  for link in "${!script_links[@]}"; do
    local expected="${script_links[$link]}"
    if [[ ! -L "$link" ]]; then
      fail "scripts-linked" "${link} is not a symlink"
      all_ok=false
    else
      local target resolved
      target="$(readlink "$link")"
      resolved="$(cd "$(dirname "$link")" && cd "$(dirname "$target")" 2>/dev/null && pwd)/$(basename "$target")" 2>/dev/null || resolved="$target"
      if [[ "$resolved" != "$expected" ]]; then
        fail "scripts-linked" "${link} points to ${resolved}, expected ${expected}"
        all_ok=false
      fi
    fi
  done

  if $all_ok; then
    pass "scripts-linked"
  fi
}

# ── 6. Brew drift ─────────────────────────────────────────────────────────────
check_brew_drift() {
  if ! command -v brew &>/dev/null; then
    info "brew-drift" "brew not found, skipping"
    return
  fi

  local output
  output="$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew bundle check --file="${REPO_DIR}/Brewfile" 2>&1)"
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    pass "brew-drift"
  else
    # Extract only the actionable line
    local missing
    missing="$(echo "$output" | tail -1)"
    fail "brew-drift" "$missing"
  fi
}

# ── 7. Git push state ─────────────────────────────────────────────────────────
check_git_push_state() {
  local unpushed
  unpushed="$(git -C "$REPO_DIR" log --oneline @{upstream}..HEAD 2>/dev/null)"

  if [[ -z "$unpushed" ]]; then
    pass "git-push-state"
  else
    local count
    count="$(echo "$unpushed" | wc -l | tr -d ' ')"
    fail "git-push-state" "${count} unpushed commit(s)"
  fi
}

# ── 8. Git dirty state ────────────────────────────────────────────────────────
check_git_dirty_state() {
  local status
  status="$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)"

  if [[ -z "$status" ]]; then
    pass "git-dirty-state"
  else
    local count
    count="$(echo "$status" | wc -l | tr -d ' ')"
    info "git-dirty-state" "${count} uncommitted change(s)"
  fi
}

# ── 9. Home bootstrap ─────────────────────────────────────────────────────────
check_home_bootstrap() {
  local zshenv="${HOME}/.zshenv"

  if [[ ! -f "$zshenv" ]]; then
    fail "home-bootstrap" "${zshenv} does not exist"
  elif ! grep -q "ZDOTDIR" "$zshenv"; then
    fail "home-bootstrap" "${zshenv} does not contain ZDOTDIR"
  else
    pass "home-bootstrap"
  fi
}

# ── 10. Remote reachable ──────────────────────────────────────────────────────
check_remote_reachable() {
  if git -C "$REPO_DIR" ls-remote origin HEAD &>/dev/null; then
    pass "remote-reachable"
  else
    fail "remote-reachable" "git ls-remote origin HEAD failed"
  fi
}

# ── Run all checks ────────────────────────────────────────────────────────────
check_stow_symlinks
check_orphaned_links
check_stow_conflicts
check_ssh_config
check_scripts_linked
check_brew_drift
check_git_push_state
check_git_dirty_state
check_home_bootstrap
check_remote_reachable

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "dotfiles-check: ${PASS_COUNT}/${TOTAL} passed, ${FAIL_COUNT} failed"

exit "$FAIL_COUNT"
