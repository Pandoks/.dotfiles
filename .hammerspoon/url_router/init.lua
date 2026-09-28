local chromium = require("lib.window_adapters.chromium")

return chromium.installURLRouter({
  bundleID = "net.imput.helium",
  fallbackProfile = "Personal",
  rules = {
    -- Lua patterns are matched in order against the complete URL.
    -- { pattern = "^https?://[^/]*%.example%-work%.com/", profile = "Work" },
    -- { pattern = "^https?://[^/]*%.example%-personal%.com/", profile = "Personal" },
  },
})
