# Task: Reorganize ZSH Config into Modular conf.d Structure

## Context
This dotfiles repo is managed with GNU Stow, targeting `~/.config/`. The ZSH config lives in `zsh/` and uses `ZDOTDIR` pointing to `~/.config/zsh/`. You are on branch `tmux/overhaul`.

The current `zsh/.zshrc` is a 254-line monolith mixing aliases, env vars, PATH mods, completions, keybindings, functions, and tool initializations. Your job is to split it into a modular `zsh/conf.d/` directory structure.

## Current Files
- `zsh/.zshrc` — monolithic config (254 lines) — THIS IS YOUR PRIMARY INPUT
- `zsh/.zprofile` — login shell config (homebrew, nix, orbstack, jetbrains PATH)
- `zsh/work.zsh` — work-specific config (gitignored, do NOT modify)
- `zsh/work.zsh.example` — template for work.zsh

## What To Do

### 1. Create `zsh/conf.d/` directory and split `.zshrc` into these files:

**`conf.d/01-env.zsh`** — Environment variables:
- `LANG`, `EDITOR`, `GOPATH`, `KUBECONFIG`, `NIX_CONF_DIR`, `XDG_CONFIG_HOME`, `FZF_DEFAULT_COMMAND`
- `K8SLAB` related exports (`K8SLAB`, `KUBECONFIG_K8SLAB`, `TALOSCONFIG_K8SLAB`, `KUBECONFIG_K8SLAB_OIDC`)
- Do NOT include `STARSHIP_CONFIG` here — keep it with starship init in tools

**`conf.d/02-path.zsh`** — Consolidate ALL scattered PATH modifications into one file:
- From line 114: `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.vimpkg/bin:${GOPATH}/bin:$HOME/.cargo/bin`
- From line 117: `$HOME/.local/bin`
- From line 175: `/opt/homebrew/bin` (NOTE: this may be redundant with `.zprofile` brew shellenv — check and skip if so)
- From line 181: `/run/current-system/sw/bin` (Nix)
- Order them sensibly (most specific first)

**`conf.d/03-options.zsh`** — Shell options:
- `setopt prompt_subst`
- `zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'`

**`conf.d/04-completions.zsh`** — Completion system:
- `autoload bashcompinit && bashcompinit`
- `autoload -Uz compinit && compinit`
- `source <(kubectl completion zsh)`
- `complete -C '/usr/local/bin/aws_completer' aws`

**`conf.d/05-keybindings.zsh`** — All keybindings:
- Autosuggestion bindings (`^w`, `^e`, `^u`, `^L`, `^k`, `^j`)
- vi-mode: `bindkey jj vi-cmd-mode`

**`conf.d/06-aliases-git.zsh`** — Git aliases (lines 31-54):
- All `gc`, `gca`, `gp`, `gpu`, `gst`, `glog`, etc.

**`conf.d/07-aliases-docker.zsh`** — Docker aliases (lines 57-66):
- `dco`, `dps`, `dpa`, `dl`, `dx`, `dcup`, `dcdn`, `dcl`, `dcb`, `dcr`

**`conf.d/08-aliases-k8s.zsh`** — Kubernetes aliases AND related functions (lines 121-146):
- All `k`, `ka`, `kg`, `kd`, etc. aliases
- Functions: `podname()`, `kexf()`, `klf()`
- k8s-lab cluster aliases (lines 244-248): `klab`, `ko`, `k9s-lab`, `k9s-oidc`, `tc`

**`conf.d/09-aliases-devops.zsh`** — DevOps tool aliases:
- Terraform (lines 69-76)
- Helm (lines 78-83)
- Flux CD (lines 86-90)
- GitLab CLI (lines 93-96)
- YAML helpers (lines 223-224): `yj`, `jy`

**`conf.d/10-aliases-general.zsh`** — General/misc aliases:
- `la`, `cat` (bat), `v` (nvim), `cl` (clear), `http` (xh)
- Eza aliases: `l`, `lt`, `ltree`
- Suffix aliases: `alias -s md=glow`
- Directory navigation: `..`, `...`, etc.
- Config editing: `ez`, `et`, `en`, `edot`, `sz`
- Network: `myip`, `localip`, `ports`
- Misc: `mat`, `nm` (nmap), `server`, `rr` (ranger)

**`conf.d/11-aliases-security.zsh`** — Security/hacking aliases (lines 163-169):
- `gobust`, `dirsearch`, `massdns`, `fuzz`, `gf`
- `server`, `tunnel`

**`conf.d/12-functions.zsh`** — Shell functions:
- `ranger()` function (lines 183-197)
- Navigation: `cx()`, `fcd()`, `f()`, `fv()` (lines 201-204)
- Port utils: `port()`, `killport()` (lines 214-215)

**`conf.d/13-tools.zsh`** — Tool initializations (order matters):
- `source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh` (MUST come before keybindings that use autosuggest-*)
- `eval "$(starship init zsh)"` + `export STARSHIP_CONFIG=~/.config/starship/starship.toml`
- `[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh`
- `eval "$(zoxide init zsh)"`
- `eval "$(atuin init zsh)"`
- `eval "$(direnv hook zsh)"`
- `eval "$(mise activate zsh)"`

### 2. Rewrite `zsh/.zshrc` as a thin loader

```zsh
# Load config modules
for conf in "$ZDOTDIR/conf.d/"*.zsh(N); do
  source "$conf"
done

# Work-specific config (not tracked in git)
[ -f "$ZDOTDIR/work.zsh" ] && source "$ZDOTDIR/work.zsh"
```

That's it. Nothing else in `.zshrc`.

### 3. Cleanup items

- **Remove stale oh-my-zsh comment** (line 1 of current .zshrc: `# Path to your oh-my-zsh installation.`)
- **Remove duplicate Nix sourcing** — Nix daemon is sourced in `.zprofile` (lines 8-10) AND `.zshrc` (lines 227-230). Keep it ONLY in `.zprofile`. Do NOT put it in any conf.d file.
- **PATH `/opt/homebrew/bin`** — `.zprofile` already runs `eval "$(/opt/homebrew/bin/brew shellenv)"` which sets this. Do NOT duplicate in `02-path.zsh`.
- **Nix PATH** — `.zprofile` already adds `/nix/var/nix/profiles/default/bin`. Check if `/run/current-system/sw/bin` is also needed (it's for NixOS systems, keep it only if it exists on this macOS system — if unsure, keep it with a comment).

### 4. Important ordering note for `13-tools.zsh`

The autosuggestions plugin MUST be sourced BEFORE the keybindings in `05-keybindings.zsh` reference `autosuggest-*` widgets. Since `13-tools.zsh` loads AFTER `05-keybindings.zsh`, you need to handle this:

**Solution:** Move the autosuggestions source into `05-keybindings.zsh` (source the plugin, then immediately bind the keys). OR rename the tools file to `04-tools.zsh` and shift completions/keybindings to `05`/`06`. Pick whichever is cleaner — just make sure autosuggestions is sourced before its keybindings are set.

### 5. Do NOT modify these files
- `zsh/work.zsh` — gitignored, user's private work config
- `zsh/work.zsh.example` — leave as-is

## Acceptance Criteria
- [ ] `zsh/conf.d/` directory exists with all numbered files
- [ ] `zsh/.zshrc` is ONLY the thin loader (for loop + work.zsh source)
- [ ] Every line from the original `.zshrc` is accounted for in exactly one conf.d file (no duplication, no loss)
- [ ] Duplicate nix sourcing removed
- [ ] Stale oh-my-zsh comment removed
- [ ] Autosuggestions plugin sourced BEFORE its keybindings are used
- [ ] `.zprofile` unchanged (or only trivially adjusted)
- [ ] `work.zsh` and `work.zsh.example` untouched
- [ ] No new functionality added — this is a pure reorganization

## Status Updates

After each significant step, update your status file at `.claude-team/agents/zsh-reorg.md`:

```
# Agent: zsh-reorg
**Status:** In Progress | Blocked | Done
**Current task:** <what you're working on now>
**Completed:** <what you've finished>
**Blockers:** <any issues>
**Updated:** <timestamp>
```
