require("applications")
require("yabai")

require("secrets")
-- template for secrets:
-- hs.hotkey.bind({ "" }, "", function()
--  hs.eventtap.keyStrokes("")
-- end)

hs.hotkey.bind({ "shift", "ctrl", "alt" }, "r", function()
  hs.alert.show("hammerspoon started", 2)
  hs.reload()
end)
