# Dotfiles symlinked on my machine

### Install with stow:
```bash
stow .
```

## VPN Tools

### Bayport VPN Script
Located in repo root (symlinked to home):
- `.bayport-vpn.sh` - Main VPN connection script
- `.bayport-vpn-completion.bash` - Bash completion
- `home/Documents/bayport-vpn-README.md` - Full documentation

#### Setup
```bash
# Scripts are already in dotfiles, just create symlinks:
cd ~
ln -sf .code/dotfiles/.bayport-vpn.sh .bayport-vpn.sh
ln -sf .code/dotfiles/.bayport-vpn-completion.bash .bayport-vpn-completion.bash
ln -sf .code/dotfiles/home/Documents/bayport-vpn-README.md Documents/bayport-vpn-README.md

# Add completion to your shell:
echo 'source ~/.bayport-vpn-completion.bash' >> ~/.zshrc
```

#### Usage
```bash
# Connect to VPN
~/.bayport-vpn.sh

# Check dependencies
~/.bayport-vpn.sh --check-deps

# See all options
~/.bayport-vpn.sh --help
```

See `home/Documents/bayport-vpn-README.md` for full documentation.
