local logger = require("lib.logger")
local module = {}
local dock, element, failure, starting
local stopped = false

-- No app watcher reports the Dock relaunching, so each read checks the attached one still runs.
local function attached()
  if not (dock and dock:isRunning()) then
    dock = hs.application.applicationsForBundleID("com.apple.dock")[1]
    element, failure, starting = dock and hs.axuielement.applicationElement(dock), nil, true
  end
  return element ~= nil
end

-- macOS 27 posts no Dock AXExpose notifications.
function module.isActive()
  if stopped or not attached() then
    return false
  end
  assert(not failure, failure)
  local children, message = element:attributeValue("AXChildren")
  if type(children) ~= "table" then
    -- A relaunched Dock can't answer until it finishes starting.
    if starting then
      return false
    end
    failure = "Mission Control: " .. tostring(message or "Dock children unavailable")
    logger.error(failure)
    error(failure, 0)
  end
  starting = false
  for _, child in ipairs(children) do
    if child:attributeValue("AXIdentifier") == "mc" then
      return true
    end
  end
  return false
end

attached()
starting = false

function module.stop()
  stopped = true
  dock, element, failure = nil, nil, nil
end

return module
