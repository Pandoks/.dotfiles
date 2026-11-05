local logger = require("lib.logger")
local chromium = {}

---@param profile { bundleID: string, profile: string } `profile` is the display name
---@return fun(url: string, report?: fun(message: string)): boolean
function chromium.url(profile)
  return function(url, report)
    report = report or logger.error
    if not hs.application.pathForBundleID(profile.bundleID) then
      report("Could not resolve Chromium browser " .. profile.bundleID)
      return false
    end

    -- Find the profile's directory by display name
    local directory
    local path = os.getenv("HOME") .. "/Library/Application Support/" .. profile.bundleID
    local file = io.open(path .. "/Local State", "r")
    if file then
      local decoded, state = pcall(hs.json.decode, file:read("a"))
      file:close()
      local cache = decoded and state and state.profile and state.profile.info_cache or {}
      for name, info in pairs(cache) do
        if info.name == profile.profile then
          directory = name
          break
        end
      end
    end
    if not directory then
      report("Chromium URL routing failed: missing profile " .. profile.profile)
      return false
    end

    -- Survives reloads via LaunchServices; `-n`'s new instance hands its arguments to a running one
    local task = hs.task.new("/usr/bin/open", function(code, _, message)
      if code ~= 0 then
        report("Chromium URL routing failed: " .. message)
      end
    end, { "-n", "-b", profile.bundleID, "--args", "--profile-directory=" .. directory, url })
    if not task or task:start() == false then
      report("Could not start Chromium URL handler")
      return false
    end
    return true
  end
end

return chromium
