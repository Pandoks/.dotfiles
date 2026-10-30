require("lib.logger").install()
require("hs.ipc") -- `hs` CLI; loads first so it survives a failed toast install
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
