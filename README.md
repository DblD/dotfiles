# Dotfiles

Managed with [GNU Stow](https://www.gnu.org/software/stow/) targeting `~/.config/`.

## Setup

```bash
git clone git@github.com:DblD/dotfiles.git ~/.code/dotfiles
cd ~/.code/dotfiles && ./setup.sh
```

### Manual prerequisites

Create these files in your home directory:

```bash
# ~/.zshenv
export ZDOTDIR="$HOME/.config/zsh"

# ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Copy and customize the work-specific config:
```bash
cp ~/.config/zsh/work.zsh.example ~/.config/zsh/work.zsh
```

## Structure

```
dotfiles/
├── .stowrc              # Stow config (target + ignore patterns)
├── Brewfile              # Homebrew packages
├── setup.sh              # Bootstrap script
│
│  Stowed to ~/.config/
├── aerospace/            # Window tiling
├── ghostty/              # Terminal
├── hammerspoon/          # macOS automation
├── karabiner/            # Keyboard remapping
├── nix/                  # Nix config
├── nushell/              # Nu shell
├── nvim/                 # Neovim (LazyVim)
├── sketchybar/           # Status bar
├── skhd/                 # Hotkey daemon
├── starship/             # Prompt
├── tmux/                 # Tmux
├── wezterm/              # Terminal
├── zellij/               # Terminal multiplexer
├── zsh/                  # Shell config
│
│  Not stowed
├── nix-darwin/           # macOS system defaults
├── scripts/              # Standalone scripts (symlinked by setup.sh)
├── ssh/                  # SSH config (symlinked by setup.sh)
└── docs/                 # Documentation
```

## Daily workflow

```bash
# Edit any config -- live immediately via stow symlinks
vim ~/.config/nvim/lua/plugins/go.lua

# Add a brew package
brew install foo
echo 'brew "foo"' >> ~/.code/dotfiles/Brewfile

# Apply macOS system defaults (rare)
darwin-rebuild switch --flake ~/.code/dotfiles/nix-darwin
```

## VPN

See `docs/bayport-vpn-README.md` for Bayport VPN script documentation.
