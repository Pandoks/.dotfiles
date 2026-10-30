local spaceFocus = require("lib.space_focus")
local tiling = require("lib.tiling")
local resizeStep = 20

tiling.manage({ "Helium", "Ghostty", "Slack", "Notion Calendar", "T3 Code (Beta)" })

hs.hotkey.bind({ "shift", "alt" }, "f", tiling.float)

hs.hotkey.bind({ "alt" }, "return", tiling.zoom)

local directions = { north = "k", south = "j", east = "l", west = "h" }
for direction, key in pairs(directions) do
  hs.hotkey.bind({ "alt" }, key, function()
    tiling.focus(direction)
  end)

  hs.hotkey.bind({ "shift", "alt" }, key, function()
    tiling.swap(direction)
  end)

  hs.hotkey.bind({ "ctrl", "alt" }, key, function()
    tiling.warp(direction)
  end)
end

spaceFocus.bindArrowKeys()

hs.hotkey.bind({ "alt" }, "0", function()
  spaceFocus.switchSpace(10)
end)
for i = 1, 9 do
  hs.hotkey.bind({ "alt" }, tostring(i), function()
    spaceFocus.switchSpace(i)
  end)
end

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

hs.hotkey.bind({ "cmd", "alt" }, "space", tiling.balance)
