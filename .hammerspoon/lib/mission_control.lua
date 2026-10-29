local logger = require("lib.logger")
local module = {}
local element, pid, failure
local stopped = false

---@param dock? hs.application
local function attach(dock)
  element, pid, failure = nil, nil, nil
  if dock then
    element, pid = hs.axuielement.applicationElement(dock), dock:pid()
  end
end

-- macOS 27 posts no Dock AXExpose notifications.
function module.isActive()
  assert(not failure, failure)
  if stopped or not element then
    return false
  end
  local children, message = element:attributeValue("AXChildren")
  if type(children) ~= "table" then
    failure = "Mission Control: " .. tostring(message or "Dock children unavailable")
    logger.error(failure)
    error(failure, 0)
  end
  for _, child in ipairs(children) do
    if child:attributeValue("AXIdentifier") == "mc" then
      return true
    end
  end
  return false
end

module.watcher = hs.application.watcher
  .new(function(_, event, app)
    if stopped or not app then
      return
    end
    if event == hs.application.watcher.terminated and app:pid() == pid then
      attach(nil)
    elseif event == hs.application.watcher.launched and app:bundleID() == "com.apple.dock" then
      attach(app)
    end
  end)
  :start() --[[@as hs.application.watcher]]
attach(hs.application.applicationsForBundleID("com.apple.dock")[1])

function module.stop()
  stopped = true
  module.watcher:stop()
  attach(nil)
end

return module
