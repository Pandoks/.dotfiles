local yabai = require("yabai")
local function openOrFocusApplication(application, space, open)
  open = open or application
  local app = hs.application.find(application, true)
  if not app then
    yabai({ "-m", "space", "--focus", tostring(space) })
    print("Focused space", space)
    hs.application.open(open)
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
  -- For some reason, hammerspoon is more stable when using the bundle id for native apple apps
  -- Can find the bundle if by doing: osascript -e 'id of app "<app>"'
  openOrFocusApplication("com.apple.mail", 4)
end)
hs.hotkey.bind({ "alt" }, "n", function()
  openOrFocusApplication("com.apple.MobileSMS", 6)
end)
hs.hotkey.bind({ "alt" }, "o", function()
  openOrFocusApplication("Obsidian", 1)
end)
hs.hotkey.bind({ "alt" }, "s", function()
  openOrFocusApplication("Slack", 6)
end)
hs.hotkey.bind({ "alt" }, "r", function()
  openOrFocusApplication("com.apple.reminders", 6)
end)
hs.hotkey.bind({ "alt" }, "c", function()
  openOrFocusApplication("com.apple.iCal", 6)
end)
hs.hotkey.bind({ "alt" }, "t", function()
  openOrFocusApplication("iTerm2", 2, "iTerm")
end)
hs.hotkey.bind({ "alt" }, "v", function()
  openOrFocusApplication("Davinci Resolve", 7)
end)
