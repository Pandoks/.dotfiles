local chromium = {}
local activeTasks = {}

local function readJson(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local contents = file:read("*a")
  file:close()

  local decoded, value = pcall(hs.json.decode, contents)
  return decoded and value or nil
end

---@param userDataDirectory string
---@param profileName string
---@return string?
local function profileDirectory(userDataDirectory, profileName)
  local state = readJson(userDataDirectory .. "/Local State")
  local infoCache = state and state.profile and state.profile.info_cache or {}
  for directory, profile in pairs(infoCache) do
    if profile.name == profileName then
      return directory
    end
  end
  return nil
end

local function lastUsedProfileDirectory(userDataDirectory, fallbackProfile)
  local state = readJson(userDataDirectory .. "/Local State")
  local profile = state and state.profile or {}
  local infoCache = profile.info_cache or {}
  local lastUsed = profile.last_used
  if type(lastUsed) == "string" and infoCache[lastUsed] then
    return lastUsed, infoCache[lastUsed].name or fallbackProfile
  end
  return profileDirectory(userDataDirectory, fallbackProfile), fallbackProfile
end

local function matchingProfile(rules, url)
  for _, rule in ipairs(rules) do
    if url:match(rule.pattern) then
      return rule.profile
    end
  end
  return nil
end

local function endsWith(value, suffix)
  return suffix == "" or value:sub(-#suffix) == suffix
end

local function focusExactWindow(window)
  local element = hs.axuielement.windowElement(window)
  if element then
    element:setAttributeValue("AXMain", true)
    element:setAttributeValue("AXFocused", true)
    element:performAction("AXRaise")
  end
end

local function openURLInWindow(window, titleSuffix, appName, url)
  focusExactWindow(window)
  local frame = window:frame()
  local title = window:title() or ""
  local pageTitle = endsWith(title, titleSuffix) and title:sub(1, -#titleSuffix - 1) or title
  local input = hs.json.encode({ appName = appName, pageTitle = pageTitle, url = url })
  local script = string.format(
    [[
      (() => {
        const input = %s;
        const app = Application(input.appName);
        const expected = { x: %f, y: %f, width: %f, height: %f };
        const expectedTitle = input.pageTitle.toLowerCase().replace(/[^a-z0-9]/g, "");
        const candidates = app.windows().map(window => {
          const bounds = window.bounds();
          const title = window.title().toLowerCase().replace(/[^a-z0-9]/g, "");
          let score = Math.abs(bounds.x - expected.x)
            + Math.abs(bounds.y - expected.y)
            + Math.abs(bounds.width - expected.width)
            + Math.abs(bounds.height - expected.height);
          if (title && (expectedTitle.startsWith(title) || title.startsWith(expectedTitle))) {
            score -= 10000;
          }
          return { window, score };
        }).sort((left, right) => left.score - right.score);
        if (!candidates.length || (candidates[1] && candidates[0].score === candidates[1].score)) {
          return false;
        }
        const target = candidates[0].window;
        target.tabs.push(app.Tab({ url: input.url }));
        target.activeTabIndex = target.tabs().length;
        target.index = 1;
        return true;
      })()
    ]],
    input,
    frame.x,
    frame.y,
    frame.w,
    frame.h
  )
  local success, opened = hs.osascript.javascript(script)
  if not success or opened ~= true then
    return false
  end
  focusExactWindow(window)
  return true
end

---@class ChromiumProfile
---@field bundleID string
---@field profile string profile display name
---@field space? integer Mission Control Space used when launching a new profile window
---@field userDataDirectory? string defaults to ~/Library/Application Support/<bundleID>

---@param profile ChromiumProfile
---@return AppTarget
function chromium.profile(profile)
  local bundlePath = hs.application.pathForBundleID(profile.bundleID)
  local info = bundlePath and hs.application.infoForBundlePath(bundlePath) or nil
  local appName = info and (info.CFBundleDisplayName or info.CFBundleName)
  local executable = info and info.CFBundleExecutable
  local userDataDirectory = profile.userDataDirectory
    or (os.getenv("HOME") .. "/Library/Application Support/" .. profile.bundleID)
  local titleSuffix = " - " .. (appName or "") .. " - " .. profile.profile

  return {
    bundleID = profile.bundleID,
    id = profile.bundleID .. ":" .. profile.profile,
    space = profile.space,
    match = function(window)
      return endsWith(window.title or "", titleSuffix)
    end,
    launch = function()
      local directory = profileDirectory(userDataDirectory, profile.profile)
      if not bundlePath or not executable or not directory then
        print("Could not resolve Chromium profile " .. profile.profile)
        return false
      end

      local executablePath = bundlePath .. "/Contents/MacOS/" .. executable
      local task = hs.task.new(executablePath, function(exitCode, _, stdErr)
        if exitCode ~= 0 then
          print("Chromium profile launch failed: " .. stdErr)
        end
      end, { "--profile-directory=" .. directory, "--new-window" })
      return task ~= nil and task:start() ~= false
    end,
  }
end

---@class ChromiumURLRouter
---@field bundleID string
---@field fallbackProfile string profile display name used when Chromium has no valid last-used profile
---@field rules? ChromiumURLRule[] first matching Lua pattern wins
---@field userDataDirectory? string defaults to ~/Library/Application Support/<bundleID>

---@class ChromiumURLRule
---@field pattern string Lua pattern matched against the complete URL
---@field profile string profile display name

---@param router ChromiumURLRouter
---@return boolean
function chromium.installURLRouter(router)
  local bundlePath = hs.application.pathForBundleID(router.bundleID)
  local info = bundlePath and hs.application.infoForBundlePath(bundlePath) or nil
  local executable = info and info.CFBundleExecutable
  if not bundlePath or not executable then
    print("Could not resolve Chromium browser " .. router.bundleID)
    return false
  end

  local executablePath = bundlePath .. "/Contents/MacOS/" .. executable
  local appName = info.CFBundleDisplayName or info.CFBundleName or executable
  local userDataDirectory = router.userDataDirectory
    or (os.getenv("HOME") .. "/Library/Application Support/" .. router.bundleID)
  local rules = router.rules or {}
  local browserWindows = hs.window.filter.new(appName)
  local focusGuard

  local function stopFocusGuard()
    if focusGuard and focusGuard.timer then
      focusGuard.timer:stop()
    end
    focusGuard = nil
  end

  browserWindows:subscribe(hs.window.filter.windowFocused, function(window)
    if not window then
      return
    end

    local guard = focusGuard
    if guard and window:id() ~= guard.window:id() then
      focusExactWindow(guard.window)
    end
  end)

  for index, rule in ipairs(rules) do
    local valid = type(rule.pattern) == "string"
      and type(rule.profile) == "string"
      and pcall(string.match, "", rule.pattern)
    if not valid then
      print("Invalid Chromium URL rule " .. index)
      return false
    end
  end

  local function routeURL(fullURL)
    if type(fullURL) ~= "string" or not fullURL:match("^https?://") then
      return false
    end

    local matchedProfile = matchingProfile(rules, fullURL)
    local directory = matchedProfile and profileDirectory(userDataDirectory, matchedProfile)
    local targetProfile = matchedProfile
    if not directory then
      directory, targetProfile = lastUsedProfileDirectory(userDataDirectory, router.fallbackProfile)
    end
    if not directory then
      print("Could not resolve Chromium profile")
      hs.urlevent.openURLWithBundle(fullURL, router.bundleID)
      return false
    end

    local targetWindow
    local titleSuffix = " - " .. appName .. " - " .. targetProfile
    for _, window in ipairs(browserWindows:getWindows(hs.window.filter.sortByFocusedLast)) do
      if endsWith(window:title() or "", titleSuffix) then
        targetWindow = window
        break
      end
    end

    local function openURLWithExecutable()
      local task
      task = hs.task.new(
        executablePath,
        function(exitCode, _, stdErr)
          activeTasks[task] = nil
          if exitCode ~= 0 then
            print("Chromium URL routing failed: " .. (stdErr or "unknown error"))
          end
        end,
        { "--profile-directory=" .. directory, fullURL }
      )
      if not task or task:start() == false then
        print("Could not start Chromium URL handler")
        hs.urlevent.openURLWithBundle(fullURL, router.bundleID)
        return false
      end
      activeTasks[task] = true
      return true
    end

    if targetWindow then
      stopFocusGuard()
      focusGuard = { window = targetWindow }
      focusGuard.timer = hs.timer.doAfter(3, stopFocusGuard)
      if openURLInWindow(targetWindow, titleSuffix, appName, fullURL) then
        return true
      end
      stopFocusGuard()
    end
    return openURLWithExecutable()
  end

  RouteHTTPURL = routeURL
  hs.urlevent.httpCallback = function(_, _, _, fullURL)
    routeURL(fullURL)
  end
  return true
end

return chromium
