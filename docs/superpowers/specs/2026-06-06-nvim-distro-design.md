# nvim canonical config — design (Path A: grow from kickstart)

**Date:** 2026-06-06
**Status:** approved approach, pending spec review
**Part of:** keybinding-unification, Ring 1 (nvim) — see `docs/plans/2026-06-06-keybinding-unification.md`

## Decision

Make **kickstart.nvim** the single canonical neovim config across the Mac and the frame,
and grow it over time toward the niceties currently provided by LazyVim — adding each
plugin deliberately so it is understood and owned.

This was a fork between two borrowed configs: Mac = **LazyVim** (a distribution; ~338 lines
of own override code over an abstracted plugin), frame = **kickstart.nvim** (a single
~974-line `init.lua` explicitly *not* a distribution, meant to be read and owned).

**Why kickstart wins for this user:** the stated goal is to *become* a power user while
ramping into ownership ("both"). Kickstart makes ownership the default state rather than a
fight against a distro's grain. Both configs are borrowed (zero sunk cost), so this is the
cheapest moment to choose the learning path. Crucially, kickstart uses the **same plugin
manager as LazyVim (`lazy.nvim`)**, so every plugin LazyVim bundles (neo-tree, bufferline,
lualine, noice, snacks, flash, …) is adoptable later via a normal plugin spec — nothing is
off-limits, it is a floor to build up from, not a ceiling.

## Goal

One identical, owned nvim experience on both machines, sourced from the dotfiles repo,
live-editable on both, with LSPs installed the right way per platform (nix on the frame,
mason on the Mac) — and a clean pattern for growing the config plugin-by-plugin.

## Current state (verified 2026-06-06)

| | Mac | Frame |
|---|---|---|
| Config | LazyVim | kickstart.nvim |
| Source of truth | `~/.code/dotfiles/nvim` (dotfiles repo) | `~/nix-config/dotfiles/nvim` (nix-config repo) |
| `~/.config/nvim` | symlink → `~/.code/dotfiles/nvim` (live) | `mkOutOfStoreSymlink` → `~/nix-config/dotfiles/nvim` (live, via home-manager) |
| LSP install | mason | nix (`home/roles/dev.nix` packages; mason off) |
| Own tweaks | ~6 plugin overrides: go, conform, surround, codesnap, windsurf/codeium, example | none beyond stock kickstart |

The two machines today share *nothing* in nvim. Canonical home for the wider effort is the
**dotfiles repo**; nvim must move there too.

## Architecture

**Canonical config = `~/.code/dotfiles/nvim`** (in the dotfiles repo), holding the kickstart
config. Both machines resolve `~/.config/nvim` to it:

- **Mac:** already `~/.config/nvim → ~/.code/dotfiles/nvim`. No symlink change — it simply
  receives the new (kickstart) contents.
- **Frame:** `home/roles/dev.nix` changes its `mkOutOfStoreSymlink` target from
  `~/nix-config/dotfiles/nvim` to `~/.code/dotfiles/nvim`. The old in-nix-config copy is
  removed. Nix continues to provide LSP binaries; mason stays off on the frame.

```
~/.code/dotfiles/nvim/            (canonical, dotfiles repo)
  init.lua                        kickstart core, made platform-aware for LSP install
  lua/custom/plugins/             where grown-in plugins live, one file per concern
    go.lua, conform.lua, ...      Mac's prior tweaks, re-added as owned modules
  lazy-lock.json                  committed; pins versions for reproducibility on both
        │
        ├── Mac:   ~/.config/nvim ── symlink ──▶ (live edit)
        └── Frame: ~/.config/nvim ── mkOutOfStoreSymlink ──▶ (live edit; nix supplies LSPs)
```

### Component 1 — Canonical kickstart in dotfiles
Replace the LazyVim contents of `~/.code/dotfiles/nvim` with the frame's kickstart config.
Keep `lazy-lock.json` committed so both machines pin identical plugin versions. Split toward
the kickstart **modular** pattern (`lua/custom/plugins/*.lua`) as it grows, so the single
file does not become unmanageable.

### Component 2 — LSP platform switch (the one real reconciliation)
Kickstart installs LSPs via mason + mason-lspconfig + mason-tool-installer. The frame must
instead use nix-provided LSP binaries on `PATH`, mason disabled. Approach:

- Gate the mason install pieces behind a platform flag, e.g.
  `local nix_lsp = vim.env.NVIM_NIX_LSP == "1"` (set by the frame's home-manager via
  `home.sessionVariables`), defaulting to mason when unset (the Mac).
- When `nix_lsp` is true: skip mason's `ensure_installed`/auto-install, and call
  `lspconfig[server].setup(...)` directly for the servers nix puts on `PATH`.
- When false (Mac): kickstart's normal mason flow, unchanged.

This lives in explicit, readable lua (~10–15 lines) — visible, not buried in a distro's
opts-merge. It is the single platform-specific seam; everything else is identical.

### Component 3 — Re-add the Mac's tweaks as owned modules
The ~6 LazyVim overrides become normal kickstart plugin specs under `lua/custom/plugins/`:
go tooling, conform (formatting), surround, codesnap, and the AI completion (windsurf/
codeium). Each is added and understood individually — this is the first increment of the
"grow into ownership" practice, not a bulk port.

### Component 4 — Frame nix wiring change
In `home/roles/dev.nix` (on branch `feat/dbldframe-setup`):
- Repoint `xdg.configFile."nvim".source` `mkOutOfStoreSymlink` to
  `${config.home.homeDirectory}/.code/dotfiles/nvim`.
- Add `home.sessionVariables.NVIM_NIX_LSP = "1"` (drives Component 2).
- Remove the now-orphaned `~/nix-config/dotfiles/nvim` from the nix-config repo.
- Ensure the dotfiles repo is present on the frame at `~/.code/dotfiles` (already true).

## Data flow

Edit `~/.code/dotfiles/nvim/**` on either machine → change is live immediately (both are
symlinks to the working tree) → commit + push from one → `git pull` on the other →
identical. lazy.nvim reconciles plugins against the committed `lazy-lock.json`. No nix
rebuild is needed for nvim config edits on the frame (out-of-store symlink); a rebuild is
only needed for the one-time dev.nix wiring change and for LSP package changes.

## Error handling / recovery

- **Back up LazyVim first:** snapshot the current `~/.code/dotfiles/nvim` (git branch/tag or
  a copy) before overwriting, so the distro is recoverable if kickstart regresses something.
- **lazy-lock.json committed** → reproducible plugin set; a bad plugin update is revertible.
- **Frame nix change is rollback-safe:** `nixos-rebuild switch --rollback` restores the prior
  generation (including the old nvim symlink) if the rewiring misbehaves. nvim breaking does
  not affect input or the session.
- **Mac has no nix** → the Mac swap is pure file/symlink work, trivially reversible.

## Testing (parity = the test of done)

This is config reconciliation, so "tests" are behavioural parity checks:
- `nvim` opens clean on both (no errors), plugins install from the locked set.
- LSP attaches on both: mason-provided on Mac, nix-provided on the frame, for the same
  languages.
- Core motions/keymaps/leader behave identically on both machines.
- `diff` of the resolved `init.lua` on both machines is empty (same dotfiles source).

## Out of scope (deliberately)

- Re-adding the *full* LazyVim feature set up front — niceties are added incrementally, only
  when actually missed.
- LazyVim's "extras" framework / opts-merge system — not adopted; individual plugins are.
- Ring 2 (kanata) and later rings — separate work in the keybinding-unification plan.
- Aerospace/Hyprland WM-level keymaps — Ring 4, untouched here.

## Open implementation details (resolved during planning, not blockers)

- Exact platform-flag mechanism (env var via home-manager vs hostname check) — env var
  preferred for being explicit; confirm at implementation.
- Whether to keep kickstart single-file initially or split to modular immediately — lean
  modular once the first custom plugin is added.
