# Keymap cheat-sheet (canonical, both machines)

Living reference for the unified terminal-stack muscle memory. Same on Mac and frame.
Leader = `Space`. nvim = kickstart.nvim (master, vim.pack). tmux prefix = `C-a`.

## nvim — core

| Key | Action |
|-----|--------|
| `<Space>` | leader |
| `<C-h/j/k/l>` | move focus between windows (left/down/up/right) |
| `<Esc><Esc>` | exit terminal mode |
| `<leader>q` | open diagnostic quickfix list |
| `<leader>f` | format buffer (conform; yaml→yamlfmt) |

## nvim — search (telescope)

| Key | Action |
|-----|--------|
| `<leader><leader>` | find existing buffers |
| `<leader>sf` | search files |
| `<leader>sg` | search by grep (live) |
| `<leader>sw` | search current word |
| `<leader>sh` | search help |
| `<leader>sk` | search keymaps |
| `<leader>sd` | search diagnostics |
| `<leader>sr` | resume last search |
| `<leader>s.` | recent files |
| `<leader>sc` | commands |
| `<leader>sn` | search neovim config files |

## nvim — LSP (buffer-local, on attach)

| Key | Action |
|-----|--------|
| `grd` | goto definition |
| `grr` | goto references |
| `gri` | goto implementation |
| `grt` | goto type definition |
| `grn` | rename |
| `gra` | code action |
| `gO` | document symbols |
| `gW` | workspace symbols |

LSP binaries: mason installs them on the **Mac**; **nix** provides them on the frame
(switched by `$NVIM_NIX_LSP`). `nixd` is frame-only (not in mason).

## tmux (prefix `C-a`)

See `tmux/tmux.conf` for the full set (sessionx, floax, thumbs, catppuccin). Byte-identical
on both machines via the canonical dotfiles symlink.

## Ring 2 (kanata) — pending

Caps → tap Esc / hold Ctrl; WM mod moves to physical Super. Not yet implemented.
