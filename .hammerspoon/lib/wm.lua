local utils = require("lib.utils")

---@alias WMDone fun(ok: boolean, err?: string)

---@class WMNative
---@field step fun(right: boolean, x: number, y: number)
---@field focus fun(pid: integer, id: integer, done?: WMDone)
---@field frame fun(pid: integer, id: integer, x: number, y: number, w: number, h: number, done?: WMDone)
---@field minimize fun(pid: integer, id: integer, minimized: boolean, done?: WMDone)
---@field windows fun(done: fun(ok: boolean, err?: string, rows: table[]))
---@field spaces fun(ids: integer[]): table<integer, integer>

local native = utils.native("wm") --[[@as WMNative]]

---@class WM
local wm = { native = native }

---@class WMJump
---@field space integer
---@field index integer
---@field display string
---@field from integer Space shown when the swipe in flight was sent
---@field point hs.geometry
---@field timer hs.timer
---@field done WMDone

---@type WMJump?
local jump

---@param ok boolean
---@param err? string
local function finish(ok, err)
  local job = assert(jump)
  jump = nil
  job.timer:stop()
  job.done(ok, err)
end

---@param job WMJump
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

-- Each swipe moves one Space, toward wherever the target is from the Space now shown.
---@param now integer
local function advance(now)
  local job = assert(jump)
  if now == job.space then
    finish(true)
    return
  end
  local origin
  for i, space in ipairs(utils.spaces() or {}) do
    if space.ManagedSpaceID == now then
      origin = i
    end
  end
  if not origin then
    finish(false, "current Space unavailable")
    return
  end
  job.from = now
  native.step(job.index > origin, job.point.x, job.point.y)
end

wm.watcher = hs.spaces.watcher
  .new(function()
    local now = jump and hs.spaces.activeSpaces()[jump.display]
    if now and now ~= jump.from then
      advance(now)
    end
  end)
  :start()

---Shows a Space instantly, by Mission Control index, on its own display.
---@param index integer
---@param done? WMDone
function wm.space(index, done)
  done = done or function() end
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
  local display = target.display
  local screen = hs.screen.find(display)
  local now = hs.spaces.activeSpaces()[display]
  if not screen or not now then
    done(false, "display unavailable")
    return
  end

  -- A swipe in flight on this display still lands; retarget the chain that follows it.
  if jump and jump.display == display then
    local previous = jump.done
    jump.space, jump.index, jump.done = target.ManagedSpaceID, index, done
    deadline(jump)
    previous(false, "superseded")
    return
  elseif jump then
    finish(false, "superseded")
  end
  if now == target.ManagedSpaceID then
    done(true)
    return
  end
  jump = {
    space = target.ManagedSpaceID,
    index = index,
    display = display,
    from = now,
    point = screen:frame().center,
    done = done,
  }
  deadline(jump)
  advance(now)
end

---Mission Control index of a native Space id.
---@param space integer
---@return integer?
function wm.index(space)
  for i, row in ipairs(utils.spaces() or {}) do
    if row.ManagedSpaceID == space then
      return i
    end
  end
end

---@param id integer
---@return integer? space
function wm.spaceOf(id)
  return native.spaces({ id })[id]
end

---Focuses a window, first showing its Space when another one is on screen.
---@param pid integer
---@param id integer
---@param done? WMDone
function wm.focus(pid, id, done)
  local space = wm.spaceOf(id)
  local display = space and hs.spaces.spaceDisplay(space)
  if space and display and hs.spaces.activeSpaces()[display] ~= space then
    local index = wm.index(space)
    if not index then
      if done then
        done(false, "window Space unavailable")
      end
      return
    end
    wm.space(index, function(ok, err)
      if not ok then
        if done then
          done(false, err)
        end
        return
      end
      native.focus(pid, id, done)
    end)
    return
  end
  native.focus(pid, id, done)
end

wm.frame = native.frame
wm.minimize = native.minimize
wm.windows = native.windows

function wm.stop()
  wm.watcher:stop()
  if jump then
    finish(false, "stopped")
  end
end

---@return WM
return wm
