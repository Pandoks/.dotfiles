require("hs.ipc") -- `hs` CLI access for debugging
hs.loadSpoon("SpoonInstall")

local install = spoon.SpoonInstall

-- Generates hs.* type annotations for lua_ls when they are missing or stale.
install:andUse("EmmyLua")

-- SkyRocket does not publish the repository metadata/zip structure SpoonInstall requires.
hs.loadSpoon("SkyRocket")

require("applications")
require("ghostty")

require("secrets")
-- template for secrets:
-- hs.hotkey.bind({ "" }, "", function()
--  hs.eventtap.keyStrokes("")
-- end)
