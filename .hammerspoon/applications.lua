-- TODO: Add minimized window support
local yabai = require("yabai")
local function openOrFocusApplication(application, space, open)
  open = open or application
  space = space or nil
  local app = hs.application.find(application, true)
  if app then
    -- focus the already open application
    app:activate(true)
    print("Focused", app)
  elseif space then
    -- app isn't opened and space is included
    yabai({ "-m", "space", "--focus", tostring(space) })
    print("Focused space", space)
    hs.application.open(open)
    print("Opened " .. application)
  else
    -- app isn't opened without a space
    hs.application.open(open)
    print("Opened " .. application)
  end
end

hs.hotkey.bind({ "alt" }, "s", function()
  openOrFocusApplication("Safari", 3)
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
  openOrFocusApplication("com.apple.Notes", 6)
end)
hs.hotkey.bind({ "alt" }, "r", function()
  openOrFocusApplication("Reminders", 6)
end)
hs.hotkey.bind({ "alt" }, "c", function()
  openOrFocusApplication("com.apple.iCal", 6)
end)
hs.hotkey.bind({ "alt" }, "b", function()
  openOrFocusApplication("BambuStudio", 6)
end)
hs.hotkey.bind({ "alt" }, "t", function()
  openOrFocusApplication("Ghostty", 2, "Ghostty")
end)
hs.hotkey.bind({ "alt" }, "v", function()
  openOrFocusApplication("Davinci Resolve", 7)
end)
hs.hotkey.bind({ "alt" }, "g", function()
  openOrFocusApplication("Figma", 7)
end)
hs.hotkey.bind({ "alt" }, "p", function()
  openOrFocusApplication("Proton Pass")
end)
hs.hotkey.bind({ "alt" }, "w", function()
  openOrFocusApplication("Slack", 5)
end)
hs.hotkey.bind({ "alt" }, "e", function()
  openOrFocusApplication("Cursor", 2)
end)
hs.hotkey.bind({ "alt" }, "q", function()
  openOrFocusApplication("Notion", 1)
end)
hs.hotkey.bind({ "alt" }, "j", function()
  openOrFocusApplication("thinkorswim", 7)
end)
