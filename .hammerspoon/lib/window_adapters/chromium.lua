local logger = require("lib.logger")
local chromium = {}

---@alias ChromiumProfile { bundleID: string, profile: string } `profile` is the display name

---@type table<string, { signature: string, profiles: table<string, string> }>
local states = {}
---@type table<string, hs.pathwatcher>
local watchers = {}

---@param path string
---@return string?
local function signature(path)
  local attributes = hs.fs and hs.fs.attributes
  if not attributes then
    return nil
  end
  local info = attributes(path)
  if type(info) == "table" then
    return string.format(
      "%s:%s:%s:%s",
      tostring(info.ino),
      tostring(info.modification),
      tostring(info.change),
      tostring(info.size)
    )
  end
  local mtime = attributes(path, "modification")
  return type(mtime) == "number" and tostring(mtime) or nil
end

---@param path string
local function watch(path)
  if watchers[path] or not (hs.pathwatcher and hs.pathwatcher.new) then
    return
  end
  local dir = path:match("^(.+)/[^/]+$")
  if not dir then
    return
  end
  local watcher = hs.pathwatcher.new(dir, function(paths)
    for _, changed in ipairs(paths or {}) do
      if changed == path or changed:match("/Local State$") then
        states[path] = nil
        return
      end
    end
  end)
  if watcher then
    watcher:start()
    watchers[path] = watcher
  end
end

---@param profile ChromiumProfile
---@return string? directory
local function directory(profile)
  local path = os.getenv("HOME")
    .. "/Library/Application Support/"
    .. profile.bundleID
    .. "/Local State"
  local stamp = signature(path)
  local entry = stamp and states[path] or nil
  if entry and entry.signature == stamp then
    return entry.profiles[profile.profile]
  end
  local file = io.open(path, "r")
  if not file then
    states[path] = nil
    return nil
  end
  local decoded, state = pcall(hs.json.decode, file:read("a"))
  file:close()
  local profiles = {}
  local cache = decoded and type(state) == "table" and state.profile and state.profile.info_cache
    or {}
  for name, info in pairs(cache) do
    if type(info) == "table" and type(info.name) == "string" then
      profiles[info.name] = name
    end
  end
  if decoded and stamp then
    states[path] = { signature = stamp, profiles = profiles }
    watch(path)
  elseif not decoded then
    states[path] = nil
  end
  return profiles[profile.profile]
end

---@param profile ChromiumProfile
---@return fun(url: string, report?: fun(message: string)): boolean
function chromium.url(profile)
  return function(url, report)
    report = report or logger.error
    if not hs.application.pathForBundleID(profile.bundleID) then
      report("Could not resolve Chromium browser " .. profile.bundleID)
      return false
    end

    -- Without the profile, the browser picks the window, as it does for an unrouted link
    local arguments = { "-n", "-b", profile.bundleID, "--args", url }
    local name = directory(profile)
    if name then
      table.insert(arguments, 5, "--profile-directory=" .. name)
    end

    -- Survives reloads via LaunchServices; `-n`'s new instance hands its arguments to a running one
    local task = hs.task.new("/usr/bin/open", function(code, _, message)
      if code ~= 0 then
        report("Chromium URL routing failed: " .. message)
      end
    end, arguments)
    if not task or task:start() == false then
      report("Could not start Chromium URL handler")
      return false
    end
    return true
  end
end

-- With several profiles, Chromium titles each window "<page> - <browser> - <profile>"
---@param profile ChromiumProfile
---@return WindowProfile
function chromium.window(profile)
  local suffix = " - " .. profile.profile
  return {
    bundleId = profile.bundleID,
    match = function(title)
      -- Audible windows end in 🔊 or 🔇
      title = title:gsub(" 🔊$", ""):gsub(" 🔇$", "")
      return title:sub(-#suffix) == suffix
    end,
    args = function()
      local name = directory(profile)
      if not name then
        logger.error("Could not open Chromium window: missing profile " .. profile.profile)
        return nil
      end
      return { "--profile-directory=" .. name }
    end,
  }
end

return chromium
