local spaceFocus = require("lib.space_focus")
local tiling = require("lib.tiling")
local resizeStep = 20

-- Tiled with BSP; every other window, and any Picture-in-Picture, is left alone.
tiling.manage({ "Helium", "Ghostty", "Slack", "Notion Calendar", "T3 Code (Nightly)" })

-- Toggle whether the focused window participates in BSP tiling.
hs.hotkey.bind({ "shift", "alt" }, "f", tiling.float)

-- Toggle BSP-aware fullscreen zoom for the focused window.
hs.hotkey.bind({ "alt" }, "return", tiling.zoom)

local directions = { north = "k", south = "j", east = "l", west = "h" }
for direction, key in pairs(directions) do
  -- Focus a neighboring window.
  hs.hotkey.bind({ "alt" }, key, function()
    tiling.focus(direction)
  end)

  -- Swap the focused window with a neighboring window.
  hs.hotkey.bind({ "shift", "alt" }, key, function()
    tiling.swap(direction)
  end)

  -- Reinsert the focused window by splitting a neighboring window.
  hs.hotkey.bind({ "ctrl", "alt" }, key, function()
    tiling.warp(direction)
  end)
end

-- Switch instantly on this display; let macOS navigate inside Mission Control.
spaceFocus.bindArrowKeys()

-- Switch to a Space.
hs.hotkey.bind({ "alt" }, "0", function()
  spaceFocus.switchSpace(10)
end)
for i = 1, 9 do
  hs.hotkey.bind({ "alt" }, tostring(i), function()
    spaceFocus.switchSpace(i)
  end)
end

-- Resize the focused BSP region.
hs.hotkey.bind({ "cmd", "alt" }, "h", function()
  tiling.resize("left", -resizeStep)
end)
hs.hotkey.bind({ "cmd", "alt" }, "l", function()
  tiling.resize("right", resizeStep)
end)
hs.hotkey.bind({ "cmd", "alt" }, "j", function()
  tiling.resize("bottom", resizeStep)
end)
hs.hotkey.bind({ "cmd", "alt" }, "k", function()
  tiling.resize("top", -resizeStep)
end)

-- Reset all BSP split ratios on the current Space.
hs.hotkey.bind({ "cmd", "alt" }, "space", tiling.balance)
