local dock = require("lib.dock")
local filter = require("lib.window_filter")
local logger = require("lib.logger")
local missionControl = require("lib.mission_control")
local windowManager = require("lib.window_manager")
local module = {}
local recent, guard, lastFocused = {}, nil, nil
local stopped = false
local lastSpace = hs.spaces.focusedSpace()
local marker = 1397769029
local lastResult
local transitionSpace, transitionDeadline
local lastClick = -math.huge
local activation, dropped
---@type table<string, { screen: hs.screen, frame: hs.geometry }>
local screens = {}

local function isPiP(title)
  title = (title or ""):lower():gsub("[^%a]", "")
  return title == "pictureinpicture" or title == "pip"
end

-- Without Screen Recording, `hs.window.list(true)` omits titles.
---@param info table `hs.window.list(true)` entry
---@param states? table<integer, WindowState>
---@return string
local function titleOf(info, states)
  if info.kCGWindowName then
    return info.kCGWindowName
  end
  local state = (states or filter.statesOf(info.kCGWindowOwnerPID))[info.kCGWindowNumber]
  return state and state.title or ""
end

local function eligible(row)
  return row.app ~= "Hammerspoon" and not isPiP(row.title)
end

---@param list table[]
---@param pid? integer
---@return boolean
local function hasPiPFor(list, pid)
  if not pid then
    return false
  end
  for _, entry in ipairs(list) do
    if entry.kCGWindowOwnerPID == pid then
      local layer = entry.kCGWindowLayer
      if (entry.kCGWindowName ~= nil or layer == nil or layer > 0) and isPiP(titleOf(entry)) then
        return true
      end
    end
  end
  return false
end

---@param list table[]
---@param pid? integer
---@param frame table
---@return boolean
local function hasOutsideWindowFor(list, pid, frame)
  if not pid then
    return false
  end
  for _, entry in ipairs(list) do
    if entry.kCGWindowOwnerPID == pid and (entry.kCGWindowLayer or 0) == 0 then
      local bounds = entry.kCGWindowBounds
      local x, y = bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2
      if
        not (x >= frame.x and x < frame.x + frame.w and y >= frame.y and y < frame.y + frame.h)
      then
        return true
      end
    end
  end
  return false
end

-- WindowServer order needs no app replies; focus can be on another screen (e.g. PiP).
-- Plain `list()` drops windows in front of the first one titled "Dock".
local function snapshot(frame, list, needFocused, knownFocusedID)
  local focusedID
  if knownFocusedID ~= nil then
    focusedID = knownFocusedID or nil
  elseif needFocused then
    local focusedWindow = hs.window.focusedWindow()
    focusedID = focusedWindow and focusedWindow:id()
  end
  local rows, cover, tracked, focused = {}, {}, {}, nil
  for _, info in
    ipairs(list or hs.window.list(true) --[[@as table[] ]])
  do
    local id, pid, layer, bounds =
      info.kCGWindowNumber, info.kCGWindowOwnerPID, info.kCGWindowLayer, info.kCGWindowBounds
    local x, y = bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2
    local inside = x >= frame.x and x < frame.x + frame.w and y >= frame.y and y < frame.y + frame.h
    if layer >= 0 and layer < 20 and (inside or id == focusedID) then
      if inside then
        tracked[pid] = tracked[pid] or filter.statesOf(pid)
      end
      local row = {
        id = id,
        pid = pid,
        app = info.kCGWindowOwnerName,
        title = titleOf(info, inside and tracked[pid] or nil),
        frame = { x = bounds.X, y = bounds.Y, w = bounds.Width, h = bounds.Height },
        inside = inside,
      }
      if inside then
        cover[#cover + 1] = row
        if layer == 0 and tracked[pid][id] then
          rows[#rows + 1] = row
        end
      end
      if id == focusedID then
        focused = row
      end
    end
  end
  return rows, focused, cover
end

local function switcherBusy()
  local menu = package.loaded["lib.window_switcher"]
  return menu ~= nil and menu.isBusy()
end

local function menuBusy()
  return switcherBusy() or missionControl.isActive()
end

---@return table[]?, string?
local function managedSpaces()
  local layout, err = windowManager.native.displaySpaces()
  if not layout then
    return nil, err
  end
  local spaces = {}
  for index, space in ipairs(layout.spaces) do
    spaces[index] = { ManagedSpaceID = space.id, display = space.display }
  end
  return spaces
end

local function spaceIndex(id, spaces)
  spaces = spaces or managedSpaces()
  for index, space in ipairs(spaces or {}) do
    if space.ManagedSpaceID == id then
      return index
    end
  end
end

local function finish(job, ok, err)
  if guard ~= job then
    return
  end
  guard = nil
  if job.deadlineTimer then
    job.deadlineTimer:stop()
    job.deadlineTimer = nil
  end
  if job.task then
    job.task:stop()
    job.task = nil
  end
  lastResult =
    { ok = ok, error = err, space = job.space, window = job.target, desktop = job.desktop }
  if err and err ~= "superseded" and err ~= "stopped" then
    transitionSpace, transitionDeadline = nil, nil
    logger.error("Space focus: " .. err)
  end
end

local function shown(space, focused)
  if (focused or hs.spaces.focusedSpace()) == space then
    return true
  end
  local layout = windowManager.native.displaySpaces()
  for _, active in pairs(layout and layout.active or {}) do
    if active == space then
      return true
    end
  end
  return false
end

local function valid(job, checked)
  if guard ~= job or job.switching then
    return false
  end
  if stopped or (not checked and switcherBusy()) or not shown(job.space) then
    finish(job, false, "superseded")
    return false
  end
  if not checked and (missionControl.isActive() or not shown(job.space)) then
    finish(job, false, "superseded")
    return false
  end
  return guard == job
end

local function defer(job, callback)
  job.task = hs.timer.doAfter(0, function()
    job.task = nil
    if valid(job) then
      callback()
    end
  end)
end

local function desktopPoint(screen, rows)
  local frame = screen:frame()
  for _, vertical in ipairs({ 0.5, 0.35, 0.65, 0.2, 0.8 }) do
    for _, horizontal in ipairs({ 0.5, 0.35, 0.65, 0.2, 0.8 }) do
      local point = { x = frame.x + frame.w * horizontal, y = frame.y + frame.h * vertical }
      local covered = false
      for _, row in ipairs(rows) do
        local windowFrame = row.frame
        if
          point.x >= windowFrame.x - 8
          and point.x < windowFrame.x + windowFrame.w + 8
          and point.y >= windowFrame.y - 8
          and point.y < windowFrame.y + windowFrame.h + 8
        then
          covered = true
          break
        end
      end
      if not covered then
        return point
      end
    end
  end
end

local function check(job, list, checked, knownFocusedID)
  if job.task or (job.probing and knownFocusedID == nil) or not valid(job, checked) then
    return
  end
  if knownFocusedID ~= nil then
    job.probing = nil
  end
  list = list or hs.window.list(true) --[[@as table[] ]]
  local rows, focused, cover = snapshot(job.frame, list, false, knownFocusedID)
  local candidate, targetValid, targetRow
  for _, row in ipairs(rows) do
    if row.id == job.target and row.pid == job.targetPID and eligible(row) then
      targetValid = true
      targetRow = row
    end
    if eligible(row) then
      candidate = candidate or row
      if job.preferred and row.id == job.preferred.id and row.pid == job.preferred.pid then
        candidate = row
        job.preferred = nil
        job.candidate = row.id
      end
      if row.id == job.candidate then
        candidate = row
      end
    end
  end
  if job.target and not targetValid then
    finish(job, false, "target window is no longer available")
    return
  end
  local front = hs.application.frontmostApplication()
  local frontPid = front and front:pid()
  if knownFocusedID == nil then
    if job.target then
      if
        lastFocused
        and lastFocused.id == job.target
        and lastFocused.pid == job.targetPID
        and (not frontPid or frontPid == job.targetPID)
      then
        focused = targetRow
      else
        job.probing = true
        windowManager.native.focusedWindow(job.targetPID, function(id)
          if guard ~= job then
            return
          end
          job.probing = nil
          local nowFront = hs.application.frontmostApplication()
          local nowPid = nowFront and nowFront:pid()
          if id and nowPid and nowPid ~= job.targetPID then
            id = false
          end
          check(job, nil, nil, id or false)
        end)
        return
      end
    elseif not job.force and not job.desktop then
      if frontPid and not hasPiPFor(list, frontPid) then
        finish(job, true)
        return
      elseif frontPid then
        job.probing = true
        windowManager.native.focusedWindow(frontPid, function(id)
          if guard ~= job then
            return
          end
          job.probing = nil
          check(job, nil, nil, id or false)
        end)
        return
      else
        rows, focused, cover = snapshot(job.frame, list, true)
      end
    elseif candidate then
      if
        frontPid
        and frontPid == candidate.pid
        and lastFocused
        and lastFocused.id == candidate.id
        and lastFocused.pid == candidate.pid
        and not hasPiPFor(list, frontPid)
      then
        recent[job.space] = { id = candidate.id, pid = candidate.pid }
        finish(job, true)
        return
      end
    elseif not job.desktop then
      if
        frontPid
        and front
        and front:bundleID() == "com.apple.finder"
        and hs.spaces.focusedSpace() == job.space
        and not hasPiPFor(list, frontPid)
        and not hasOutsideWindowFor(list, frontPid, job.frame)
      then
        finish(job, true)
        return
      elseif frontPid then
        job.probing = true
        windowManager.native.focusedWindow(frontPid, function(id)
          if guard ~= job then
            return
          end
          job.probing = nil
          check(job, nil, nil, id or false)
        end)
        return
      else
        rows, focused, cover = snapshot(job.frame, list, true)
      end
    end
  end
  if
    job.target
    and focused
    and focused.id == job.target
    and focused.pid == job.targetPID
    and eligible(focused)
  then
    recent[job.space] = { id = focused.id, pid = focused.pid }
    finish(job, true)
    return
  end
  -- After the desktop click, focus is left to the transition.
  if not job.force and (job.desktop or not (focused and isPiP(focused.title))) then
    finish(job, true)
    return
  end
  if candidate and focused and focused.id == candidate.id then
    finish(job, true)
    return
  end
  if hs.timer.secondsSinceEpoch() >= job.deadline then
    finish(job, false, "timed out restoring focus")
    return
  end
  if candidate then
    if job.target then
      return
    end
    job.target = candidate.id
    job.targetPID = candidate.pid
    defer(job, function()
      windowManager.native.focus(candidate.pid, candidate.id, function(focusedOK, focusError)
        if valid(job) then
          if not focusedOK then
            finish(job, false, focusError or "window focus failed")
          else
            check(job)
          end
        end
      end, job.space)
    end)
  elseif not job.desktop then
    if
      hs.spaces.focusedSpace() == job.space
      and not (focused and (isPiP(focused.title) or not focused.inside))
    then
      finish(job, true)
      return
    end
    job.desktop = true
    defer(job, function()
      local point = desktopPoint(job.screen, cover)
      if not point then
        finish(job, false, "no uncovered desktop point")
        return
      end
      job.force = false
      dropped = false
      local event = hs.eventtap.event
      local pointer = hs.mouse.absolutePosition()
      for _, kind in ipairs({ event.types.leftMouseDown, event.types.leftMouseUp }) do
        local click = event.newMouseEvent(kind, point, {})
        click:setProperty(event.properties.eventSourceUserData, marker)
        click:setProperty(event.properties.mouseEventClickState, 1)
        click:post()
      end
      local movement = event.newMouseEvent(event.types.mouseMoved, pointer, {})
      movement:setProperty(event.properties.eventSourceUserData, marker)
      movement:post()
      -- An already active Finder reports no activation for its desktop.
      local activeFront = hs.application.frontmostApplication()
      if activeFront and activeFront:bundleID() == "com.apple.finder" then
        finish(job, true)
      end
    end)
  end
end

local function restore(job, list, checked)
  if job.deadlineTimer then
    job.deadlineTimer:stop()
  end
  job.switching = nil
  local display = job.display or hs.spaces.spaceDisplay(job.space)
  local cached = display and screens[display]
  if not cached then
    local screen = display and hs.screen.find(display)
    if not screen then
      finish(job, false, "Space display unavailable")
      return
    end
    cached = { screen = screen, frame = screen:fullFrame() }
    screens[display] = cached
  end
  job.screen, job.frame = cached.screen, cached.frame
  job.deadline = hs.timer.secondsSinceEpoch() + 0.8
  job.deadlineTimer = hs.timer.doAfter(0.8, function()
    finish(job, false, "timed out restoring focus")
  end)
  -- Focus can still be on another display.
  lastSpace = hs.spaces.focusedSpace()
  transitionSpace, transitionDeadline = job.space, job.deadline
  check(job, list, checked)
end

local function protect(space, force, preferred, list, checked)
  if guard then
    finish(guard, false, "superseded")
  end
  if stopped or (not checked and menuBusy()) then
    return
  end
  local job = { space = space, force = force, preferred = preferred }
  guard = job
  restore(job, list, true)
end

-- After the switch, a shown Space arrives on a focus event, or at once on another display.
local function arrive(space, settled, list)
  local job = guard
  if
    not job
    or not job.switching
    or (
      job.space ~= space
      and not (job.replied and (settled or job.away) and shown(job.space, space))
    )
  then
    return false
  end
  restore(job, list)
  return true
end

function module.switchSpace(selector)
  local fromSpace = guard and guard.switching and guard.space or hs.spaces.focusedSpace()
  local spaces, err = managedSpaces()
  if not spaces then
    logger.error("Space focus: " .. tostring(err))
    return
  end
  local index, from = tonumber(selector), spaceIndex(fromSpace, spaces)
  if selector == "prev" or selector == "next" then
    index = from and from + (selector == "prev" and -1 or 1)
    local target = index and spaces[index]
    if not target or target.display ~= spaces[from].display then
      return
    end
  end
  local target = index and spaces[index]
  if stopped then
    return
  elseif not target then
    logger.error("Space focus: Space does not exist")
    return
  end
  local moving = guard and guard.switching
  if guard then
    windowManager.native.cancelFocus()
    finish(guard, false, "superseded")
  end
  local job = {
    space = target.ManagedSpaceID,
    display = target.display,
    away = from ~= nil and spaces[from].display ~= target.display,
    preferred = recent[target.ManagedSpaceID],
    force = true,
    switching = true,
  }
  guard = job
  if not moving and hs.spaces.focusedSpace() == job.space then
    restore(job)
  else
    job.deadlineTimer = hs.timer.doAfter(1.5, function()
      finish(job, false, "timed out waiting for Space " .. index)
    end)
    windowManager.space(index --[[@as number]], function(ok, message)
      if guard ~= job then
        return
      end
      -- Focus can update just after the display does; notifications finish the job.
      local space = hs.spaces.focusedSpace()
      if ok or space == job.space then
        job.replied = true
        arrive(space)
      else
        finish(job, false, message or "switch failed")
      end
    end)
  end
end

---@param index integer Mission Control index
function module.moveWindow(index)
  local window = hs.window.focusedWindow()
  local app = window and window:application()
  local spaces, err = managedSpaces()
  local target = spaces and spaces[index]
  if not app then
    return
  elseif not target then
    logger.error("Space focus: " .. (err or "Space does not exist"))
    return
  end
  local id, space = window:id(), target.ManagedSpaceID
  dock.move(id --[[@as integer]], space, function(moved, failure)
    if not moved then
      logger.error("Space focus: " .. tostring(failure))
      return
    end
    recent[space] = { id = id, pid = app:pid() }
    module.switchSpace(index)
  end)
end

function module.bindArrowKeys()
  if module.keys then
    module.keys:stop()
  end
  local types, keys = hs.eventtap.event.types, hs.keycodes.map
  local swallowed = {}
  module.keys = hs.eventtap
    .new({ types.keyDown, types.keyUp }, function(event)
      local kind, key = event:getType(), event:getKeyCode()
      if kind == types.keyUp then
        local handled = swallowed[key]
        swallowed[key] = nil
        return handled or false
      end
      if stopped or (key ~= keys.left and key ~= keys.right) then
        return false
      end
      local flags = event:getFlags()
      if not flags.ctrl or flags.cmd or flags.alt or flags.shift then
        return false
      end
      -- Needs macOS Move left/right a space shortcuts; passing through keeps Mission Control open.
      if missionControl.isActive() then
        swallowed[key] = nil
        return false
      end
      swallowed[key] = true
      module.switchSpace(key == keys.left and "prev" or "next")
      return true
    end)
    :start() --[[@as hs.eventtap]]
end

-- An app activated onto its PiP (e.g. from the Dock) continues to its latest real window.
local function leavePiP(id, pid, list)
  local now = hs.timer.secondsSinceEpoch()
  if
    not id
    or not activation
    or activation.pid ~= pid
    or now - activation.time > 0.5
    or guard
    or (transitionDeadline and now < transitionDeadline)
  then
    return
  end
  local info
  for _, entry in
    ipairs(list or hs.window.list(true) --[[@as table[] ]])
  do
    if entry.kCGWindowNumber == id then
      info = entry
      break
    end
  end
  local bounds = info and info.kCGWindowBounds
  if
    not bounds
    or not isPiP(titleOf(info))
    or hs.geometry
      .new(hs.mouse.absolutePosition())
      :inside({ x = bounds.X, y = bounds.Y, w = bounds.Width, h = bounds.Height })
  then
    return
  end
  local states, ids, candidates = filter.statesOf(pid), {}, {}
  for other in pairs(states) do
    ids[#ids + 1] = other
  end
  table.sort(ids)
  for _, other in ipairs(ids) do
    local state = states[other]
    if other ~= id and not isPiP(state.title) and not state.minimized then
      candidates[#candidates + 1] = { id = other, pid = pid }
    end
  end
  local menu = package.loaded["lib.window_switcher"]
  local target = menu and menu.mostRecent(candidates) or candidates[1]
  if target then
    windowManager.native.focus(target.pid, target.id, function(ok, err)
      if not ok then
        logger.error("Space focus: PiP redirect: " .. err)
      end
    end)
  end
end

local function showing(now, focused)
  return transitionSpace ~= nil
    and (now or hs.timer.secondsSinceEpoch()) < transitionDeadline
    and shown(transitionSpace, focused)
end

-- Undo PiP taking focus from a Space just shown, on any display.
local function retake(list, now, focused)
  if guard or not showing(now, focused) then
    return false
  end
  protect(transitionSpace, false, recent[transitionSpace], list)
  return true
end

local function recordManaged(space)
  if type(space) == "number" then
    lastSpace = space
    local target = windowManager.focusedTarget()
    if target and target.space == space and target.id and target.pid then
      local entry = { id = target.id, pid = target.pid }
      recent[space] = entry
      lastFocused = entry
    end
  end
end

local function observe(list, name, state)
  if stopped then
    return
  end
  local space = hs.spaces.focusedSpace()
  if type(space) ~= "number" then
    return
  end
  if guard and guard.switching then
    arrive(space, true, list)
    return
  end
  local windowID = state and state.id
  local title = state and state.title
  if not guard and windowManager.isBusy(space) then
    local target = windowManager.focusedTarget()
    if not windowID or not target or target.id == windowID or isPiP(title) then
      recordManaged(space)
      return
    end
  end
  local changed = space ~= lastSpace
  lastSpace = space
  if state then
    if isPiP(title) then
      lastFocused = nil
    elseif state.standard and name ~= "Hammerspoon" and state.pid then
      local entry = { id = windowID, pid = state.pid }
      recent[space] = entry
      lastFocused = entry
    end
  end
  -- Another display's Space can take focus just after the event that moved it.
  if guard and (guard.space == space or guard.away) then
    check(guard, list, nil, windowID)
  end
  local now = hs.timer.secondsSinceEpoch()
  if state and isPiP(title) and retake(list, now, space) then
    return
  elseif
    changed
    and not (guard and guard.switching)
    and now - lastClick > 0.2
    -- Focus moving off a Space still shown can be PiP taking it; its focus event decides.
    and not showing(now, space)
    and not menuBusy()
  then
    transitionSpace, transitionDeadline = space, now + 0.8
    protect(space, false, recent[space], list, true)
  end
  if state and activation and isPiP(title) then
    leavePiP(windowID, state.pid, list)
  end
end

-- Catches transitions to apps without standard windows (e.g. the desktop).
module.appWatcher = hs.application.watcher
  .new(function(_, event, app)
    if event ~= hs.application.watcher.activated or not app then
      return
    end
    local space = hs.spaces.focusedSpace()
    if not guard and windowManager.isBusy(space, app:pid()) then
      recordManaged(space)
      return
    end
    -- The PiP can take focus just before or after activation, and again after a redirect.
    local pid, now = app:pid(), hs.timer.secondsSinceEpoch()
    activation = { pid = pid, time = now }
    local list = hs.window.list(true) --[[@as table[] ]]
    local window
    for _, entry in ipairs(list) do
      if
        entry.kCGWindowOwnerPID == pid
        and (entry.kCGWindowName ~= nil or entry.kCGWindowLayer == nil or entry.kCGWindowLayer > 0)
        and isPiP(titleOf(entry))
      then
        window = app:focusedWindow()
        if window and window:id() == entry.kCGWindowNumber then
          retake(list)
        end
        break
      end
    end
    observe(list)
    leavePiP(window and window:id(), pid, list)
  end)
  :start() --[[@as hs.application.watcher]]

local types = hs.eventtap.event.types
module.input = hs.eventtap
  .new({ types.leftMouseDown, types.leftMouseUp, types.rightMouseDown }, function(event)
    local user = event:getProperty(hs.eventtap.event.properties.eventSourceUserData) ~= marker
    if user and event:getType() ~= types.leftMouseUp then
      -- A desktop click queued behind this one is dropped too.
      dropped = true
      lastClick = hs.timer.secondsSinceEpoch() --[[@as number]]
      transitionSpace, transitionDeadline = nil, nil
      if guard then
        finish(guard, false, "superseded")
      end
    end
    return not user and dropped
  end)
  :start() --[[@as hs.eventtap]]
module.windows = filter.new(function(_, _, state)
  return state.standard
end)
module.windows:subscribe(filter.windowFocused, function(_, name, _, _, state)
  observe(nil, name, state)
end)
module.watcher = hs.spaces.watcher
  .new(function()
    if stopped then
      return
    end
    local space = hs.spaces.focusedSpace()
    if arrive(space) then
      return
    end
    if not (guard and guard.switching) and windowManager.isBusy(space) then
      recordManaged(space)
      return
    end
    local now = hs.timer.secondsSinceEpoch()
    if space ~= lastSpace and not (guard and guard.switching) and now - lastClick > 0.2 then
      lastSpace = space
      transitionSpace, transitionDeadline = space, now + 0.8
      protect(space, false, recent[space])
    end
  end)
  :start() --[[@as hs.spaces.watcher]]
if hs.screen.watcher then
  module.screenWatcher = hs.screen.watcher
    .new(function()
      screens = {}
    end)
    :start() --[[@as hs.screen.watcher]]
end
local focused = hs.window.focusedWindow()
if type(lastSpace) == "number" and focused then
  local id = focused:id()
  local app = id and not isPiP(focused:title()) and focused:isStandard() and focused:application()
    or nil
  if app and app:name() ~= "Hammerspoon" then
    local entry = { id = id, pid = app:pid() }
    recent[lastSpace] = entry
    lastFocused = entry
  end
end

function module.status()
  return {
    active = not stopped
      and module.input:isEnabled()
      and (not module.keys or module.keys:isEnabled()),
    busy = guard ~= nil,
    last = lastResult,
  }
end

function module.stop()
  stopped = true
  screens = {}
  lastFocused = nil
  if guard then
    finish(guard, false, "stopped")
  end
  module.input:stop()
  if module.keys then
    module.keys:stop()
  end
  module.watcher:stop()
  if module.screenWatcher then
    module.screenWatcher:stop()
  end
  module.appWatcher:stop()
  module.windows:delete()
end

return module
