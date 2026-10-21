local filter = require("lib.window_filter")
local logger = require("lib.logger")
local wm = require("lib.wm")

-- Apps tiled with BSP; every other window, and any Picture-in-Picture, is left alone.
local apps = {
  ["Helium"] = true,
  ["Ghostty"] = true,
  ["Slack"] = true,
  ["Notion Calendar"] = true,
  ["T3 Code (Nightly)"] = true,
}

---@class TileNode
---@field parent? TileNode
---@field id? integer leaf window
---@field pid? integer
---@field zoom? boolean
---@field vertical? boolean children side by side
---@field ratio? number
---@field first? TileNode
---@field second? TileNode

---@class TileWindow
---@field leaf TileNode
---@field space integer

local tiling = {}
local trees = {} ---@type table<integer, TileNode>
local tiled = {} ---@type table<integer, TileWindow>
local floating = {} ---@type table<integer, boolean>
local stopped = false

local function isPiP(title)
  title = (title or ""):lower():gsub("[^%a]", "")
  return title == "pictureinpicture" or title == "pip"
end

---@param space integer
---@return hs.geometry?
local function area(space)
  local screen = hs.screen.find(hs.spaces.spaceDisplay(space) or "")
  return screen and screen:frame()
end

---@param node TileNode
---@param frame hs.geometry
---@param out table<TileNode, hs.geometry>
local function measure(node, frame, out)
  if node.id then
    out[node] = frame
    return
  end
  local a, b = hs.geometry.copy(frame), hs.geometry.copy(frame)
  if node.vertical then
    a.w = math.floor(frame.w * node.ratio)
    b.x, b.w = frame.x + a.w, frame.w - a.w
  else
    a.h = math.floor(frame.h * node.ratio)
    b.y, b.h = frame.y + a.h, frame.h - a.h
  end
  measure(node.first, a, out)
  measure(node.second, b, out)
end

---@param space integer
---@return table<TileNode, hs.geometry>
local function frames(space)
  local out, tree, screen = {}, trees[space], area(space)
  if tree and screen then
    measure(tree, screen, out)
    for leaf in pairs(out) do
      if leaf.zoom then
        out[leaf] = screen
      end
    end
  end
  return out
end

---@param space integer
local function apply(space)
  for leaf, frame in pairs(frames(space)) do
    local id = leaf.id
    wm.frame(leaf.pid, id, frame.x, frame.y, frame.w, frame.h, function(ok, err)
      if not ok and tiled[id] then
        print(string.format("Tiling: window %d: %s", id, err))
      end
    end)
  end
end

---@param node TileNode
---@return TileNode
local function last(node)
  while not node.id do
    node = node.second
  end
  return node
end

---@param space integer
---@param window hs.window
local function insert(space, window)
  local id, pid = window:id(), window:application():pid()
  local leaf = { id = id, pid = pid }
  local root = trees[space]
  if not root then
    trees[space] = leaf
  else
    -- Split the last window along its longer side; the new window takes the second half.
    local target = last(root)
    local frame = frames(space)[target] or area(space)
    local split = {
      parent = target.parent,
      vertical = not frame or frame.w >= frame.h,
      ratio = 0.5,
      first = { id = target.id, pid = target.pid, zoom = target.zoom },
      second = leaf,
    }
    split.first.parent, leaf.parent = split, split
    tiled[target.id].leaf = split.first
    if target.parent then
      if target.parent.first == target then
        target.parent.first = split
      else
        target.parent.second = split
      end
    else
      trees[space] = split
    end
  end
  tiled[id] = { leaf = leaf, space = space }
end

---@param id integer
local function remove(id)
  local entry = tiled[id]
  if not entry then
    return
  end
  tiled[id] = nil
  local leaf, parent = entry.leaf, entry.leaf.parent
  if not parent then
    trees[entry.space] = nil
    return
  end
  local sibling = parent.first == leaf and parent.second or parent.first
  sibling.parent = parent.parent
  if parent.parent then
    if parent.parent.first == parent then
      parent.parent.first = sibling
    else
      parent.parent.second = sibling
    end
  else
    trees[entry.space] = sibling
  end
end

---@param window hs.window
---@return boolean
local function manageable(window)
  local app = window:application()
  return app ~= nil
    and apps[app:name()] == true
    and not app:isHidden()
    and window:isStandard()
    and not window:isMinimized()
    and not window:isFullScreen()
    and not isPiP(window:title())
    and not floating[window:id()]
end

-- Reconcile trees with the tracked windows, then lay out every Space that changed.
local function sync()
  if stopped then
    return
  end
  local changed, seen, ids, windows = {}, {}, {}, {}
  for _, window in ipairs(tiling.windows:getWindows()) do
    if manageable(window) then
      ids[#ids + 1] = window:id()
      windows[window:id()] = window
    end
  end
  local spaces = wm.native.spaces(ids)
  for id, window in pairs(windows) do
    local space = spaces[id]
    local entry = tiled[id]
    if space and area(space) then
      seen[id] = true
      if entry and entry.space ~= space then
        changed[entry.space] = true
        remove(id)
        entry = nil
      end
      if not entry then
        insert(space, window)
        changed[space] = true
      end
    end
  end
  for id, entry in pairs(tiled) do
    if not seen[id] then
      changed[entry.space] = true
      remove(id)
    end
  end
  for space in pairs(changed) do
    apply(space)
  end
end

---@param window hs.window
---@return TileWindow?
local function current(window)
  local entry = window and tiled[window:id()]
  if not entry then
    logger.error("Tiling: focused window is not tiled")
  end
  return entry
end

-- Nearest tiled window whose edge faces `direction`, by gap, then perpendicular center distance,
-- then top-most and left-most.
---@param from hs.geometry
---@param direction string
---@param candidates table<integer, hs.geometry>
---@return integer?
local function neighbor(from, direction, candidates)
  local best, bestGap, bestOffset, bestFrame
  for id, frame in pairs(candidates) do
    local gap, offset
    if direction == "east" then
      gap, offset = frame.x - (from.x + from.w), math.abs(frame.center.y - from.center.y)
    elseif direction == "west" then
      gap, offset = from.x - (frame.x + frame.w), math.abs(frame.center.y - from.center.y)
    elseif direction == "south" then
      gap, offset = frame.y - (from.y + from.h), math.abs(frame.center.x - from.center.x)
    else
      gap, offset = from.y - (frame.y + frame.h), math.abs(frame.center.x - from.center.x)
    end
    local overlaps = (direction == "east" or direction == "west")
        and frame.y < from.y + from.h and from.y < frame.y + frame.h
      or (direction == "north" or direction == "south")
        and frame.x < from.x + from.w and from.x < frame.x + frame.w
    local closer = not best
      or gap < bestGap
      or gap == bestGap
        and (offset < bestOffset or offset == bestOffset and (frame.y < bestFrame.y or frame.y == bestFrame.y and frame.x < bestFrame.x))
    if gap >= -1 and overlaps and closer then
      best, bestGap, bestOffset, bestFrame = id, gap, offset, frame
    end
  end
  return best
end

---@param space integer
---@param skip integer
---@return table<integer, hs.geometry>
local function peers(space, skip)
  local out = {}
  for leaf, frame in pairs(frames(space)) do
    if leaf.id ~= skip and not leaf.zoom then
      out[leaf.id] = frame
    end
  end
  return out
end

---Focuses the nearest tiled window in a direction, across displays.
---@param direction "north"|"south"|"east"|"west"
function tiling.focus(direction)
  local window = hs.window.focusedWindow()
  if not window then
    logger.error("Tiling: no focused window")
    return
  end
  local candidates = {}
  for _, space in pairs(hs.spaces.activeSpaces()) do
    for id, frame in pairs(peers(space, window:id())) do
      candidates[id] = frame
    end
  end
  local target = neighbor(window:frame(), direction, candidates)
  if not target then
    logger.error("Tiling: no window to the " .. direction)
    return
  end
  local leaf = tiled[target].leaf
  wm.native.focus(leaf.pid, leaf.id, function(ok, err)
    if not ok then
      logger.error("Tiling: focus failed: " .. err)
    end
  end)
end

---@param direction string
---@return TileWindow?, TileWindow?
local function pair(direction)
  local window = hs.window.focusedWindow()
  local entry = current(window)
  if not entry then
    return
  end
  local frame = frames(entry.space)[entry.leaf]
  local target = frame and neighbor(frame, direction, peers(entry.space, entry.leaf.id))
  if not target then
    logger.error("Tiling: no window to the " .. direction)
    return
  end
  return entry, tiled[target]
end

---Swaps the focused window with its neighbor.
---@param direction "north"|"south"|"east"|"west"
function tiling.swap(direction)
  local a, b = pair(direction)
  if not a or not b then
    return
  end
  local x, y = a.leaf, b.leaf
  x.id, y.id, x.pid, y.pid = y.id, x.id, y.pid, x.pid
  tiled[x.id].leaf, tiled[y.id].leaf = x, y
  apply(a.space)
end

---Re-inserts the focused window by splitting its neighbor, on the side it moved toward.
---@param direction "north"|"south"|"east"|"west"
function tiling.warp(direction)
  local a, b = pair(direction)
  if not a or not b then
    return
  end
  local id, pid, target, space = a.leaf.id, a.leaf.pid, b.leaf, a.space
  remove(id)
  target = tiled[target.id].leaf
  local leaf = { id = id, pid = pid }
  local moved = { id = target.id, pid = target.pid, zoom = target.zoom }
  local ahead = direction == "west" or direction == "north"
  local split = {
    parent = target.parent,
    vertical = direction == "east" or direction == "west",
    ratio = 0.5,
    first = ahead and leaf or moved,
    second = ahead and moved or leaf,
  }
  leaf.parent, moved.parent = split, split
  if target.parent then
    if target.parent.first == target then
      target.parent.first = split
    else
      target.parent.second = split
    end
  else
    trees[space] = split
  end
  tiled[moved.id].leaf = moved
  tiled[id] = { leaf = leaf, space = space }
  apply(space)
end

---@param node TileNode
---@param space integer
---@return hs.geometry?
local function bounds(node, space)
  if not node.parent then
    return area(space)
  end
  local parent = node.parent
  local frame = bounds(parent, space)
  if not frame then
    return
  end
  local out = hs.geometry.copy(frame)
  local cut = parent.vertical and math.floor(frame.w * parent.ratio) or math.floor(frame.h * parent.ratio)
  if parent.vertical then
    out.w = parent.first == node and cut or frame.w - cut
    out.x = parent.first == node and frame.x or frame.x + cut
  else
    out.h = parent.first == node and cut or frame.h - cut
    out.y = parent.first == node and frame.y or frame.y + cut
  end
  return out
end

---Moves one edge of the focused window by `delta` points (negative is left or up).
---@param edge "left"|"right"|"top"|"bottom"
---@param delta number
function tiling.resize(edge, delta)
  local entry = current(hs.window.focusedWindow())
  if not entry then
    return
  end
  local vertical = edge == "left" or edge == "right"
  local second = edge == "left" or edge == "top"
  local node = entry.leaf
  while node.parent do
    local parent = node.parent
    if parent.vertical == vertical and (parent.second == node) == second then
      local frame = bounds(parent, entry.space)
      if not frame then
        return
      end
      parent.ratio = math.min(0.9, math.max(0.1, parent.ratio + delta / (vertical and frame.w or frame.h)))
      apply(entry.space)
      return
    end
    node = parent
  end
  logger.error("Tiling: no " .. edge .. " edge to move")
end

---Resets every split on the focused window's Space to equal halves.
function tiling.balance()
  local window = hs.window.focusedWindow()
  local space = window and wm.spaceOf(window:id()) or hs.spaces.focusedSpace()
  local function reset(node)
    if node and not node.id then
      node.ratio = 0.5
      reset(node.first)
      reset(node.second)
    end
  end
  reset(trees[space])
  apply(space)
end

---Toggles the focused window between its tile and the whole Space.
function tiling.zoom()
  local entry = current(hs.window.focusedWindow())
  if not entry then
    return
  end
  local zoom = not entry.leaf.zoom
  for _, other in pairs(tiled) do
    if other.space == entry.space then
      other.leaf.zoom = nil
    end
  end
  entry.leaf.zoom = zoom or nil
  apply(entry.space)
end

---Toggles whether the focused window is tiled.
function tiling.float()
  local window = hs.window.focusedWindow()
  if not window then
    logger.error("Tiling: no focused window")
    return
  end
  local id = window:id()
  floating[id] = not floating[id] or nil
  sync()
end

tiling.windows = filter.new(function(window)
  local app = window:application()
  return app ~= nil and apps[app:name()] == true
end)
tiling.windows:subscribe({
  filter.windowCreated,
  filter.windowDestroyed,
  filter.windowMinimized,
  filter.windowUnminimized,
  filter.windowHidden,
  filter.windowUnhidden,
  filter.windowTitleChanged,
}, function(_, _, event, id)
  if event == filter.windowDestroyed then
    floating[id] = nil
  end
  sync()
end)
tiling.spaces = hs.spaces.watcher.new(sync):start()
tiling.screens = hs.screen.watcher.new(function()
  for space in pairs(trees) do
    apply(space)
  end
end):start()
sync()

-- Exposed for the Hammerspoon console.
function tiling.status()
  local out = {}
  for id, entry in pairs(tiled) do
    out[id] = { space = entry.space, zoom = entry.leaf.zoom, floating = floating[id] }
  end
  return out
end

function tiling.stop()
  stopped = true
  tiling.spaces:stop()
  tiling.screens:stop()
  tiling.windows:delete()
end


return tiling
