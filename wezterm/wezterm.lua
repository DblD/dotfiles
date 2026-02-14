local wezterm = require 'wezterm'
local act = wezterm.action

-- Catppuccin themes (light to dark)
local catppuccin_themes = {
	'Catppuccin Latte',   -- Light
	'Catppuccin Frappe',  -- Light-dark
	'Catppuccin Macchiato', -- Dark-light
	'Catppuccin Mocha',   -- Dark
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
					window:set_config_overrides { color_scheme = id }
				end
			end),
		},
	},
	-- Quick toggle: Latte (light) <-> Mocha (dark) (Ctrl+Shift+L)
	{
		key = 'l',
		mods = 'CTRL|SHIFT',
		action = wezterm.action_callback(function(window, pane)
			local overrides = window:get_config_overrides() or {}
			local current = overrides.color_scheme or 'Catppuccin Mocha'
			if current == 'Catppuccin Latte' then
				overrides.color_scheme = 'Catppuccin Mocha'
			else
				overrides.color_scheme = 'Catppuccin Latte'
			end
			window:set_config_overrides(overrides)
		end),
	},
	-- Cycle through all Catppuccin themes (Ctrl+Shift+C)
	{
		key = 'c',
		mods = 'CTRL|SHIFT',
		action = wezterm.action_callback(function(window, pane)
			local overrides = window:get_config_overrides() or {}
			local current = overrides.color_scheme or 'Catppuccin Mocha'
			local next_theme = catppuccin_themes[1]
			for i, theme in ipairs(catppuccin_themes) do
				if theme == current then
					next_theme = catppuccin_themes[(i % #catppuccin_themes) + 1]
					break
				end
			end
			overrides.color_scheme = next_theme
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
