local utils = require("lib.utils")

---@alias WindowManagerDone fun(ok: boolean, err?: string)

---@class WindowManagerNative
---@field move fun(right: boolean, count: integer, x: number, y: number): boolean, string?
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
---@field landing integer Space the swipes in flight end on
---@field from number Mission Control index of `landing`
---@field display string
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

-- Swipes posted together move straight to the target, without showing the Spaces between.
---@param job SpaceJump
---@param origin number Mission Control index the swipes start from
local function send(job, origin)
  job.landing, job.from = job.space, job.index
  local ok, err =
    native.move(job.index > origin, math.abs(job.index - origin), job.point.x, job.point.y)
  if not ok then
    finish(false, err)
  end
end

-- The Dock mishandles swipes posted while others are in flight, so later presses wait for them.
local watcher = hs.spaces.watcher
  .new(function()
    local job = jump
    if not job then
      return
    end
    local active, err = hs.spaces.activeSpaces()
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
  local active
  active, err = hs.spaces.activeSpaces()
  if not active then
    done(false, err)
    return
  end
  local now = active[display]
  if not screen or not now then
    done(false, "display unavailable")
    return
  end

  -- Swipes in flight on this display still land; the watcher continues from there.
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
  local origin
  for position, space in ipairs(spaces) do
    if space.ManagedSpaceID == now then
      origin = position
    end
  end
  if not origin then
    done(false, "current Space unavailable")
    return
  end
  jump = {
    space = target.ManagedSpaceID,
    index = index,
    landing = now,
    from = origin,
    display = display,
    point = screen:frame().center,
    done = done,
  }
  deadline(jump)
  send(jump, origin)
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
  -- A window on no Space (e.g. minimized) is focused directly.
  local space = windowManager.spaceOf(id)
  if not space then
    native.focus(pid, id, done)
    return
  end
  local display = hs.spaces.spaceDisplay(space)
  local active, err = hs.spaces.activeSpaces()
  if not display or not active then
    done(false, display and err or "display unavailable for Space " .. space)
    return
  end
  if active[display] == space then
    native.focus(pid, id, done)
    return
  end
  for index, row in ipairs(utils.spaces() or {}) do
    if row.ManagedSpaceID == space then
      windowManager.space(index, function(ok, failure)
        if ok then
          native.focus(pid, id, done)
        else
          done(false, failure)
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

-- Finding windows on other Spaces is the slow part (about 1.5 s); do it once now, in the
-- background, so the first Cmd-Tab is already cached. Later windows are found as they appear.
native.windows(function() end)

function windowManager.stop()
  watcher:stop()
  if jump then
    finish(false, "stopped")
  end
end

return windowManager
