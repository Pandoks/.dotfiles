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

for i = 1, 10 do
  hs.hotkey.bind({ "alt" }, tostring(i % 10), function()
    spaceFocus.switchSpace(i)
  end)
  hs.hotkey.bind({ "shift", "alt" }, tostring(i % 10), function()
    spaceFocus.moveWindow(i)
  end)
end

-- Repeats while held.
local edges = {
  h = { "left", -resizeStep },
  l = { "right", resizeStep },
  j = { "bottom", resizeStep },
  k = { "top", -resizeStep },
}
for key, edge in pairs(edges) do
  local function resize()
    tiling.resize(edge[1], edge[2])
  end
  hs.hotkey.bind({ "cmd", "alt" }, key, resize, nil, resize)
end

hs.hotkey.bind({ "cmd", "alt" }, "space", tiling.balance)
hs.hotkey.bind({ "shift", "alt" }, "space", tiling.columns)
