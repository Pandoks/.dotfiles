local filter = require("lib.window_filter")
local logger = require("lib.logger")
local windowManager = require("lib.window_manager")

---@class KnownWindow
---@field pid integer
---@field id integer
---@field title string
---@field minimized boolean
---@field recent integer

---@type table<string, { windows: WindowFilter, deadline: hs.timer }>
local launching = {}
---@type table<integer, KnownWindow>
local known = {}
local recent = 0
local serial = 0

---@alias WindowMatcher string|(fun(title: string): boolean)

---@class WindowProfile
---@field bundleId string
---@field match? WindowMatcher omit = any window
---@field args? string[]|fun(): string[]? launch args; nil cancels the launch

---@param pid integer
---@param id integer
---@param title string
---@param minimized boolean
---@return KnownWindow
local function cache(pid, id, title, minimized)
  local entry = known[id]
  if entry and entry.pid == pid then
    entry.title = title
    entry.minimized = minimized
    return entry
  end
  entry = { pid = pid, id = id, title = title, minimized = minimized, recent = 0 }
  known[id] = entry
  return entry
end

local tracker = filter.new()
tracker:subscribe({
  filter.windowCreated,
  filter.windowTitleChanged,
  filter.windowMinimized,
  filter.windowUnminimized,
  filter.windowFocused,
}, function(window, _, event, id)
  local entry = known[id]
  if entry then
    if event == filter.windowFocused then
      recent = recent + 1
      entry.recent = recent
      entry.minimized = false
      return
    elseif event == filter.windowMinimized or event == filter.windowUnminimized then
      entry.minimized = event == filter.windowMinimized
      return
    elseif event == filter.windowTitleChanged then
      entry.title = window:title() or ""
      return
    end
  end
  if not window:isStandard() then
    known[id] = nil
    return
  end
  local app = window:application()
  if not app then
    return
  end
  local minimized = event == filter.windowMinimized
    or (
      event ~= filter.windowUnminimized
      and event ~= filter.windowFocused
      and window:isMinimized() == true
    )
  local stored = cache(app:pid(), id, window:title() or "", minimized)
  if event == filter.windowFocused then
    recent = recent + 1
    stored.recent = recent
  end
end)
tracker:subscribe({ filter.windowDestroyed }, function(_, _, _, id)
  known[id] = nil
end)

---@param bundleId string
---@param pid integer
---@param id integer
---@param minimized? boolean
---@param token? integer
---@param space? integer
local function focus(bundleId, pid, id, minimized, token, space)
  local live = token and function()
    return token == serial
  end or nil
  windowManager.focus(pid, id, function(focused, reason)
    if focused then
      local entry = known[id]
      if entry and entry.pid == pid then
        entry.minimized = false
      end
      print("Focused window", bundleId, id)
    elseif reason ~= "superseded" and reason ~= "stopped" and reason ~= "cancelled" then
      local entry = known[id]
      if
        entry
        and entry.pid == pid
        and (reason == "window unavailable" or reason == "process unavailable")
      then
        known[id] = nil
      end
      logger.error(string.format("Could not focus %s: %s", bundleId, reason))
    end
  end, minimized, live, space)
end

---@param profile WindowProfile
---@param matcher fun(title: string): boolean
local function launch(profile, matcher)
  local args = profile.args
  if type(args) == "function" then
    args = args()
    if not args then
      return
    end
  end
  local launchKey = table.concat({ profile.bundleId, table.unpack(args or {}) }, " ")
  if launching[launchKey] then
    print("Already launching", launchKey)
    return
  end
  -- `open` returns before the window exists, so the key waits for the window
  local windows = filter.new(function(window)
    local app = window:application()
    return app ~= nil and app:bundleID() == profile.bundleId and matcher(window:title() or "")
  end)
  local function settle()
    local pending = launching[launchKey]
    if pending then
      launching[launchKey] = nil
      pending.windows:delete()
      pending.deadline:stop()
    end
    return pending
  end
  windows:subscribe({ filter.windowCreated, filter.windowTitleChanged }, function(window, _, _, id)
    local app = window:application()
    if settle() and app then
      focus(profile.bundleId, app:pid(), id)
    end
  end)
  launching[launchKey] = {
    windows = windows,
    deadline = hs.timer.doAfter(10, function()
      settle()
      logger.error("No window appeared after launching " .. launchKey)
    end),
  }

  local arguments = { "-b", profile.bundleId }
  if profile.match ~= nil then
    table.insert(arguments, 1, "-n")
  end
  if args then
    table.insert(arguments, "--args")
    for _, argument in ipairs(args) do
      table.insert(arguments, argument)
    end
  end
  hs.task
    .new("/usr/bin/open", function(exitCode, _, stdErr)
      if exitCode ~= 0 then
        settle()
        logger.error(
          string.format("Could not launch %s (exit %d): %s", profile.bundleId, exitCode, stdErr)
        )
      end
    end, arguments)
    :start()
  print("Launching", launchKey)
end

---@param profile WindowProfile
local function openOrFocusWindow(profile)
  serial = serial + 1
  local token = serial
  local matcher = profile.match
  if type(matcher) ~= "function" then
    local title = matcher
    ---@param windowTitle string
    matcher = function(windowTitle)
      return title == nil or windowTitle == title
    end
  end

  local apps = hs.application.applicationsForBundleID(profile.bundleId)
  if #apps == 0 then
    launch(profile, matcher)
    return
  end

  local currentSpace = hs.spaces.focusedSpace()
  ---@type table<integer, boolean>, integer[]
  local owners, pids = {}, {}
  for _, app in ipairs(apps) do
    local pid = app:pid()
    if not owners[pid] then
      owners[pid] = true
      pids[#pids + 1] = pid
    end
  end

  -- Cached windows first: zero AX IPC, verified live via SkyLight Space lookup
  ---@type KnownWindow?, integer?, integer?
  local cached, bestCached, bestSpace
  for id, entry in pairs(known) do
    if owners[entry.pid] and matcher(entry.title) then
      local space = windowManager.spaceOf(id)
      if not space then
        known[id] = nil
      else
        local rank = entry.minimized and 3 or space == currentSpace and 1 or 2
        if
          not cached
          or not bestCached
          or rank < bestCached
          or (
            rank == bestCached
            and (entry.recent > cached.recent or (entry.recent == cached.recent and id < cached.id))
          )
        then
          cached, bestCached, bestSpace = entry, rank, space
        end
      end
    end
  end
  if cached then
    recent = recent + 1
    cached.recent = recent
    focus(profile.bundleId, cached.pid, cached.id, cached.minimized, token, bestSpace)
    return
  end

  ---@param app hs.application
  ---@param window? hs.window
  ---@return KnownWindow?
  local function shown(app, window)
    if not window then
      return
    end
    local id = window:id()
    if not id or not window:isStandard() then
      return
    end
    local title = window:title() or ""
    local minimized = window:isMinimized() == true
    local entry = cache(app:pid(), id, title, minimized)
    if
      not minimized
      and matcher(title)
      and (hs.spaces.windowSpaces(id) or {})[1] == currentSpace
    then
      return entry
    end
  end

  -- This Space front to back, main windows first: much faster than a window server scan
  for _, app in ipairs(apps) do
    local entry = shown(app, app:mainWindow())
    if entry then
      recent = recent + 1
      entry.recent = recent
      focus(profile.bundleId, entry.pid, entry.id, false, token, currentSpace)
      return
    end
  end
  for _, app in ipairs(apps) do
    for _, window in ipairs(app:allWindows()) do
      local entry = shown(app, window)
      if entry then
        recent = recent + 1
        entry.recent = recent
        focus(profile.bundleId, entry.pid, entry.id, false, token, currentSpace)
        return
      end
    end
  end

  -- Every Space: targeted PID scan, preferring this Space, then others, then minimized
  local list = windowManager.windows --[[@as fun(done: fun(ok: boolean, err?: string, rows: table[]), pids?: integer[])]]
  ---@param ok boolean
  ---@param err? string
  ---@param rows table[]
  local function scanned(ok, err, rows)
    if token ~= serial then
      return
    end
    if not ok then
      logger.error("Could not list windows: " .. tostring(err))
      return
    end
    ---@type KnownWindow?, integer?, integer?
    local target, best, bestSpace
    for _, row in ipairs(rows) do
      if owners[row.pid] and row.root and row.subrole == "AXStandardWindow" then
        local entry = cache(row.pid, row.id, row.title or "", row.minimized == true)
        if matcher(entry.title) then
          local space = windowManager.spaceOf(row.id)
          local rank = entry.minimized and 3 or space == currentSpace and 1 or 2
          if not target or not best or rank < best then
            target, best, bestSpace = entry, rank, space
          end
        end
      end
    end
    if not target then
      launch(profile, matcher)
      return
    end
    recent = recent + 1
    target.recent = recent
    focus(profile.bundleId, target.pid, target.id, target.minimized, token, bestSpace)
  end
  local native = windowManager.native --[[@as { displaySpaces?: function }?]]
  if not native or native.displaySpaces ~= nil then
    list(scanned, pids)
  else
    list(scanned)
  end
end

return openOrFocusWindow
