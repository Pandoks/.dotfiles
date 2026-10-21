local filter = require("lib.window_filter")
local logger = require("lib.logger")
local windowManager = require("lib.window_manager")

-- Tiled apps, set by `tiling.manage`.
local apps = {} ---@type table<string, boolean>

---@class TileLeaf
---@field parent? TileSplit
---@field id integer
---@field pid integer
---@field zoom? boolean

---@class TileSplit
---@field parent? TileSplit
---@field vertical boolean children side by side
---@field ratio number
---@field first TileNode
---@field second TileNode

---@alias TileNode TileLeaf|TileSplit

---@class TileWindow
---@field leaf TileLeaf
---@field space integer

local tiling = {}
local trees = {} ---@type table<integer, TileNode>
local tiled = {} ---@type table<integer, TileWindow>
local floating = {} ---@type table<integer, boolean>
local moving = {} ---@type table<integer, integer> frame updates in flight per window
local stopped = false

local function isPiP(title)
  title = (title or ""):lower():gsub("[^%a]", "")
  return title == "pictureinpicture" or title == "pip"
end

---@param space integer
---@return hs.geometry?
local function area(space)
  -- A string hint matches screen names too, so a missing display must not reach `find`.
  local display = hs.spaces.spaceDisplay(space)
  local screen = display and hs.screen.find(display)
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
  local first, second = hs.geometry.copy(frame), hs.geometry.copy(frame)
  if node.vertical then
    first.w = math.floor(frame.w * node.ratio)
    second.x, second.w = frame.x + first.w, frame.w - first.w
  else
    first.h = math.floor(frame.h * node.ratio)
    second.y, second.h = frame.y + first.h, frame.h - first.h
  end
  measure(node.first, first, out)
  measure(node.second, second, out)
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
    moving[id] = (moving[id] or 0) + 1
    windowManager.frame(leaf.pid, id, frame.x, frame.y, frame.w, frame.h, function(ok, err)
      moving[id] = moving[id] > 1 and moving[id] - 1 or nil
      if not ok and tiled[id] then
        logger.error(string.format("Tiling: window %d: %s", id, err))
      end
    end)
  end
end

-- Puts `new` where `old` sits in its parent, or at the root.
---@param space integer
---@param old TileNode
---@param new TileNode
local function replace(space, old, new)
  local parent = old.parent
  new.parent = parent
  if not parent then
    trees[space] = new
  elseif parent.first == old then
    parent.first = new
  else
    parent.second = new
  end
end

---@param space integer
---@param id integer
---@param pid integer
local function insert(space, id, pid)
  local leaf = { id = id, pid = pid }
  local root = trees[space]
  if not root then
    trees[space] = leaf
  else
    -- Split the last window along its longer side; the new window takes the second half.
    local target = root
    while target.second do
      target = target.second
    end
    ---@cast target TileLeaf
    local frame = frames(space)[target] or area(space)
    local moved = { id = target.id, pid = target.pid, zoom = target.zoom }
    local split =
      { vertical = not frame or frame.w >= frame.h, ratio = 0.5, first = moved, second = leaf }
    moved.parent, leaf.parent = split, split
    tiled[target.id].leaf = moved
    replace(space, target, split)
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
  replace(entry.space, parent, parent.first == leaf and parent.second or parent.first)
end

---@param window hs.window
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
      windows[#windows + 1] = window
    end
  end
  -- Most recently used first, so a reload builds the same layout.
  local spaces = windowManager.native.spaces(ids)
  for index, window in ipairs(windows) do
    local id = ids[index]
    local space = spaces[id]
    local entry = tiled[id]
    if space and area(space) then
      seen[id] = true
      if entry and entry.space ~= space then
        changed[entry.space] = true
        remove(id)
      end
      if not tiled[id] then
        insert(space, id, assert(window:application()):pid())
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
        and frame.y < from.y + from.h
        and from.y < frame.y + frame.h
      or (direction == "north" or direction == "south")
        and frame.x < from.x + from.w
        and from.x < frame.x + frame.w
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

-- Candidates include tiled windows on other displays.
---@param direction "north"|"south"|"east"|"west"
function tiling.focus(direction)
  local window = hs.window.focusedWindow()
  if not window then
    logger.error("Tiling: no focused window")
    return
  end
  local id = window:id() --[[@as integer]]
  local own = windowManager.spaceOf(id)
  local candidates = {}
  for _, space in pairs(hs.spaces.activeSpaces() or {}) do
    if space == own then
      for other, frame in pairs(peers(space, id)) do
        candidates[other] = frame
      end
    else
      -- On another display, a zoomed window is the only one showing.
      local shown = frames(space)
      for leaf, frame in pairs(shown) do
        if leaf.zoom then
          shown = { [leaf] = frame }
          break
        end
      end
      for leaf, frame in pairs(shown) do
        candidates[leaf.id] = frame
      end
    end
  end
  local target = neighbor(window:frame(), direction, candidates)
  if not target then
    logger.error("Tiling: no window to the " .. direction)
    return
  end
  local leaf = tiled[target].leaf
  windowManager.native.focus(leaf.pid, leaf.id, function(ok, err)
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

---@param direction "north"|"south"|"east"|"west"
function tiling.swap(direction)
  local focused, other = pair(direction)
  if not focused or not other then
    return
  end
  local mine, theirs = focused.leaf, other.leaf
  mine.id, theirs.id, mine.pid, theirs.pid = theirs.id, mine.id, theirs.pid, mine.pid
  tiled[mine.id].leaf, tiled[theirs.id].leaf = mine, theirs
  apply(focused.space)
end

-- The focused window splits its neighbor, on the side it moved toward.
---@param direction "north"|"south"|"east"|"west"
function tiling.warp(direction)
  local focused, other = pair(direction)
  if not focused or not other then
    return
  end
  local id, pid, target, space = focused.leaf.id, focused.leaf.pid, other.leaf, focused.space
  remove(id)
  target = tiled[target.id].leaf
  local leaf = { id = id, pid = pid }
  local moved = { id = target.id, pid = target.pid, zoom = target.zoom }
  local ahead = direction == "west" or direction == "north"
  local split = {
    vertical = direction == "east" or direction == "west",
    ratio = 0.5,
    first = ahead and leaf or moved,
    second = ahead and moved or leaf,
  }
  leaf.parent, moved.parent = split, split
  replace(space, target, split)
  tiled[moved.id].leaf = moved
  tiled[id] = { leaf = leaf, space = space }
  apply(space)
end

---@param node TileNode
---@param space integer
---@return hs.geometry?
local function bounds(node, space)
  local parent = node.parent
  if not parent then
    return area(space)
  end
  local frame = bounds(parent, space)
  if not frame then
    return
  end
  local out = hs.geometry.copy(frame)
  local cut = parent.vertical and math.floor(frame.w * parent.ratio)
    or math.floor(frame.h * parent.ratio)
  if parent.vertical then
    out.w = parent.first == node and cut or frame.w - cut
    out.x = parent.first == node and frame.x or frame.x + cut
  else
    out.h = parent.first == node and cut or frame.h - cut
    out.y = parent.first == node and frame.y or frame.y + cut
  end
  return out
end

---@param edge "left"|"right"|"top"|"bottom"
---@param delta number points; negative moves the edge left or up
function tiling.resize(edge, delta)
  local entry = current(hs.window.focusedWindow())
  if not entry then
    return
  end
  local vertical = edge == "left" or edge == "right"
  local second = edge == "left" or edge == "top"
  ---@type TileNode
  local node = entry.leaf
  local parent = node.parent
  while parent do
    if parent.vertical == vertical and (parent.second == node) == second then
      local frame = bounds(parent, entry.space)
      if not frame then
        return
      end
      parent.ratio =
        math.min(0.9, math.max(0.1, parent.ratio + delta / (vertical and frame.w or frame.h)))
      apply(entry.space)
      return
    end
    node, parent = parent, parent.parent
  end
  logger.error("Tiling: no " .. edge .. " edge to move")
end

function tiling.balance()
  local window = hs.window.focusedWindow()
  local space = window and windowManager.spaceOf(window:id() --[[@as integer]])
    or hs.spaces.focusedSpace()
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

function tiling.float()
  local window = hs.window.focusedWindow()
  if not window then
    logger.error("Tiling: no focused window")
    return
  end
  local id = window:id() --[[@as integer]]
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

-- Windows moved or resized by hand snap back to their tile, after the drag when there is one.
local dragged = {} ---@type table<integer, boolean>
tiling.windows:subscribe(filter.windowMoved, function(window, _, _, id)
  local entry = tiled[id]
  local tile = entry and not moving[id] and frames(entry.space)[entry.leaf]
  if not tile or window:frame():equals(tile) then
    return
  end
  if hs.mouse.getButtons()[1] then
    dragged[entry.space] = true
  else
    apply(entry.space)
  end
end)
tiling.release = hs.eventtap
  .new({ hs.eventtap.event.types.leftMouseUp }, function()
    for space in pairs(dragged) do
      apply(space)
    end
    dragged = {}
    return false
  end)
  :start() --[[@as hs.eventtap]]
tiling.spaces = hs.spaces.watcher.new(sync):start() --[[@as hs.spaces.watcher]]
tiling.screens = hs.screen.watcher
  .new(function()
    for space in pairs(trees) do
      apply(space)
    end
  end)
  :start() --[[@as hs.screen.watcher]]
sync()

---@param names string[] app names to tile
function tiling.manage(names)
  apps = {}
  for _, name in ipairs(names) do
    apps[name] = true
  end
  sync()
end

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
  tiling.release:stop()
  tiling.spaces:stop()
  tiling.screens:stop()
  tiling.windows:delete()
end

return tiling
