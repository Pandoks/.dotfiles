require("applications")
require("shortcuts")
require("yabai")

hs.hotkey.bind({ "shift", "ctrl", "alt" }, "r", function()
  hs.alert.show("hammerspoon started", 2)
  hs.reload()
end)
