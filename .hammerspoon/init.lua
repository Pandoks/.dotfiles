require("lib.logger").install()
require("hs.ipc") -- `hs` CLI access for debugging
hs.loadSpoon("SpoonInstall")

local install = spoon.SpoonInstall

-- Generates hs.* type annotations for lua_ls when they are missing or stale.
install:andUse("EmmyLua")

require("yabai")
require("applications")
require("ghostty")

require("secrets")
-- template for secrets:
-- hs.hotkey.bind({ "" }, "", function()
--  hs.eventtap.keyStrokes("")
-- end)
