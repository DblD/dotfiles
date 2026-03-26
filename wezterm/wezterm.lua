local wezterm = require 'wezterm'
local act = wezterm.action

-- Catppuccin themes (light to dark) + custom sepia variant
local catppuccin_themes = {
	'Catppuccin Latte',       -- Light
	'Sepia Latte',            -- Light warm/parchment
	'Catppuccin Frappe',      -- Light-dark
	'Catppuccin Macchiato',   -- Dark-light
	'Catppuccin Mocha',       -- Dark
}

-- Sepia overrides: warm parchment tones on Latte base
local sepia_colors = {
	background = '#f5ead0',
	foreground = '#5c4a32',
	cursor_bg = '#8a6d4b',
	cursor_fg = '#f5ead0',
	selection_bg = '#e0d1b0',
	selection_fg = '#5c4a32',
	ansi = {
		'#ede3d0', -- black (warm parchment — used as code block bg)
		'#d9b0a0', -- red (warm blush parchment — diff removed bg)
		'#c5d4b0', -- green (warm sage parchment — diff added bg)
		'#9e7a2a', -- yellow (amber)
		'#62728a', -- blue (dusty)
		'#876080', -- magenta (muted)
		'#5f8a78', -- cyan (sage)
		'#5c4a32', -- white (warm dark)
	},
	brights = {
		'#c8b898', -- bright black (warm tan — diff context bg)
		'#b86060', -- bright red
		'#6f8e60', -- bright green
		'#b08a30', -- bright yellow
		'#7282a0', -- bright blue
		'#9a7093', -- bright magenta
		'#70a090', -- bright cyan
		'#4a3a24', -- bright white
	},
}

-- Build theme picker choices
local theme_choices = {}
for _, theme in ipairs(catppuccin_themes) do
	table.insert(theme_choices, { label = theme, id = theme })
end

-- Config
local config = wezterm.config_builder and wezterm.config_builder() or {}

config.adjust_window_size_when_changing_font_size = false
config.color_scheme = 'Catppuccin Mocha'
config.enable_tab_bar = false
config.font_size = 16.0
config.font = wezterm.font('JetBrains Mono')
config.macos_window_background_blur = 30
config.window_background_opacity = 1.0
config.window_decorations = 'RESIZE'

config.keys = {
	-- Existing keys
	{
		key = 'q',
		mods = 'CTRL',
		action = act.ToggleFullScreen,
	},
	{
		key = '\'',
		mods = 'CTRL',
		action = act.ClearScrollback 'ScrollbackAndViewport',
	},
	-- Theme picker (Ctrl+Shift+T)
	{
		key = 't',
		mods = 'CTRL|SHIFT',
		action = act.InputSelector {
			title = 'Catppuccin Themes',
			choices = theme_choices,
			action = wezterm.action_callback(function(window, pane, id, label)
				if id then
					local overrides = window:get_config_overrides() or {}
					if id == 'Sepia Latte' then
						overrides.color_scheme = 'Catppuccin Latte'
						overrides.colors = sepia_colors
					else
						overrides.color_scheme = id
						overrides.colors = nil
					end
					window:set_config_overrides(overrides)
				end
			end),
		},
	},
	-- Quick toggle: Sepia Latte (light) <-> Mocha (dark) (Ctrl+Shift+L)
	{
		key = 'l',
		mods = 'CTRL|SHIFT',
		action = wezterm.action_callback(function(window, pane)
			local overrides = window:get_config_overrides() or {}
			local has_sepia = overrides.colors and overrides.colors.background == sepia_colors.background
			if has_sepia then
				overrides.color_scheme = 'Catppuccin Mocha'
				overrides.colors = nil
			else
				overrides.color_scheme = 'Catppuccin Latte'
				overrides.colors = sepia_colors
			end
			window:set_config_overrides(overrides)
		end),
	},
	-- Cycle through all themes (Ctrl+Shift+C)
	{
		key = 'c',
		mods = 'CTRL|SHIFT',
		action = wezterm.action_callback(function(window, pane)
			local overrides = window:get_config_overrides() or {}
			local has_sepia = overrides.colors and overrides.colors.background == sepia_colors.background
			local current = has_sepia and 'Sepia Latte' or (overrides.color_scheme or 'Catppuccin Mocha')
			local next_theme = catppuccin_themes[1]
			for i, theme in ipairs(catppuccin_themes) do
				if theme == current then
					next_theme = catppuccin_themes[(i % #catppuccin_themes) + 1]
					break
				end
			end
			if next_theme == 'Sepia Latte' then
				overrides.color_scheme = 'Catppuccin Latte'
				overrides.colors = sepia_colors
			else
				overrides.color_scheme = next_theme
				overrides.colors = nil
			end
			window:set_config_overrides(overrides)
			wezterm.log_info('Switched to: ' .. next_theme)
		end),
	},
	-- Toggle transparency (Ctrl+Shift+O for Opacity)
	{
		key = 'o',
		mods = 'CTRL|SHIFT',
		action = wezterm.action_callback(function(window, pane)
			local overrides = window:get_config_overrides() or {}
			local current = overrides.window_background_opacity or 1.0
			if current < 1.0 then
				overrides.window_background_opacity = 1.0
			else
				overrides.window_background_opacity = 0.85
			end
			window:set_config_overrides(overrides)
		end),
	},
}

config.mouse_bindings = {
	-- Ctrl-click will open the link under the mouse cursor
	{
		event = { Up = { streak = 1, button = 'Left' } },
		mods = 'CTRL',
		action = act.OpenLinkAtMouseCursor,
	},
}

return config
