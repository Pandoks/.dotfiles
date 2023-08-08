require("applications")
require("shortcuts")
require("yabai")

hs.hotkey.bind({ "shift", "ctrl", "alt" }, "r", function()
	hs.reload()
end)
hs.alert.show("hammerspoon started")
