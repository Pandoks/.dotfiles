local dock = require("lib.dock")
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
---@field focus fun(pid: integer, id: integer, done?: WindowManagerDone, space?: integer)
---@field cancelFocus fun()
---@field focusedWindow fun(pid: integer, done: fun(id?: integer, err?: string))
---@field frame fun(pid: integer, id: integer, x: number, y: number, w: number, h: number, done?: WindowManagerDone)
---@field minimize fun(pid: integer, id: integer, minimized: boolean, done?: WindowManagerDone)
---@field windows fun(done: fun(ok: boolean, err?: string, rows: table[]), pids?: integer[]|table<integer, boolean>)
---@field spaces fun(ids: integer[]): table<integer, integer>
---@field displaySpaces fun(): DisplaySpaces?, string?
---@field watchWindowSpaces fun(callback?: WindowSpaceCallback): boolean, string?

local raw = utils.native("window_manager") --[[@as WindowManagerNative]]
---@type integer?
local focused

local native = setmetatable({}, { __index = raw }) --[[@as WindowManagerNative]]
function native.focus(pid, id, done, space)
  focused = id
  raw.focus(pid, id, done, space)
end

---@class WindowManager
local windowManager = { native = native }

---@type { done: WindowManagerDone, cancel?: fun() }?
local switching
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

---@param err? string
local function cancel(err)
  local job = switching
  if not job then
    return
  end
  switching = nil
  if job.cancel then
    job.cancel()
  end
  job.done(false, err)
end

---@param index number Mission Control index
---@param done? WindowManagerDone
---@param layout? DisplaySpaces
---@param leaving? integer
---@param reset? boolean
local function jumpTo(index, done, layout, leaving, reset)
  done = done or function() end
  if not layout then
    local err
    layout, err = native.displaySpaces()
    if not layout then
      done(false, err)
      return
    end
  end
  local target = layout.spaces[index]
  if not target then
    done(false, "Space " .. index .. " does not exist")
    return
  end
  local current = layout.active[target.display]
  if not hs.screen.find(target.display) or not current then
    done(false, "display unavailable")
    return
  end

  if switching then
    native.cancelFocus()
    cancel("superseded")
  end
  if current == target.id then
    done(true)
    return
  end
  native.cancelFocus()
  if reset then
    focused = nil
  end
  local job = { done = done }
  switching = job
  job.cancel = dock.switch(target.id, function(ok, err)
    if switching == job then
      switching = nil
      job.done(ok, err)
    end
  end, leaving)
end

---@param index number Mission Control index
---@param done? WindowManagerDone
function windowManager.space(index, done)
  clearSettled()
  jumpTo(index, done, nil, focused, true)
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
      native.cancelFocus()
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
    if switching then
      cancel("superseded")
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
  local leaving = focused ~= id and focused or nil
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
  if layout.active[entry.display] == space then
    if switching then
      cancel("superseded")
    end
    show()
    return
  end
  jumpTo(entry.index, arrive, layout, leaving)
end

---@param space? integer
---@param pid? integer
---@return boolean
function windowManager.isBusy(space, pid)
  if switching ~= nil or focusing ~= nil then
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
  focusing = nil
  focused = nil
  clearSettled()
  if watchingSpaces then
    watchingSpaces = false
    spaceListeners = {}
    native.watchWindowSpaces(nil)
  end
  native.cancelFocus()
  cancel("stopped")
end

return windowManager
