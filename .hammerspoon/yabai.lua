local spaceManager = require("lib.space_manager")
local appLauncher = require("lib.app_launcher")
local yabaiClient = require("lib.yabai_client")
local resizeStep = 20
local yabai = yabaiClient.run

local function moveFocusedWindowAndFollow(space)
  local window = hs.window.focusedWindow()
  if not window or appLauncher.isPictureInPicture({ title = window:title() }) then
    return
  end

  local windowId = window:id()
  if not windowId then
    return
  end

  yabaiClient.moveWindow(windowId, space, function(success, errorMessage)
    if not success then
      print("yabai error: " .. (errorMessage or ("could not move window " .. windowId)))
      return
    end

    spaceManager.switch(space, function(switched, reason)
      if not switched then
        if reason ~= "superseded" then
          print("Space Rabbit error: could not switch to space " .. space)
        end
        return
      end

      spaceManager.focusWindow(windowId, function(focused)
        if not focused then
          print("Hammerspoon error: could not focus window " .. windowId)
        end
      end)
    end)
  end)
end

local function resize(primary, fallback)
  yabai({ "-m", "window", "--resize", primary }, function(success)
    if not success then
      yabai({ "-m", "window", "--resize", fallback })
    end
  end)
end

-- Toggle whether the focused window participates in BSP tiling.
hs.hotkey.bind({ "shift", "alt" }, "f", function()
  yabai({ "-m", "window", "--toggle", "float" })
end)

-- Toggle BSP-aware fullscreen zoom for the focused window.
hs.hotkey.bind({ "alt" }, "return", function()
  yabai({ "-m", "window", "--toggle", "zoom-fullscreen" })
end)

local directions = { north = "k", south = "j", east = "l", west = "h" }
for direction, key in pairs(directions) do
  -- Focus a neighboring window.
  hs.hotkey.bind({ "alt" }, key, function()
    yabai({ "-m", "window", "--focus", direction })
  end)

  -- Swap the focused window with a neighboring window.
  hs.hotkey.bind({ "shift", "alt" }, key, function()
    yabai({ "-m", "window", "--swap", direction })
  end)

  -- Reinsert the focused window by splitting a neighboring window.
  hs.hotkey.bind({ "ctrl", "alt" }, key, function()
    yabai({ "-m", "window", "--warp", direction })
  end)
end

for i = 1, 9 do
  local space = tostring(i)

  -- Move the focused window to a Space, then follow it.
  hs.hotkey.bind({ "shift", "alt" }, space, function()
    moveFocusedWindowAndFollow(tonumber(space))
  end)
end

-- Resize the focused BSP region.
hs.hotkey.bind({ "cmd", "alt" }, "h", function()
  resize("left:" .. -resizeStep .. ":0", "right:" .. -resizeStep .. ":0")
end)
hs.hotkey.bind({ "cmd", "alt" }, "l", function()
  resize("right:" .. resizeStep .. ":0", "left:" .. resizeStep .. ":0")
end)
hs.hotkey.bind({ "cmd", "alt" }, "j", function()
  resize("bottom:0:" .. resizeStep, "top:0:" .. resizeStep)
end)
hs.hotkey.bind({ "cmd", "alt" }, "k", function()
  resize("top:0:" .. -resizeStep, "bottom:0:" .. -resizeStep)
end)

-- Reset all BSP split ratios on the current Space.
hs.hotkey.bind({ "cmd", "alt" }, "space", function()
  yabai({ "-m", "space", "--balance" })
end)

return { run = yabai }
