local utils = require("lib.utils")

---@alias WindowManagerDone fun(ok: boolean, err?: string)

---@class WindowManagerNative
---@field step fun(right: boolean, x: number, y: number): boolean, string?
---@field focus fun(pid: integer, id: integer, done?: WindowManagerDone)
---@field frame fun(pid: integer, id: integer, x: number, y: number, w: number, h: number, done?: WindowManagerDone)
---@field minimize fun(pid: integer, id: integer, minimized: boolean, done?: WindowManagerDone)
---@field windows fun(done: fun(ok: boolean, err?: string, rows: table[]))
---@field spaces fun(ids: integer[]): table<integer, integer>

local native = utils.native("window_manager") --[[@as WindowManagerNative]]

---@class WindowManager
local windowManager = { native = native }

---@class SpaceJump
---@field space integer
---@field index number
---@field display string
---@field from integer Space shown when the swipe in flight was sent
---@field point hs.geometry
---@field timer? hs.timer
---@field done WindowManagerDone

---@type SpaceJump?
local jump

---@param ok boolean
---@param err? string
local function finish(ok, err)
  local job = assert(jump)
  jump = nil
  assert(job.timer):stop()
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

-- Each swipe moves one Space, toward the target from the Space now shown.
---@param now integer
local function advance(now)
  local job = assert(jump)
  if now == job.space then
    finish(true)
    return
  end
  local origin
  for index, space in ipairs(utils.spaces() or {}) do
    if space.ManagedSpaceID == now then
      origin = index
    end
  end
  if not origin then
    finish(false, "current Space unavailable")
    return
  end
  job.from = now
  local ok, err = native.step(job.index > origin, job.point.x, job.point.y)
  if not ok then
    finish(false, err)
  end
end

local watcher = hs.spaces.watcher
  .new(function()
    local job = jump
    local now = job and hs.spaces.activeSpaces()[job.display]
    if job and now and now ~= job.from then
      advance(now)
    end
  end)
  :start() --[[@as hs.spaces.watcher]]

---@param index number Mission Control index
---@param done? WindowManagerDone
function windowManager.space(index, done)
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

---@param id integer
---@return integer? space
function windowManager.spaceOf(id)
  return native.spaces({ id })[id]
end

-- Shows the window's Space first when another one is on screen.
---@param pid integer
---@param id integer
---@param done? WindowManagerDone
function windowManager.focus(pid, id, done)
  done = done or function() end
  local space = windowManager.spaceOf(id)
  local display = space and hs.spaces.spaceDisplay(space)
  if not space or not display or hs.spaces.activeSpaces()[display] == space then
    native.focus(pid, id, done)
    return
  end
  for index, row in ipairs(utils.spaces() or {}) do
    if row.ManagedSpaceID == space then
      windowManager.space(index, function(ok, err)
        if ok then
          native.focus(pid, id, done)
        else
          done(false, err)
        end
      end)
      return
    end
  end
  done(false, "window Space unavailable")
end

windowManager.frame = native.frame
windowManager.minimize = native.minimize
windowManager.windows = native.windows

function windowManager.stop()
  watcher:stop()
  if jump then
    finish(false, "stopped")
  end
end

return windowManager
