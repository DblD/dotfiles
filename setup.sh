#!/usr/bin/env bash
set -euo pipefail
echo "=== Dotfiles Setup ==="

cd "$(dirname "$0")"

# Stow configs to ~/.config
echo "Stowing configs..."
stow .

# SSH config (not stow-managed)
echo "Linking SSH config..."
mkdir -p ~/.ssh
ln -sf "$PWD/ssh/ssh-config" ~/.ssh/config

# Scripts
echo "Linking scripts..."
ln -sf "$PWD/scripts/bayport-vpn.sh" ~/.bayport-vpn.sh
ln -sf "$PWD/scripts/bayport-vpn-completion.bash" ~/.bayport-vpn-completion.bash

# Homebrew packages
if command -v brew &>/dev/null; then
  echo "Installing Homebrew packages..."
  brew bundle install
fi

# Shell bootstrap (manual files in ~)
echo ""
echo "Manual steps:"
echo "  1. Ensure ~/.zshenv contains: export ZDOTDIR=\"\$HOME/.config/zsh\""
echo "  2. Ensure ~/.zprofile contains: eval \"\$(/opt/homebrew/bin/brew shellenv)\""
echo "  3. Copy zsh/work.zsh.example to ~/.config/zsh/work.zsh and customize"
echo ""
echo "Done!"
