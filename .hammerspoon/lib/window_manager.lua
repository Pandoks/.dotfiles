local dock = require("lib.dock")
local utils = require("lib.utils")

---@alias WindowManagerDone fun(ok: boolean, err?: string)

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
---@field focus fun(pid: integer, id: integer, done?: WindowManagerDone)
---@field frame fun(pid: integer, id: integer, x: number, y: number, w: number, h: number, done?: WindowManagerDone)
---@field minimize fun(pid: integer, id: integer, minimized: boolean, done?: WindowManagerDone)
---@field windows fun(done: fun(ok: boolean, err?: string, rows: table[]), pids?: integer[]|table<integer, boolean>)
---@field spaces fun(ids: integer[]): table<integer, integer>
---@field displaySpaces? fun(): DisplaySpaces?, string?

local native = utils.native("window_manager") --[[@as WindowManagerNative]]

---@class WindowManager
local windowManager = { native = native }

---@type { done: WindowManagerDone }?
local switching

---@param err? string
local function cancel(err)
  local job = switching
  if not job then
    return
  end
  switching = nil
  job.done(false, err)
end

---@param index number Mission Control index
---@param done? WindowManagerDone
---@param layout? DisplaySpaces
local function jumpTo(index, done, layout)
  done = done or function() end
  local targetID, display, current
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
  end
  local screen = hs.screen.find(display)
  if not screen or not current then
    done(false, "display unavailable")
    return
  end

  if switching then
    cancel("superseded")
  end
  if current == targetID then
    done(true)
    return
  end
  local job = { done = done }
  switching = job
  dock.switch(targetID, function(ok, err)
    if switching == job then
      switching = nil
      job.done(ok, err)
    end
  end)
end

---@param index number Mission Control index
---@param done? WindowManagerDone
function windowManager.space(index, done)
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
function windowManager.focus(pid, id, done, minimized, live)
  done = done or function() end
  local function cancelled()
    if live and not live() then
      done(false, "cancelled")
      return true
    end
  end
  local function show()
    if cancelled() then
      return
    elseif not minimized then
      native.focus(pid, id, done)
      return
    end
    native.minimize(pid, id, false, function(ok, err)
      if not ok then
        done(false, err)
      elseif not cancelled() then
        native.focus(pid, id, done)
      end
    end)
  end
  -- No Space to show first.
  local space = windowManager.spaceOf(id)
  if not space then
    show()
    return
  end
  local function arrive(ok, failure)
    if ok then
      show()
    else
      done(false, failure)
    end
  end
  if native.displaySpaces then
    local layout, err = native.displaySpaces()
    if not layout then
      done(false, err)
      return
    end
    local entry = layout.bySpace[space]
    if not entry then
      done(false, "display unavailable for Space " .. space)
      return
    end
    if layout.active[entry.display] == space then
      show()
      return
    end
    jumpTo(entry.index, arrive, layout)
    return
  end
  local display = hs.spaces.spaceDisplay(space)
  local active, err = hs.spaces.activeSpaces()
  if not display or not active then
    done(false, display and err or "display unavailable for Space " .. space)
    return
  end
  if active[display] == space then
    show()
    return
  end
  for index, row in ipairs(utils.spaces() or {}) do
    if row.ManagedSpaceID == space then
      jumpTo(index, arrive)
      return
    end
  end
  done(false, "window Space unavailable")
end

---@return boolean
function windowManager.isBusy()
  return switching ~= nil
end

windowManager.frame = native.frame
windowManager.windows = native.windows

-- Cache other-Space windows so the first Cmd-Tab doesn't search.
native.windows(function() end)

function windowManager.stop()
  cancel("stopped")
end

return windowManager
