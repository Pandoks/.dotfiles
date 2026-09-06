local yabaiClient = require("lib.yabai")
local resizeStep = 20

---@param args string[]
---@param done? fun(ok: boolean)
local function yabai(args, done)
  yabaiClient.run(args, function(ok, _, err)
    if not ok then
      print("yabai error: " .. err)
    end
    if done then
      done(ok)
    end
  end)
end

---@param primary string first `--resize` spec, e.g. `"left:-20:0"`
---@param fallback string used if the primary edge cannot resize
local function resize(primary, fallback)
  yabai({ "window", "--resize", primary }, function(ok)
    if not ok then
      yabai({ "window", "--resize", fallback })
    end
  end)
end

-- Toggle whether the focused window participates in BSP tiling.
hs.hotkey.bind({ "shift", "alt" }, "f", function()
  yabai({ "window", "--toggle", "float" })
end)

-- Toggle BSP-aware fullscreen zoom for the focused window.
hs.hotkey.bind({ "alt" }, "return", function()
  yabai({ "window", "--toggle", "zoom-fullscreen" })
end)

local directions = { north = "k", south = "j", east = "l", west = "h" }
for direction, key in pairs(directions) do
  -- Focus a neighboring window.
  hs.hotkey.bind({ "alt" }, key, function()
    yabai({ "window", "--focus", direction })
  end)

  -- Swap the focused window with a neighboring window.
  hs.hotkey.bind({ "shift", "alt" }, key, function()
    yabai({ "window", "--swap", direction })
  end)

  -- Reinsert the focused window by splitting a neighboring window.
  hs.hotkey.bind({ "ctrl", "alt" }, key, function()
    yabai({ "window", "--warp", direction })
  end)
end

-- Switch to a Space.
hs.hotkey.bind({ "alt" }, "0", function()
  yabai({ "space", "--focus", "10" })
end)
for i = 1, 9 do
  local space = tostring(i)

  hs.hotkey.bind({ "alt" }, space, function()
    yabai({ "space", "--focus", space })
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
  yabai({ "space", "--balance" })
end)
