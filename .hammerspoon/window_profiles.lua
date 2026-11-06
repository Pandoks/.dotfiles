local filter = require("lib.window_filter")
local logger = require("lib.logger")
local windowManager = require("lib.window_manager")

---@type table<string, { windows: WindowFilter, deadline: hs.timer }>
local launching = {}

---@param bundleId string
---@param exitCode integer
---@param stdErr string
local function report(bundleId, exitCode, stdErr)
  if exitCode ~= 0 then
    logger.error(string.format("Could not launch %s (exit %d): %s", bundleId, exitCode, stdErr))
  end
end

---@alias WindowMatcher string|(fun(title: string): boolean)

---@class WindowProfile
---@field bundleId string
---@field match? WindowMatcher omit = any window
---@field args? string[]|fun(): string[]? launch args; nil cancels the launch

---@param profile WindowProfile
---@param matcher fun(title: string): boolean
local function launch(profile, matcher)
  if profile.match == nil then
    hs.task
      .new("/usr/bin/open", function(exitCode, _, stdErr)
        report(profile.bundleId, exitCode, stdErr)
      end, { "-b", profile.bundleId })
      :start()
    print("Launching app", profile.bundleId)
    return
  end

  local args = profile.args
  if type(args) == "function" then
    args = args()
    if not args then
      return
    end
  end
  local launchKey = profile.bundleId .. " " .. table.concat(args or {}, " ")
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
  end
  windows:subscribe({ filter.windowCreated, filter.windowTitleChanged }, settle)
  launching[launchKey] = {
    windows = windows,
    deadline = hs.timer.doAfter(10, function()
      settle()
      logger.error("No window appeared after launching " .. launchKey)
    end),
  }

  local arguments = { "-n", "-b", profile.bundleId, "--args" }
  for _, argument in ipairs(args or {}) do
    table.insert(arguments, argument)
  end
  hs.task
    .new("/usr/bin/open", function(exitCode, _, stdErr)
      if exitCode ~= 0 then
        settle()
      end
      report(profile.bundleId, exitCode, stdErr)
    end, arguments)
    :start()
  print("Launching window", launchKey)
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
  local function shown(window)
    return window
      and window:isStandard()
      and not window:isMinimized()
      and matcher(window:title() or "")
      and (hs.spaces.windowSpaces(window:id()) or {})[1] == currentSpace
  end

  -- This Space front to back, main windows first: much faster than a window server scan
  ---@type table<integer, boolean>
  local pids = {}
  for _, app in ipairs(apps) do
    pids[app:pid()] = true
    local window = app:mainWindow()
    if shown(window) then
      app:activate(true)
      print("Focused window", profile.bundleId, window:id())
      return
    end
  end
  for _, app in ipairs(apps) do
    for _, window in ipairs(app:allWindows()) do
      if shown(window) then
        window:focus()
        print("Focused window", profile.bundleId, window:id())
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

    ---@param focused boolean
    ---@param reason? string
    local function done(focused, reason)
      if focused then
        print("Focused window", profile.bundleId, target.id)
      elseif reason ~= "superseded" and reason ~= "stopped" then
        logger.error(string.format("Could not focus %s: %s", profile.bundleId, reason))
      end
    end
    windowManager.focus(target.pid, target.id, done, target.minimized)
  end)
end

return openOrFocusWindow
