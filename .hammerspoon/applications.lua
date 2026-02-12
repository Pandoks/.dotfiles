local yabai = require("yabai")

NeedsToBeHidden = nil
-- needs to be a global variable or else it will get garbage collected and lose scope
ApplicationWatcher = hs.application.watcher.new(function(app, event, object)
  -- deactivated will happen before unhidden event when switching between 2 apps
  if event == hs.application.watcher.deactivated and app == NeedsToBeHidden then
    object:hide()
    NeedsToBeHidden = nil
    print("Hid", app)
  elseif event == hs.application.watcher.unhidden then
    NeedsToBeHidden = app
    print("Set hidden toggle", app)
  end
end)
ApplicationWatcher:start()

local function openOrFocusApplication(application, space)
  space = space or nil
  local app = hs.application.find(application, true)
  if not app then
    if not space then
      hs.application.open(application)
      print("Opened " .. application)
      return
    end

    yabai({ "-m", "space", "--focus", tostring(space) })
    print("Focused space", space)
    hs.application.open(application)
    print("Opened " .. application)
    return
  end

  local currentSpace = hs.spaces.focusedSpace()
  local mainWindow = app:mainWindow()

  -- focus on previously focused window if it's in the same space
  if mainWindow then
    local spaces = hs.spaces.windowSpaces(mainWindow:id())
    for _, spaceId in ipairs(spaces) do
      if spaceId == currentSpace then
        app:activate(true)
        print("Focused", app)
        return
      end
    end
  end

  -- focus on application window in the current space
  for _, window in ipairs(app:allWindows()) do
    local spaces = hs.spaces.windowSpaces(window:id())
    for _, spaceId in ipairs(spaces) do
      if spaceId == currentSpace then
        window:focus()
        print("Focused", app, "on current space")
        return
      end
    end
  end

  app:activate(true)
  print("Focused", app)
end

hs.hotkey.bind({ "cmd", "shift" }, "h", function()
  NeedsToBeHidden = nil
  print("Clear hidden toggle")
end)
hs.hotkey.bind({ "alt" }, "s", function()
  openOrFocusApplication("Helium", 3)
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
  openOrFocusApplication("Codex", 6)
end)
hs.hotkey.bind({ "alt" }, "b", function()
  openOrFocusApplication("BambuStudio", 6)
end)
hs.hotkey.bind({ "alt" }, "c", function()
  openOrFocusApplication("Notion Calendar", 6)
end)
hs.hotkey.bind({ "alt" }, "t", function()
  openOrFocusApplication("Ghostty", 2)
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
hs.hotkey.bind({ "alt" }, "i", function()
  openOrFocusApplication("thinkorswim", 7)
end)
hs.hotkey.bind({ "alt" }, "u", function()
  openOrFocusApplication("UTM", 7)
end)
hs.hotkey.bind({ "alt" }, "v", function()
  openOrFocusApplication("Davinci Resolve", 7)
end)
