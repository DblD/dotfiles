// Zen Browser memory optimization
// Deployed by dotfiles/setup.sh into active Zen profile

// Unload tabs automatically when system memory is low
user_pref("browser.tabs.unloadOnLowMemory", true);

// Only load tabs when clicked (not all at once on startup)
user_pref("browser.sessionstore.restore_on_demand", true);

// Same for pinned tabs — don't load until clicked
user_pref("browser.sessionstore.restore_pinned_tabs_on_demand", true);
