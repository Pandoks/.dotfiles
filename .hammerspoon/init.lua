require("hs.ipc") -- `hs` CLI access for debugging
hs.loadSpoon("EmmyLua") -- generates hs.* type annotations for lua_ls (only when stale)
require("applications")
require("ghostty")
require("yabai")

require("secrets")
-- template for secrets:
-- hs.hotkey.bind({ "" }, "", function()
--  hs.eventtap.keyStrokes("")
-- end)
