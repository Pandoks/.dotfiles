local yabai = require("yabai")
local function openOrFocusApplication(application, space)
	local app = hs.application.get(application)
	if not app then
		yabai({ "-m", "space", "--focus", tostring(space) })
		print("Focused space", space)
		hs.application.open(application)
		print("Opened " .. application)
	else
		-- focus the already open application
		app:activate(true)
		print("Focused", app)
	end
end

hs.hotkey.bind({ "alt" }, "a", function()
	openOrFocusApplication("Arc", 3)
end)
hs.hotkey.bind({ "alt" }, "d", function()
	openOrFocusApplication("Discord", 5)
end)
hs.hotkey.bind({ "alt" }, "m", function()
	-- Need to do this or else hammerspoon will get confused with Proton Mail Bridge
	openOrFocusApplication("com.apple.mail", 4) -- Apple Mail
end)
hs.hotkey.bind({ "alt" }, "n", function()
	openOrFocusApplication("Messages", 6)
end)
hs.hotkey.bind({ "alt" }, "r", function()
	openOrFocusApplication("Reminders", 6)
end)
hs.hotkey.bind({ "alt" }, "t", function()
	openOrFocusApplication("iTerm", 2)
end)
