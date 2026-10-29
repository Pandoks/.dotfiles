require("lib.logger").install()
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

-- Gitignored, so only where it was set up.
if hs.fs.attributes(hs.configdir .. "/secrets.lua") then
  require("secrets")
end
-- template for secrets:
-- hs.hotkey.bind({ "" }, "", function()
--  hs.eventtap.keyStrokes("")
-- end)

-- MLX needs Apple Silicon and macOS 14+; last, so a load error in it stops nothing else.
if
  (hs.processInfo.arch == "arm64" or hs.processInfo.isRosetta)
  and hs.host.operatingSystemVersion()["major"] >= 14
then
  require("dictation")
end
