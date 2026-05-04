# Homebrew (sets PATH early) — guarded so the file works on Linux hosts too
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"

# Nix: put bin on PATH explicitly
export PATH="/nix/var/nix/profiles/default/bin:$PATH"

# Optional: source nix.sh for extra env (NIX_PATH, etc.)
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix.sh
fi

# OrbStack
source ~/.orbstack/shell/init.zsh 2>/dev/null || :

# JetBrains Toolbox
export PATH="$PATH:$HOME/Library/Application Support/JetBrains/Toolbox/scripts"
