# Keybinding Unification Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to work this task-by-task. Steps use checkbox (`- [ ]`) syntax. This is a **config-reconciliation** plan, not a codebase — "verify" steps replace unit tests: the test of done is *identical behaviour on both machines*.

**Goal:** Make the canonical terminal-stack interaction (nvim, tmux, vim, and the Esc/Ctrl/leader substrate that feeds them) one identical muscle memory across the **Mac** (macOS) and **dbldframe** (NixOS/Hyprland) — then expand outward ring by ring.

**Architecture:** One canonical source of truth for terminal-stack configs (the **dotfiles repo**), symlinked on both machines; tmux + nvim reconciled to a single config each; the modifier substrate unified via **kanata** (retiring keyd on Linux and Karabiner remaps on macOS), starting minimal (just Caps→Esc/Ctrl). Build in rings from the editor outward; defer the WM and app-level layers.

**Tech stack:** git (dotfiles), symlinks/stow (macOS) + nix home-manager `mkOutOfStoreSymlink` (frame), kanata, Karabiner DriverKit VirtualHIDDevice (kanata's macOS backend), tmux + tpm, neovim, vim-tmux-navigator, WezTerm.

**Machines:** Mac = `~/.code/dotfiles` (no nix). Frame = `dbld@10.226.20.229`, nix-config at `~/nix-config`, desktop work on branch `feat/dbldframe-setup`.

**Locked decisions:**
1. **Canonical home** = the dotfiles repo (`~/.code/dotfiles`); both machines symlink it.
2. **Caps Lock** = tap→Esc, hold→Ctrl (terminal-first). The WM **Super** mod returns to the **physical Super key**; a home-row WM mod is revisited in Ring 4.
3. **Terminal** = WezTerm on both; retire alacritty on the frame.

---

## Ring 0 — One canonical config home

*Precondition for everything else: kill the "two repos" drift so nvim/tmux/wezterm have a single source both machines read.*

### Task 0.1: Get the dotfiles repo onto the frame

**Files:** Frame: clone target `~/.code/dotfiles` (mirror the Mac's path so symlinks are portable).

- [ ] **Confirm the frame can read the dotfiles repo remote.** On the frame: `git ls-remote <dotfiles-remote>`. (If the dotfiles repo is local-only on the Mac with no remote, first push it to gitlab.mwlab.dev, or `rsync` it to the frame as a stop-gap.)
- [ ] **Clone it on the frame at the same path as the Mac:** `git clone <dotfiles-remote> ~/.code/dotfiles` (path parity means `mkOutOfStoreSymlink` targets match the Mac).
- [ ] **Verify:** `ls ~/.code/dotfiles/nvim ~/.code/dotfiles/tmux ~/.code/dotfiles/wezterm` on the frame all exist.

### Task 0.2: Reconcile the two nvim configs into the canonical one

**Files:** Mac `~/.code/dotfiles/nvim/` (canonical) vs Frame `~/nix-config/dotfiles/nvim/` (to retire).

- [ ] **Surface the drift.** Copy the frame's nvim to the Mac for diffing: `rsync -a dbld@10.226.20.229:~/nix-config/dotfiles/nvim/ /tmp/frame-nvim/` then `diff -ru ~/.code/dotfiles/nvim /tmp/frame-nvim`.
- [ ] **Reconcile:** for each difference, decide the canonical version and fold it into `~/.code/dotfiles/nvim`. (Frame-specific bits — e.g. nix LSP paths — should already be handled by the dev role's `ensure_installed = {}`, so the nvim config itself should be platform-neutral.)
- [ ] **Commit** the reconciled nvim to the dotfiles repo: `git -C ~/.code/dotfiles add nvim && git -C ~/.code/dotfiles commit -m "nvim: reconcile frame + mac into one canonical config"` and push.
- [ ] **Verify:** the diff is empty after the frame pulls (Task 0.4).

### Task 0.3: Repoint the frame's nvim symlink at the canonical dotfiles

**Files:** Modify `~/nix-config/home/roles/dev.nix` (the `xdg.configFile."nvim".source` line).

- [ ] **Change the symlink target** from `${config.home.homeDirectory}/nix-config/dotfiles/nvim` to `${config.home.homeDirectory}/.code/dotfiles/nvim`.
- [ ] **Remove** the now-orphaned `~/nix-config/dotfiles/nvim` from the nix-config repo (it's superseded by the canonical one).
- [ ] **Commit** on the appropriate nix-config branch and `nixos-rebuild build --flake .#dbldframe` to verify it evaluates.

### Task 0.4: Frame consumes the canonical configs

- [ ] On the frame: `git -C ~/.code/dotfiles pull`, then deploy the dev.nix change (`nixos-rebuild switch`).
- [ ] **Verify nvim parity:** `diff <(ssh dbld@10.226.20.229 'cat ~/.config/nvim/init.lua') ~/.config/nvim/init.lua` returns no differences (both resolve to the same dotfiles).

---

## Ring 1 — nvim + tmux become literally identical

> **STATUS 2026-06-06:** Ring 1 COMPLETE. tmux done (frame byte-identical to Mac). nvim done
> via the dedicated spec+plan — canonical = **kickstart.nvim master** (not LazyVim; decided
> after brainstorm, see `docs/superpowers/specs/2026-06-06-nvim-distro-design.md` and
> `docs/superpowers/plans/2026-06-06-nvim-canonical-kickstart.md`). Resolved `init.lua` is
> identical on both machines; LSPs via mason on Mac / nix on frame, switched by `$NVIM_NIX_LSP`.
> Next ring: Ring 2 (kanata).

### Task 1.1: Bring the frame's tmux up to the canonical (plugin-rich) config

*The frame currently uses a bare home-manager `programs.tmux`; the Mac has the rich `tmux/tmux.conf` (sessionx, floax, theme pickers, `prefix2 C-Space`). Make the frame read the same `tmux.conf`.*

**Files:** Modify `~/nix-config/home/roles/dev.nix` (the `programs.tmux` block) + add an `xdg.configFile."tmux".source` symlink.

- [ ] **Stop home-manager from generating tmux config:** in `dev.nix`, reduce `programs.tmux` to `{ enable = true; }` (so the binary/plugins deps are present) **or** disable it and add tmux to `home.packages`. Decide based on whether you want tpm-managed plugins (the Mac uses tpm) — if so, do NOT let home-manager manage the config.
- [ ] **Symlink the canonical tmux config:** add `xdg.configFile."tmux".source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.code/dotfiles/tmux";` (live-editable, same pattern as nvim).
- [ ] **Plugins:** the Mac's tmux uses tpm + plugins (sessionx, floax, catppuccin). Ensure tpm is bootstrapped on the frame: clone `tpm` to `~/.config/tmux/plugins/tpm` (or via the config's auto-install snippet), and the plugin deps (fzf, etc.) are on PATH (fzf is already in home.packages).
- [ ] **Commit + build-verify + deploy.**
- [ ] **Verify:** `tmux kill-server` on the frame, start fresh, hit `prefix` (`C-a`) + the sessionx/floax/theme binds — they behave exactly as on the Mac. `diff <(ssh dbld@... 'tmux show -g | sort') <(tmux show -g | sort)` shows only host-irrelevant differences.

### Task 1.2: Sanity-pass the editor stack end to end

- [ ] **Verify on both machines:** open nvim → leader key, common mappings, LSP, treesitter all behave identically. Open tmux → prefix, splits, session switching identical. Open vim (if used standalone) → reads the same `~/.vimrc`/shared bits if applicable.
- [ ] **Document the canonical bindings** in `~/.code/dotfiles/docs/keymap.md` (a living cheat-sheet: tmux prefix + binds, nvim leader + core maps) so muscle memory has a reference. Commit.

---

## Ring 2 — The modifier substrate via kanata (minimal)

*Not full home-row mods yet — just the vim/tmux essentials, identical on both: Caps→tap Esc / hold Ctrl. Retire keyd (frame) and the equivalent Karabiner remap (Mac).*

### Task 2.1: Author the minimal shared kanata config

**Files:** Create `~/.code/dotfiles/kanata/base.kbd`.

- [ ] **Write the minimal config:** define `defsrc` with `caps`, and `deflayer` mapping `caps` to a `tap-hold` action → tap `esc`, hold `lctl`. Example:
  ```lisp
  (defcfg process-unmapped-keys yes)
  (defsrc caps)
  (deflayer base
    (tap-hold 200 200 esc lctl))
  ```
- [ ] **Commit** to the dotfiles repo.
- [ ] **Verify (later, per platform):** holding Caps acts as Ctrl (e.g. `Caps+a` = `Ctrl+a` = tmux prefix); tapping Caps = Esc (nvim normal mode).

### Task 2.2: kanata on the frame (replace keyd)

**Files:** Modify `~/nix-config/hosts/dbldframe/keyboard.nix` (currently keyd) + reference the kbd file.

- [ ] **Replace `services.keyd`** with `services.kanata`: `services.kanata.keyboards.default = { devices = [...]; configFile = "${config.home.homeDirectory}/.code/dotfiles/kanata/base.kbd"; };` (or inline `config` mirroring base.kbd; a symlinked file is preferable for parity). Keep the `uinput` access kanata needs.
- [ ] **Move the WM Super mod off Caps:** since Caps is now Ctrl, ensure Hyprland's `$mod` is the **physical Super key** (verify `bind=$mod` still resolves to a key you can press; the Framework has a Super key). Update the keyd removal so capslock=Super is gone.
- [ ] **Build-verify + deploy** (detached switch). **Recovery net:** SSH stays up; if input breaks, `nixos-rebuild switch --rollback`.
- [ ] **Verify on the frame:** tap Caps = Esc, hold Caps = Ctrl; tmux prefix via `Caps+a` works; Hyprland WM binds still fire via the physical Super key.

### Task 2.3: kanata on the Mac (replace the Karabiner Caps remap)

**Files:** macOS — install kanata + Karabiner DriverKit VirtualHIDDevice; create a LaunchDaemon; point at the same `base.kbd`.

- [ ] **Install the backend:** `brew install kanata` and the Karabiner-DriverKit-VirtualHIDDevice driver (kanata's docs cover the exact pkg + `karabiner_grabber`/driver activation). Grant kanata Input Monitoring + Accessibility in System Settings → Privacy.
- [ ] **Remove the Caps→Esc/Ctrl rule from `karabiner.json`** so it doesn't double-remap (keep other Karabiner rules for now, or migrate them to kanata in a later ring).
- [ ] **Run kanata against the shared config:** `sudo kanata --cfg ~/.code/dotfiles/kanata/base.kbd` (then a LaunchDaemon plist for persistence — store it under `~/.code/dotfiles/macos/` and commit).
- [ ] **Verify on the Mac:** tap Caps = Esc, hold Caps = Ctrl, identical to the frame. `Caps+a` in tmux = prefix.

### Task 2.4: Cross-machine parity check

- [ ] **Verify:** the exact same finger motions (Caps-tap for Esc, Caps-hold for Ctrl, tmux prefix, nvim normal-mode) feel identical on Mac and frame. Note any timing differences and tune the `tap-hold` ms in `base.kbd` (shared → both update).

---

## Ring 3 — The glue (seamless nav + one terminal)

### Task 3.1: vim-tmux-navigator (Ctrl+hjkl across nvim splits and tmux panes)

**Files:** `~/.code/dotfiles/nvim/` (plugin spec) + `~/.code/dotfiles/tmux/tmux.conf` (matching binds).

- [ ] **Add the plugin** to the nvim config (`christoomey/vim-tmux-navigator` or the lua fork) and the **matching tmux bindings** (the `is_vim` pane-aware `bind -n C-h/j/k/l` block). Both from the canonical configs → land on both machines.
- [ ] **Commit + pull/deploy on both.**
- [ ] **Verify:** with nvim open inside tmux, `Ctrl+h/j/k/l` moves between nvim splits and tmux panes seamlessly, identically on both machines. (Ctrl is now Caps-hold, so this is a pure home-row motion.)

### Task 3.2: Standardize the terminal on WezTerm

**Files:** Frame: `~/nix-config/home/roles/desktop.nix` / dbldframe Hyprland binds; Mac already on WezTerm. Canonical config: `~/.code/dotfiles/wezterm/wezterm.lua`.

- [ ] **Frame:** change the Hyprland terminal binds (`Super+Return`, `Super+Q` exec) from `alacritty` to `wezterm`; add wezterm to packages if not present; symlink `~/.config/wezterm` → `~/.code/dotfiles/wezterm` via home-manager.
- [ ] **Commit + build-verify + deploy.**
- [ ] **Verify:** the terminal launched by the WM is WezTerm on both, reading the same `wezterm.lua` → identical terminal keybinds/appearance.

---

## Ring 4+ — Outer rings (future, not yet scoped)

Deliberately deferred until Rings 0–3 are bedded in:
- **Full home-row mods** (generalize kanata: home-row Shift/Ctrl/Alt/GUI on `asdf`/`jkl;`), and relocate the **WM modifier** onto a home-row/thumb mod.
- **WM layer reconciliation:** make **Aerospace** (Mac, currently Alt-based) and **Hyprland** (Super-based) respond to the *same* logical scheme — same mod, same `hjkl` semantics (today Aerospace=directional focus, Hyprland=cycle/resize — must converge), same workspace/terminal binds.
- **App-level Cmd vs Ctrl** — the hardest, most divisive frontier; bridge selectively via kanata layers rather than fighting macOS system-wide.

---

## Self-review notes
- **Spec coverage:** Rings 0–3 cover the user's "start small with nvim/tmux/vim, build out" intent; Ring 4 captures the outer rings as future scope.
- **Sequencing:** Ring 0 (single source) MUST precede Rings 1–3, or you unify keybinds on top of drifting configs.
- **Risk:** Ring 2 (kanata) is the only step that can lock you out of input — always deploy the frame detached with SSH as the recovery net, and test the Mac kanata config before removing the Karabiner rule.
- **Open input needed at execution time:** the dotfiles repo's remote (push it if local-only); exact kanata macOS driver install steps (follow kanata's current macOS docs); whether tmux plugins stay tpm-managed or move to nix.
</content>
