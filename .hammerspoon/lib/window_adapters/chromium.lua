local logger = require("lib.logger")
local chromium = {}

---@alias ChromiumProfile { bundleID: string, profile: string } `profile` is the display name

---@type table<string, { mtime: number, profiles: table<string, string> }>
local states = {}

---@param profile ChromiumProfile
---@return string? directory
local function directory(profile)
  local path = os.getenv("HOME")
    .. "/Library/Application Support/"
    .. profile.bundleID
    .. "/Local State"
  local mtime = hs.fs and hs.fs.attributes and hs.fs.attributes(path, "modification")
  local entry = type(mtime) == "number" and states[path] or nil
  if entry and entry.mtime == mtime then
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
  if decoded and type(mtime) == "number" then
    states[path] = { mtime = mtime, profiles = profiles }
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

    local name = directory(profile)
    if not name then
      report("Chromium URL routing failed: missing profile " .. profile.profile)
      return false
    end

    -- Survives reloads via LaunchServices; `-n`'s new instance hands its arguments to a running one
    local task = hs.task.new("/usr/bin/open", function(code, _, message)
      if code ~= 0 then
        report("Chromium URL routing failed: " .. message)
      end
    end, { "-n", "-b", profile.bundleID, "--args", "--profile-directory=" .. name, url })
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
