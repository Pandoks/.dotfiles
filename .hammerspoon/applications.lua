local yabai = require("yabai")
local function openOrFocusApplication(application, space)
	local app = hs.application.get(application)
	if not app then
		yabai({ "-m", "space", "--focus", tostring(space) })
		hs.application.open(application)
	else
		-- focus the already open application
		app:activate(true)
	end
end

hs.hotkey.bind({ "alt" }, "a", function()
	openOrFocusApplication("Arc", 3)
end)
hs.hotkey.bind({ "alt" }, "d", function()
	openOrFocusApplication("Discord", 5)
end)
hs.hotkey.bind({ "alt" }, "m", function()
	openOrFocusApplication("Mail", 4)
end)
hs.hotkey.bind({ "alt" }, "n", function()
	openOrFocusApplication("Messages", 6)
end)
hs.hotkey.bind({ "alt" }, "r", function()
	openOrFocusApplication("Reminders", 6)
end)
hs.hotkey.bind({ "alt" }, "t", function()
	openOrFocusApplication("iTerm2", 2)
end)
