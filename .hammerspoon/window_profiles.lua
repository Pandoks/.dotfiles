-- Focuses a window matching the profile, spawning it if none exists.
-- Handles both whole apps (no match = any window of the app) and specific
-- windows (match by forced title or custom function).
local YABAI = "/opt/homebrew/bin/yabai"

---@alias WindowMatcher string|(fun(title: string): boolean)

---@class WindowProfile
---@field bundleId string bundle id, e.g. "com.mitchellh.ghostty" (osascript -e 'id of app "<app>"'); one lookup returns every running instance
---@field match? WindowMatcher which window of the app; omit = any window
---@field spawnArgs string[] args for /usr/bin/open when no window matched, e.g. { "-b", bundle }

---Focus the profile's window, spawning it if it doesn't exist anywhere.
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

  ---nothing found
  local spawnKey = profile.bundleId
    .. "/"
    .. (type(profile.match) == "string" and profile.match or "*")
  if spawning[spawnKey] then
    print("Already spawning", spawnKey)
    return
  end
  spawning[spawnKey] = true
  ---measured: a spawned window is findable ~0.5s after open, and once it
  ---exists this guard is unobservable (searches find it first) -- so the
  ---duration only sets the retry delay after a failed launch. 3s = 6x margin
  hs.timer.doAfter(3, function()
    spawning[spawnKey] = nil
  end)

  hs.task
    .new("/usr/bin/open", function(exitCode)
      if exitCode ~= 0 then
        ---launch request itself failed (e.g. app not installed): retry instantly
        spawning[spawnKey] = nil
        print("Spawn failed", spawnKey)
      end
    end, profile.spawnArgs)
    :start()
  print("Spawned window", profile.bundleId)
end

return openOrFocusWindow
