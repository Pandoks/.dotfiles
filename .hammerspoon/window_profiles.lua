local filter = require("lib.window_filter")
local logger = require("lib.logger")
local windowManager = require("lib.window_manager")

---@type table<string, { windows: WindowFilter, deadline: hs.timer }>
local launching = {}

---@alias WindowMatcher string|(fun(title: string): boolean)

---@class WindowProfile
---@field bundleId string
---@field match? WindowMatcher omit = any window
---@field args? string[]|fun(): string[]? launch args; nil cancels the launch
---@field foreground? boolean for apps that make no window until active

---@param bundleId string
---@param pid integer
---@param id integer
---@param minimized? boolean
local function focus(bundleId, pid, id, minimized)
  windowManager.focus(pid, id, function(focused, reason)
    if focused then
      print("Focused window", bundleId, id)
    elseif reason ~= "superseded" and reason ~= "stopped" then
      logger.error(string.format("Could not focus %s: %s", bundleId, reason))
    end
  end, minimized)
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

  -- In the background: apps reopen windows on their last Space, and activating animates there
  local arguments = { "-b", profile.bundleId }
  if profile.match ~= nil then
    table.insert(arguments, 1, "-n")
  end
  if not profile.foreground then
    table.insert(arguments, 1, "-g")
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
  local matcher = profile.match
  if type(matcher) ~= "function" then
    local title = matcher
    ---@param windowTitle string
    matcher = function(windowTitle)
      return title == nil or windowTitle == title
    end
  end

  local apps = hs.application.applicationsForBundleID(profile.bundleId)
  local currentSpace = hs.spaces.focusedSpace()

  ---@param window? hs.window
  ---@return integer? id
  local function shown(window)
    if not window then
      return
    end
    local id = window:id()
    if
      id
      and window:isStandard()
      and not window:isMinimized()
      and matcher(window:title() or "")
      and (hs.spaces.windowSpaces(id) or {})[1] == currentSpace
    then
      return id
    end
  end

  -- This Space front to back, main windows first: much faster than a window server scan
  ---@type table<integer, boolean>
  local pids = {}
  for _, app in ipairs(apps) do
    pids[app:pid()] = true
    local id = shown(app:mainWindow())
    if id then
      focus(profile.bundleId, app:pid(), id)
      return
    end
  end
  for _, app in ipairs(apps) do
    for _, window in ipairs(app:allWindows()) do
      local id = shown(window)
      if id then
        focus(profile.bundleId, app:pid(), id)
        return
      end
    end
  end
  if #apps == 0 then
    launch(profile, matcher)
    return
  end

  -- Every Space: this one (hidden apps), then others, then minimized
  windowManager.windows(function(ok, err, rows)
    if not ok then
      logger.error("Could not list windows: " .. tostring(err))
      return
    end
    local target, best
    for _, row in ipairs(rows) do
      if
        pids[row.pid]
        and row.root
        and row.subrole == "AXStandardWindow"
        and matcher(row.title)
      then
        local rank = row.minimized and 3 or windowManager.spaceOf(row.id) == currentSpace and 1 or 2
        if not best or rank < best then
          target, best = row, rank
        end
      end
    end
    if not target then
      launch(profile, matcher)
      return
    end
    focus(profile.bundleId, target.pid, target.id, target.minimized)
  end)
end

return openOrFocusWindow
