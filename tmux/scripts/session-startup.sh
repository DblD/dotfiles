#!/usr/bin/env bash
# Auto-run nvim when a new bare session is created (zoxide/sessionx picks).
# Skips: team-* sessions (claude-team), tmuxinator sessions (multi-window),
# and sessions that already have something running.

session="$1"

# Skip claude-team sessions
[[ "$session" == team-* ]] && exit 0

# Give the session a moment to set up (tmuxinator creates extra windows)
sleep 0.3

# Skip if more than 1 window (tmuxinator layout)
windows=$(tmux list-windows -t "$session" 2>/dev/null | wc -l | tr -d ' ')
[[ "$windows" -gt 1 ]] && exit 0

# Skip if the pane already has a process running (not just shell)
pane_cmd=$(tmux display-message -t "$session" -p '#{pane_current_command}')
case "$pane_cmd" in
  bash|zsh|fish|sh) ;; # bare shell — proceed
  *) exit 0 ;;         # something already running — skip
esac

# Launch nvim with file picker
tmux send-keys -t "$session" 'nvim' Enter
