local logger = require("lib.logger")

---@type table<string, boolean>
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
---@field args? string[] launch args

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

  ---@type hs.application?
  local offSpaceMainWindowApp = nil
  ---mainWindow first: much faster than an allWindows scan
  for _, app in ipairs(apps) do
    local mainWindow = app:mainWindow()
    if mainWindow and mainWindow:isStandard() and matcher(mainWindow:title() or "") then
      if (hs.spaces.windowSpaces(mainWindow:id()) or {})[1] == currentSpace then
        app:activate(true)
        print("Focused window", profile.bundleId, mainWindow:id())
        return
      end

      offSpaceMainWindowApp = offSpaceMainWindowApp or app
    end
  end

  ---@type hs.window?
  local offSpaceWindow = nil
  for _, app in ipairs(apps) do
    for _, window in ipairs(app:allWindows()) do
      if window:isStandard() and matcher(window:title() or "") then
        if (hs.spaces.windowSpaces(window:id()) or {})[1] == currentSpace then
          window:focus()
          print("Focused window", profile.bundleId, window:id())
          return
        end

        offSpaceWindow = offSpaceWindow or window
      end
    end
  end

  if offSpaceMainWindowApp then
    offSpaceMainWindowApp:activate(true)
    print("Focused app on another space", profile.bundleId)
    return
  end
  if offSpaceWindow then
    offSpaceWindow:focus()
    print("Focused window on another space", profile.bundleId, offSpaceWindow:id())
    return
  end

  if profile.match == nil then
    hs.task
      .new("/usr/bin/open", function(exitCode, _, stdErr)
        report(profile.bundleId, exitCode, stdErr)
      end, { "-b", profile.bundleId })
      :start()
    print("Launching app", profile.bundleId)
    return
  end

  local launchKey = profile.bundleId
    .. "/"
    .. (type(profile.match) == "string" and profile.match or "*")
  if launching[launchKey] then
    print("Already launching", launchKey)
    return
  end
  launching[launchKey] = true

  local arguments = { "-W", "-n", "-b", profile.bundleId, "--args" }
  for _, argument in ipairs(profile.args or {}) do
    table.insert(arguments, argument)
  end

  hs.task
    .new("/usr/bin/open", function(exitCode, _, stdErr)
      launching[launchKey] = nil
      report(profile.bundleId, exitCode, stdErr)
    end, arguments)
    :start()
  print("Launching window", launchKey)
end

return openOrFocusWindow
