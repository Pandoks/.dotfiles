require("lib.logger").install()
require("hs.ipc") -- `hs` CLI access for debugging
hs.loadSpoon("SpoonInstall")

local install = spoon.SpoonInstall

-- Generates hs.* type annotations for lua_ls when they are missing or stale.
install:andUse("EmmyLua")

require("yabai")
require("applications")
require("ghostty")

-- Local, free, Raycast-style dictation (./dictation); MLX needs Apple Silicon and macOS 14+. After
-- the modules above, so a load error in it stops none of them; before secrets.lua (gitignored),
-- which may be absent.
if
  (hs.processInfo.arch == "arm64" or hs.processInfo.isRosetta)
  and hs.host.operatingSystemVersion()["major"] >= 14
then
  require("dictation")
end

require("secrets")
-- template for secrets:
-- hs.hotkey.bind({ "" }, "", function()
--  hs.eventtap.keyStrokes("")
-- end)
