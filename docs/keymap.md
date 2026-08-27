# Keymap cheat-sheet (canonical, both machines)

Living reference for the unified terminal-stack muscle memory. nvim = kickstart.nvim
(master, vim.pack). tmux prefix = `Ctrl+a`. Keyboard substrate = kanata (frame done;
Mac pending). nvim leader = `Space`.

## Keyboard substrate (kanata — `kanata/base.kbd`)

| Key | tap | hold |
|-----|-----|------|
| **Caps** | Esc | Left Super (WM `$mod`; also the physical Super key) |
| **d** | `d` | Left Ctrl |
| **k** | `k` | Left Ctrl |

- Home-row Ctrl uses an **opposite-hand rule**: Ctrl only fires when the *other* key is on
  the opposite hand (same-hand keys / space force a tap → no misfires).
  - `k` = right-hand Ctrl → use with **left-hand** keys (e.g. tmux prefix `k`+`a`).
  - `d` = left-hand Ctrl → use with **right-hand** keys.
- **Physical Ctrl still works** for anything (and for same-hand combos HRM can't do).
- Timing: 200/200 ms (`base.kbd` is the single tuning point).

## tmux (prefix `Ctrl+a`, i.e. `k`+`a`)

| After prefix | Action |
|-----|--------|
| `c` | **new window** (opens in current dir) |
| `1`…`9` | jump to window N · `H`/`L` previous/next window |
| `Ctrl+a` | last window · `Ctrl+d` detach |
| `|` / `v` | split left-right · `s` split top-bottom |
| `h j k l` | move between panes |
| `x` | kill pane (with y/n confirm) · `X` swap pane |
| `z` | zoom/unzoom pane |
| `,` | rename window · `w` window/session tree |
| `o` | sessionx (session switcher) · `p` floax (floating pane) |
| `?` | **full keybinding list** (ground truth for this config) |

> Note: this config is the "reset.conf" style — `?` shows everything. `c` was kill-pane
> upstream; normalized here to new-window.

## nvim — core (leader = Space)

| Key | Action |
|-----|--------|
| `<C-h/j/k/l>` | move between windows |
| `<leader>f` | format buffer (conform; yaml→yamlfmt) |
| `<leader>q` | diagnostic quickfix list |
| `<leader>sf` / `sg` / `sw` | find files / live grep / grep word |
| `<leader>sh` / `sk` / `sd` | search help / keymaps / diagnostics |
| `<leader><leader>` | buffers |
| `grd` `grr` `gri` `grt` | LSP goto definition / refs / impl / type |
| `grn` `gra` | rename / code action |

LSP binaries: mason on the Mac, nix on the frame (switched by `$NVIM_NIX_LSP`).

## Ring status
- Ring 0/1 (config home, tmux, nvim): done.
- Ring 2 (kanata substrate): **frame done & proven**; Mac (Karabiner DriverKit driver) pending.
- Ring 3 (vim-tmux-navigator, WezTerm everywhere): not started.
- Ring 4 (full home-row mods / GACS): partially previewed (Ctrl-only on d+k); rest deferred.
