#!/usr/bin/env bash
set -euo pipefail
echo "=== Dotfiles Setup ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

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

# macOS file associations
if command -v duti &>/dev/null; then
  echo "Setting file associations..."
  duti -s dev.zed.Zed net.daringfireball.markdown all
fi

# --- Zen Browser ---
# Copy user.js into all Zen profiles (profile names are random per install)
install_zen_config() {
    local zen_dir=""

    case "$(uname -s)" in
        Darwin) zen_dir="$HOME/Library/Application Support/zen/Profiles" ;;
        Linux)  zen_dir="$HOME/.zen" ;;
        *)      echo "zen: unsupported platform, skipping"; return ;;
    esac

    if [ ! -d "$zen_dir" ]; then
        echo "zen: no profiles found at $zen_dir, skipping"
        return
    fi

    local count=0
    while IFS= read -r profile; do
        cp "$SCRIPT_DIR/zen/user.js" "$profile/user.js"
        count=$((count + 1))
        echo "zen: installed user.js → $(basename "$profile")"
    done < <(find "$zen_dir" -maxdepth 1 -type d -name "*.default*" -o -type d -name "*.Default*" 2>/dev/null)

    if [ "$count" -eq 0 ]; then
        echo "zen: no profiles matched, skipping"
    else
        echo "zen: configured $count profile(s) — restart Zen to apply"
    fi
}

install_zen_config

# Deploy Zen extension policies (managed settings for extensions)
install_zen_policies() {
    local zen_app=""

    case "$(uname -s)" in
        Darwin) zen_app="/Applications/Zen Browser.app/Contents/Resources" ;;
        Linux)
            for path in /usr/lib/zen /usr/lib/zen-browser /opt/zen-browser; do
                [ -d "$path" ] && zen_app="$path" && break
            done
            ;;
    esac

    if [ -z "$zen_app" ] || [ ! -d "$zen_app" ]; then
        echo "zen-policies: Zen Browser not found, skipping"
        return
    fi

    local dist_dir="$zen_app/distribution"
    mkdir -p "$dist_dir" 2>/dev/null || {
        echo "zen-policies: cannot create $dist_dir (may need sudo), skipping"
        return
    }

    # Build policies.json from extension config files
    python3 -c "
import json, glob, os

extensions = {}
for f in glob.glob(os.path.join('$SCRIPT_DIR', 'zen', 'extensions', '*.json')):
    with open(f) as fh:
        data = json.load(fh)
        extensions[data['id']] = data['settings']

policies = {'policies': {'3rdparty': {'Extensions': extensions}}}

with open('$dist_dir/policies.json', 'w') as out:
    json.dump(policies, out, indent=2)
"
    echo "zen-policies: installed policies.json → $dist_dir"
}

install_zen_policies

# Shell bootstrap (manual files in ~)
echo ""
echo "Manual steps:"
echo "  1. Ensure ~/.zshenv contains: export ZDOTDIR=\"\$HOME/.config/zsh\""
echo "  2. Ensure ~/.zprofile contains: eval \"\$(/opt/homebrew/bin/brew shellenv)\""
echo "  3. Copy zsh/work.zsh.example to ~/.config/zsh/work.zsh and customize"
echo ""
echo "Done!"
