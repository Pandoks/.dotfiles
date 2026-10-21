---@type table<string, boolean>
local launching = {}

---@alias WindowMatcher string|(fun(title: string): boolean)

---@class WindowProfile
---@field bundleId string bundle id, e.g. "com.mitchellh.ghostty" (osascript -e 'id of app "<app>"'); one lookup returns every running instance
---@field match? WindowMatcher which window of the app; omit = any window
---@field args? string[] arguments handed to the app when it has to be launched

---Focus the profile's window, launching it if it doesn't exist anywhere.
---
---Search order:
--- 1. last-focused window of each running instance, current space first
--- 2. any other matching window on the current space
--- 3. matching window on another space
--- 4. nothing found → launch
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

  ---usually just one app instance
  local apps = hs.application.applicationsForBundleID(profile.bundleId)
  local currentSpace = hs.spaces.focusedSpace()

  ---@type hs.application?
  local offSpaceMainWindowApp = nil
  ---fast path: mainWindow is signficantly faster than allWindows scan
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
  ---slow path: allWindows scans for windows of app on this space that aren't mainWindow
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
    hs.task.new("/usr/bin/open", nil, { "-b", profile.bundleId }):start()
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

  local launchArgs = { "-W", "-n", "-b", profile.bundleId, "--args" }
  for _, arg in ipairs(profile.args or {}) do
    table.insert(launchArgs, arg)
  end

  hs.task
    .new("/usr/bin/open", function(exitCode)
      launching[launchKey] = nil
      if exitCode ~= 0 then
        print("Launch failed", launchKey)
      end
    end, launchArgs)
    :start()
  print("Launching window", launchKey)
end

return openOrFocusWindow
