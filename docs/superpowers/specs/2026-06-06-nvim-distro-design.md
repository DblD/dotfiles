# nvim canonical config — design (Path A: grow from kickstart)

**Date:** 2026-06-06
**Status:** approved approach, corrected after reading the actual configs
**Part of:** keybinding-unification, Ring 1 (nvim) — see `docs/plans/2026-06-06-keybinding-unification.md`

## Decision

Make **kickstart.nvim (master branch)** the single canonical neovim config across the Mac
and the frame, and grow it over time toward the niceties currently provided by LazyVim —
adding each plugin deliberately so it is understood and owned.

This was a fork between two borrowed configs: Mac = **LazyVim** (a distribution; ~338 lines
of own override code over an abstracted plugin, using the `lazy.nvim` plugin manager),
frame = **kickstart.nvim master** (a single ~974-line `init.lua` explicitly *not* a
distribution, meant to be read and owned, using Neovim's **built-in `vim.pack` manager**).

**Why kickstart wins for this user:** the stated goal is to *become* a power user while
ramping into ownership ("both"). Kickstart makes ownership the default state rather than a
fight against a distro's grain. Both configs are borrowed (zero sunk cost), so this is the
cheapest moment to choose the learning path. Crucially, kickstart-master uses Neovim's own
**built-in `vim.pack`** plugin manager — there is no third-party manager layer at all, which
is *more* native/owned than LazyVim's `lazy.nvim`. Adopting any plugin LazyVim bundles
(neo-tree, bufferline, lualine, noice, snacks, flash, …) later is still simple — a
`vim.pack.add { gh '...' }` call plus its `setup` — so nothing is off-limits; it is a floor
to build up from, not a ceiling.

> **Correction note (2026-06-06):** an earlier draft of this spec claimed kickstart and
> LazyVim share the `lazy.nvim` manager and referenced a `lazy-lock.json`. That was wrong:
> kickstart-master uses `vim.pack`, and there is no lock file (versions are pinned per-plugin
> via `version` ranges where it matters — e.g. `LuaSnip 2.*`, `blink.cmp 1.*`,
> treesitter `main`). The decision stands and is strengthened.

## Goal

One identical, owned nvim experience on both machines, sourced from the dotfiles repo,
live-editable on both, with LSPs installed the right way per platform (nix on the frame,
mason on the Mac) — and a clean pattern for growing the config plugin-by-plugin.

## Current state (verified 2026-06-06)

| | Mac | Frame |
|---|---|---|
| Config | LazyVim (`lazy.nvim`) | kickstart.nvim **master** (`vim.pack`) |
| Neovim version | **0.11.6** (too old for `vim.pack`) | 0.12.2 |
| Source of truth | `~/.code/dotfiles/nvim` (dotfiles repo) | `~/nix-config/dotfiles/nvim` (nix-config repo) |
| `~/.config/nvim` | symlink → `~/.code/dotfiles/nvim` (live) | `mkOutOfStoreSymlink` → `~/nix-config/dotfiles/nvim` (live, via home-manager) |
| LSP install | mason | nix (`home/roles/dev.nix` packages); kickstart sets `ensure_installed = {}` so mason installs nothing |
| Own tweaks | gopls settings, conform yaml→yamlfmt, mini.surround custom maps, codesnap, windsurf (disabled) | none beyond stock kickstart-master |

The two machines today share *nothing* in nvim. Canonical home for the wider effort is the
**dotfiles repo**; nvim must move there too. The frame's kickstart-master already includes
mini.nvim (surround/ai/statusline), which-key, gitsigns, telescope, blink.cmp, treesitter,
conform, fidget — so the gap from the Mac is small.

## Architecture

**Canonical config = `~/.code/dotfiles/nvim/init.lua`** (in the dotfiles repo), holding the
kickstart-master config. Both machines resolve `~/.config/nvim` to it:

- **Mac:** already `~/.config/nvim → ~/.code/dotfiles/nvim`. No symlink change — it receives
  the new (kickstart) contents. **Requires Neovim ≥ 0.12 first** (prerequisite upgrade).
- **Frame:** `home/roles/dev.nix` changes its `mkOutOfStoreSymlink` target from
  `~/nix-config/dotfiles/nvim` to `~/.code/dotfiles/nvim`, and sets the LSP-platform env var.
  The old in-nix-config copy is removed. Nix continues to provide LSP binaries.

```
~/.code/dotfiles/nvim/init.lua    (canonical, dotfiles repo, single file)
  SECTION 5 (LSP)   ── ensure_installed gated by $NVIM_NIX_LSP (mason on Mac, nix on frame)
  SECTION 5 servers ── gopls settings re-added (owned tweak)
  SECTION 6 conform ── yaml → yamlfmt re-added (owned tweak)
  SECTION N codesnap ── new vim.pack section (owned tweak)
        │
        ├── Mac (nvim ≥0.12):  ~/.config/nvim ── symlink ──▶ (live edit; mason installs LSPs)
        └── Frame (nvim 0.12.2): ~/.config/nvim ── mkOutOfStoreSymlink ──▶ (live edit; nix LSPs)
```

### Prerequisite — Neovim 0.12 on the Mac
The Mac is on 0.11.6; `vim.pack` needs 0.12+. Upgrade via Homebrew to match the frame's
0.12.x (version parity is desirable regardless). This must happen before the Mac can load
the kickstart config.

### Component 1 — Canonical kickstart in dotfiles
Copy the frame's `init.lua` to `~/.code/dotfiles/nvim/init.lua`, replacing the LazyVim
contents. Single file (kickstart-master's shape). Grown-in plugins are added as new `do ...
end` sections following kickstart's existing section convention — *not* a `lua/custom/plugins`
auto-loader (that is a lazy.nvim idiom; vim.pack uses explicit `vim.pack.add` calls).

### Component 2 — LSP platform switch (the one real reconciliation)
The frame's kickstart already sets `local ensure_installed = {}` so mason installs nothing
and nix is the source of truth. The *only* change needed is to make mason populate
`ensure_installed` **on the Mac** (which has no nix), gated by an env var:

```lua
-- SECTION 5, replacing `local ensure_installed = {}`
-- On the frame, $NVIM_NIX_LSP=1 (set by home-manager) → mason installs nothing; nix supplies
-- the binaries on PATH. Anywhere else (the Mac), mason installs the toolchain.
local ensure_installed = {}
if vim.env.NVIM_NIX_LSP ~= '1' then
  ensure_installed = {
    'lua-language-server', 'stylua',
    'gopls', 'pyright', 'typescript-language-server',
    'clangd', 'nixd', 'jdtls', 'rust-analyzer',
  }
end
require('mason-tool-installer').setup { ensure_installed = ensure_installed }
```

The `servers` table and the `vim.lsp.config/enable` loop stay identical on both — lspconfig
sets up each server regardless of where the binary came from. This is the single
platform-specific seam; everything else is byte-identical.

> Language *runtimes* on the Mac (go, node, python, jdk, rust) are assumed present or
> installed via Homebrew as needed — mason installs the LSP servers, not the runtimes. Out of
> scope to automate here; trim the Mac `ensure_installed` list to languages actually used.

### Component 3 — Re-add the Mac's tweaks (owned, inline)
Three concrete deltas folded into the canonical `init.lua`:
- **gopls settings** → expand `servers.gopls = {}` in SECTION 5 to carry the analyses/
  staticcheck/gofumpt settings from the Mac's `go.lua`.
- **conform yaml** → add `yaml = { 'yamlfmt' }` to `formatters_by_ft` and the `yamlfmt`
  formatter args in SECTION 6.
- **codesnap** → a new `do … end` section: `vim.pack.add { gh 'mistricky/codesnap.nvim' }`
  + `require('codesnap').setup { watermark = '' }`.
- **dropped:** `windsurf` (was `enabled = false` on the Mac — YAGNI). mini.surround custom
  leader maps are optional — kickstart-master already loads mini.surround with defaults; only
  re-add custom mappings if the defaults annoy.

### Component 4 — Frame nix wiring change
In `home/roles/dev.nix` (branch `feat/dbldframe-setup`):
- Repoint `xdg.configFile."nvim".source` `mkOutOfStoreSymlink` to
  `${config.home.homeDirectory}/.code/dotfiles/nvim`.
- Add `home.sessionVariables.NVIM_NIX_LSP = "1"` (drives Component 2).
- Remove the now-orphaned `~/nix-config/dotfiles/nvim/init.lua` from the nix-config repo.
- The dotfiles repo is already present on the frame at `~/.code/dotfiles`.

## Data flow

Edit `~/.code/dotfiles/nvim/init.lua` on either machine → change is live immediately (both
are symlinks to the working tree; `:source` or restart applies it) → commit + push from one →
`git pull` on the other → identical. `vim.pack` installs/updates plugins on launch
(`:help vim.pack`). No nix rebuild is needed for nvim config edits on the frame (out-of-store
symlink); a rebuild is only needed for the one-time dev.nix wiring change and for LSP package
changes.

## Error handling / recovery

- **Back up LazyVim first:** tag/branch the current `~/.code/dotfiles/nvim` (e.g. a
  `nvim-lazyvim-archive` git tag) before overwriting, so the distro is recoverable.
- **Frame nix change is rollback-safe:** `nixos-rebuild switch --rollback` restores the prior
  generation (including the old nvim symlink and pre-upgrade env) if the rewiring misbehaves.
  nvim breaking does not affect input or the session.
- **Mac has no nix** → the Mac swap is file/symlink work; the nvim upgrade is `brew`-revertible.
- **vim.pack** versions: pinned ranges where it matters; a bad plugin update is fixable by
  pinning a `version` or rolling the plugin dir.

## Testing (parity = the test of done)

This is config reconciliation, so "tests" are behavioural parity checks:
- `nvim` opens clean on both (no errors), plugins install via `vim.pack` on first launch.
- LSP attaches on both for the same languages: mason-provided on the Mac, nix-provided on the
  frame (where `ensure_installed` is empty).
- Core motions/keymaps/leader behave identically.
- `diff` of `~/.config/nvim/init.lua` resolved on both machines is empty (same dotfiles
  source).

## Out of scope (deliberately)

- Re-adding the *full* LazyVim feature set up front — niceties are added incrementally, only
  when actually missed.
- Automating Mac language *runtimes* (go/node/python/jdk/rust) — mason handles LSP servers;
  runtimes are the user's existing brew setup.
- Ring 2 (kanata) and later rings — separate work in the keybinding-unification plan.
- Aerospace/Hyprland WM-level keymaps — Ring 4, untouched here.

## Open implementation details (resolved during planning, not blockers)

- Whether the Mac `ensure_installed` carries all servers or a trimmed subset — start with the
  full list; trim to languages actually used on the Mac if installs are heavy.
- mini.surround custom mappings — re-add only if kickstart defaults are unsatisfactory.
