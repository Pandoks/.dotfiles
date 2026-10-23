require("lib.logger").install()
require("lib.toast").install()
require("hs.ipc") -- `hs` CLI access for debugging
hs.loadSpoon("SpoonInstall")

local install = spoon.SpoonInstall

-- Generates hs.* type annotations for lua_ls when they are missing or stale.
install:andUse("EmmyLua")

require("windows")
require("applications")
require("ghostty")

local windowSwitcher = require("lib.window_switcher")
local previousShutdown = hs.shutdownCallback
rawset(hs, "shutdownCallback", function()
  require("lib.space_focus").stop()
  require("lib.tiling").stop()
  require("lib.window_manager").stop()
  windowSwitcher.stop()
  require("lib.window_filter").stop()
  require("lib.mission_control").stop()
  if previousShutdown then
    previousShutdown()
  end
end)

require("secrets")
-- template for secrets:
-- hs.hotkey.bind({ "" }, "", function()
--  hs.eventtap.keyStrokes("")
-- end)
