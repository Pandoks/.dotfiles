local utils = require("lib.utils")

---@alias WindowManagerDone fun(ok: boolean, err?: string)
---@alias WindowSpaceCallback fun(id: integer, space: integer, added: boolean, pid?: integer)

---@class DisplaySpace
---@field id integer
---@field display string

---@class DisplaySpaceEntry
---@field index integer
---@field display string

---@class DisplaySpaces
---@field spaces DisplaySpace[]
---@field active table<string, integer>
---@field bySpace table<integer, DisplaySpaceEntry>

---@class WindowManagerNative
---@field move fun(right: boolean, count: integer, x: number, y: number): boolean, string?
---@field focus fun(pid: integer, id: integer, done?: WindowManagerDone, space?: integer)
---@field cancelFocus? fun()
---@field focusedWindow? fun(pid: integer, done: fun(id?: integer, err?: string))
---@field frame fun(pid: integer, id: integer, x: number, y: number, w: number, h: number, done?: WindowManagerDone)
---@field minimize fun(pid: integer, id: integer, minimized: boolean, done?: WindowManagerDone)
---@field windows fun(done: fun(ok: boolean, err?: string, rows: table[]), pids?: integer[]|table<integer, boolean>)
---@field spaces fun(ids: integer[]): table<integer, integer>
---@field displaySpaces? fun(): DisplaySpaces?, string?
---@field watchWindowSpaces? fun(callback?: WindowSpaceCallback): boolean, string?

local native = utils.native("window_manager") --[[@as WindowManagerNative]]

---@class WindowManager
local windowManager = { native = native }

---@class SpaceJump
---@field space integer
---@field index number
---@field landing integer Space in-flight swipes end on
---@field from number Mission Control index of `landing`
---@field display string
---@field point hs.geometry
---@field timer? hs.timer
---@field done WindowManagerDone

---@type SpaceJump?
local jump
---@type { space?: integer, pid: integer, id: integer }?
local focusing
---@type { space?: integer, pid: integer, id: integer, timer?: hs.timer }?
local settled

local function clearSettled()
  if settled and settled.timer then
    settled.timer:stop()
  end
  settled = nil
end

---@return table<string, integer>?
---@return string?
local function activeSpaces()
  if native.displaySpaces then
    local layout, err = native.displaySpaces()
    return layout and layout.active or nil, err
  end
  return hs.spaces.activeSpaces()
end

---@param ok boolean
---@param err? string
local function finish(ok, err)
  local job = assert(jump)
  jump = nil
  assert(job.timer):stop()
  job.timer = nil
  job.done(ok, err)
end

---@param job SpaceJump
local function deadline(job)
  if job.timer then
    job.timer:stop()
  end
  job.timer = hs.timer.doAfter(1.5, function()
    if jump == job then
      finish(false, "timed out showing Space " .. job.index)
    end
  end)
end

-- Swipes posted together skip showing the Spaces between.
---@param job SpaceJump
---@param origin number Mission Control index
local function send(job, origin)
  job.landing, job.from = job.space, job.index
  local ok, err =
    native.move(job.index > origin, math.abs(job.index - origin), job.point.x, job.point.y)
  if not ok then
    finish(false, err)
  end
end

-- The Dock mishandles swipes posted mid-flight, so later presses wait.
local watcher = hs.spaces.watcher
  .new(function()
    local job = jump
    if not job then
      return
    end
    local active, err = activeSpaces()
    if not active then
      finish(false, err)
    elseif active[job.display] ~= job.landing then
      return
    elseif job.landing == job.space then
      finish(true)
    else
      send(job, job.from)
    end
  end)
  :start() --[[@as hs.spaces.watcher]]

---@param index number Mission Control index
---@param done? WindowManagerDone
---@param layout? DisplaySpaces
local function jumpTo(index, done, layout)
  done = done or function() end
  local targetID, display, current, origin
  if not layout and native.displaySpaces then
    local err
    layout, err = native.displaySpaces()
    if not layout then
      done(false, err)
      return
    end
  end
  if layout then
    local target = layout.spaces[index]
    if not target then
      done(false, "Space " .. index .. " does not exist")
      return
    end
    targetID, display = target.id, target.display
    current = layout.active[display]
    local entry = current and layout.bySpace[current]
    origin = entry and entry.index
  else
    local spaces, err = utils.spaces()
    if not spaces then
      done(false, err)
      return
    end
    local target = spaces[index]
    if not target then
      done(false, "Space " .. index .. " does not exist")
      return
    end
    targetID, display = target.ManagedSpaceID, target.display
    local active
    active, err = hs.spaces.activeSpaces()
    if not active then
      done(false, err)
      return
    end
    current = active[display]
    for position, space in ipairs(spaces) do
      if space.ManagedSpaceID == current then
        origin = position
      end
    end
  end
  local screen = hs.screen.find(display)
  if not screen or not current then
    done(false, "display unavailable")
    return
  end

  -- Swipes in flight on this display still land; the watcher continues from there.
  if jump and jump.display == display then
    if native.cancelFocus then
      native.cancelFocus()
    end
    local previous = jump.done
    jump.space, jump.index, jump.done = targetID, index, done
    deadline(jump)
    previous(false, "superseded")
    return
  elseif jump then
    if native.cancelFocus then
      native.cancelFocus()
    end
    finish(false, "superseded")
  end
  if current == targetID then
    done(true)
    return
  end
  if not origin then
    done(false, "current Space unavailable")
    return
  end
  if native.cancelFocus then
    native.cancelFocus()
  end
  jump = {
    space = targetID,
    index = index,
    landing = current,
    from = origin,
    display = display,
    point = screen:frame().center,
    done = done,
  }
  deadline(jump)
  send(jump, origin)
end

---@param index number Mission Control index
---@param done? WindowManagerDone
function windowManager.space(index, done)
  clearSettled()
  jumpTo(index, done)
end

---@param id integer
---@return integer? space
function windowManager.spaceOf(id)
  return native.spaces({ id })[id]
end

---@param pid integer
---@param id integer
---@param done? WindowManagerDone
---@param minimized? boolean unminimize once its Space shows; earlier, macOS animates there itself
---@param live? fun(): boolean false cancels the remaining steps
---@param knownSpace? integer
function windowManager.focus(pid, id, done, minimized, live, knownSpace)
  done = done or function() end
  local space = knownSpace or windowManager.spaceOf(id)
  local job = { space = space, pid = pid, id = id }
  focusing = job
  clearSettled()
  local function complete(ok, err)
    local current = focusing == job
    if current then
      focusing = nil
    end
    if ok and current then
      local entry = { space = space, pid = pid, id = id }
      settled = entry
      entry.timer = hs.timer.doAfter(0.3, function()
        if settled == entry then
          settled = nil
        end
      end)
    end
    done(ok, err)
  end
  local function cancelled()
    if live and not live() then
      if native.cancelFocus then
        native.cancelFocus()
      end
      complete(false, "cancelled")
      return true
    end
  end
  local function show()
    if cancelled() then
      return
    elseif not minimized then
      native.focus(pid, id, complete, space)
      return
    end
    native.minimize(pid, id, false, function(ok, err)
      if not ok then
        complete(false, err)
      elseif not cancelled() then
        native.focus(pid, id, complete, space)
      end
    end)
  end
  -- No Space to show first.
  if not space then
    if jump then
      finish(false, "superseded")
    end
    show()
    return
  end
  local function arrive(ok, failure)
    if ok then
      show()
    else
      complete(false, failure)
    end
  end
  if native.displaySpaces then
    local layout, err = native.displaySpaces()
    if not layout then
      complete(false, err)
      return
    end
    local entry = layout.bySpace[space]
    if not entry then
      complete(false, "display unavailable for Space " .. space)
      return
    end
    if not jump and layout.active[entry.display] == space then
      show()
      return
    end
    jumpTo(entry.index, arrive, layout)
    return
  end
  local display = hs.spaces.spaceDisplay(space)
  local active, err = hs.spaces.activeSpaces()
  if not display or not active then
    complete(false, display and err or "display unavailable for Space " .. space)
    return
  end
  if not jump and active[display] == space then
    show()
    return
  end
  for index, row in ipairs(utils.spaces() or {}) do
    if row.ManagedSpaceID == space then
      jumpTo(index, arrive)
      return
    end
  end
  complete(false, "window Space unavailable")
end

---@param space? integer
---@param pid? integer
---@return boolean
function windowManager.isBusy(space, pid)
  if jump ~= nil or focusing ~= nil then
    return true
  end
  if
    settled ~= nil
    and ((space ~= nil and settled.space == space) or (pid ~= nil and settled.pid == pid))
  then
    return true
  end
  return false
end

---@return { space?: integer, pid: integer, id: integer }?
function windowManager.focusedTarget()
  return focusing or settled
end

windowManager.frame = native.frame
windowManager.windows = native.windows

local spaceListeners, watchingSpaces = {}, false

---@param callback WindowSpaceCallback
---@return fun() stop
function windowManager.watchWindowSpaces(callback)
  if not native.watchWindowSpaces then
    return function() end
  end
  spaceListeners[callback] = true
  if not watchingSpaces then
    local ok, err = native.watchWindowSpaces(function(id, space, added, pid)
      local snapshot = {}
      for listener in pairs(spaceListeners) do
        snapshot[#snapshot + 1] = listener
      end
      for _, listener in ipairs(snapshot) do
        if spaceListeners[listener] then
          listener(id, space, added, pid)
        end
      end
    end)
    if not ok then
      spaceListeners[callback] = nil
      error(err or "could not watch window Spaces", 0)
    end
    watchingSpaces = true
  end
  return function()
    spaceListeners[callback] = nil
    if watchingSpaces and not next(spaceListeners) then
      watchingSpaces = false
      native.watchWindowSpaces(nil)
    end
  end
end

-- Cache other-Space windows so the first Cmd-Tab doesn't search.
native.windows(function() end)

function windowManager.stop()
  watcher:stop()
  focusing = nil
  clearSettled()
  if watchingSpaces and native.watchWindowSpaces then
    watchingSpaces = false
    spaceListeners = {}
    native.watchWindowSpaces(nil)
  end
  if native.cancelFocus then
    native.cancelFocus()
  end
  if jump then
    finish(false, "stopped")
  end
end

return windowManager
