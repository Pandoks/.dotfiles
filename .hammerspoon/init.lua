require("lib.logger").install()
require("hs.ipc") -- `hs` CLI
require("lib.toast").install({ theme = "metal" })
hs.loadSpoon("SpoonInstall")

local install = spoon.SpoonInstall

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

require("secrets") -- gitignored: hotkeys that type secrets
