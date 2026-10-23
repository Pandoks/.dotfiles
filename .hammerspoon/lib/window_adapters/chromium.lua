local logger = require("lib.logger")
local chromium = {}

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

---@class ChromiumProfile
---@field bundleID string
---@field profile string profile display name
---@field userDataDirectory? string defaults to ~/Library/Application Support/<bundleID>

---@param profile ChromiumProfile
---@return fun(url: string, report?: fun(message: string)): boolean
function chromium.url(profile)
  return function(url, report)
    report = report or logger.error
    local path = hs.application.pathForBundleID(profile.bundleID)
    local info = path and hs.application.infoForBundlePath(path) or nil --[[@as {CFBundleExecutable?: string}?]]
    local executable = info and info.CFBundleExecutable
    if not path or not executable then
      report("Could not resolve Chromium browser " .. profile.bundleID)
      return false
    end

    local data = profile.userDataDirectory
      or (os.getenv("HOME") .. "/Library/Application Support/" .. profile.bundleID)
    local directory = profileDirectory(data, profile.profile)
    if not directory then
      report("Chromium URL routing failed: missing profile " .. profile.profile)
      return false
    end

    local task = hs.task.new(path .. "/Contents/MacOS/" .. executable, function(code, _, message)
      if code ~= 0 then
        report("Chromium URL routing failed: " .. message)
      end
    end, { "--profile-directory=" .. directory, url })
    if not task or task:start() == false then
      report("Could not start Chromium URL handler")
      return false
    end
    return true
  end
end

return chromium
