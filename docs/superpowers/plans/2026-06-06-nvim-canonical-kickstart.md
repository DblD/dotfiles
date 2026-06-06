# Canonical nvim (kickstart) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **This is a config-reconciliation plan, not a codebase.** There is no unit-test harness: each task's **Verify** step is its test, and the definition of done is *identical behaviour on both machines*.

**Goal:** Make kickstart.nvim (master, `vim.pack`) the single canonical neovim config in the dotfiles repo, running identically on the Mac and the frame, with LSPs from mason on the Mac and nix on the frame.

**Architecture:** One `~/.code/dotfiles/nvim/init.lua` (the frame's kickstart-master), symlinked on both machines. The single platform seam is `ensure_installed`, gated by a `$NVIM_NIX_LSP` env var (set by home-manager on the frame). The Mac's three real tweaks (gopls settings, conform yaml, codesnap) are folded in as owned, inline sections.

**Tech Stack:** neovim 0.12+ (`vim.pack`), kickstart.nvim master, mason (Mac), nix-provided LSPs (frame), home-manager `mkOutOfStoreSymlink`, git (dotfiles + nix-config).

**Machines:** Mac = `~/.code/dotfiles` (dotfiles repo, branch `feat/keybinding-unification`; no nix). Frame = `dbld@10.226.20.229`; nix-config Mac worktree at `~/.code/worktrees/dbldframe-setup` (branch `feat/dbldframe-setup`), frame deploy worktree at `~/nix-config-wt/feat/dbldframe-setup`; dotfiles on the frame at `~/.code/dotfiles`.

---

## Task 1: Prerequisite — upgrade the Mac's Neovim to 0.12+

The Mac is on 0.11.6; `vim.pack` needs 0.12+. The frame is on 0.12.2.

**Files:** none (Homebrew-managed system package).

- [ ] **Step 1: Check what Homebrew offers**

Run: `brew info neovim | head -3`
- If the stable version shown is `0.12.x` or newer → use Step 2a.
- If it is still `0.11.x` → use Step 2b (HEAD).

- [ ] **Step 2a: Upgrade to stable 0.12+**

```bash
brew upgrade neovim
```

- [ ] **Step 2b: (only if stable < 0.12) install HEAD**

```bash
brew install neovim --HEAD
```

- [ ] **Step 3: Verify**

Run: `nvim --version | head -1`
Expected: `NVIM v0.12.x` (or newer). Must be ≥ 0.12 or the rest of the plan cannot run on the Mac.

---

## Task 2: Archive the Mac's LazyVim config (recovery point)

Before overwriting, make the current LazyVim recoverable.

**Files:** dotfiles repo working tree at `~/.code/dotfiles`.

- [ ] **Step 1: Confirm clean tree on the right branch**

Run: `git -C ~/.code/dotfiles status -sb`
Expected: branch `feat/keybinding-unification`, no uncommitted changes under `nvim/`.

- [ ] **Step 2: Tag the current state**

```bash
git -C ~/.code/dotfiles tag nvim-lazyvim-archive
```

- [ ] **Step 3: Verify the tag exists**

Run: `git -C ~/.code/dotfiles tag -l nvim-lazyvim-archive`
Expected: prints `nvim-lazyvim-archive`. (Recovery later: `git checkout nvim-lazyvim-archive -- nvim`.)

---

## Task 3: Make the kickstart config canonical in the dotfiles repo

Replace the LazyVim contents of `~/.code/dotfiles/nvim` with the frame's single-file kickstart `init.lua`.

**Files:**
- Create/replace: `~/.code/dotfiles/nvim/init.lua`
- Delete: `~/.code/dotfiles/nvim/lua/` (tree), `lazy-lock.json`, `lazyvim.json`, `.neoconf.json`, `stylua.toml`, `LICENSE`, `README.md` (LazyVim's)

- [ ] **Step 1: Pull the frame's init.lua to a temp file**

```bash
rsync -a dbld@10.226.20.229:~/nix-config/dotfiles/nvim/init.lua /tmp/kickstart-init.lua
```

- [ ] **Step 2: Verify it transferred and is the kickstart file**

Run: `head -5 /tmp/kickstart-init.lua && wc -l /tmp/kickstart-init.lua`
Expected: the kickstart ASCII header comment; ~974 lines.

- [ ] **Step 3: Remove LazyVim files and install the kickstart init.lua**

```bash
cd ~/.code/dotfiles/nvim
git rm -r --quiet lua lazy-lock.json lazyvim.json .neoconf.json stylua.toml LICENSE README.md
cp /tmp/kickstart-init.lua init.lua
git add init.lua
```

- [ ] **Step 4: Verify the directory is now just the kickstart config**

Run: `ls -A ~/.code/dotfiles/nvim`
Expected: `init.lua` (plus `.gitignore` if it was present). No `lua/`, no `lazy-lock.json`.

- [ ] **Step 5: Commit**

```bash
git -C ~/.code/dotfiles commit -m "nvim: replace LazyVim with canonical kickstart-master init.lua"
```

---

## Task 4: Add the LSP platform-switch env var

Make mason install LSP servers on the Mac (no nix) while staying empty on the frame.

**Files:** Modify `~/.code/dotfiles/nvim/init.lua` (SECTION 5, the `ensure_installed` block).

- [ ] **Step 1: Make the edit**

Replace:

```lua
  local ensure_installed = {}

  require('mason-tool-installer').setup { ensure_installed = ensure_installed }
```

with:

```lua
  -- On the frame, home-manager sets $NVIM_NIX_LSP=1 → mason installs NOTHING; nix supplies
  -- the LSP/tool binaries on PATH. Anywhere else (the Mac, no nix), mason installs them.
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

- [ ] **Step 2: Verify the config still loads (Mac, env var unset → mason path)**

Run: `nvim --headless "+lua print(vim.env.NVIM_NIX_LSP or 'unset')" +qa`
Expected: prints `unset` and exits 0 (no lua error). On first interactive launch mason will begin installing the listed servers.

- [ ] **Step 3: Commit**

```bash
git -C ~/.code/dotfiles commit -am "nvim: gate mason ensure_installed on \$NVIM_NIX_LSP (mason on mac, nix on frame)"
```

---

## Task 5: Re-add the gopls settings (owned tweak)

**Files:** Modify `~/.code/dotfiles/nvim/init.lua` (SECTION 5, `servers` table).

- [ ] **Step 1: Make the edit**

Replace:

```lua
    gopls = {}, -- Go
```

with:

```lua
    gopls = { -- Go
      settings = {
        gopls = {
          analyses = { unusedparams = true },
          staticcheck = true,
          usePlaceholders = true,
          completeUnimported = true, -- auto-import
          gofumpt = true,
        },
      },
    },
```

- [ ] **Step 2: Verify config loads**

Run: `nvim --headless "+qa"`
Expected: exits 0, no lua error printed.

- [ ] **Step 3: Commit**

```bash
git -C ~/.code/dotfiles commit -am "nvim: re-add gopls analyses/staticcheck/gofumpt settings"
```

---

## Task 6: Re-add the conform yaml formatter (owned tweak)

**Files:** Modify `~/.code/dotfiles/nvim/init.lua` (SECTION 6, conform setup).

- [ ] **Step 1: Add the yaml formatter mapping**

Replace:

```lua
    formatters_by_ft = {
      -- rust = { 'rustfmt' },
      -- Conform can also run multiple formatters sequentially
      -- python = { "isort", "black" },
      --
      -- You can use 'stop_after_first' to run the first available formatter from the list
      -- javascript = { "prettierd", "prettier", stop_after_first = true },
    },
  }
```

with:

```lua
    formatters_by_ft = {
      yaml = { 'yamlfmt' }, -- K8s-friendly formatter
      -- rust = { 'rustfmt' },
      -- python = { "isort", "black" },
      -- javascript = { "prettierd", "prettier", stop_after_first = true },
    },
    formatters = {
      yamlfmt = {
        command = 'yamlfmt',
        args = { '-formatter', 'basic', '-indentless_arrays=true' },
      },
    },
  }
```

- [ ] **Step 2: Verify config loads**

Run: `nvim --headless "+qa"`
Expected: exits 0, no lua error.

- [ ] **Step 3: Commit**

```bash
git -C ~/.code/dotfiles commit -am "nvim: re-add conform yaml->yamlfmt formatter"
```

> Note: `yamlfmt` itself is not an LSP and is not in mason's `ensure_installed`. On the Mac
> install it via `brew install yamlfmt` (or `go install`); on the frame add `yamlfmt` to
> `dev.nix` packages if K8s yaml formatting is wanted there. Tracked, not blocking.

---

## Task 7: Full Mac verification

Prove the canonical config works end to end on the Mac before touching the frame.

**Files:** none (interactive verification).

- [ ] **Step 1: First launch — plugins install**

Run: `nvim` (interactive). Wait for `vim.pack` to clone plugins and mason to install the LSP servers (watch `:Mason` / `:checkhealth`).
Expected: no startup errors; `:checkhealth vim.pack` and `:checkhealth mason` are clean.

- [ ] **Step 2: LSP + format smoke test**

Open a Go file (`nvim /tmp/x.go`, paste a trivial `package main` + unused param), confirm gopls attaches (`:LspInfo` shows `gopls`). Open a YAML file and run `<leader>f` → yamlfmt reformats (after installing yamlfmt per Task 6 note).
Expected: LSP attaches; diagnostics appear; yaml formats.

- [ ] **Step 3: Confirm clean git state**

Run: `git -C ~/.code/dotfiles status -sb`
Expected: branch `feat/keybinding-unification`, clean (all nvim edits committed).

- [ ] **Step 4: Push canonical dotfiles**

```bash
git -C ~/.code/dotfiles push mwlab feat/keybinding-unification
```

---

## Task 8: Frame nix wiring — repoint symlink + set env var

Point the frame's nvim at the canonical dotfiles and turn on the nix-LSP flag.

**Files:** Modify `~/.code/worktrees/dbldframe-setup/home/roles/dev.nix`. Delete `~/.code/worktrees/dbldframe-setup/dotfiles/nvim/init.lua` (orphaned kickstart copy in nix-config).

- [ ] **Step 1: Repoint the nvim symlink target**

Replace:

```nix
  xdg.configFile."nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nix-config/dotfiles/nvim";
```

with:

```nix
  # nvim config is the canonical dotfiles kickstart (shared with the Mac), live-editable.
  xdg.configFile."nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.code/dotfiles/nvim";
```

- [ ] **Step 2: Add the LSP-platform env var**

After the `home.shellAliases = { ... };` block (or anywhere at the top level of the module), add:

```nix
  # nvim: tell kickstart to leave mason empty and use nix-provided LSPs on PATH.
  home.sessionVariables.NVIM_NIX_LSP = "1";
```

- [ ] **Step 3: Remove the orphaned in-nix-config kickstart**

```bash
git -C ~/.code/worktrees/dbldframe-setup rm dotfiles/nvim/init.lua
```

- [ ] **Step 4: Commit + push the nix-config branch**

```bash
git -C ~/.code/worktrees/dbldframe-setup commit -am "dbldframe: nvim from canonical dotfiles + NVIM_NIX_LSP=1; drop in-repo kickstart"
git -C ~/.code/worktrees/dbldframe-setup push origin feat/dbldframe-setup
```

- [ ] **Step 5: Verify the commit is pushed**

Run: `git -C ~/.code/worktrees/dbldframe-setup log --oneline -1 origin/feat/dbldframe-setup`
Expected: shows the commit from Step 4.

---

## Task 9: Frame deploy + verification

**Files:** none on the Mac; deploy runs on the frame.

- [ ] **Step 1: Pull both repos on the frame**

```bash
ssh dbld@10.226.20.229 'git -C ~/.code/dotfiles pull --ff-only && git -C ~/nix-config-wt/feat/dbldframe-setup pull --ff-only'
```
Expected: both fast-forward; the dotfiles pull brings the new `nvim/init.lua`.

- [ ] **Step 2: Build-verify the nix change (no switch yet)**

```bash
ssh dbld@10.226.20.229 'cd ~/nix-config-wt/feat/dbldframe-setup && nixos-rebuild build --flake .#dbldframe'
```
Expected: builds with no errors. (nvim config breaking input is impossible here — this only changes a symlink + env var.)

- [ ] **Step 3: Switch (detached, SSH is the recovery net)**

```bash
ssh dbld@10.226.20.229 'cd ~/nix-config-wt/feat/dbldframe-setup && setsid sudo nixos-rebuild switch --flake .#dbldframe'
```
Expected: switch completes. If anything is wrong: `sudo nixos-rebuild switch --rollback`.

- [ ] **Step 4: Verify the symlink now points at canonical dotfiles**

Run: `ssh dbld@10.226.20.229 'readlink -f ~/.config/nvim'`
Expected: resolves to `/home/dbld/.code/dotfiles/nvim`.

- [ ] **Step 5: Verify nvim runs with nix LSPs and mason empty**

```bash
ssh dbld@10.226.20.229 'NVIM_NIX_LSP=1 nvim --headless "+lua print(vim.env.NVIM_NIX_LSP)" "+qa"'
```
Expected: prints `1`. (Env var is permanent after next login via sessionVariables; the explicit prefix proves the gate now.) Then interactively (`ssh -t`): open a `.go`/`.lua` file, `:LspInfo` shows the nix-provided server attached, and `:Mason` shows nothing auto-installed.

---

## Task 10: Cross-machine parity check (definition of done)

**Files:** none.

- [ ] **Step 1: Diff the resolved config on both machines**

```bash
diff <(ssh dbld@10.226.20.229 'cat ~/.config/nvim/init.lua') ~/.config/nvim/init.lua
```
Expected: **no output** (identical canonical source on both).

- [ ] **Step 2: Behavioural parity**

On each machine: open nvim, confirm same leader, same core maps, mini.surround, telescope (`<leader>sf`), gitsigns, treesitter highlighting, LSP attach. Note any divergence and reconcile in `init.lua` (shared → both update on next pull).

- [ ] **Step 3: Update the living keymap reference + mark the ring done**

Append the kickstart core binds to `~/.code/dotfiles/docs/keymap.md` (create if absent), and tick **Ring 1 — nvim** in `~/.code/dotfiles/docs/plans/2026-06-06-keybinding-unification.md`. Commit both:

```bash
git -C ~/.code/dotfiles commit -am "docs: nvim keymap reference; Ring 1 nvim done"
git -C ~/.code/dotfiles push mwlab feat/keybinding-unification
```

---

## Task 11 (optional): codesnap

Defer unless you actually want code screenshots. codesnap.nvim ships a Rust binary that lazy.nvim built via `build = "make"`; `vim.pack` has no build hook, so it needs a manual build (or a release-binary download) after install.

**Files:** Modify `~/.code/dotfiles/nvim/init.lua` (new section near SECTION 9).

- [ ] **Step 1: Add a codesnap section**

```lua
-- ============================================================
-- codesnap — pretty code screenshots
-- ============================================================
do
  vim.pack.add { gh 'mistricky/codesnap.nvim' }
  require('codesnap').setup { watermark = '' }
end
```

- [ ] **Step 2: Build the native binary after first launch**

Run `nvim` once so `vim.pack` clones it, then:
```bash
make -C "$(nvim --headless "+lua io.write(vim.fn.stdpath('data'))" +qa 2>&1)/site/pack/core/opt/codesnap.nvim"
```
Expected: `make` produces the `generator` binary. If `make` fails, check codesnap's README for the current prebuilt-binary path. Verify with `:CodeSnap` on a visual selection.

- [ ] **Step 3: Commit**

```bash
git -C ~/.code/dotfiles commit -am "nvim: add codesnap (optional)"
```

---

## Self-review notes

- **Spec coverage:** Prereq nvim upgrade (Task 1) ↔ spec "Prerequisite"; canonical move (Task 3) ↔ Component 1; env-var switch (Task 4) ↔ Component 2; gopls/conform/codesnap (Tasks 5,6,11) ↔ Component 3; frame wiring (Task 8) ↔ Component 4; recovery (Task 2) ↔ spec recovery; parity (Task 10) ↔ spec testing.
- **Sequencing:** Mac is fully proven (Tasks 1–7) before the frame is touched (8–9), so a bad config is caught on the low-stakes machine first.
- **Risk:** none of this can break *input* (that's Ring 2/kanata). Worst case is nvim failing to open; the frame nix change is `--rollback`-safe and the Mac swap is tag-recoverable.
- **Identifier consistency:** the env var is `NVIM_NIX_LSP` everywhere (init.lua gate, dev.nix sessionVariable, frame verify). mason package names (e.g. `typescript-language-server`, `lua-language-server`) are mason's, matching the `servers` lspconfig names by mason-lspconfig's mapping.
- **Known non-blocking gaps:** `yamlfmt` runtime install (Task 6 note); Mac language runtimes assumed present (spec out-of-scope); codesnap build hook (Task 11).

---

## Execution log (2026-06-06) — completed

All tasks done; resolved `init.lua` identical on Mac & frame (both dotfiles @ `92e20cb`).
Deviations / findings worth recording:

- **Mac nvim upgrade:** 0.11.6 → 0.12.2 via `brew upgrade neovim` (now matches frame). vim.pack confirmed (not lazy.nvim) — spec corrected mid-flight.
- **Mac runtime deps the frame gets from nix:**
  - `tree-sitter` CLI — brew's `tree-sitter` is library-only (no bin); installed the CLI via `npm install -g tree-sitter-cli` (0.26.9, matches lib). Required or kickstart-master parser compile fails with ENOENT.
  - `yamlfmt` — NOT installed on the Mac yet (only needed for `<leader>f` on yaml). `brew install yamlfmt` when wanted.
- **nixd:** dropped from the Mac mason list (not in mason registry). Decision: **skip nixd on Mac entirely** (brew has no formula; would require installing Nix). `servers` table keeps `nixd={}` so it attaches on the frame (nix-provided) and would attach on the Mac if a binary ever appears.
- **mason residue:** the Mac's `~/.local/share/nvim/mason/` still holds LazyVim-era extras (docker/helm/hadolint/marksman/etc.). Harmless; left in place.
- **Frame git-auth saga (Task 9):** the frame can't reach `gitlab.mwlab.dev` over SSH (Cloudflare fronts 443 only — known, see brainlayer `manual-fbe1ee028d724f1f`). dotfiles pulled via its GitHub mirror (`origin`, SSH works). nix-config is mwlab-only and the frame's HTTPS token had vanished from `~/.git-credentials` → minted a fresh repo-scoped project access token (`dbldframe`, read+write, expires 2027-06-06) via `glab` on the Mac and wrote it to the frame (0600). **TODO: store that token in Bitwarden per bw-doctrine.**
- **Self-inflicted bug:** first frame commit (`6a83790`) used `git commit -m` without `-a`, so the `dev.nix` changes were left uncommitted; the frame deployed a no-op. Fixed with a follow-up commit `ac9e771` (no force-push). Lesson: stage explicitly or verify `git show HEAD` after committing config edits.

## Deferred decision — full nix on the Mac
Hitting nixd surfaced the bigger question: adopt nix-darwin + home-manager on the Mac (level 3)?
That would let nix provide LSPs on the Mac too and **collapse the entire `$NVIM_NIX_LSP` mason
split** (both machines `=1`, drop mason). Decided to **defer** — finish nvim on brew/mason now;
treat full-nix-on-Mac as its own brainstorm later. The current design degrades gracefully into it.
